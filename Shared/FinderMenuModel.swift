import Foundation

/// A bounded URL-only hint for menu presentation. Deferred selections are always
/// resolved in full during background preparation and again before any write or handoff.
public enum FinderMenuSelectionPreflight {
    public enum Result: Equatable {
        case sameParent, differentParents, deferred
    }

    public static let maximumInspectedItems = 256

    public static func check(_ selectedURLs: [URL]) -> Result {
        guard selectedURLs.count > 1, let first = selectedURLs.first else { return .sameParent }
        let parent = first.deletingLastPathComponent().absoluteString
        for url in selectedURLs.dropFirst().prefix(maximumInspectedItems - 1) {
            if url.deletingLastPathComponent().absoluteString != parent { return .differentParents }
        }
        return selectedURLs.count > maximumInspectedItems ? .deferred : .sameParent
    }
}

public struct FinderTemplateMenuEntry: Equatable, Identifiable, Sendable {
    public let id: FileTemplate.ID
    private static let untitledNames = Dictionary(uniqueKeysWithValues: QuickFileLanguage.supportedIdentifiers.map {
        ($0, String(localized: "未命名模板", bundle: QuickFileLocalization.resourceBundle(for: $0)))
    })
    public static func prepareLocalization() { _ = untitledNames }
    private let storedName: String
    private let isNameEmpty: Bool
    private let fileExtension: String

    public var title: String {
        let name = BuiltInTemplates.displayName(id: id, storedName: storedName)
        let displayName = isNameEmpty ? Self.untitledNames[QuickFileLocalization.identifier]! : name
        return fileExtension.isEmpty ? displayName : "\(displayName) (.\(fileExtension))"
    }

    /// A menu owns display metadata only. Creation resolves this ID against a
    /// fresh authoritative load; no menu entry keeps a template body alive.
    public init(template: FileTemplate) {
        id = template.id
        // Older stored templates can bypass draft validation. Keep their identity and
        // contents intact while removing controls from the display projection.
        storedName = template.name.components(separatedBy: TemplateNameCharacters.forbiddenControls).joined()
        isNameEmpty = storedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        fileExtension = template.fileExtension
            .components(separatedBy: TemplateNameCharacters.forbiddenFilenameCharacters).joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
    }
}

public struct FinderMenuModelBuilder {
    public init() {}

    public func entries(from templates: [FileTemplate], limit: FinderMenuDisplayLimit = .all) -> [FinderTemplateMenuEntry] {
        presentation(from: templates, limit: limit).entries
    }

    public func presentation(from templates: [FileTemplate], limit: FinderMenuDisplayLimit = .all) -> FinderTemplateMenuPresentation {
        buildPresentation(from: templates, limit: limit)
    }

    /// The cache has already removed disabled templates. Apply display preferences
    /// to its immutable metadata without reloading or retaining template contents.
    public func presentation(fromEntries entries: [FinderTemplateMenuEntry], limit: FinderMenuDisplayLimit = .all) -> FinderTemplateMenuPresentation {
        FinderTemplateMenuPresentation(entries: Array(entries.prefix(limit.maximumCount ?? Int.max)))
    }

    // Sequence input lets tests verify how far the production builder consumes its input.
    func buildPresentation<Templates: Sequence>(
        from templates: Templates, limit: FinderMenuDisplayLimit
    ) -> FinderTemplateMenuPresentation where Templates.Element == FileTemplate {
        var entries: [FinderTemplateMenuEntry] = []
        let maximumCount = limit.maximumCount ?? Int.max
        for template in templates where template.isEnabled {
            entries.append(FinderTemplateMenuEntry(template: template))
            if entries.count == maximumCount { break }
        }
        return FinderTemplateMenuPresentation(entries: entries)
    }
}

public struct FinderTemplateMenuPresentation: Equatable, Sendable {
    public let entries: [FinderTemplateMenuEntry]
}

public struct FinderMenuAction: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case directory(URL)
        case selection(targetedURL: URL?, selectedItemURLs: [URL])
    }

    public let templateID: FileTemplate.ID
    public let context: FinderMenuContext
    public let target: Target
    public let preparedDestination: FinderMenuDestination?
    /// Opt-in trace identity for the menu that registered this action.
    public let menuTimingID: String?

    public init(
        templateID: FileTemplate.ID,
        context: FinderMenuContext,
        destinationFolder: URL,
        destinationIdentity: DirectoryIdentity? = nil,
        menuTimingID: String? = nil
    ) {
        self.templateID = templateID
        self.context = context
        self.menuTimingID = menuTimingID
        self.target = .directory(destinationFolder.standardizedFileURL)
        self.preparedDestination = destinationIdentity.map {
            FinderMenuDestination(folder: destinationFolder, identity: $0)
        }
    }

    /// Captures only values. Without a prepared destination this is deliberately not executable.
    public init(
        templateID: FileTemplate.ID,
        context: FinderMenuContext,
        targetedURL: URL?,
        selectedItemURLs: [URL],
        preparedDestination: FinderMenuDestination? = nil,
        menuTimingID: String? = nil
    ) {
        self.templateID = templateID
        self.context = context
        self.menuTimingID = menuTimingID
        let capturedSelection: [URL]
        if context == .container || (context == .toolbar && targetedURL != nil) {
            // Resolution ignores this selection. Preserve its original first URL for
            // scheduler admission without retaining the unused array or its tail.
            capturedSelection = selectedItemURLs.first.map { [$0] } ?? []
        } else {
            capturedSelection = selectedItemURLs
        }
        self.target = .selection(targetedURL: targetedURL, selectedItemURLs: capturedSelection)
        self.preparedDestination = preparedDestination
    }
}

// All mutable state is protected by the lock; returned actions are immutable values.
public final class FinderMenuActionRegistry: @unchecked Sendable {
    private let retainedGenerationCount: Int
    private let lock = NSLock()
    private var nextTag = 1
    private var actions: [Int: FinderMenuAction] = [:]
    private var menuTagGenerations: [[Int]] = []

    public init(retainedGenerationCount: Int = 3) {
        self.retainedGenerationCount = max(1, retainedGenerationCount)
    }

    /// Register and evict whole menus under one lock. Concurrent menu builders
    /// cannot append their actions to another menu's generation.
    public func registerMenu(_ menuActions: [FinderMenuAction]) -> [Int] {
        lock.lock()
        defer { lock.unlock() }

        let tags = menuActions.map { action in
            let tag = makeTag()
            actions[tag] = action
            return tag
        }
        menuTagGenerations.append(tags)
        if menuTagGenerations.count > retainedGenerationCount {
            for tag in menuTagGenerations.removeFirst() {
                actions.removeValue(forKey: tag)
            }
        }
        return tags
    }

    public func takeAction(for tag: Int) -> FinderMenuAction? {
        lock.lock()
        defer { lock.unlock() }

        return actions.removeValue(forKey: tag)
    }

    private func makeTag() -> Int {
        while actions[nextTag] != nil {
            nextTag = incrementedTag(after: nextTag)
        }

        let tag = nextTag
        nextTag = incrementedTag(after: nextTag)
        return tag
    }

    private func incrementedTag(after tag: Int) -> Int {
        tag == Int.max ? 1 : tag + 1
    }
}
