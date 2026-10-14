import XCTest
import Darwin
import os
import QuickFileCore
@testable import QuickFileInfrastructure

final class LocalSharedStorageTests: XCTestCase {
    private var directory: URL!
    private var storage: LocalSharedStorage!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent(".build/Temporary/community-storage-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        directory = directory.resolvingSymlinksInPath()
        storage = LocalSharedStorage(root: directory.appendingPathComponent("shared"))
    }

    override func tearDownWithError() throws {
        if let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in entries where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
        }
        try FileManager.default.removeItem(at: directory)
    }

    private var libraryURL: URL { storage.root.appendingPathComponent("templates.v2.json") }
    private var markerURL: URL { storage.root.appendingPathComponent("templates.persistence.v1.json") }

    private func templates(defaults: UserDefaults? = nil,
                           write: (@Sendable (Data, URL) throws -> Void)? = nil) -> TemplateStore {
        let backend = storage!
        return TemplateStore(defaults: defaults, storageURL: libraryURL, localStorage: backend,
                             writeTemplatesData: write ?? { try backend.write($0, to: $1) },
                             readTemplatesData: { try backend.read($0) })
    }

    func testStorageModeMustMatchTheCompiledProduct() {
        XCTAssertTrue(QuickFileSharedStorage.configurationMatches(["QuickFileStorageMode": QuickFileStorageMode.current.rawValue]))
        XCTAssertFalse(QuickFileSharedStorage.configurationMatches([:]))
        XCTAssertFalse(QuickFileSharedStorage.configurationMatches(["QuickFileStorageMode": true]))
        for oldMode in ["community", "app-group"] {
            XCTAssertFalse(QuickFileSharedStorage.configurationMatches(["QuickFileStorageMode": oldMode]))
        }
        for channel in ["community", "developer-id", "development"] {
            XCTAssertTrue(QuickFileSharedStorage.configurationMatches([
                "QuickFileStorageMode": "local-shared", "QuickFileDistributionChannel": channel
            ]))
        }
        XCTAssertNil(QuickFileSharedStorage.legacyDefaults())
        XCTAssertEqual(QuickFileSharedStorage.directoryName, "QuickFileCommunity")
    }

    func testTemplatesPersistWithoutSharedDefaultsAndDoNotReadPoisonedLegacyData() throws {
        let name = "QuickFileCommunityTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("bad legacy".utf8), forKey: "templates.v1")
        defaults.set("legacy-revision", forKey: "templates.revision.v2")
        let store = templates(defaults: defaults)
        let baseline = try store.loadTemplates()
        XCTAssertEqual(baseline, BuiltInTemplates.all)
        let custom = [FileTemplate(name: "Community", fileExtension: "txt", content: "saved")]
        try store.saveTemplates(custom, expectedTemplates: baseline)
        XCTAssertEqual(try templates().reloadTemplates(), custom)
        XCTAssertEqual(try store.reloadCreationSnapshot(templateID: custom[0].id).template, custom[0])
        XCTAssertEqual(try store.reloadMenuEntries().count, 1)
        XCTAssertEqual(defaults.string(forKey: "templates.revision.v2"), "legacy-revision")
        XCTAssertEqual(defaults.data(forKey: "templates.v1"), Data("bad legacy".utf8))
        XCTAssertEqual(try storage.read(markerURL), Data("{\"version\":1}".utf8))
    }

    func testMissingSavedLibraryRequiresRecoveryAndPreservesMarkerInBackup() throws {
        let store = templates()
        try store.saveTemplates([], expectedTemplates: BuiltInTemplates.all)
        try storage.remove(libraryURL)
        XCTAssertThrowsError(try store.loadTemplates()) { error in
            guard case TemplateStore.StoreError.savedConfigurationMissing = error else { return XCTFail("\(error)") }
        }
        let recovery = try store.prepareRecovery()
        XCTAssertEqual(recovery.reason, .missingSavedConfiguration)
        let result = try store.recoverTemplates(BuiltInTemplates.all, expectedRecoveryState: recovery)
        XCTAssertEqual(try Data(contentsOf: result.backupURL.appendingPathComponent("persistence.original.json")),
                       try storage.read(markerURL))
        XCTAssertEqual(try templates().reloadTemplates(), BuiltInTemplates.all)
    }

    func testInterruptedFirstSaveCannotLookLikeFirstUse() throws {
        let failing = templates(write: { _, _ in throw POSIXError(.ENOSPC) })
        XCTAssertThrowsError(try failing.saveTemplates([], expectedTemplates: BuiltInTemplates.all))
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryURL.path))
        XCTAssertThrowsError(try templates().reloadTemplates()) { error in
            guard case TemplateStore.StoreError.savedConfigurationMissing = error else { return XCTFail("\(error)") }
        }
    }

    func testMarkerFailurePreventsPayloadPublication() throws {
        try storage.prepare(markerURL)
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let store = templates(write: { _, _ in writes.withLock { $0 += 1 } })
        XCTAssertThrowsError(try store.saveTemplates([], expectedTemplates: BuiltInTemplates.all))
        XCTAssertEqual(writes.withLock { $0 }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryURL.path))
    }

    func testRecoveryDetectsMarkerChangesAndExportProtectsMarkerAliases() throws {
        let store = templates()
        try store.saveTemplates([], expectedTemplates: BuiltInTemplates.all)
        XCTAssertThrowsError(try store.validateExportDestination(markerURL))
        let alias = directory.appendingPathComponent("marker-alias")
        try FileManager.default.linkItem(at: markerURL, to: alias)
        XCTAssertThrowsError(try store.validateExportDestination(alias))
        try FileManager.default.removeItem(at: alias)
        try storage.write(Data("broken".utf8), to: libraryURL)
        let snapshot = try store.prepareRecovery()
        try storage.write(Data("{\"version\":1,\"changed\":true}".utf8), to: markerURL)
        XCTAssertThrowsError(try store.recoverTemplates([], expectedRecoveryState: snapshot)) { error in
            guard case TemplateStore.RecoveryError.configurationChanged = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try storage.read(libraryURL), Data("broken".utf8))
    }

    func testConcurrentTemplateSavesUseCAS() throws {
        let original = try templates().loadTemplates()
        let first = templates(), second = templates()
        let successes = OSAllocatedUnfairLock(initialState: 0)
        let conflicts = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                try (index == 0 ? first : second).saveTemplates(
                    [FileTemplate(name: "writer \(index)", fileExtension: "txt", content: "")], expectedTemplates: original)
                successes.withLock { $0 += 1 }
            } catch TemplateStore.StoreError.configurationChanged { conflicts.withLock { $0 += 1 } }
            catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(successes.withLock { $0 }, 1)
        XCTAssertEqual(conflicts.withLock { $0 }, 1)
        XCTAssertEqual(try templates().reloadTemplates().count, 1)
    }

    func testAuthorizationQueueActivityAndMenuUseOnlyCommunityFiles() throws {
        let repository = AuthorizedDirectoryRepository(containerURL: storage.root, localStorage: storage)
        let legacy = storage.root.appendingPathComponent("Library/Preferences/" + QuickFileConfiguration.appGroupIdentifier + ".plist")
        try storage.write(Data("poisoned legacy plist".utf8), to: legacy)
        XCTAssertEqual(try repository.load().count, 0)
        let authorization = StoredDirectoryAuthorization(id: UUID(), persistentBookmarkData: Data([1]), transferBookmarkData: Data([2]))
        try repository.update { $0.append(authorization) }
        XCTAssertTrue(try repository.contains(authorization))
        try repository.update { $0.removeAll() }
        XCTAssertFalse(try repository.contains(authorization))
        XCTAssertEqual(try storage.read(legacy), Data("poisoned legacy plist".utf8))

        let queue = FinderAuthorizationRequestStore(defaults: nil,
            directoryURL: storage.root.appendingPathComponent("finder-authorization-requests"), localStorage: storage)
        let request = FinderAuthorizationRequest(templateID: UUID(), destinationFolder: directory)
        try queue.save(request)
        XCTAssertEqual(try queue.takePendingRequest(), request)
        XCTAssertNil(try queue.takePendingRequest())

        let activity = FinderExtensionActivityStore(defaults: nil,
            failureHistoryFileURL: storage.root.appendingPathComponent("activity.json"), localStorage: storage)
        XCTAssertTrue(activity.isAvailable)
        try activity.record(.launched)
        XCTAssertEqual(activity.latestActivity()?.kind, .launched)
        XCTAssertEqual(try activity.recentFailures().count, 0)
        let menu = FinderMenuSettingsStore(localStorage: storage)
        XCTAssertEqual(try menu.load(), .all)
        try menu.save(FinderMenuDisplayLimit(maximumCount: 5))
        XCTAssertEqual(try FinderMenuSettingsStore(localStorage: storage).load().maximumCount, 5)
    }

    func testPrivateModesBoundedReadsAndUnsafeEntries() throws {
        let file = storage.root.appendingPathComponent("value")
        try storage.write(Data("value".utf8), to: file)
        var status = stat()
        XCTAssertEqual(lstat(storage.root.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(file.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)
        XCTAssertEqual(try storage.read(file, maximumBytes: 5), Data("value".utf8))
        XCTAssertThrowsError(try storage.read(file, maximumBytes: 4))
        let link = storage.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try storage.read(link))
        XCTAssertThrowsError(try storage.write(Data(), to: link))
        XCTAssertThrowsError(try storage.withLock(at: link) {})
        let fifo = storage.root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try storage.read(fifo))
        XCTAssertEqual(try storage.read(file), Data("value".utf8))
    }

    func testNonPrivateTemplatesAndRequestsAreNotReadOrConsumed() throws {
        let store = templates()
        try store.saveTemplates([], expectedTemplates: BuiltInTemplates.all)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: libraryURL.path)
        XCTAssertThrowsError(try store.changeToken())
        XCTAssertThrowsError(try store.reloadTemplates())
        XCTAssertThrowsError(try store.prepareRecovery())

        let queueDirectory = storage.root.appendingPathComponent("finder-authorization-requests")
        let queue = FinderAuthorizationRequestStore(defaults: nil, directoryURL: queueDirectory, localStorage: storage)
        let request = FinderAuthorizationRequest(templateID: UUID(), destinationFolder: directory)
        try queue.save(request)
        let requestURL = queueDirectory.appendingPathComponent(request.id.uuidString + ".json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: requestURL.path)
        XCTAssertThrowsError(try queue.takePendingRequest())
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL.path))
    }

    func testReplacedRootAndInsecureDirectoryFailClosed() throws {
        try storage.prepare(storage.root)
        let displaced = directory.appendingPathComponent("displaced")
        try FileManager.default.moveItem(at: storage.root, to: displaced)
        try FileManager.default.createSymbolicLink(at: storage.root, withDestinationURL: displaced)
        XCTAssertThrowsError(try storage.write(Data(), to: storage.root.appendingPathComponent("value")))
        try FileManager.default.removeItem(at: storage.root)
        try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try storage.prepare(storage.root))
        let newStorage = LocalSharedStorage(root: storage.root)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storage.root.path)
        XCTAssertThrowsError(try newStorage.prepare(newStorage.root))
    }
}
