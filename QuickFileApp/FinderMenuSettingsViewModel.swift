import Combine
import Foundation
import QuickFileCore
import QuickFileInfrastructure

@MainActor
final class FinderMenuSettingsViewModel: ObservableObject {
    enum Status: Equatable {
        case success(String)
        case failure(String)
    }

    @Published var showsAll = true {
        didSet { if oldValue != showsAll { draftDidChange() } }
    }
    @Published var maximumCountText = "" {
        didSet { if oldValue != maximumCountText { draftDidChange() } }
    }
    @Published private(set) var savedLimit: FinderMenuDisplayLimit = .all
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var loadError: String?
    @Published private(set) var status: Status?

    private let loadSetting: @Sendable () throws -> FinderMenuDisplayLimit
    private let saveSetting: @Sendable (FinderMenuDisplayLimit) throws -> Void
    private var didAttemptInitialLoad = false
    private var draftGeneration: UInt64 = 0

    // Neither initialization nor an injected fixture touches production preferences.
    // The default store is constructed only when BackgroundWork runs an operation.
    init(
        load: @escaping @Sendable () throws -> FinderMenuDisplayLimit = {
            try FinderMenuSettingsStore().load()
        },
        save: @escaping @Sendable (FinderMenuDisplayLimit) throws -> Void = {
            try FinderMenuSettingsStore().save($0)
        }
    ) {
        loadSetting = load
        saveSetting = save
    }

    var canEdit: Bool {
        // A failed read leaves a visible warning, but an explicit save may repair
        // malformed storage. Never enable writes before the first read finishes.
        (hasLoaded || loadError != nil) && !isLoading && !isSaving
    }

    var canSave: Bool {
        guard canEdit else { return false }
        // Keep Save available for invalid drafts so validation explains the problem.
        guard let draft = try? draftLimit() else { return true }
        return loadError != nil || draft != savedLimit
    }

    var savedSummary: String {
        if let count = savedLimit.maximumCount {
            return "已保存：最多 \(count) 个模板"
        }
        return "已保存：全部模板"
    }

    func loadIfNeeded() async {
        guard !hasLoaded, !didAttemptInitialLoad else { return }
        didAttemptInitialLoad = true
        await reload()
    }

    func reload() async {
        // Reads and writes are mutually exclusive: an old read cannot finish after
        // a newer save and overwrite the saved value or the editor's draft.
        guard !isLoading, !isSaving else { return }
        isLoading = true
        status = nil
        defer { isLoading = false }
        let generation = draftGeneration
        let load = loadSetting
        let result = await BackgroundWork.result { try load() }
        switch result {
        case let .success(value):
            savedLimit = value
            hasLoaded = true
            loadError = nil
            if generation == draftGeneration { replaceDraft(with: value) }
            status = nil
        case let .failure(error):
            // Retain the last successful value; retry or explicit Save can recover.
            loadError = error.localizedDescription
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard canEdit else { return false }
        let value: FinderMenuDisplayLimit
        do {
            value = try draftLimit()
        } catch {
            status = .failure(error.localizedDescription)
            return false
        }
        guard value != savedLimit || loadError != nil else { return true }

        isSaving = true
        status = nil
        defer { isSaving = false }
        let generation = draftGeneration
        let save = saveSetting
        let result = await BackgroundWork.result { try save(value) }
        switch result {
        case .success:
            savedLimit = value
            hasLoaded = true
            loadError = nil
            if generation == draftGeneration {
                replaceDraft(with: value)
                status = .success("Finder 菜单设置已保存。")
            }
            return true
        case let .failure(error):
            // Keep the failed draft for retry, without changing the committed value.
            status = .failure(error.localizedDescription)
            return false
        }
    }

    private func draftLimit() throws -> FinderMenuDisplayLimit {
        if showsAll { return .all }
        return try FinderMenuDisplayLimit.parse(maximumCountText)
    }

    private func replaceDraft(with value: FinderMenuDisplayLimit) {
        showsAll = value.maximumCount == nil
        maximumCountText = value.maximumCount.map(String.init) ?? ""
    }

    private func draftDidChange() {
        draftGeneration &+= 1
        status = nil
    }
}
