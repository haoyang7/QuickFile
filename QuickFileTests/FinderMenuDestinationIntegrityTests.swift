import XCTest
@testable import QuickFileCore
@testable import QuickFileApplication
@testable import QuickFileInfrastructure

/// The same before-click fixtures can be copied to the unmodified baseline and run with
/// -D QUICKFILE_LEGACY_MENU_ACTIONS. Only menu preparation changes in that comparison;
/// the replacement, parent grant, coordinator, real writer, and assertions are identical.
final class FinderMenuDestinationIntegrityTests: XCTestCase {
    func testMenuRejectsOrdinaryDirectoryReplacementBeforeClickUnderParentGrant() throws {
        try assertReplacementBeforeClick(retargetsSymlink: false)
    }

    func testMenuRejectsSymlinkRetargetBeforeClickUnderParentGrant() throws {
        try assertReplacementBeforeClick(retargetsSymlink: true)
    }

    func testUnchangedPreparedMenuCreatesWithParentGrantDespiteUnrelatedDirectoryChanges() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "prepared content")
        let registry = FinderMenuActionRegistry()
        let tag = try prepareMenu(registry, template: template, target: target)
        // Directory modification time is not its identity.
        try Data("sentinel".utf8).write(to: target.appendingPathComponent("existing.txt"))
        let (store, defaults, suite) = try parentGrant(root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = coordinator(template, store: store)
        let result = try coordinator.createFile(for: XCTUnwrap(registry.takeAction(for: tag)))
        XCTAssertEqual(result.fileURL.deletingLastPathComponent().resolvingSymlinksInPath(), target.resolvingSymlinksInPath())
        XCTAssertEqual(try String(contentsOf: result.fileURL), "prepared content")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("existing.txt")), "sentinel")
    }

    #if !QUICKFILE_LEGACY_MENU_ACTIONS
    func testLegacyURLOnlyActionsFailClosedBeforeMetadataTemplatesOrAccess() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "")
        let actions = [
            FinderMenuAction(templateID: template.id, context: .container, destinationFolder: root),
            FinderMenuAction(templateID: template.id, context: .items, targetedURL: root, selectedItemURLs: [root])
        ]
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in XCTFail("An unprepared menu must not load templates"); return template },
            performWithAccess: { _, operation in XCTFail("An unprepared menu must not request access"); return try operation() },
            createFile: { _ in XCTFail("An unprepared menu must not write"); throw FinderFileCreationError.destinationUnavailable },
            requiresAuthorization: { _ in XCTFail("An unprepared menu must not offer authorization"); return false },
            resolveSelection: { _, _, _ in XCTFail("An unprepared action must not resolve a replacement"); return root }
        )
        for action in actions {
            XCTAssertThrowsError(try coordinator.createFile(for: action)) {
                XCTAssertEqual($0 as? FinderFileCreationError, .destinationUnavailable)
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testNewMenuForReplacementDoesNotRebindOlderRegisteredMenu() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target")
        let moved = root.appendingPathComponent("Original")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "new menu")
        let registry = FinderMenuActionRegistry()
        let oldTag = try prepareMenu(registry, template: template, target: target)
        try FileManager.default.moveItem(at: target, to: moved)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let newTag = try prepareMenu(registry, template: template, target: target)
        let (store, defaults, suite) = try parentGrant(root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = coordinator(template, store: store)
        XCTAssertThrowsError(try coordinator.createFile(for: XCTUnwrap(registry.takeAction(for: oldTag)))) {
            guard case FileCreationError.destinationIdentityChanged = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        let result = try coordinator.createFile(for: XCTUnwrap(registry.takeAction(for: newTag)))
        XCTAssertEqual(try String(contentsOf: result.fileURL), "new menu")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).count, 1)
    }
    #endif

    private func assertReplacementBeforeClick(retargetsSymlink: Bool) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("A")
        let original = root.appendingPathComponent("Original")
        let other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        if retargetsSymlink {
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
        } else {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        }
        let (store, defaults, suite) = try parentGrant(root)
        defer { defaults.removePersistentDomain(forName: suite) }
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "must not be written")
        let registry = FinderMenuActionRegistry()
        let tag = try prepareMenu(registry, template: template, target: target)
        if retargetsSymlink {
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        } else {
            try FileManager.default.moveItem(at: target, to: original)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        }
        // Prove the existing parent grant covers the replacement; authorization alone
        // cannot reject this fixture. No writer is invoked in this control operation.
        _ = try store.withAccess(to: target) {
            FileCreationResult(fileURL: target, didRenameForConflict: false)
        }
        let coordinator = coordinator(template, store: store)
        XCTAssertThrowsError(try coordinator.createFile(for: XCTUnwrap(registry.takeAction(for: tag)))) {
            guard case FileCreationError.destinationIdentityChanged = $0 else {
                return XCTFail("Expected rejection of the menu's original identity, got \($0)")
            }
        }
        for folder in [target, original, other] {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty,
                          "No output or temporary files may appear in \(folder.lastPathComponent)")
        }
    }

    private func prepareMenu(_ registry: FinderMenuActionRegistry, template: FileTemplate, target: URL) throws -> Int {
        #if QUICKFILE_LEGACY_MENU_ACTIONS
        return registry.registerMenu([FinderMenuAction(templateID: template.id, context: .items, targetedURL: target, selectedItemURLs: [target])])[0]
        #else
        let selection = FinderMenuSelection(context: .items, targetedURL: target, selectedItemURLs: [target])
        let cache = FinderMenuDestinationCache()
        XCTAssertEqual(cache.currentSnapshot(for: selection), .loading)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while cache.activePreparationCount != 0, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard case let .ready(destination)? = cache.cachedSnapshot(for: selection) else {
            XCTFail("Menu preparation did not finish")
            throw FinderFileCreationError.destinationUnavailable
        }
        return registry.registerMenu([FinderMenuAction(templateID: template.id, context: .items, targetedURL: target,
                                 selectedItemURLs: [target], preparedDestination: destination)])[0]
        #endif
    }

    private func coordinator(_ template: FileTemplate, store: AuthorizedDirectoryStore) -> FinderFileCreationCoordinator {
        FinderFileCreationCoordinator(
            loadTemplate: { _ in template },
            performWithAccess: { url, operation in try store.withAccess(to: url, perform: operation) },
            createFile: { try FileCreationService().createFile(for: $0) },
            requiresAuthorization: { AuthorizedDirectoryFailureClassifier.requiresAuthorization($0) }
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func parentGrant(_ root: URL) throws -> (AuthorizedDirectoryStore, UserDefaults, String) {
        let suite = "QuickFileTests.MenuIntegrity.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let resolve: AuthorizedDirectoryStore.BookmarkResolver = { data in
            let path = try XCTUnwrap(String(data: data, encoding: .utf8))
            return ResolvedSecurityScopedBookmark(url: URL(fileURLWithPath: path), isStale: false)
        }
        let store = AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: root.appendingPathComponent("Grants"),
            persistentBookmarkCreator: { Data($0.path.utf8) }, transferBookmarkCreator: { Data($0.path.utf8) },
            persistentBookmarkResolver: resolve, transferBookmarkResolver: resolve,
            startAccessing: { _ in true }, stopAccessing: { _ in }
        )
        try store.authorize(root)
        return (store, defaults, suite)
    }
}
