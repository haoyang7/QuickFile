import XCTest
import Darwin
import os
import QuickFileCore
@testable import QuickFileInfrastructure
@testable import QuickFile

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

    @MainActor
    private func model(store: TemplateStore, baseline: [FileTemplate]) -> QuickFileViewModel {
        let grants = AuthorizedDirectoryStore(defaults: nil,
            localStorage: LocalSharedStorage(root: directory.appendingPathComponent("grants")),
            persistentBookmarkCreator: { Data($0.path.utf8) }, transferBookmarkCreator: { Data($0.path.utf8) },
            persistentBookmarkResolver: { .init(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false) },
            transferBookmarkResolver: { .init(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false) },
            startAccessing: { _ in true }, stopAccessing: { _ in })
        return QuickFileViewModel(templateStore: store, templates: baseline, authorizedDirectoryStore: grants)
    }

    private func failNextPublishedClose() -> OSAllocatedUnfairLock<Int> {
        let closes = OSAllocatedUnfairLock(initialState: 0)
        storage = LocalSharedStorage(root: storage.root, closeWrittenFile: { descriptor in
            let result = Darwin.close(descriptor)
            guard result == 0 else { return result }
            let fail = closes.withLock { value in value += 1; return value == 1 }
            if fail { errno = EIO; return -1 }
            return result
        })
        return closes
    }

    func testPublishedWriteCloseErrorsPreserveNewFileAndAreNeverRetried() throws {
        for durable in [false, true] {
            for code in [EIO, EINTR] {
                let root = directory.appendingPathComponent(UUID().uuidString)
                let original = LocalSharedStorage(root: root)
                let url = root.appendingPathComponent("settings.json")
                try original.write(Data("old".utf8), to: url)
                let closes = OSAllocatedUnfairLock(initialState: 0)
                let failing = LocalSharedStorage(root: root, closeWrittenFile: { descriptor in
                    let result = Darwin.close(descriptor)
                    closes.withLock { $0 += 1 }
                    guard result == 0 else { return result }
                    errno = code
                    return -1
                })

                XCTAssertThrowsError(try failing.write(Data("new".utf8), to: url, durable: durable)) { error in
                    guard let error = error as? LocalSharedStorage.PublishedWriteError else {
                        return XCTFail("Expected an already-published write error, got \(error)")
                    }
                    XCTAssertEqual(error.underlyingError.domain, NSPOSIXErrorDomain)
                    XCTAssertEqual(error.underlyingError.code, Int(code))
                }
                XCTAssertEqual(closes.withLock { $0 }, 1)
                XCTAssertEqual(try original.read(url), Data("new".utf8))
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["settings.json"])
            }
        }
    }

    func testPublishedTemplateCloseErrorRemainsVisibleAndReloadsAuthoritativeLibrary() throws {
        let baseline = [FileTemplate(name: "Before", fileExtension: "txt", content: "old")]
        try templates().saveTemplates(baseline, expectedTemplates: BuiltInTemplates.all)
        let root = storage.root
        storage = LocalSharedStorage(root: root, closeWrittenFile: { descriptor in
            let result = Darwin.close(descriptor)
            guard result == 0 else { return result }
            errno = EIO
            return -1
        })
        let writer = templates()
        XCTAssertEqual(try writer.loadTemplates(), baseline)
        let updated = [FileTemplate(name: "After", fileExtension: "txt", content: "new")]

        XCTAssertThrowsError(try writer.saveTemplates(updated, expectedTemplates: baseline)) { error in
            guard case TemplateStore.StoreError.persistenceFailed(let underlying) = error,
                  underlying is LocalSharedStorage.PublishedWriteError else {
                return XCTFail("Expected publication state to survive the store error: \(error)")
            }
        }
        XCTAssertEqual(try writer.reloadTemplates(), updated)
        XCTAssertThrowsError(try writer.saveTemplates(baseline, expectedTemplates: baseline)) { error in
            guard case TemplateStore.StoreError.configurationChanged = error else {
                return XCTFail("Expected stale baseline rejection, got \(error)")
            }
        }
        XCTAssertEqual(try writer.reloadTemplates(), updated)
    }

    @MainActor
    func testPublishedTemplateCloseFailurePreservesDraftAndBlocksStaleSavesUntilReload() async throws {
        let original = FileTemplate(name: "Before", fileExtension: "txt", content: "old")
        try templates().saveTemplates([original], expectedTemplates: BuiltInTemplates.all)
        let closes = OSAllocatedUnfairLock(initialState: 0)
        storage = LocalSharedStorage(root: storage.root, closeWrittenFile: { descriptor in
            let result = Darwin.close(descriptor)
            guard result == 0 else { return result }
            let fail = closes.withLock { value in value += 1; return value == 1 }
            if fail { errno = EIO; return -1 }
            return result
        })
        let writer = templates()
        let grants = AuthorizedDirectoryStore(defaults: nil,
            localStorage: LocalSharedStorage(root: directory.appendingPathComponent("grants")),
            persistentBookmarkCreator: { Data($0.path.utf8) }, transferBookmarkCreator: { Data($0.path.utf8) },
            persistentBookmarkResolver: { .init(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false) },
            transferBookmarkResolver: { .init(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false) },
            startAccessing: { _ in true }, stopAccessing: { _ in })
        let model = QuickFileViewModel(templateStore: writer, templates: [original],
                                      authorizedDirectoryStore: grants)
        var editor = TemplateEditorState(template: original)
        editor.draft.content = "published draft"
        let draft = editor.draft
        let updated = try draft.makeTemplate()
        XCTAssertTrue(editor.beginSave())
        do {
            try await model.saveTemplate(updated, replacing: original)
            XCTFail("A final close failure must remain visible")
        } catch {
            let failure = try XCTUnwrap(error as? TemplateStore.StoreError)
            XCTAssertTrue(failure.requiresReloadAfterSave)
            editor.finishSave(error: error)
        }
        XCTAssertEqual(try writer.reloadTemplates(), [updated])
        XCTAssertEqual(model.templates, [original])
        XCTAssertEqual(model.templateLoadFailure, .writeUnconfirmed)
        XCTAssertEqual(editor.draft, draft)
        XCTAssertEqual(editor.errorMessage, QuickFileViewModel.TemplateLoadFailure.writeUnconfirmed.message)
        XCTAssertEqual(editor.requestDismissal(), .confirmDiscard)
        do {
            try await model.saveTemplate(updated, replacing: original)
            XCTFail("The old baseline must not be retried")
        } catch {
            guard case QuickFileViewModel.TemplateSaveError.notLoaded = error else {
                return XCTFail("Expected a required reload, got \(error)")
            }
        }
        XCTAssertEqual(closes.withLock { $0 }, 1)
        await model.reloadTemplates()
        XCTAssertNil(model.templateLoadFailure)
        XCTAssertEqual(model.templates, [updated])
        var next = updated
        next.content = "after reload"
        try await model.saveTemplate(next, replacing: updated)
        XCTAssertEqual(model.templates, [next])
        XCTAssertEqual(try writer.reloadTemplates(), [next])
        XCTAssertEqual(closes.withLock { $0 }, 2)
    }

    @MainActor
    func testPublishedTemplateErrorPresentationIsSanitizedWithoutChangingOrdinaryFailures() {
        let secret = "/private/fixture/template-body"
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO),
                                 userInfo: [NSLocalizedDescriptionKey: secret])
        let published = TemplateStore.StoreError.persistenceFailed(
            LocalSharedStorage.PublishedWriteError(underlyingError: underlying))
        let ordinary = TemplateStore.StoreError.persistenceFailed(underlying)
        let message = QuickFileViewModel.templateOperationErrorMessage(published)
        XCTAssertTrue(published.requiresReloadAfterSave)
        XCTAssertFalse(ordinary.requiresReloadAfterSave)
        XCTAssertFalse(TemplateStore.StoreError.configurationChanged.requiresReloadAfterSave)
        XCTAssertEqual(QuickFileViewModel.TemplateLoadFailure(published), .writeUnconfirmed)
        XCTAssertFalse(QuickFileViewModel.TemplateLoadFailure(published).offersConfigurationRecovery)
        XCTAssertEqual(message, QuickFileViewModel.TemplateLoadFailure.writeUnconfirmed.message)
        XCTAssertFalse(message.contains(secret))
        XCTAssertNotEqual(message, QuickFileViewModel.templateOperationErrorMessage(ordinary))
        XCTAssertFalse(QuickFileViewModel.templateOperationErrorMessage(ordinary).contains(secret))
        let recovery = TemplateStore.RecoveryError.replacementFailed(
            backupURL: directory.appendingPathComponent("backup"), underlying: published)
        XCTAssertEqual(QuickFileViewModel.TemplateLoadFailure(recovery), .writeUnconfirmed)
        XCTAssertEqual(QuickFileViewModel.templateOperationErrorMessage(recovery), message)
    }

    @MainActor
    func testPublishedTemplateCopyFailureCannotAppendAgainBeforeReload() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "keep")
        try templates().saveTemplates([original], expectedTemplates: BuiltInTemplates.all)
        let closes = failNextPublishedClose()
        let writer = templates()
        let model = model(store: writer, baseline: [original])
        var editor = TemplateEditorState(template: original, isCopy: true)
        editor.draft.content = "copy draft"
        let draft = editor.draft
        XCTAssertTrue(editor.beginSave())
        do {
            _ = try await model.saveTemplateAsNew(editor.makeTemplate())
            XCTFail("A published copy must not report confirmed success")
        } catch {
            editor.finishSave(error: error)
        }
        let published = try writer.reloadTemplates()
        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(published.first, original)
        XCTAssertEqual(published.last?.content, "copy draft")
        XCTAssertEqual(model.templates, [original])
        XCTAssertEqual(model.templateLoadFailure, .writeUnconfirmed)
        XCTAssertEqual(editor.draft, draft)
        XCTAssertEqual(editor.errorMessage, QuickFileViewModel.TemplateLoadFailure.writeUnconfirmed.message)
        let publishedBytes = try storage.read(libraryURL)
        XCTAssertTrue(editor.beginSave())
        do {
            _ = try await model.saveTemplateAsNew(editor.makeTemplate())
            XCTFail("Retry must not append another UUID after a published copy")
        } catch {
            editor.finishSave(error: error)
            guard case QuickFileViewModel.TemplateSaveError.notLoaded = error else {
                return XCTFail("Expected a required reload, got \(error)")
            }
        }
        XCTAssertEqual(closes.withLock { $0 }, 1)
        XCTAssertEqual(try storage.read(libraryURL), publishedBytes)
        XCTAssertEqual(editor.draft, draft)
        await model.reloadTemplates()
        XCTAssertNil(model.templateLoadFailure)
        XCTAssertEqual(model.templates, published)
    }

    @MainActor
    func testPublishedTemplateImportFailureRequiresReloadAndPreservesAppliedPlan() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "keep")
        let addition = FileTemplate(name: "Imported", fileExtension: "md", content: "new")
        try templates().saveTemplates([original], expectedTemplates: BuiltInTemplates.all)
        let closes = failNextPublishedClose()
        let writer = templates()
        let model = model(store: writer, baseline: [original])
        let url = directory.appendingPathComponent("import.json")
        try TemplateTransferFile.write(TemplateTransferBundle(templates: [addition]), to: url)
        let preview = try await model.prepareTemplateImport(from: url)
        do {
            try await model.importTemplates(preview)
            XCTFail("A published import must remain unconfirmed")
        } catch {
            let failure = try XCTUnwrap(error as? TemplateStore.StoreError)
            XCTAssertTrue(failure.requiresReloadAfterSave)
        }
        XCTAssertEqual(try writer.reloadTemplates(), preview.plan.templates)
        XCTAssertEqual(model.templates, [original])
        XCTAssertEqual(model.templateLoadFailure, .writeUnconfirmed)
        let publishedBytes = try storage.read(libraryURL)
        do {
            try await model.importTemplates(preview)
            XCTFail("An unconfirmed import cannot reuse its old preview")
        } catch {
            guard case QuickFileViewModel.TemplateSaveError.notLoaded = error else {
                return XCTFail("Expected a required reload, got \(error)")
            }
        }
        XCTAssertEqual(closes.withLock { $0 }, 1)
        XCTAssertEqual(try storage.read(libraryURL), publishedBytes)
        await model.reloadTemplates()
        XCTAssertNil(model.templateLoadFailure)
        XCTAssertEqual(model.templates, preview.plan.templates)
        let refreshed = try await model.prepareTemplateImport(from: url)
        XCTAssertEqual(refreshed.plan.addedCount, 0)
        try await model.importTemplates(refreshed)
        XCTAssertEqual(closes.withLock { $0 }, 1)
    }

    @MainActor
    func testPublishedTemplateRecoveryFailurePreservesBackupAndRequiresReload() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "keep")
        try templates().saveTemplates([original], expectedTemplates: BuiltInTemplates.all)
        let malformed = Data("{broken configuration".utf8)
        try storage.write(malformed, to: libraryURL)
        let closes = failNextPublishedClose()
        let writer = templates()
        let model = model(store: writer, baseline: [original])
        await model.reloadTemplates()
        XCTAssertEqual(model.templateLoadFailure, .malformedConfiguration)
        let preview = try await model.prepareTemplateRecovery()
        do {
            try await model.recoverTemplates(preview)
            XCTFail("A published recovery must remain unconfirmed")
        } catch {
            XCTAssertEqual(QuickFileViewModel.TemplateLoadFailure(error), .writeUnconfirmed)
            XCTAssertEqual(QuickFileViewModel.templateOperationErrorMessage(error),
                           QuickFileViewModel.TemplateLoadFailure.writeUnconfirmed.message)
        }
        XCTAssertEqual(try writer.reloadTemplates(), preview.templates)
        XCTAssertEqual(model.templates, [original])
        XCTAssertEqual(model.templateLoadFailure, .writeUnconfirmed)
        XCTAssertFalse(try XCTUnwrap(model.templateLoadFailure).offersConfigurationRecovery)
        let backup = try XCTUnwrap(model.recoveryBackupURL)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("templates.original.json")), malformed)
        let publishedBytes = try storage.read(libraryURL)
        do {
            try await model.recoverTemplates(preview)
            XCTFail("The stale recovery must not be retried")
        } catch {
            guard case TemplateStore.RecoveryError.notRecoverable = error else {
                return XCTFail("Expected an explicit reload before any further recovery, got \(error)")
            }
        }
        XCTAssertEqual(closes.withLock { $0 }, 1)
        XCTAssertEqual(try storage.read(libraryURL), publishedBytes)
        await model.reloadTemplates()
        XCTAssertNil(model.templateLoadFailure)
        XCTAssertEqual(model.templates, preview.templates)
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

    func testOpaquePersistenceMarkersKeepSavedStateAndRecoveryPreservesOriginalBytes() throws {
        for bytes in [Data(), Data("broken".utf8), Data("{\"version\":2}".utf8), Data(repeating: 32, count: 4097)] {
            storage = LocalSharedStorage(root: directory.appendingPathComponent(UUID().uuidString))
            let store = templates()
            try store.saveTemplates([], expectedTemplates: BuiltInTemplates.all)
            try storage.write(bytes, to: markerURL)
            XCTAssertEqual(try store.reloadTemplates(), [])
            XCTAssertNoThrow(try store.changeToken())
            try store.saveTemplates([], expectedTemplates: [])
            XCTAssertEqual(try storage.read(markerURL), bytes)
            try storage.remove(libraryURL)
            XCTAssertThrowsError(try store.reloadTemplates()) {
                guard case TemplateStore.StoreError.savedConfigurationMissing = $0 else { return XCTFail("\($0)") }
            }
            XCTAssertNoThrow(try store.changeToken())
            let snapshot = try store.prepareRecovery()
            let result = try store.recoverTemplates([], expectedRecoveryState: snapshot)
            XCTAssertEqual(try Data(contentsOf: result.backupURL.appendingPathComponent("persistence.original.json")), bytes)
            XCTAssertEqual(try storage.read(markerURL), bytes)
            XCTAssertEqual(try store.reloadTemplates(), [])
        }
    }

    func testExplicitPermissionRepairPreservesDataAndRestoresAccess() throws {
        for rootMode in [0o755, 0o500] {
            storage = LocalSharedStorage(root: directory.appendingPathComponent(UUID().uuidString))
            let store = templates()
            try store.saveTemplates([], expectedTemplates: BuiltInTemplates.all)
            let original = try storage.read(libraryURL)
            let marker = Data("future marker".utf8)
            try storage.write(marker, to: markerURL)
            for url in [libraryURL, markerURL, libraryURL.appendingPathExtension("lock")] {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            }
            try FileManager.default.setAttributes([.posixPermissions: rootMode], ofItemAtPath: storage.root.path)
            XCTAssertThrowsError(try store.reloadTemplates())
            try store.repairStoragePermissions()
            XCTAssertEqual(try storage.read(libraryURL), original)
            XCTAssertEqual(try storage.read(markerURL), marker)
            XCTAssertEqual(try store.reloadTemplates(), [])
            try store.saveTemplates([], expectedTemplates: [])
            try storage.remove(libraryURL)
            let snapshot = try store.prepareRecovery()
            _ = try store.recoverTemplates([], expectedRecoveryState: snapshot)
        }
    }

    func testPermissionRepairRefusesUnopenableDirectoryWithoutPathBasedMutation() throws {
        let store = templates()
        try store.saveTemplates([], expectedTemplates: BuiltInTemplates.all)
        let original = try storage.read(libraryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storage.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storage.root.path) }
        XCTAssertThrowsError(try store.repairStoragePermissions())
        let attributes = try FileManager.default.attributesOfItem(atPath: storage.root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o000)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storage.root.path)
        XCTAssertEqual(try storage.read(libraryURL), original)
    }

    func testPermissionRepairRefusesLinksWithoutTouchingTheirTargets() throws {
        let target = directory.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        for hardLink in [false, true] {
            storage = LocalSharedStorage(root: directory.appendingPathComponent(UUID().uuidString))
            let store = templates()
            try store.saveTemplates([], expectedTemplates: BuiltInTemplates.all)
            try storage.remove(markerURL)
            if hardLink { try FileManager.default.linkItem(at: target, to: markerURL) }
            else { try FileManager.default.createSymbolicLink(at: markerURL, withDestinationURL: target) }
            XCTAssertThrowsError(try store.repairStoragePermissions())
            XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
            try FileManager.default.removeItem(at: markerURL)
        }
    }

    func testPermissionRepairRefusesReplacedOrMissingRoot() throws {
        let store = templates()
        try store.saveTemplates([], expectedTemplates: BuiltInTemplates.all)
        let displaced = directory.appendingPathComponent("original")
        try FileManager.default.moveItem(at: storage.root, to: displaced)
        XCTAssertThrowsError(try store.repairStoragePermissions())
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.root.path))
        try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try store.repairStoragePermissions())
        XCTAssertEqual(try Data(contentsOf: displaced.appendingPathComponent("templates.persistence.v1.json")),
                       Data("{\"version\":1}".utf8))
    }

    @MainActor
    func testRequestRepairRequiresConfirmationAndDoesNotResumeQueue() async throws {
        let queue = storage.root.appendingPathComponent("finder-authorization-requests")
        let store = FinderAuthorizationRequestStore(defaults: nil, directoryURL: queue, localStorage: storage)
        let request = FinderAuthorizationRequest(templateID: UUID(), destinationFolder: directory)
        try store.save(request)
        let url = queue.appendingPathComponent(request.id.uuidString + ".json")
        let original = try storage.read(url)
        XCTAssertEqual(chmod(url.path, 0o644), 0)
        let model = FinderRequestRecoveryViewModel(backend: .init(store: store))
        model.open()
        await model.repairPermissions { false }
        XCTAssertThrowsError(try storage.read(url))
        // Modal event-loop reentrancy must invalidate an approval after close.
        await model.repairPermissions { model.close(); return true }
        XCTAssertThrowsError(try storage.read(url))
        model.open()
        await model.repairPermissions { true }
        XCTAssertEqual(try storage.read(url), original)
        XCTAssertFalse(model.hasInspected)
        XCTAssertNil(model.operation)
        XCTAssertEqual(try store.takePendingRequest(), request)
    }

    @MainActor
    func testAuthorizationRepairConfirmationPreservesRecordAndRestoresInventory() async throws {
        let store = AuthorizedDirectoryStore(defaults: nil, localStorage: storage,
            persistentBookmarkCreator: { Data($0.path.utf8) }, transferBookmarkCreator: { Data($0.path.utf8) },
            persistentBookmarkResolver: { .init(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false) },
            transferBookmarkResolver: { .init(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false) },
            startAccessing: { _ in true }, stopAccessing: { _ in })
        let authorization = try store.authorize(directory)
        let url = storage.root.appendingPathComponent("authorizedDirectories.v2.json")
        let original = try storage.read(url)
        XCTAssertEqual(chmod(url.path, 0o644), 0)
        let model = DiagnosticsViewModel(
            extensionEnabledProvider: { false },
            runtimeProvider: { _ in
                FinderExtensionDiagnosticSnapshot(embeddedIdentifiers: [], embeddingKnown: true,
                    registration: .unknown, registrationEvidence: "fixture", enabled: false, responded: nil)
            },
            extensionActivityStore: FinderExtensionActivityStore(defaults: nil,
                failureHistoryFileURL: directory.appendingPathComponent("history.json")),
            authorizedDirectoryStore: store, inventoryReadGate: DiagnosticsInventoryReadGate()
        )
        await model.refreshRuntimeStatus()
        XCTAssertTrue(model.authorizationInventoryReadFailed)
        await model.repairAuthorizationPermissions { false }
        XCTAssertThrowsError(try storage.read(url))
        await model.refreshRuntimeStatus()
        XCTAssertTrue(model.authorizationInventoryReadFailed, "Cancellation keeps the direct recovery entry visible")
        await model.repairAuthorizationPermissions { true }
        XCTAssertFalse(model.authorizationHasError)
        XCTAssertTrue(model.authorizationInventoryReadFailed, "Repair alone does not prove a readable inventory")
        XCTAssertEqual(try storage.read(url), original)
        XCTAssertEqual(try store.loadAuthorizedDirectories().map(\.id), [authorization.id])
        await model.refreshRuntimeStatus()
        XCTAssertFalse(model.authorizationInventoryReadFailed)
        XCTAssertEqual(model.authorizedDirectories.map(\.id), [authorization.id])
    }

    func testAuthorizationPermissionRepairPreservesAllBookmarkBytes() throws {
        let repository = AuthorizedDirectoryRepository(containerURL: storage.root, localStorage: storage)
        let authorization = StoredDirectoryAuthorization(id: UUID(), persistentBookmarkData: Data([1, 2]), transferBookmarkData: Data([3, 4]))
        try repository.update { $0.append(authorization) }
        let names = ["authorizedDirectories.v2.json", "authorizedDirectories.lock", "authorizedDirectories.migrated"]
        var originals: [String: Data] = [:]
        for name in names {
            let url = storage.root.appendingPathComponent(name)
            originals[name] = try storage.read(url)
            XCTAssertEqual(chmod(url.path, 0o644), 0)
        }
        XCTAssertThrowsError(try repository.load())
        try repository.repairStoragePermissions()
        XCTAssertEqual(try repository.load(), [authorization])
        for name in names { XCTAssertEqual(try storage.read(storage.root.appendingPathComponent(name)), originals[name]) }
    }

    func testPermissionRepairUnblocksFullExpiredQueueWithoutConsumingOriginals() throws {
        let queue = storage.root.appendingPathComponent("finder-authorization-requests")
        let store = FinderAuthorizationRequestStore(defaults: nil, directoryURL: queue, localStorage: storage)
        let past = Date(timeIntervalSinceNow: -7200)
        var originals: [URL: Data] = [:]
        for _ in 0..<64 {
            let request = FinderAuthorizationRequest(templateID: UUID(), destinationFolder: directory, createdAt: past)
            try store.save(request, referenceDate: past)
            let url = queue.appendingPathComponent(request.id.uuidString + ".json")
            originals[url] = try storage.read(url)
            XCTAssertEqual(chmod(url.path, 0o644), 0)
        }
        let newRequest = FinderAuthorizationRequest(templateID: UUID(), destinationFolder: directory)
        XCTAssertThrowsError(try store.save(newRequest))
        XCTAssertTrue(try store.inspectRecoveryCandidates().candidates.allSatisfy { !$0.canPrepare })
        for url in [queue, storage.root] { XCTAssertEqual(chmod(url.path, 0o755), 0) }
        // Production does not migrate old defaults on save. Seed the optional
        // legacy marker explicitly to verify repair of an existing marker as well.
        let marker = queue.appendingPathComponent(".legacy-v1-migrated")
        try Data().write(to: marker)
        for name in [".queue.lock", ".legacy-v1-migrated"] { XCTAssertEqual(chmod(queue.appendingPathComponent(name).path, 0o644), 0) }
        XCTAssertThrowsError(try store.inspectRecoveryCandidates())
        try store.repairStoragePermissions()
        for (url, bytes) in originals { XCTAssertEqual(try storage.read(url), bytes) }
        let inspection = try store.inspectRecoveryCandidates()
        XCTAssertEqual(inspection.candidates.count, 64)
        XCTAssertTrue(inspection.candidates.allSatisfy { $0.canPrepare && $0.reason == .expired })
        // Prepared archival owns admission; no permission action can run under it.
        let ticket = try store.prepareRecovery(candidateID: inspection.candidates[0].id)
        XCTAssertThrowsError(try store.repairStoragePermissions())
        store.cancelRecovery(ticket)
        // Only an explicit normal operation prunes expired requests and frees slots.
        try store.save(newRequest)
        XCTAssertEqual(try store.takePendingRequest(), newRequest)
    }

    func testQueuePermissionRepairRefusesLinksAndLeavesUnknownEntriesUntouched() throws {
        let queue = storage.root.appendingPathComponent("finder-authorization-requests")
        try storage.prepare(queue)
        let outside = directory.appendingPathComponent("outside")
        try Data("sentinel".utf8).write(to: outside)
        XCTAssertEqual(chmod(outside.path, 0o644), 0)
        let linked = queue.appendingPathComponent(UUID().uuidString + ".json")
        XCTAssertEqual(symlink(outside.path, linked.path), 0)
        XCTAssertThrowsError(try storage.repairRequestPermissions())
        var metadata = stat()
        XCTAssertEqual(stat(outside.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o644)
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
        XCTAssertEqual(unlink(linked.path), 0)
        let unknown = queue.appendingPathComponent("unknown.json")
        try Data("keep".utf8).write(to: unknown)
        XCTAssertEqual(chmod(unknown.path, 0o644), 0)
        try storage.repairRequestPermissions()
        XCTAssertEqual(stat(unknown.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o644)
        XCTAssertEqual(link(outside.path, linked.path), 0)
        XCTAssertThrowsError(try storage.repairRequestPermissions())
    }

    func testInterruptedFirstSaveCannotLookLikeFirstUse() throws {
        let failing = templates(write: { _, _ in throw POSIXError(.ENOSPC) })
        XCTAssertThrowsError(try failing.saveTemplates([], expectedTemplates: BuiltInTemplates.all))
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryURL.path))
        XCTAssertThrowsError(try templates().reloadTemplates()) { error in
            guard case TemplateStore.StoreError.savedConfigurationMissing = error else { return XCTFail("\(error)") }
        }
    }

    func testArchiveModeRepairMakesBlockedArchivalUsableWithoutChangingEvidence() throws {
        let queue = storage.root.appendingPathComponent("finder-authorization-requests")
        let archive = queue.appendingPathComponent(".recovery-archive")
        try storage.prepare(archive)
        let evidence = archive.appendingPathComponent("existing-evidence")
        try storage.write(Data("keep evidence".utf8), to: evidence)
        let id = UUID().uuidString
        let source = queue.appendingPathComponent(id + ".json")
        try storage.write(Data("broken request".utf8), to: source)
        let store = FinderAuthorizationRequestStore(defaults: nil, directoryURL: storage.root.appendingPathComponent("finder-authorization-requests"), localStorage: storage)
        XCTAssertEqual(chmod(archive.path, 0o755), 0)
        let blocked = try store.prepareRecovery(candidateID: id)
        XCTAssertThrowsError(try store.commitRecovery(blocked))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try store.repairStoragePermissions()
        var metadata = stat()
        XCTAssertEqual(lstat(archive.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o7777, 0o700)
        XCTAssertEqual(try storage.read(evidence), Data("keep evidence".utf8))
        let ticket = try store.prepareRecovery(candidateID: id)
        let result = try store.commitRecovery(ticket)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.archiveURL)), Data("broken request".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testUnknownQueueFilesDoNotConsumeRequestCapacity() throws {
        let queue = storage.root.appendingPathComponent("finder-authorization-requests")
        try storage.prepare(queue)
        for index in 0..<64 {
            try Data("unknown".utf8).write(to: queue.appendingPathComponent("unknown-\(index).json"))
        }
        let store = FinderAuthorizationRequestStore(defaults: nil, directoryURL: queue, localStorage: storage)
        let request = FinderAuthorizationRequest(templateID: UUID(), destinationFolder: directory)
        try store.save(request)
        XCTAssertEqual(try store.takePendingRequest(), request)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: queue.path).filter { $0.hasPrefix("unknown-") }.count, 64)
    }

    func testArchivePermissionRepairRefusesSymlinkAndExtendedAllowACL() throws {
        let queue = storage.root.appendingPathComponent("finder-authorization-requests")
        try storage.prepare(queue)
        let archive = queue.appendingPathComponent(".recovery-archive")
        let outside = directory.appendingPathComponent("outside-archive")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(outside.path, 0o755), 0)
        XCTAssertEqual(symlink(outside.path, archive.path), 0)
        XCTAssertThrowsError(try storage.repairRequestPermissions())
        var metadata = stat()
        XCTAssertEqual(stat(outside.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o755)
        XCTAssertEqual(unlink(archive.path), 0)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        let acl = try XCTUnwrap(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:read,write\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertEqual(acl_set_file(archive.path, ACL_TYPE_EXTENDED, acl), 0)
        defer { acl_delete_def_file(archive.path) }
        XCTAssertThrowsError(try storage.repairRequestPermissions())
    }

    func testWriteReclaimsOldFragmentsButProtectsActiveProcessUntilItDies() throws {
        try storage.prepare(storage.root)
        let fragment = storage.root.appendingPathComponent(".quickfile-write-" + UUID().uuidString)
        let ready = directory.appendingPathComponent("writer-ready")
        let diagnostics = directory.appendingPathComponent("writer-stderr")
        // Xcode embeds this test-only tool in the test bundle. Starting it
        // requires neither the system Python shim nor runtime compiler discovery.
        let executable = try XCTUnwrap(Bundle(for: Self.self)
            .url(forAuxiliaryExecutable: "QuickFileStorageWriterFixture"))
        let process = try startWriter(executable: executable.path,
            arguments: [fragment.path, ready.path], diagnostics: diagnostics)
        defer { stopWriter(process) }
        // Fail here with startup evidence, before asserting anything about the file lock.
        try waitForWriter(process, ready: ready, diagnostics: diagnostics)
        let output = storage.root.appendingPathComponent("saved")
        try storage.write(Data("first".utf8), to: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fragment.path), "Live writer owns its temporary file")
        stopWriter(process)
        try storage.write(Data("second".utf8), to: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fragment.path))
        XCTAssertEqual(try storage.read(output), Data("second".utf8))
    }

    private enum WriterStartupFailure: Error, CustomStringConvertible {
        case launchFailed(executable: String, underlying: Error)
        case exited(status: Int32, reason: Process.TerminationReason, stderr: String)
        case timedOut(seconds: TimeInterval, pid: Int32, stderr: String)

        var description: String {
            switch self {
            case let .launchFailed(executable, underlying):
                let error = underlying as NSError
                return "Writer fixture failed to launch: executable=\(executable), domain=\(error.domain), code=\(error.code), error=\(error)"
            case let .exited(status, reason, stderr):
                return "Writer exited before readiness: status=\(status), reason=\(reason), stderr=\(stderr)"
            case let .timedOut(seconds, pid, stderr):
                return "Writer still running but not ready after \(seconds)s: pid=\(pid), stderr=\(stderr)"
            }
        }
    }

    private func startWriter(executable: String, arguments: [String], diagnostics: URL) throws -> Process {
        try Data().write(to: diagnostics)
        let stderr = try FileHandle(forWritingTo: diagnostics)
        defer { try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw WriterStartupFailure.launchFailed(executable: executable, underlying: error)
        }
        return process
    }

    private func stopWriter(_ process: Process) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func waitForWriter(_ process: Process, ready: URL, diagnostics: URL,
                               timeout: TimeInterval = 30) throws {
        func stderr() -> String {
            guard let file = try? FileHandle(forReadingFrom: diagnostics) else { return "<unavailable>" }
            defer { try? file.close() }
            return String(decoding: (try? file.read(upToCount: 16 * 1024)) ?? Data(), as: UTF8.self)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            guard process.isRunning else {
                process.waitUntilExit()
                throw WriterStartupFailure.exited(status: process.terminationStatus,
                    reason: process.terminationReason, stderr: stderr())
            }
            if FileManager.default.fileExists(atPath: ready.path) { return }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw WriterStartupFailure.timedOut(seconds: timeout, pid: process.processIdentifier, stderr: stderr())
            }
            Thread.sleep(forTimeInterval: min(0.01, remaining))
        }
    }

    func testWriterLaunchFailureIdentifiesExecutableAndPreservesSystemError() throws {
        let missing = directory.appendingPathComponent("missing-writer")
        let nonExecutable = directory.appendingPathComponent("non-executable-writer")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: nonExecutable)
        XCTAssertEqual(chmod(nonExecutable.path, 0o600), 0)

        for executable in [missing, nonExecutable] {
            // Foundation may map launch failures differently across macOS versions.
            // Compare with its actual error instead of prescribing an error code.
            let rawProcess = Process()
            rawProcess.executableURL = executable
            rawProcess.arguments = []
            let expectedError: NSError
            do {
                try rawProcess.run()
                stopWriter(rawProcess)
                XCTFail("Fixture must produce a system launch error")
                continue
            } catch {
                expectedError = error as NSError
            }
            let diagnostics = directory.appendingPathComponent(executable.lastPathComponent + "-stderr")
            do {
                let process = try startWriter(executable: executable.path, arguments: [], diagnostics: diagnostics)
                stopWriter(process)
                XCTFail("An unavailable writer executable must fail at launch")
            } catch let failure as WriterStartupFailure {
                guard case let .launchFailed(path, underlying) = failure else {
                    return XCTFail("Expected launch failure, received \(failure)")
                }
                let error = underlying as NSError
                XCTAssertEqual(path, executable.path)
                XCTAssertEqual(error, expectedError)
                XCTAssertTrue(failure.description.contains("Writer fixture failed to launch"))
                XCTAssertTrue(failure.description.contains(executable.path))
                XCTAssertTrue(failure.description.contains("domain=\(expectedError.domain), code=\(expectedError.code)"))
            }
        }
    }

    func testWriterReadinessAllowsStartupLongerThanOldTwoSecondBudget() throws {
        let ready = directory.appendingPathComponent("delayed-ready")
        let diagnostics = directory.appendingPathComponent("delayed-stderr")
        // exec leaves one owned process after readiness; no lingering sleep descendant.
        let process = try startWriter(executable: "/bin/sh",
            arguments: ["-c", "sleep 2.2; touch \"$1\"; exec sleep 30", "writer", ready.path], diagnostics: diagnostics)
        defer { stopWriter(process) }
        try waitForWriter(process, ready: ready, diagnostics: diagnostics)
        XCTAssertTrue(process.isRunning)
    }

    func testWriterReadinessReportsEarlyExitWithStatusAndStderr() throws {
        let ready = directory.appendingPathComponent("never-ready")
        let diagnostics = directory.appendingPathComponent("exited-stderr")
        let process = try startWriter(executable: "/bin/sh",
            arguments: ["-c", "printf writer-fixture-exit >&2; exit 7"], diagnostics: diagnostics)
        defer { stopWriter(process) }
        do {
            try waitForWriter(process, ready: ready, diagnostics: diagnostics)
            XCTFail("An exited writer cannot establish readiness")
        } catch WriterStartupFailure.exited(let status, let reason, let stderr) {
            XCTAssertEqual(status, 7)
            XCTAssertEqual(reason, .exit)
            XCTAssertEqual(stderr, "writer-fixture-exit")
        }
    }

    func testWriterReadinessReportsTimeoutWhileProcessIsAlive() throws {
        let ready = directory.appendingPathComponent("never-ready")
        let diagnostics = directory.appendingPathComponent("timeout-stderr")
        let process = try startWriter(executable: "/bin/sleep", arguments: ["30"], diagnostics: diagnostics)
        defer { stopWriter(process) }
        do {
            try waitForWriter(process, ready: ready, diagnostics: diagnostics, timeout: 0.1)
            XCTFail("An unready writer cannot proceed to storage assertions")
        } catch WriterStartupFailure.timedOut(let seconds, let pid, _) {
            XCTAssertEqual(seconds, 0.1)
            XCTAssertEqual(pid, process.processIdentifier)
            XCTAssertTrue(process.isRunning)
        }
    }

    func testFragmentCleanupLeavesFreshUnknownLinkedAndNonPrivateFilesUntouched() throws {
        try storage.prepare(storage.root)
        let old = Date(timeIntervalSinceNow: -172800)
        func file(_ name: String = ".quickfile-write-" + UUID().uuidString, aged: Bool = true) throws -> URL {
            let url = storage.root.appendingPathComponent(name)
            try Data("keep".utf8).write(to: url)
            XCTAssertEqual(chmod(url.path, 0o600), 0)
            if aged { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
            return url
        }
        let fresh = try file(aged: false)
        let unknown = try file(".quickfile-write-unknown")
        let nonPrivate = try file()
        XCTAssertEqual(chmod(nonPrivate.path, 0o644), 0)
        let hardlinked = try file()
        let hardlink = storage.root.appendingPathComponent("retained-link")
        XCTAssertEqual(link(hardlinked.path, hardlink.path), 0)
        let symlinkURL = storage.root.appendingPathComponent(".quickfile-write-" + UUID().uuidString)
        XCTAssertEqual(symlink(unknown.path, symlinkURL.path), 0)
        let aclGranted = try file()
        try setACL("allow:read", on: aclGranted)
        defer { try? setACL(nil, on: aclGranted) }
        let orphan = try file()
        try storage.write(Data("normal".utf8), to: storage.root.appendingPathComponent("saved"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        for url in [fresh, unknown, nonPrivate, hardlinked, hardlink, symlinkURL, aclGranted] {
            XCTAssertEqual(try Data(contentsOf: url), Data("keep".utf8))
        }
    }

    func testInvalidMarkerPreventsPayloadPublication() throws {
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

    private func setACL(_ entry: String?, on url: URL) throws {
        let text = "!#acl 1\n" + (entry.map {
            "group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:\($0)\n"
        } ?? "")
        let acl = try XCTUnwrap(entry == nil ? acl_init(0) : acl_from_text(text))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertEqual(acl_set_file(url.path, ACL_TYPE_EXTENDED, acl), 0)
    }

    func testRootAllowACLRejectsReadsWritesLocksAndEveryPermissionRepair() throws {
        let original = Data("original".utf8)
        try storage.write(original, to: libraryURL)
        try setACL("allow,file_inherit,directory_inherit:read,execute", on: storage.root)
        defer { try? setACL(nil, on: storage.root) }
        XCTAssertThrowsError(try storage.read(libraryURL))
        XCTAssertThrowsError(try storage.write(Data("replacement".utf8), to: libraryURL))
        XCTAssertThrowsError(try storage.containsFile(at: libraryURL))
        XCTAssertThrowsError(try storage.withLock(at: storage.root.appendingPathComponent("new.lock")) {})
        XCTAssertThrowsError(try storage.repairTemplatePermissions())
        XCTAssertThrowsError(try storage.repairAuthorizationPermissions())
        XCTAssertThrowsError(try storage.repairRequestPermissions())
        XCTAssertEqual(try Data(contentsOf: libraryURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.root.appendingPathComponent("new.lock").path))
        // Repair must leave the ACL intact, so a fresh backend also refuses it.
        XCTAssertThrowsError(try LocalSharedStorage(root: storage.root).prepare(storage.root))
    }

    func testLeafAllowACLRejectsAccessAndRepairWithoutReplacingDataOrACL() throws {
        let original = Data("original".utf8)
        for name in ["templates.v2.json", "templates.persistence.v1.json", "templates.v2.json.lock"] {
            let file = storage.root.appendingPathComponent(name)
            try storage.write(original, to: file)
            try setACL("allow:read,write", on: file)
            XCTAssertThrowsError(try storage.read(file))
            XCTAssertThrowsError(try storage.containsFile(at: file))
            XCTAssertThrowsError(try storage.write(Data(), to: file))
            XCTAssertThrowsError(try storage.remove(file))
            XCTAssertThrowsError(try storage.withLock(at: file) { XCTFail("Unsafe lock admitted operation") })
            XCTAssertThrowsError(try storage.repairTemplatePermissions())
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertThrowsError(try storage.read(file), "Repair must preserve the rejecting ACL")
            try setACL(nil, on: file)
            XCTAssertEqual(try storage.read(file), original)
        }
    }

    func testInheritedLeafACLIsRejectedAfterParentACLIsRemoved() throws {
        try storage.prepare(storage.root)
        try setACL("allow,file_inherit,only_inherit:read", on: storage.root)
        let original = Data("inherited".utf8)
        // Create through the OS so this fixture genuinely inherits its ACL.
        try original.write(to: libraryURL)
        XCTAssertEqual(chmod(libraryURL.path, 0o600), 0)
        try setACL(nil, on: storage.root)
        XCTAssertThrowsError(try storage.read(libraryURL))
        XCTAssertThrowsError(try storage.write(Data(), to: libraryURL))
        XCTAssertThrowsError(try storage.repairTemplatePermissions())
        XCTAssertEqual(try Data(contentsOf: libraryURL), original)
        try setACL(nil, on: libraryURL)
        XCTAssertEqual(try storage.read(libraryURL), original)
    }

    func testNewRootWithInheritedAllowACLDoesNotPublishPayloadOrLock() throws {
        try setACL("allow,file_inherit,directory_inherit,only_inherit:read", on: directory)
        defer {
            try? setACL(nil, on: storage.root)
            try? setACL(nil, on: directory)
        }
        XCTAssertThrowsError(try storage.write(Data("private".utf8), to: libraryURL))
        XCTAssertThrowsError(try storage.withLock(at: storage.root.appendingPathComponent("new.lock")) {})
        XCTAssertThrowsError(try storage.prepare(storage.root.appendingPathComponent("nested")))
        XCTAssertThrowsError(try storage.repairTemplatePermissions())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.root.path), [])
    }

    func testDenyACLRemainsCompatibleWithPrivateStorageAndRepair() throws {
        try storage.write(Data("private".utf8), to: libraryURL)
        try setACL("deny:delete", on: libraryURL)
        defer { try? setACL(nil, on: libraryURL) }
        XCTAssertEqual(try storage.read(libraryURL), Data("private".utf8))
        XCTAssertNoThrow(try storage.repairTemplatePermissions())
        XCTAssertEqual(try storage.read(libraryURL), Data("private".utf8))
    }

    func testOptionalReadBudgetAndIntegerBoundaries() throws {
        try storage.write(Data(), to: libraryURL)
        XCTAssertEqual(try storage.read(libraryURL, maximumBytes: 0), Data())
        XCTAssertThrowsError(try storage.read(libraryURL, maximumBytes: -1))
        try storage.write(Data("value".utf8), to: libraryURL)
        XCTAssertEqual(try storage.read(libraryURL, maximumBytes: nil), Data("value".utf8))
        XCTAssertEqual(try storage.read(libraryURL, maximumBytes: Int.max), Data("value".utf8))
        XCTAssertThrowsError(try storage.read(libraryURL, maximumBytes: 0))
        // Sparse storage proves nil exceeds the default budget without a second large fixture buffer.
        let descriptor = open(libraryURL.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let largeSize = 64 * 1024 * 1024 + 1
        XCTAssertEqual(ftruncate(descriptor, off_t(largeSize)), 0)
        XCTAssertThrowsError(try storage.read(libraryURL))
        XCTAssertEqual(try storage.read(libraryURL, maximumBytes: nil).count, largeSize)
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
