import Combine
import XCTest
import Darwin
@testable import QuickFile
@testable import QuickFileCore
@testable import QuickFileApplication
@testable import QuickFileInfrastructure

@MainActor
final class QuickFileViewModelTests: XCTestCase {
    private enum TestError: Error {
        case bookmarkResolutionFailed
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        suiteName = "QuickFileTests.ViewModel.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickFileViewModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        defer {
            if let suiteName {
                defaults?.removePersistentDomain(forName: suiteName)
            }
            temporaryDirectory = nil
            defaults = nil
            suiteName = nil
        }
        if let temporaryDirectory {
            // Recovery backups are read-only. Restore only fixture directory permissions.
            if let entries = FileManager.default.enumerator(
                at: temporaryDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ) {
                for case let url as URL in entries {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true {
                        entries.skipDescendants()
                    } else if values.isDirectory == true {
                        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                    }
                }
            }
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testTemplateLoadFailureClassificationSeparatesSafeNextSteps() {
        typealias Failure = QuickFileViewModel.TemplateLoadFailure
        typealias StoreError = TemplateStore.StoreError
        let malformed = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "invalid JSON"))
        let cases: [(Error, Failure)] = [
            (StoreError.configurationChanged, .configurationChanged),
            (StoreError.readFailed(TemplateStore.RecoveryError.configurationChanged), .configurationChanged),
            (StoreError.savedConfigurationMissing, .missingConfiguration),
            (StoreError.sharedDefaultsUnavailable, .storageUnavailable),
            (StoreError.readFailed(CocoaError(.fileReadNoPermission)), .permissionDenied),
            (StoreError.readFailed(CocoaError(.fileReadNoSuchFile)), .missingConfiguration),
            (StoreError.readFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))), .permissionDenied),
            (StoreError.readFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))), .permissionDenied),
            (StoreError.readFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))), .missingConfiguration),
            (StoreError.readFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(ENODEV))), .storageUnavailable),
            (StoreError.readFailed(malformed), .malformedConfiguration),
            (StoreError.readFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))), .unreadable)
        ]
        for (error, expected) in cases {
            let failure = Failure(error)
            XCTAssertEqual(failure, expected)
            XCTAssertEqual(failure.offersConfigurationRecovery, expected == .malformedConfiguration || expected == .missingConfiguration)
            XCTAssertFalse(failure.message.isEmpty)
        }
        XCTAssertEqual(Failure.malformedConfiguration.recoveryActionTitle, "修复损坏的配置…")
        XCTAssertEqual(Failure.missingConfiguration.recoveryActionTitle, "恢复缺失的配置…")
        for failure in [Failure.configurationChanged, .permissionDenied, .storageUnavailable, .unreadable] {
            XCTAssertNil(failure.recoveryActionTitle)
        }
        XCTAssertTrue(Failure.configurationChanged.message.contains("重新加载"))
        XCTAssertTrue(Failure.missingConfiguration.message.contains("恢复原配置文件"))
        XCTAssertTrue(Failure.permissionDenied.message.contains("访问权限"))
        XCTAssertTrue(Failure.storageUnavailable.message.contains("存储位置"))
    }

    func testTemplateLoadFailureUnwrapsBoundedlyWithoutTrustingRawMessagesOrWriteErrors() {
        typealias Failure = QuickFileViewModel.TemplateLoadFailure
        typealias StoreError = TemplateStore.StoreError
        let secret = "/private/user-folder/private-template.json"
        let malformed = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: secret))
        let wrapped = NSError(domain: "Fixture", code: 1, userInfo: [NSUnderlyingErrorKey: malformed])
        XCTAssertEqual(Failure(StoreError.readFailed(wrapped)), .malformedConfiguration)
        XCTAssertFalse(Failure(StoreError.readFailed(wrapped)).message.contains(secret))
        let generic = NSError(domain: secret, code: 1,
            userInfo: [NSLocalizedDescriptionKey: "corrupt JSON: " + secret])
        XCTAssertEqual(Failure(StoreError.readFailed(generic)), .unreadable)
        XCTAssertFalse(Failure(StoreError.readFailed(generic)).offersConfigurationRecovery)
        XCTAssertFalse(Failure(StoreError.readFailed(generic)).message.contains(secret))
        XCTAssertEqual(Failure(StoreError.persistenceFailed(malformed)), .unreadable)
        XCTAssertEqual(Failure(StoreError.persistenceFailed(StoreError.readFailed(malformed))), .unreadable)
        var nested: Error = malformed
        for _ in 0..<16 { nested = StoreError.readFailed(nested) }
        XCTAssertEqual(Failure(nested), .unreadable)
        XCTAssertFalse(Failure(nested).offersConfigurationRecovery)
    }

    func testPermissionReadFailurePreservesSnapshotAndDraftButRejectsConfigurationRecovery() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let original = FileTemplate(name: "Keep", fileExtension: "txt", content: "literal {{clipboard}}")
        let originalData = try JSONEncoder().encode([original])
        try originalData.write(to: storageURL)
        let store = TemplateStore(defaults: defaults, storageURL: storageURL, readTemplatesData: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                userInfo: [NSLocalizedDescriptionKey: "/private/user-folder/private-template.json"])
        })
        let model = QuickFileViewModel(templateStore: store, templates: [original])
        model.requestedFilename = "unsaved e\u{0301}"
        await model.reloadTemplates()

        XCTAssertEqual(model.templateLoadFailure, .permissionDenied)
        XCTAssertEqual(model.templateLoadError, QuickFileViewModel.TemplateLoadFailure.permissionDenied.message)
        XCTAssertEqual(model.status, .failure(QuickFileViewModel.TemplateLoadFailure.permissionDenied.message))
        XCTAssertEqual(model.templates, [original])
        XCTAssertTrue(model.requestedFilename.utf8.elementsEqual("unsaved e\u{0301}".utf8))
        XCTAssertFalse(model.isLoadingTemplates)
        XCTAssertFalse(model.canCreate)
        await assertThrowsAsync(try await model.prepareTemplateRecovery()) { error in
            guard case TemplateStore.RecoveryError.notRecoverable = error else {
                return XCTFail("An access failure must not offer destructive recovery")
            }
        }
        XCTAssertEqual(try Data(contentsOf: storageURL), originalData)
        XCTAssertNil(model.recoveryBackupURL)
    }

    func testMissingConfigurationPreviewPreservesSourceAndSuccessfulReloadClearsTypedFailure() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let original = FileTemplate(name: "Keep", fileExtension: "txt", content: "body")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        try store.saveTemplates([original])
        let originalData = try Data(contentsOf: storageURL)
        try FileManager.default.removeItem(at: storageURL)
        let model = QuickFileViewModel(templateStore: store, templates: [original])
        await model.reloadTemplates()
        XCTAssertEqual(model.templateLoadFailure, .missingConfiguration)
        XCTAssertTrue(try XCTUnwrap(model.templateLoadFailure).offersConfigurationRecovery)
        let preview = try await model.prepareTemplateRecovery()
        XCTAssertTrue(preview.isMissingConfiguration)
        XCTAssertEqual(preview.title, "恢复缺失的模板配置")
        XCTAssertEqual(preview.confirmationActionTitle, "记录缺失状态并恢复")
        XCTAssertTrue(preview.explanation.contains("无法备份其原始内容"))
        XCTAssertTrue(preview.explanation.contains("缺失状态记录"))
        XCTAssertEqual(model.templates, [original])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
        XCTAssertNil(model.recoveryBackupURL)

        try originalData.write(to: storageURL)
        await model.reloadTemplates()
        XCTAssertNil(model.templateLoadFailure)
        XCTAssertNil(model.templateLoadError)
        XCTAssertEqual(model.templates, [original])
    }

    func testRecoveryPreparationUsesFreshMissingStateInsteadOfStaleCorruptionLabel() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        try store.saveTemplates([FileTemplate(name: "Original", fileExtension: "txt", content: "body")])
        try Data("malformed".utf8).write(to: storageURL)
        let model = QuickFileViewModel(templateStore: store)
        await model.reloadTemplates()
        XCTAssertEqual(model.templateLoadFailure, .malformedConfiguration)
        try FileManager.default.removeItem(at: storageURL)

        let preview = try await model.prepareTemplateRecovery()
        XCTAssertEqual(model.templateLoadFailure, .missingConfiguration)
        XCTAssertEqual(model.status, .failure(QuickFileViewModel.TemplateLoadFailure.missingConfiguration.message))
        XCTAssertTrue(preview.isMissingConfiguration)
        XCTAssertEqual(preview.snapshot.reason, .missingSavedConfiguration)
        XCTAssertTrue(preview.explanation.contains("无法备份其原始内容"))
        XCTAssertFalse(preview.title.contains("损坏"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
        XCTAssertNil(model.recoveryBackupURL)
    }

    func testRecoveryPreparationUsesFreshMalformedStateInsteadOfStaleMissingLabel() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        defaults.set("previously-saved", forKey: "templates.revision.v2")
        let model = QuickFileViewModel(templateStore: TemplateStore(defaults: defaults, storageURL: storageURL))
        await model.reloadTemplates()
        XCTAssertEqual(model.templateLoadFailure, .missingConfiguration)
        let malformed = Data("malformed".utf8)
        try malformed.write(to: storageURL)

        let preview = try await model.prepareTemplateRecovery()
        XCTAssertEqual(model.templateLoadFailure, .malformedConfiguration)
        XCTAssertEqual(preview.snapshot.reason, .corruptFile)
        XCTAssertFalse(preview.isMissingConfiguration)
        XCTAssertEqual(preview.title, "恢复损坏的模板配置")
        XCTAssertEqual(preview.confirmationActionTitle, "备份原配置并恢复")
        XCTAssertFalse(preview.explanation.contains("无法备份其原始内容"))
        XCTAssertEqual(try Data(contentsOf: storageURL), malformed)
        XCTAssertNil(model.recoveryBackupURL)
    }

    func testMissingConfigurationRecoverySavesMetadataWithoutClaimingOriginalBytes() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        defaults.set("previously-saved", forKey: "templates.revision.v2")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        let model = QuickFileViewModel(templateStore: store)
        await model.reloadTemplates()
        XCTAssertEqual(model.templateLoadFailure, .missingConfiguration)
        let preview = try await model.prepareTemplateRecovery()
        try await model.recoverTemplates(preview)
        XCTAssertEqual(try store.reloadTemplates(), BuiltInTemplates.all)
        XCTAssertNil(model.templateLoadFailure)
        let backupURL = try XCTUnwrap(model.recoveryBackupURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("templates.original.json").path))
        let data = try Data(contentsOf: backupURL.appendingPathComponent("metadata.plist"))
        let metadata = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(metadata["reason"] as? String, "missingSavedConfiguration")
        XCTAssertEqual(metadata["fileWasMissing"] as? Bool, true)
        XCTAssertEqual(metadata["revisionWasPresent"] as? Bool, true)
        guard case let .success(message) = model.status else { return XCTFail("Expected explicit missing-state recovery") }
        XCTAssertTrue(message.contains("已记录缺失状态"))
        XCTAssertFalse(message.contains("已备份原配置"))
    }

    func testMissingConfigurationRecoveryRejectsFileReappearingAfterPreview() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        defaults.set("previously-saved", forKey: "templates.revision.v2")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        let model = QuickFileViewModel(templateStore: store)
        await model.reloadTemplates()
        let preview = try await model.prepareTemplateRecovery()
        let restored = FileTemplate(name: "Restored elsewhere", fileExtension: "txt", content: "keep")
        let restoredData = try JSONEncoder().encode([restored])
        try restoredData.write(to: storageURL)

        await assertThrowsAsync(try await model.recoverTemplates(preview)) { error in
            guard case TemplateStore.RecoveryError.configurationChanged = error else {
                return XCTFail("The missing-state receipt must not replace a reappeared file")
            }
        }
        XCTAssertEqual(model.templateLoadFailure, .configurationChanged)
        XCTAssertNil(model.recoveryBackupURL)
        XCTAssertEqual(try Data(contentsOf: storageURL), restoredData)
        await model.reloadTemplates()
        XCTAssertNil(model.templateLoadFailure)
        XCTAssertEqual(model.templates, [restored])
    }

    func testRecoveryPreparationReclassifiesConfigurationThatBecameUnreadable() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        try Data("malformed".utf8).write(to: storageURL)
        let model = QuickFileViewModel(templateStore: TemplateStore(defaults: defaults, storageURL: storageURL))
        await model.reloadTemplates()
        XCTAssertEqual(model.templateLoadFailure, .malformedConfiguration)
        try FileManager.default.removeItem(at: storageURL)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: false)

        await assertThrowsAsync(try await model.prepareTemplateRecovery())
        XCTAssertEqual(model.templateLoadFailure, .unreadable)
        XCTAssertFalse(try XCTUnwrap(model.templateLoadFailure).offersConfigurationRecovery)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))
        XCTAssertNil(model.recoveryBackupURL)
    }

    func testRecoveryPreparationRequiresReloadWhenConfigurationHasAlreadyBeenRepaired() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        try Data("malformed".utf8).write(to: storageURL)
        let model = QuickFileViewModel(templateStore: TemplateStore(defaults: defaults, storageURL: storageURL))
        await model.reloadTemplates()
        XCTAssertEqual(model.templateLoadFailure, .malformedConfiguration)
        let repaired = FileTemplate(name: "Repaired", fileExtension: "txt", content: "keep")
        let repairedData = try JSONEncoder().encode([repaired])
        try repairedData.write(to: storageURL)

        await assertThrowsAsync(try await model.prepareTemplateRecovery())
        XCTAssertEqual(model.templateLoadFailure, .configurationChanged)
        XCTAssertFalse(try XCTUnwrap(model.templateLoadFailure).offersConfigurationRecovery)
        XCTAssertEqual(try Data(contentsOf: storageURL), repairedData)
        XCTAssertNil(model.recoveryBackupURL)
        await model.reloadTemplates()
        XCTAssertNil(model.templateLoadFailure)
        XCTAssertEqual(model.templates, [repaired])
    }

    func testRecoveryBackupFailureIsSanitizedAndDoesNotClaimBackupOrReplaceOriginal() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let originalData = Data("malformed".utf8)
        try originalData.write(to: storageURL)
        let store = TemplateStore(defaults: defaults, storageURL: storageURL, backupWriteOverride: { _, _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                userInfo: [NSLocalizedDescriptionKey: "/private/backup-file"])
        })
        let model = QuickFileViewModel(templateStore: store)
        await model.reloadTemplates()
        let preview = try await model.prepareTemplateRecovery()
        await assertThrowsAsync(try await model.recoverTemplates(preview))
        XCTAssertNil(model.recoveryBackupURL)
        XCTAssertEqual(try Data(contentsOf: storageURL), originalData)
        guard case let .failure(message) = model.status else { return XCTFail("Expected backup failure") }
        XCTAssertTrue(message.contains("无法备份恢复前状态"))
        XCTAssertTrue(message.contains("未写入替代配置"))
        XCTAssertFalse(message.contains("/private/backup-file"))
    }

    func testRecoveryReplacementFailureIsSanitizedAndPreservesBackupAccess() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let originalData = Data("malformed".utf8)
        try originalData.write(to: storageURL)
        let store = TemplateStore(defaults: defaults, storageURL: storageURL, writeTemplatesData: { _, _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                userInfo: [NSLocalizedDescriptionKey: "/private/replacement-file"])
        })
        let model = QuickFileViewModel(templateStore: store)
        await model.reloadTemplates()
        let preview = try await model.prepareTemplateRecovery()
        await assertThrowsAsync(try await model.recoverTemplates(preview))
        let backupURL = try XCTUnwrap(model.recoveryBackupURL)
        XCTAssertTrue(backupURL.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try Data(contentsOf: storageURL), originalData)
        guard case let .failure(message) = model.status else { return XCTFail("Expected replacement failure") }
        XCTAssertTrue(message.contains("恢复前状态已备份"))
        XCTAssertTrue(message.contains("恢复写入失败"))
        XCTAssertFalse(message.contains("/private/replacement-file"))
    }

    func testMissingRecoveryReplacementFailureRetainsMetadataBackupWithoutClaimingOriginalBytes() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        defaults.set("previously-saved", forKey: "templates.revision.v2")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL, writeTemplatesData: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let model = QuickFileViewModel(templateStore: store)
        await model.reloadTemplates()
        let preview = try await model.prepareTemplateRecovery()
        await assertThrowsAsync(try await model.recoverTemplates(preview))
        let backupURL = try XCTUnwrap(model.recoveryBackupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("metadata.plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("templates.original.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
        guard case let .failure(message) = model.status else { return XCTFail("Expected replacement failure") }
        XCTAssertTrue(message.contains("恢复前状态已备份"))
        XCTAssertTrue(message.contains("恢复写入失败"))
        XCTAssertFalse(message.contains("原配置已备份"))
    }

    func testDirectPanelSelectionDoesNotSaveFinderGrantAndCanCreate() async throws {
        let store = TemplateStore(defaults: defaults)
        let template = FileTemplate(name: "Plain", fileExtension: "txt", content: "plain")
        try store.saveTemplates([template])
        let grants = makeAuthorizationStore(defaults: defaults)
        let model = QuickFileViewModel(templateStore: store, templates: [template], authorizedDirectoryStore: grants)
        await model.selectDestinationFolder(temporaryDirectory)
        XCTAssertTrue(try grants.loadAuthorizedDirectories().isEmpty)
        XCTAssertEqual(model.finderAuthorizationState, .notConfirmed)
        XCTAssertTrue(model.canCreate)
        await model.createFile()
        XCTAssertNotNil(model.createdFileURL)
        XCTAssertTrue(try grants.loadAuthorizedDirectories().isEmpty)
    }

    func testSavedGrantSelectionResolvesOnlySelectedIDAndSkipsBlockedUnrelatedResolver() async throws {
        let selectedURL = temporaryDirectory.appendingPathComponent("Selected")
        let unrelatedURL = temporaryDirectory.appendingPathComponent("Offline")
        for url in [selectedURL, unrelatedURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let seed = makeAuthorizationStore(defaults: defaults)
        // Put the unrelated record first so accidental whole-inventory scans hit it.
        _ = try seed.authorize(unrelatedURL)
        let selected = try seed.authorize(selectedURL)
        let unrelatedGate = CreationGate()
        defer { unrelatedGate.release.signal() }
        let selectedPersistentCalls = DispatchSemaphore(value: 0)
        let selectedTransferCalls = DispatchSemaphore(value: 0)
        let grants = AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { Self.bookmarkData(for: $0) },
            transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { data in
                let value = try Self.resolveBookmark(data)
                guard value.url.resolvingSymlinksInPath() == selected.url else {
                    unrelatedGate.blockOnce()
                    throw TestError.bookmarkResolutionFailed
                }
                selectedPersistentCalls.signal()
                return value
            },
            transferBookmarkResolver: { data in
                let value = try Self.resolveBookmark(data)
                guard value.url.resolvingSymlinksInPath() == selected.url else {
                    XCTFail("Selected-ID access must skip unrelated transfer bookmarks")
                    throw TestError.bookmarkResolutionFailed
                }
                selectedTransferCalls.signal()
                return value
            },
            startAccessing: { _ in true }, stopAccessing: { _ in }
        )
        let model = makeViewModel(authorizationStore: grants)
        try TemplateStore(defaults: defaults).saveTemplates(model.templates)
        await model.selectAuthorizedDirectory(selected)
        XCTAssertEqual(model.destinationFolder, selected.url)
        XCTAssertEqual(selectedPersistentCalls.wait(timeout: .now()), .success)
        XCTAssertEqual(selectedPersistentCalls.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(selectedTransferCalls.wait(timeout: .now()), .success)
        XCTAssertEqual(selectedTransferCalls.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(unrelatedGate.started.wait(timeout: .now()), .timedOut)
        await model.createFile()
        XCTAssertNotNil(model.createdFileURL)
        XCTAssertEqual(selectedTransferCalls.wait(timeout: .now()), .success)
        XCTAssertEqual(selectedTransferCalls.wait(timeout: .now()), .success)
        XCTAssertEqual(selectedTransferCalls.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(unrelatedGate.started.wait(timeout: .now()), .timedOut)
    }

    func testTargetedSavedGrantResolutionRejectsMissingAndStaleSelection() async throws {
        let seed = makeAuthorizationStore(defaults: defaults)
        let selected = try seed.authorize(temporaryDirectory)
        XCTAssertThrowsError(try seed.authorizedDirectory(withID: UUID()))
        let grants = AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { Self.bookmarkData(for: $0) },
            transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { data in
                let value = try Self.resolveBookmark(data)
                return ResolvedSecurityScopedBookmark(url: value.url, isStale: true)
            },
            transferBookmarkResolver: { _ in
                XCTFail("A newly stale selection must fail before access admission")
                throw TestError.bookmarkResolutionFailed
            },
            startAccessing: { _ in true }, stopAccessing: { _ in }
        )
        let model = makeViewModel(authorizationStore: grants)
        await model.selectAuthorizedDirectory(selected)
        XCTAssertNil(model.destinationFolder)
        XCTAssertEqual(model.status, .failure(AuthorizedDirectoryStoreError.authorizationChanged.localizedDescription))
    }

    func testSavedGrantSelectionCanCreateUsingAuthoritativeTemplate() async throws {
        let destination = temporaryDirectory.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let grants = makeAuthorizationStore(defaults: defaults)
        let selected = try grants.authorize(destination)
        let model = makeViewModel(authorizationStore: grants)
        try TemplateStore(defaults: defaults).saveTemplates(model.templates)
        await model.selectAuthorizedDirectory(selected)
        XCTAssertTrue(model.canCreate)
        await model.createFile()
        let created = try XCTUnwrap(model.createdFileURL)
        XCTAssertEqual(created.deletingLastPathComponent().resolvingSymlinksInPath(), destination.resolvingSymlinksInPath())
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
    }

    func testSavedSelectionRejectsRevokedGrantInsteadOfUsingOverlappingParentGrant() async throws {
        let destination = temporaryDirectory.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let grants = makeAuthorizationStore(defaults: defaults)
        _ = try grants.authorize(temporaryDirectory)
        let selected = try grants.authorize(destination)
        let model = makeViewModel(authorizationStore: grants)
        try TemplateStore(defaults: defaults).saveTemplates(model.templates)
        await model.selectAuthorizedDirectory(selected)
        XCTAssertEqual(model.destinationFolder, selected.url)
        XCTAssertEqual(model.finderAuthorizationState, .saved)
        XCTAssertTrue(try grants.revoke(selected.id))
        await model.createFile()
        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(model.status, .failure("无法确认目标文件夹，本次未创建文件：\(AuthorizedDirectoryStoreError.directoryNotAuthorized.localizedDescription)"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        // Existing URL-only callers still have their explicitly permitted parent fallback.
        XCTAssertTrue(try grants.withAccess(to: destination) { true })
    }

    func testSavedSelectionRechecksGrantAtWriteAfterTemplateLoad() async throws {
        let destination = temporaryDirectory.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let grants = makeAuthorizationStore(defaults: defaults)
        _ = try grants.authorize(temporaryDirectory)
        let selected = try grants.authorize(destination)
        let template = FileTemplate(name: "Plain", fileExtension: "txt", content: "body")
        let gate = CreationGate()
        defer { gate.release.signal() }
        let model = QuickFileViewModel(templates: [template], authorizedDirectoryStore: grants,
            authoritativeTemplateLoader: { gate.blockOnce(); return [template] })
        await model.selectAuthorizedDirectory(selected)
        let creation = Task { await model.createFile() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertTrue(try grants.revoke(selected.id))
        gate.release.signal()
        await creation.value
        XCTAssertNil(model.createdFileURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testSavedSelectionUsesSelectedIDAndRejectsSamePathReplacement() async throws {
        let destination = temporaryDirectory.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let grants = makeAuthorizationStore(defaults: defaults)
        let selected = try grants.authorize(destination)
        XCTAssertTrue(try grants.withAccess(to: destination, authorizationID: selected.id) { true })
        XCTAssertThrowsError(try grants.withAccess(to: destination, authorizationID: UUID()) { true })
        let model = makeViewModel(authorizationStore: grants)
        try TemplateStore(defaults: defaults).saveTemplates(model.templates)
        await model.selectAuthorizedDirectory(selected)
        try FileManager.default.moveItem(at: destination, to: temporaryDirectory.appendingPathComponent("Old"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        await model.createFile()
        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(model.status, .failure("无法确认目标文件夹，本次未创建文件：\(FileCreationError.destinationIdentityChanged.localizedDescription)"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testStaleEditorRejectsCanonicallyEquivalentButByteDifferentConcurrentEdit() async throws {
        let store = TemplateStore(defaults: defaults)
        let original = FileTemplate(name: "Name", fileExtension: "txt", content: "\u{00e9}")
        try store.saveTemplates([original])
        let model = QuickFileViewModel(templateStore: store, templates: [original])
        var newer = original
        newer.content = "e\u{0301}"
        try await model.saveTemplate(newer, replacing: original)
        var staleDraft = original
        staleDraft.name = "Stale name change"
        await assertThrowsAsync(try await model.saveTemplate(staleDraft, replacing: original)) { error in
            guard case QuickFileViewModel.TemplateSaveError.changed = error else {
                return XCTFail("Expected byte-exact stale-editor conflict: \(error)")
            }
        }
        let saved = try XCTUnwrap(store.reloadTemplates().first)
        XCTAssertTrue(saved.content.utf8.elementsEqual(newer.content.utf8))
        XCTAssertEqual(saved.name, original.name)
    }

    func testPreparingDuplicateByIDAndDiscardingDraftDoesNotSave() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "{{clipboard}}",
                                    isEnabled: false, defaultFilename: "Original document")
        let writer = TemplateStore(defaults: defaults, storageURL: storageURL)
        try writer.saveTemplates([original])
        let bytes = try Data(contentsOf: storageURL)
        let writes = TemplateWriteCounter()
        let store = TemplateStore(defaults: defaults, storageURL: storageURL, writeTemplatesData: { data, url in
            writes.record()
            try data.write(to: url, options: .atomic)
        })
        let model = QuickFileViewModel(templateStore: store, templates: [original], clipboardProvider: {
            XCTFail("Preparing a duplicate must not read the clipboard")
            return nil
        })

        var draft = TemplateDraft(template: try XCTUnwrap(model.template(withID: original.id)))
        XCTAssertEqual(draft.defaultFilename, original.defaultFilename)
        XCTAssertEqual(draft.content, original.content)
        XCTAssertFalse(draft.isEnabled)
        draft.name = "Unsaved copy"
        draft.defaultFilename = "Unsaved filename"
        draft.content = "Unsaved body"

        XCTAssertNil(model.template(withID: UUID()))
        XCTAssertEqual(writes.count, 0)
        XCTAssertEqual(try Data(contentsOf: storageURL), bytes)
        XCTAssertEqual(model.templates, [original])
        XCTAssertNil(model.status)
        XCTAssertFalse(model.isSavingTemplates)
    }

    func testSaveAsNewLoadsFreshSnapshotAppendsNewIDAndPreservesConcurrentChanges() async throws {
        let store = TemplateStore(defaults: defaults)
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old",
                                    defaultFilename: "Old filename")
        try store.saveTemplates([original])
        let model = QuickFileViewModel(templateStore: store, templates: [original])
        let newer = FileTemplate(id: original.id, name: "Original", fileExtension: "txt", content: "newer",
                                 defaultFilename: "Concurrent filename")
        let other = FileTemplate(name: "Other", fileExtension: "md", content: "keep", isEnabled: false)
        try store.saveTemplates([newer, other])
        var draft = original
        draft.content = "my draft"
        draft.defaultFilename = "Copy filename"
        draft.isEnabled = false
        let id = try await model.saveTemplateAsNew(draft)
        let result = try store.reloadTemplates()
        XCTAssertEqual(Array(result.prefix(2)), [newer, other])
        XCTAssertEqual(result.last?.id, id)
        XCTAssertNotEqual(id, original.id)
        XCTAssertEqual(result.last?.content, "my draft")
        XCTAssertEqual(result.last?.name, draft.name)
        XCTAssertEqual(result.last?.fileExtension, draft.fileExtension)
        XCTAssertEqual(result.last?.defaultFilename, "Copy filename")
        XCTAssertEqual(result.last?.isEnabled, false)
        XCTAssertEqual(model.templates, result)
    }

    func testSaveAsNewCountBudgetFailurePreservesLibraryAndAllowsDeletionAndRetry() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let maximum = TemplateTransferLimits.default.maximumTemplates
        let originals = (0..<maximum).map {
            FileTemplate(name: "Template \($0)", fileExtension: "txt", content: "keep")
        }
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        try store.saveTemplates(originals)
        let bytes = try Data(contentsOf: storageURL)
        let model = QuickFileViewModel(
            templateStore: store, templates: originals,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults)
        )
        await model.selectDestinationFolder(temporaryDirectory)
        model.requestedFilename = "keep filename draft"
        let selectedID = model.selectedTemplateID
        let draft = FileTemplate(name: "Draft", fileExtension: "md", content: "keep template draft")

        await assertThrowsAsync(try await model.saveTemplateAsNew(draft)) { error in
            XCTAssertEqual(error as? TemplateTransferError, .tooManyTemplates(maximum: maximum))
        }
        XCTAssertEqual(try Data(contentsOf: storageURL), bytes)
        XCTAssertEqual(model.templates, originals)
        XCTAssertNil(model.templateLoadError)
        XCTAssertFalse(model.isSavingTemplates)
        XCTAssertTrue(model.canCreate)
        XCTAssertEqual(model.selectedTemplateID, selectedID)
        XCTAssertEqual(model.requestedFilename, "keep filename draft")

        // Repair the count using the still-available library, without a reload.
        await assertTrueAsync(await model.deleteTemplate(withID: originals.last!.id))
        let id = try await model.saveTemplateAsNew(draft)
        let saved = try store.reloadTemplates()
        XCTAssertEqual(saved.count, maximum)
        XCTAssertEqual(saved.last?.id, id)
        XCTAssertNotEqual(id, draft.id)
        XCTAssertEqual(saved.last.map(TransferTemplate.init), TransferTemplate(draft))
        XCTAssertEqual(model.templates, saved)
        XCTAssertNil(model.templateLoadError)
    }

    func testSaveAsNewFieldBudgetFailurePreservesLibraryAndAllowsCorrectedDraftRetry() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "keep")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        try store.saveTemplates([original])
        let bytes = try Data(contentsOf: storageURL)
        let model = QuickFileViewModel(
            templateStore: store, templates: [original],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults)
        )
        await model.selectDestinationFolder(temporaryDirectory)
        model.requestedFilename = "keep filename draft"
        let maximum = TemplateTransferLimits.default.maximumNameBytes
        var draft = FileTemplate(name: String(repeating: "x", count: maximum + 1),
                                 fileExtension: "md", content: "keep template draft")
        let originalDraft = draft

        await assertThrowsAsync(try await model.saveTemplateAsNew(draft)) { error in
            XCTAssertEqual(error as? TemplateTransferError,
                           .fieldTooLarge(index: 1, field: "名称", maximumBytes: maximum))
        }
        XCTAssertEqual(try Data(contentsOf: storageURL), bytes)
        XCTAssertEqual(model.templates, [original])
        XCTAssertNil(model.templateLoadError)
        XCTAssertFalse(model.isSavingTemplates)
        XCTAssertTrue(model.canCreate)
        XCTAssertEqual(model.selectedTemplateID, original.id)
        XCTAssertEqual(model.requestedFilename, "keep filename draft")
        XCTAssertEqual(TransferTemplate(draft), TransferTemplate(originalDraft))

        draft.name = "Corrected draft"
        let id = try await model.saveTemplateAsNew(draft)
        let saved = try store.reloadTemplates()
        XCTAssertEqual(saved.first, original)
        XCTAssertEqual(saved.last?.id, id)
        XCTAssertNotEqual(id, draft.id)
        XCTAssertEqual(saved.last.map(TransferTemplate.init), TransferTemplate(draft))
        XCTAssertEqual(model.templates, saved)
        XCTAssertNil(model.templateLoadError)
    }

    func testSaveAsNewReadFailureWrappingBudgetErrorStillInvalidatesLibrary() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "keep")
        try TemplateStore(defaults: defaults, storageURL: storageURL).saveTemplates([original])
        let bytes = try Data(contentsOf: storageURL)
        let store = TemplateStore(defaults: defaults, storageURL: storageURL, readTemplatesData: { _ in
            throw TemplateTransferError.fileTooLarge(maximumBytes: 1)
        })
        let model = QuickFileViewModel(
            templateStore: store, templates: [original],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults)
        )
        await model.selectDestinationFolder(temporaryDirectory)
        model.requestedFilename = "keep draft"

        await assertThrowsAsync(try await model.saveTemplateAsNew(original)) { error in
            guard case TemplateStore.StoreError.readFailed = error else {
                return XCTFail("Expected authoritative read failure: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: storageURL), bytes)
        XCTAssertEqual(model.templates, [original])
        XCTAssertNotNil(model.templateLoadError)
        XCTAssertFalse(model.isSavingTemplates)
        XCTAssertFalse(model.canCreate)
        XCTAssertEqual(model.requestedFilename, "keep draft")
    }

    func testSaveAsNewPersistenceFailurePreservesReadableLibrary() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "keep")
        try TemplateStore(defaults: defaults, storageURL: storageURL).saveTemplates([original])
        let bytes = try Data(contentsOf: storageURL)
        let store = TemplateStore(defaults: defaults, storageURL: storageURL, writeTemplatesData: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let model = QuickFileViewModel(
            templateStore: store, templates: [original],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults)
        )
        await model.selectDestinationFolder(temporaryDirectory)
        model.requestedFilename = "keep draft"

        await assertThrowsAsync(try await model.saveTemplateAsNew(original)) { error in
            guard case TemplateStore.StoreError.persistenceFailed = error else {
                return XCTFail("Expected persistence failure: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: storageURL), bytes)
        XCTAssertEqual(model.templates, [original])
        XCTAssertNil(model.templateLoadError)
        XCTAssertFalse(model.isSavingTemplates)
        XCTAssertTrue(model.canCreate)
        XCTAssertEqual(model.requestedFilename, "keep draft")
    }

    func testSaveAsNewCASConflictDoesNotOverwriteNewerList() async throws {
        let store = TemplateStore(defaults: defaults)
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        let newer = FileTemplate(name: "Concurrent", fileExtension: "md", content: "new")
        try store.saveTemplates([original])
        let gate = CreationGate()
        defer { gate.release.signal() }
        let model = QuickFileViewModel(templateStore: store, templates: [original], authoritativeTemplateLoader: {
            let loaded = try store.reloadTemplates()
            gate.blockOnce()
            return loaded
        })
        let saving = Task { try await model.saveTemplateAsNew(original) }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertTrue(model.isSavingTemplates)
        await assertThrowsAsync(try await model.saveTemplateAsNew(original))
        try store.saveTemplates([newer])
        gate.release.signal()
        await assertThrowsAsync(try await saving.value)
        XCTAssertEqual(try store.reloadTemplates(), [newer])
        XCTAssertEqual(model.templates, [original])
        XCTAssertEqual(model.templateLoadFailure, .configurationChanged)
        XCTAssertFalse(try XCTUnwrap(model.templateLoadFailure).offersConfigurationRecovery)
        await assertThrowsAsync(try await model.prepareTemplateRecovery())
    }

    func testSaveAsNewCannotBypassCorruptReadButSucceedsAfterFreshAuthoritativeRead() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let bytes = Data("invalid-json".utf8)
        try bytes.write(to: storageURL)
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        let model = QuickFileViewModel(templateStore: store)
        await model.loadTemplatesIfNeeded()
        let draft = FileTemplate(name: "Draft", fileExtension: "txt", content: "keep")
        await assertThrowsAsync(try await model.saveTemplateAsNew(draft))
        XCTAssertEqual(try Data(contentsOf: storageURL), bytes)
        XCTAssertNotNil(model.templateLoadError)
        let restored = FileTemplate(name: "Restored", fileExtension: "md", content: "authoritative")
        try JSONEncoder().encode([restored]).write(to: storageURL)
        let id = try await model.saveTemplateAsNew(draft)
        XCTAssertEqual(try store.reloadTemplates().first, restored)
        XCTAssertEqual(model.templates.last?.id, id)
        XCTAssertNil(model.templateLoadError)
    }

    func testSearchUsesNameOrExtensionOnlyAndMovesIDsAgainstFullList() async throws {
        let values = [
            FileTemplate(name: "Alpha", fileExtension: "txt", content: "hidden needle"),
            FileTemplate(name: "Beta", fileExtension: "md", content: "", isEnabled: false),
            FileTemplate(name: "Gamma", fileExtension: "TXT", content: "")
        ]
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates(values)
        let model = QuickFileViewModel(templateStore: store, templates: values)
        XCTAssertTrue(model.filteredTemplates(search: "needle").isEmpty)
        XCTAssertEqual(model.filteredTemplates(search: " txt ").map(\.id), [values[0].id, values[2].id])
        XCTAssertEqual(model.filteredTemplates(search: "bEtA").map(\.id), [values[1].id])
        XCTAssertTrue(model.filteredTemplates(search: "Beta", enabledOnly: true).isEmpty)
        await assertTrueAsync(await model.moveTemplate(withID: values[2].id, to: .first))
        XCTAssertEqual(model.templates.map(\.id), [values[2].id, values[0].id, values[1].id])
        await assertTrueAsync(await model.moveTemplate(withID: values[2].id, to: .last))
        XCTAssertEqual(model.templates, values)
        await assertFalseAsync(await model.moveTemplate(withID: UUID(), to: .first))
        await assertTrueAsync(await model.deleteTemplate(withID: values[1].id))
        XCTAssertEqual(model.templates.map(\.id), [values[0].id, values[2].id])
    }

    func testDropMovesBeforeAndAfterInBothDirectionsWithOneSavePerMove() async throws {
        let values = (0..<4).map { FileTemplate(name: "Template \($0)", fileExtension: "txt", content: "body \($0)") }
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let writer = TemplateStore(defaults: defaults, storageURL: storageURL)
        let writes = TemplateWriteCounter()
        let store = TemplateStore(defaults: defaults, storageURL: storageURL, writeTemplatesData: { data, url in
            writes.record()
            try data.write(to: url, options: .atomic)
        })
        let cases: [(Int, Int, QuickFileViewModel.TemplatePlacement, [Int])] = [
            (0, 2, .before, [1, 0, 2, 3]),
            (0, 2, .after, [1, 2, 0, 3]),
            (3, 1, .before, [0, 3, 1, 2]),
            (3, 1, .after, [0, 1, 3, 2])
        ]
        for (source, target, placement, order) in cases {
            try writer.saveTemplates(values)
            let model = QuickFileViewModel(templateStore: store, templates: values)
            let previousWrites = writes.count
            await assertTrueAsync(await model.moveTemplate(
                withID: values[source].id, relativeTo: values[target].id, placement: placement
            ))
            let expected = order.map { values[$0] }
            XCTAssertEqual(model.templates, expected)
            XCTAssertEqual(try writer.reloadTemplates(), expected)
            XCTAssertEqual(writes.count, previousWrites + 1)
            await assertFalseAsync(await model.moveTemplate(
                withID: values[source].id, relativeTo: values[target].id, placement: placement
            ))
            XCTAssertEqual(writes.count, previousWrites + 1)
        }
    }

    func testDropInFilteredListKeepsHiddenRowsInTheirRelativeOrder() async throws {
        let values = [
            FileTemplate(name: "Visible first", fileExtension: "txt", content: ""),
            FileTemplate(name: "Hidden first", fileExtension: "md", content: "", isEnabled: false),
            FileTemplate(name: "Visible second", fileExtension: "txt", content: ""),
            FileTemplate(name: "Hidden second", fileExtension: "md", content: "", isEnabled: false),
            FileTemplate(name: "Visible third", fileExtension: "txt", content: "")
        ]
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates(values)
        let model = QuickFileViewModel(templateStore: store, templates: values)
        XCTAssertEqual(model.filteredTemplates(search: "Visible", enabledOnly: true).map(\.id),
                       [values[0].id, values[2].id, values[4].id])
        await assertTrueAsync(await model.moveTemplate(
            withID: values[4].id, relativeTo: values[0].id, placement: .before
        ))
        XCTAssertEqual(model.templates.map(\.id), [values[4].id, values[0].id, values[1].id, values[2].id, values[3].id])
        await assertTrueAsync(await model.moveTemplate(
            withID: values[4].id, relativeTo: values[2].id, placement: .after
        ))
        XCTAssertEqual(model.templates.map(\.id), [values[0].id, values[1].id, values[2].id, values[4].id, values[3].id])
        XCTAssertEqual(model.templates.filter { !$0.isEnabled }.map(\.id), [values[1].id, values[3].id])
        XCTAssertEqual(try store.reloadTemplates(), model.templates)
    }

    func testDropRejectsMissingIDsSameIDAndUnchangedPositionWithoutSaving() async throws {
        let values = (0..<3).map { FileTemplate(name: "Template \($0)", fileExtension: "txt", content: "") }
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let writer = TemplateStore(defaults: defaults, storageURL: storageURL)
        try writer.saveTemplates(values)
        let bytes = try Data(contentsOf: storageURL)
        let writes = TemplateWriteCounter()
        let store = TemplateStore(defaults: defaults, storageURL: storageURL, writeTemplatesData: { data, url in
            writes.record()
            try data.write(to: url, options: .atomic)
        })
        let model = QuickFileViewModel(templateStore: store, templates: values)
        let cases: [(FileTemplate.ID, FileTemplate.ID, QuickFileViewModel.TemplatePlacement)] = [
            (UUID(), values[0].id, .before),
            (values[0].id, UUID(), .after),
            (values[0].id, values[0].id, .before),
            (values[0].id, values[1].id, .before),
            (values[1].id, values[0].id, .after)
        ]
        for (source, target, placement) in cases {
            await assertFalseAsync(await model.moveTemplate(withID: source, relativeTo: target, placement: placement))
        }
        XCTAssertEqual(writes.count, 0)
        XCTAssertEqual(try Data(contentsOf: storageURL), bytes)
        XCTAssertEqual(model.templates, values)
        XCTAssertNil(model.status)
    }

    func testDropWhileAnotherDropIsSavingDoesNotSubmitSecondWrite() async throws {
        let values = (0..<3).map { FileTemplate(name: "Template \($0)", fileExtension: "txt", content: "") }
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let writer = TemplateStore(defaults: defaults, storageURL: storageURL)
        try writer.saveTemplates(values)
        let gate = CreationGate()
        defer { gate.release.signal() }
        let writes = TemplateWriteCounter()
        let store = TemplateStore(
            defaults: defaults, storageURL: storageURL,
            fileManager: PausedTemplateFileManager(gate: gate),
            writeTemplatesData: { data, url in
                writes.record()
                try data.write(to: url, options: .atomic)
            }
        )
        let model = QuickFileViewModel(templateStore: store, templates: values)
        let dropping = Task { await model.moveTemplate(withID: values[2].id, relativeTo: values[0].id, placement: .before) }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertTrue(model.isSavingTemplates)
        await assertFalseAsync(await model.moveTemplate(withID: values[2].id, relativeTo: values[0].id, placement: .before))
        await assertFalseAsync(await model.moveTemplate(withID: values[0].id, relativeTo: values[1].id, placement: .after))
        XCTAssertEqual(model.templates, values)
        XCTAssertEqual(writes.count, 0)
        XCTAssertNil(model.status)
        gate.release.signal()
        await assertTrueAsync(await dropping.value)
        XCTAssertTrue(gate.wasReleasedBeforeTimeout)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(model.templates, [values[2], values[0], values[1]])
        XCTAssertEqual(try writer.reloadTemplates(), model.templates)
    }

    func testDropPersistenceFailureKeepsOldListAndConfiguration() async throws {
        let values = (0..<3).map { FileTemplate(name: "Template \($0)", fileExtension: "txt", content: "") }
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let writer = TemplateStore(defaults: defaults, storageURL: storageURL)
        try writer.saveTemplates(values)
        let bytes = try Data(contentsOf: storageURL)
        let writes = TemplateWriteCounter()
        let store = TemplateStore(defaults: defaults, storageURL: storageURL, writeTemplatesData: { _, _ in
            writes.record()
            throw CocoaError(.fileWriteNoPermission)
        })
        let model = QuickFileViewModel(templateStore: store, templates: values)
        await assertFalseAsync(await model.moveTemplate(withID: values[2].id, relativeTo: values[0].id, placement: .before))
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(model.templates, values)
        XCTAssertEqual(try Data(contentsOf: storageURL), bytes)
        XCTAssertFalse(model.isSavingTemplates)
        XCTAssertNil(model.templateLoadError)
        guard case .failure = model.status else { return XCTFail("Expected save failure") }
    }

    func testDropCASConflictKeepsExternalSaveAndRequiresReload() async throws {
        let values = (0..<3).map { FileTemplate(name: "Template \($0)", fileExtension: "txt", content: "") }
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let writer = TemplateStore(defaults: defaults, storageURL: storageURL)
        try writer.saveTemplates(values)
        let gate = CreationGate()
        defer { gate.release.signal() }
        let writes = TemplateWriteCounter()
        let store = TemplateStore(
            defaults: defaults, storageURL: storageURL,
            fileManager: PausedTemplateFileManager(gate: gate),
            writeTemplatesData: { data, url in
                writes.record()
                try data.write(to: url, options: .atomic)
            }
        )
        let model = QuickFileViewModel(templateStore: store, templates: values)
        let dropping = Task { await model.moveTemplate(withID: values[2].id, relativeTo: values[0].id, placement: .before) }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        var changed = values[1]
        changed.defaultFilename = "Saved externally"
        let external = [values[0], changed]
        try writer.saveTemplates(external)
        gate.release.signal()
        await assertFalseAsync(await dropping.value)
        XCTAssertTrue(gate.wasReleasedBeforeTimeout)
        XCTAssertEqual(writes.count, 0)
        XCTAssertEqual(try writer.reloadTemplates(), external)
        XCTAssertEqual(model.templates, values)
        XCTAssertEqual(model.templateLoadFailure, .configurationChanged)
        XCTAssertFalse(model.isSavingTemplates)
        await assertFalseAsync(await model.moveTemplate(withID: values[2].id, relativeTo: values[0].id, placement: .before))
        XCTAssertEqual(writes.count, 0)
    }

    func testImportPreviewCancellationHasNoMutationAndImportAppendsOnceWithoutClipboardReads() async throws {
        let existing = FileTemplate(name: "Name", fileExtension: "txt", content: "existing")
        let imported = FileTemplate(name: "Name", fileExtension: "md", content: "{{clipboard}}", isEnabled: false)
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates([existing])
        let model = QuickFileViewModel(templateStore: store, templates: [existing], clipboardProvider: {
            XCTFail("Import must never read the clipboard"); return "private"
        })
        let url = temporaryDirectory.appendingPathComponent("import.json")
        try TemplateTransferFile.write(TemplateTransferBundle(templates: [existing, imported]), to: url)
        let cancelled = try await model.prepareTemplateImport(from: url)
        XCTAssertEqual(cancelled.plan.addedCount, 1)
        XCTAssertEqual(cancelled.plan.renamedCount, 1)
        XCTAssertEqual(cancelled.plan.skippedCount, 1)
        XCTAssertEqual(cancelled.clipboardCount, 1)
        XCTAssertEqual(model.templates, [existing])
        XCTAssertEqual(try store.reloadTemplates(), [existing])
        let preview = try await model.prepareTemplateImport(from: url)
        try await model.importTemplates(preview)
        XCTAssertEqual(model.templates.count, 2)
        XCTAssertEqual(model.templates.first, existing)
        XCTAssertFalse(model.templates[1].isEnabled)
        XCTAssertEqual(model.templates[1].content, "{{clipboard}}")
        XCTAssertNotEqual(model.templates[1].id, imported.id)
        await assertThrowsAsync(try await model.importTemplates(preview))
        XCTAssertEqual(try store.reloadTemplates().count, 2)
    }

    func testImportCASFailureAndMalformedFinalItemDoNotPartiallyChangeOriginalData() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "keep")
        let addition = FileTemplate(name: "Added", fileExtension: "md", content: "new")
        try store.saveTemplates([original])
        let model = QuickFileViewModel(templateStore: store, templates: [original])
        let url = temporaryDirectory.appendingPathComponent("import.json")
        try TemplateTransferFile.write(TemplateTransferBundle(templates: [addition]), to: url)
        let preview = try await model.prepareTemplateImport(from: url)
        try store.saveTemplates([original, addition])
        let concurrentBytes = try Data(contentsOf: storageURL)
        await assertThrowsAsync(try await model.importTemplates(preview))
        XCTAssertEqual(try Data(contentsOf: storageURL), concurrentBytes)
        XCTAssertEqual(model.templates, [original])
        await model.reloadTemplates()
        try Data("{\"format\":\"quickfile.templates\",\"version\":1,\"templates\":[{\"name\":\"valid\",\"fileExtension\":\"txt\",\"content\":\"x\",\"isEnabled\":true},{}]}".utf8).write(to: url)
        await assertThrowsAsync(try await model.prepareTemplateImport(from: url))
        XCTAssertEqual(try Data(contentsOf: storageURL), concurrentBytes)
    }

    func testExportAllPreservesLargeLiteralBodyDisabledOrderAndExcludesPrivateMetadata() async throws {
        let content = String(repeating: "x", count: 4_600_000) + "{{clipboard}} {{date}}"
        let disabled = FileTemplate(name: "Disabled", fileExtension: "txt", content: content, isEnabled: false)
        let enabled = FileTemplate(name: "Enabled", fileExtension: "md", content: "raw")
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates([disabled, enabled])
        let model = QuickFileViewModel(templateStore: store, templates: [disabled, enabled], clipboardProvider: {
            XCTFail("Export must never read the clipboard"); return "secret pasteboard"
        })
        let url = temporaryDirectory.appendingPathComponent("export.json")
        try await model.exportTemplates(to: url)
        let bundle = try TemplateTransferFile.read(from: url)
        XCTAssertEqual(bundle.templates.map(\.name), ["Disabled", "Enabled"])
        XCTAssertFalse(bundle.templates[0].isEnabled)
        XCTAssertEqual(bundle.templates[0].content, content)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains(disabled.id.uuidString))
        XCTAssertFalse(json.contains("secret pasteboard"))
        XCTAssertFalse(json.contains("bookmark"))
        XCTAssertFalse(json.contains("authorization"))
        XCTAssertFalse(json.contains("history"))
    }

    func testExportCannotOverwriteLiveTemplateConfiguration() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let original = FileTemplate(name: "Keep", fileExtension: "txt", content: "original")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        try store.saveTemplates([original])
        let bytes = try Data(contentsOf: storageURL)
        let model = QuickFileViewModel(templateStore: store, templates: [original])
        await assertThrowsAsync(try await model.exportTemplates(to: storageURL))
        XCTAssertEqual(try Data(contentsOf: storageURL), bytes)
        XCTAssertEqual(model.templates, [original])
        XCTAssertNil(model.templateLoadError)
    }

    func testExplicitRecoveryPreviewDoesNotResetAndConfirmedRecoveryShowsLocalBackup() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let original = Data("corrupt-json".utf8)
        try original.write(to: storageURL)
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        let model = QuickFileViewModel(templateStore: store)
        await model.loadTemplatesIfNeeded()
        XCTAssertEqual(model.templateLoadFailure, .malformedConfiguration)
        XCTAssertTrue(try XCTUnwrap(model.templateLoadFailure).offersConfigurationRecovery)
        let preview = try await model.prepareTemplateRecovery()
        XCTAssertEqual(try Data(contentsOf: storageURL), original)
        XCTAssertNil(model.recoveryBackupURL)
        await assertFalseAsync(await model.restoreBuiltInTemplates())
        try await model.recoverTemplates(preview)
        XCTAssertEqual(model.templates, BuiltInTemplates.all)
        XCTAssertNil(model.templateLoadError)
        let backupURL = try XCTUnwrap(model.recoveryBackupURL)
        XCTAssertTrue(backupURL.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testFinderPresentationLimitDoesNotLimitMainAppThreeHundredTemplates() throws {
        let templates = (0..<300).map { FileTemplate(name: "Template \($0)", fileExtension: "txt", content: "") }
        let model = QuickFileViewModel(templateStore: TemplateStore(defaults: defaults), templates: templates)
        let limited = FinderMenuModelBuilder().entries(from: model.templates, limit: try FinderMenuDisplayLimit(maximumCount: 1))
        XCTAssertEqual(limited.count, 1)
        XCTAssertEqual(model.templates, templates)
        XCTAssertEqual(model.enabledTemplates, templates)
        model.selectedTemplateID = templates[299].id
        XCTAssertEqual(model.selectedTemplate?.id, templates[299].id)
    }

    func testExplicitFinderAuthorizationSavesDirectoryWithoutAppKit() async throws {
        let authorizationStore = makeAuthorizationStore(defaults: defaults)
        let viewModel = makeViewModel(authorizationStore: authorizationStore)

        await viewModel.saveFinderAuthorization(for: temporaryDirectory)

        XCTAssertEqual(viewModel.destinationFolder, temporaryDirectory)
        XCTAssertEqual(viewModel.finderAuthorizationState, .saved)
        XCTAssertEqual(
            viewModel.status,
            .success("已选择文件夹，并保存 Finder Extension 的安全授权。")
        )
        XCTAssertEqual(
            try authorizationStore.loadAuthorizedDirectories().map(\.url),
            [temporaryDirectory.standardizedFileURL]
        )
    }

    func testCreatesFileUsingInjectedClipboardProvider() async throws {
        let template = FileTemplate(
            name: "Markdown",
            fileExtension: "md",
            content: "{{clipboard}}"
        )
        let templateStore = TemplateStore(defaults: defaults)
        try templateStore.saveTemplates([template])
        let viewModel = QuickFileViewModel(
            templateStore: templateStore,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            fileCreationService: FileCreationService(),
            clipboardProvider: { "copied" }
        )
        await viewModel.loadTemplatesIfNeeded()
        await viewModel.saveFinderAuthorization(for: temporaryDirectory)
        viewModel.requestedFilename = "note"

        await viewModel.createFile()

        let createdFileURL = try XCTUnwrap(viewModel.createdFileURL)
        XCTAssertEqual(createdFileURL.lastPathComponent, "note.md")
        XCTAssertEqual(try String(contentsOf: createdFileURL, encoding: .utf8), "copied")
        XCTAssertEqual(viewModel.status, .success("已创建 note.md"))
    }

    func testOrdinaryCreationRejectsTemplateDisabledByAnotherInstanceWithoutReadingClipboard() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("shared-templates.json")
        let firstStore = TemplateStore(defaults: defaults, storageURL: storageURL)
        let secondStore = TemplateStore(defaults: defaults, storageURL: storageURL)
        var template = FileTemplate(name: "Clipboard", fileExtension: "txt", content: "{{clipboard}}")
        try firstStore.saveTemplates([template])
        var clipboardReads = 0
        let model = QuickFileViewModel(
            templateStore: firstStore,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            clipboardProvider: { clipboardReads += 1; return "private" }
        )
        await model.loadTemplatesIfNeeded()
        model.destinationFolder = temporaryDirectory

        template.isEnabled = false
        try secondStore.saveTemplates([template])
        await model.createFile()

        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(clipboardReads, 0)
        XCTAssertEqual(model.templates, [template])
        XCTAssertEqual(model.status, .failure("所选模板已被删除或停用，请重新选择模板后再试。"))
    }

    func testOrdinaryCreationRejectsTemplateDeletedByAnotherInstanceWithoutReadingClipboard() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("shared-templates.json")
        let firstStore = TemplateStore(defaults: defaults, storageURL: storageURL)
        let secondStore = TemplateStore(defaults: defaults, storageURL: storageURL)
        let template = FileTemplate(name: "Clipboard", fileExtension: "txt", content: "{{clipboard}}")
        try firstStore.saveTemplates([template])
        var clipboardReads = 0
        let model = QuickFileViewModel(
            templateStore: firstStore,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            clipboardProvider: { clipboardReads += 1; return "private" }
        )
        await model.loadTemplatesIfNeeded()
        model.destinationFolder = temporaryDirectory

        try secondStore.saveTemplates([])
        await model.createFile()

        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(clipboardReads, 0)
        XCTAssertTrue(model.templates.isEmpty)
        XCTAssertNil(model.selectedTemplate)
        XCTAssertFalse(model.canCreate)
    }

    func testCreationAfter300To8RecoveryRejectsRemovedTemplateAndRepairsSelectionForRetry() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("shared-templates.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        let writer = TemplateStore(defaults: defaults, storageURL: storageURL)
        let templates = (0..<300).map {
            FileTemplate(name: "Template \($0)", fileExtension: "txt", content: "body \($0)")
        }
        try store.saveTemplates(templates)
        let model = QuickFileViewModel(templateStore: store)
        await model.loadTemplatesIfNeeded()
        let target = temporaryDirectory.appendingPathComponent("Output")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        model.destinationFolder = target
        model.selectedTemplateID = templates.last!.id
        model.requestedFilename = "keep draft"
        let restored = Array(templates.prefix(8))
        try writer.saveTemplates(restored)

        await model.createFile()

        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        XCTAssertEqual(model.templates, restored)
        XCTAssertEqual(model.selectedTemplateID, restored[0].id)
        XCTAssertEqual(model.requestedFilename, "keep draft")
        XCTAssertTrue(model.canCreate)
        XCTAssertEqual(model.status, .failure("所选模板已被删除或停用，请重新选择模板后再试。"))

        await model.createFile()
        let created = try XCTUnwrap(model.createdFileURL)
        XCTAssertEqual(created.lastPathComponent, "keep draft.txt")
        XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), restored[0].content)
    }

    func testCreationRepairsDisabledSelectionButDoesNotCreateUsingFallback() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        let disabled = FileTemplate(id: original.id, name: original.name,
                                    fileExtension: original.fileExtension, content: original.content,
                                    isEnabled: false)
        let fallback = FileTemplate(name: "Fallback", fileExtension: "md", content: "next")
        let model = QuickFileViewModel(templates: [original, fallback],
                                      authoritativeTemplateLoader: { [disabled, fallback] })
        model.destinationFolder = temporaryDirectory

        await model.createFile()

        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), [])
        XCTAssertEqual(model.selectedTemplateID, fallback.id)
        XCTAssertTrue(model.canCreate)
    }

    func testCreationPreflightPreservesNewerValidSelectionWhenRequestedTemplateWasRemoved() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let removed = FileTemplate(name: "Removed", fileExtension: "txt", content: "old")
        let first = FileTemplate(name: "First", fileExtension: "txt", content: "first")
        let newer = FileTemplate(name: "Newer", fileExtension: "md", content: "next")
        let model = QuickFileViewModel(templates: [removed, first, newer], authoritativeTemplateLoader: {
            gate.blockOnce()
            return [first, newer]
        })
        model.destinationFolder = temporaryDirectory
        let creation = Task { await model.createFile() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        model.selectedTemplateID = newer.id
        gate.release.signal()
        await creation.value

        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), [])
        XCTAssertEqual(model.selectedTemplateID, newer.id)
        XCTAssertTrue(model.canCreate)
    }

    func testOrdinaryCreationUsesLatestTemplateBeforeDecidingWhetherToReadClipboard() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("shared-templates.json")
        let firstStore = TemplateStore(defaults: defaults, storageURL: storageURL)
        let secondStore = TemplateStore(defaults: defaults, storageURL: storageURL)
        var template = FileTemplate(name: "Clipboard", fileExtension: "txt", content: "{{clipboard}}")
        try firstStore.saveTemplates([template])
        var clipboardReads = 0
        let model = QuickFileViewModel(
            templateStore: firstStore,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            clipboardProvider: { clipboardReads += 1; return "private" }
        )
        await model.loadTemplatesIfNeeded()
        model.destinationFolder = temporaryDirectory

        template.content = "latest"
        try secondStore.saveTemplates([template])
        await model.createFile()

        let createdURL = try XCTUnwrap(model.createdFileURL)
        XCTAssertEqual(clipboardReads, 0)
        XCTAssertEqual(try String(contentsOf: createdURL, encoding: .utf8), "latest")
        XCTAssertEqual(model.templates, [template])
    }

    func testOrdinaryCreationReadsClipboardAddedToLatestTemplateOnMainActor() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("shared-templates.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        var template = FileTemplate(name: "Plain", fileExtension: "txt", content: "plain")
        try store.saveTemplates([template])
        var reads = 0
        let model = QuickFileViewModel(
            templateStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            clipboardProvider: {
                XCTAssertTrue(Thread.isMainThread)
                reads += 1
                return "captured"
            }
        )
        await model.loadTemplatesIfNeeded()
        model.destinationFolder = temporaryDirectory
        template.content = "latest {{clipboard}}"
        try TemplateStore(defaults: defaults, storageURL: storageURL).saveTemplates([template])

        await model.createFile()

        let output = try XCTUnwrap(model.createdFileURL)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "latest captured")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.templates, [template])
    }

    func testClipboardDecisionUsesRequestedTemplateWhenSelectionChangesDuringPreflight() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let requested = FileTemplate(name: "Clipboard", fileExtension: "txt", content: "{{clipboard}}")
        let other = FileTemplate(name: "Plain", fileExtension: "txt", content: "plain")
        var reads = 0
        let model = QuickFileViewModel(
            templates: [requested, other],
            clipboardProvider: {
                XCTAssertTrue(Thread.isMainThread)
                reads += 1
                return "requested"
            },
            authoritativeTemplateLoader: {
                XCTAssertFalse(Thread.isMainThread)
                gate.blockOnce()
                return [requested, other]
            }
        )
        model.destinationFolder = temporaryDirectory
        model.selectedTemplateID = requested.id
        let creation = Task { await model.createFile() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        model.selectedTemplateID = other.id
        gate.release.signal()
        await creation.value

        let output = try XCTUnwrap(model.createdFileURL)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "requested")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.selectedTemplateID, other.id)
        XCTAssertTrue(gate.wasReleasedBeforeTimeout)
    }

    func testOrdinaryCreationDoesNotOverwriteFormEditedWhileFileWriteIsInFlight() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let initialTemplate = FileTemplate(name: "Initial", fileExtension: "txt", content: "{{clipboard}}")
        let otherTemplate = FileTemplate(name: "Other", fileExtension: "md", content: "other")
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates([initialTemplate, otherTemplate])
        let model = QuickFileViewModel(
            templateStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            fileCreationService: FileCreationService(clipboardProvider: {
                gate.blockOnce()
                return "initial"
            })
        )
        await model.loadTemplatesIfNeeded()
        model.destinationFolder = temporaryDirectory
        model.selectedTemplateID = initialTemplate.id
        model.requestedFilename = "first"

        let creation = Task { await model.createFile() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        model.selectedTemplateID = otherTemplate.id
        model.requestedFilename = "next"
        gate.release.signal()
        await creation.value

        let createdURL = try XCTUnwrap(model.createdFileURL)
        XCTAssertEqual(createdURL.lastPathComponent, "first.txt")
        XCTAssertEqual(try String(contentsOf: createdURL, encoding: .utf8), "initial")
        XCTAssertEqual(model.selectedTemplateID, otherTemplate.id)
        XCTAssertEqual(model.requestedFilename, "next")
    }

    func testOrdinaryCreationRejectsDirectoryReplacedDuringTemplateRead() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let destination = temporaryDirectory.appendingPathComponent("Selected")
        let moved = temporaryDirectory.appendingPathComponent("Original")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "safe")
        let model = QuickFileViewModel(
            templates: [template],
            authoritativeTemplateLoader: {
                XCTAssertFalse(Thread.isMainThread)
                gate.blockOnce()
                return [template]
            }
        )
        model.destinationFolder = destination
        let creation = Task { await model.createFile() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        try FileManager.default.moveItem(at: destination, to: moved)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        gate.release.signal()
        await creation.value

        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(model.status, .failure(FileCreationError.destinationIdentityChanged.localizedDescription))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [])
    }

    func testOrdinaryCreationRejectsRetargetedDirectorySymlinkDuringTemplateRead() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let first = temporaryDirectory.appendingPathComponent("First")
        let second = temporaryDirectory.appendingPathComponent("Second")
        let link = temporaryDirectory.appendingPathComponent("Selected")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "safe")
        let model = QuickFileViewModel(templates: [template], authoritativeTemplateLoader: {
            gate.blockOnce()
            return [template]
        })
        model.destinationFolder = link
        let creation = Task { await model.createFile() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        gate.release.signal()
        await creation.value

        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(model.status, .failure(FileCreationError.destinationIdentityChanged.localizedDescription))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: second.path), [])
    }

    func testUnavailableCreationTargetDoesNotInvalidateTemplateSnapshotOrReadClipboard() async throws {
        let template = FileTemplate(name: "Clipboard", fileExtension: "txt", content: "{{clipboard}}")
        var clipboardReads = 0
        let model = QuickFileViewModel(
            templates: [template], clipboardProvider: { clipboardReads += 1; return "private" },
            authoritativeTemplateLoader: { XCTFail("Invalid target should fail before template I/O"); return [template] }
        )
        model.destinationFolder = temporaryDirectory.appendingPathComponent("Missing")
        await model.createFile()
        XCTAssertNil(model.createdFileURL)
        XCTAssertNil(model.templateLoadError)
        XCTAssertEqual(model.templates, [template])
        XCTAssertEqual(clipboardReads, 0)
        XCTAssertFalse(model.isCreatingFile)
        guard case let .failure(message) = model.status else { return XCTFail("Expected target failure") }
        XCTAssertTrue(message.contains("无法确认目标文件夹"))
    }

    func testOrdinaryCreationDoesNotPublishStaleReloadOverTemplateSavedWhileAwaiting() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let store = TemplateStore(defaults: defaults)
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "{{clipboard}}")
        try store.saveTemplates([original])
        var clipboardReads = 0
        // Seed the initial snapshot so the one-shot loader gate belongs to creation,
        // not the initial load, which now shares the authoritative loader.
        let model = QuickFileViewModel(
            templateStore: store,
            templates: [original],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            clipboardProvider: { clipboardReads += 1; return "private" },
            authoritativeTemplateLoader: {
                let snapshot = try store.reloadTemplates()
                gate.blockOnce()
                return snapshot
            }
        )
        model.destinationFolder = temporaryDirectory
        var edited = original
        edited.content = "saved while reload was suspended"

        let creation = Task { await model.createFile() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertTrue(model.isCreatingFile, "Creation must own the blocked preflight before the template mutation")
        try await model.saveTemplate(edited, replacing: original)
        gate.release.signal()
        await creation.value
        XCTAssertTrue(gate.wasReleasedBeforeTimeout, "The preflight must be released by the test, not the gate timeout")

        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(clipboardReads, 0)
        XCTAssertEqual(model.templates, [edited])
        XCTAssertEqual(try store.reloadTemplates(), [edited])
        XCTAssertEqual(
            model.status,
            .failure("模板配置已在创建期间更新，本次未创建文件。请确认当前模板后重试。")
        )
    }

    func testOrdinaryCreationDoesNotPublishStaleReloadOverTemplateDisabledWhileAwaiting() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let store = TemplateStore(defaults: defaults)
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "{{clipboard}}")
        try store.saveTemplates([original])
        var clipboardReads = 0
        // Seed the initial snapshot so the one-shot loader gate belongs to creation,
        // not the initial load, which now shares the authoritative loader.
        let model = QuickFileViewModel(
            templateStore: store,
            templates: [original],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            clipboardProvider: { clipboardReads += 1; return "private" },
            authoritativeTemplateLoader: {
                let snapshot = try store.reloadTemplates()
                gate.blockOnce()
                return snapshot
            }
        )
        model.destinationFolder = temporaryDirectory

        let creation = Task { await model.createFile() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertTrue(model.isCreatingFile, "Creation must own the blocked preflight before the template mutation")
        await model.setTemplateEnabled(false, id: original.id)
        gate.release.signal()
        await creation.value
        XCTAssertTrue(gate.wasReleasedBeforeTimeout, "The preflight must be released by the test, not the gate timeout")

        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(clipboardReads, 0)
        XCTAssertEqual(model.templates.first?.isEnabled, false)
        XCTAssertEqual(try store.reloadTemplates().first?.isEnabled, false)
    }

    func testAuthorizationFailureDoesNotDiscardSelectedDirectory() async throws {
        let unavailableStore = makeAuthorizationStore(defaults: nil)
        let viewModel = makeViewModel(authorizationStore: unavailableStore)
        try TemplateStore(defaults: defaults).saveTemplates(viewModel.templates)

        await viewModel.saveFinderAuthorization(for: temporaryDirectory)

        XCTAssertEqual(viewModel.destinationFolder, temporaryDirectory)
        guard case .failed = viewModel.finderAuthorizationState else {
            return XCTFail("Finder authorization must remain failed independently from the app destination")
        }
        XCTAssertTrue(viewModel.canCreate, "Saving Finder authorization must not disable ordinary app creation")
        guard case let .failure(message) = viewModel.status else {
            return XCTFail("Expected an authorization failure")
        }
        XCTAssertTrue(message.contains("文件夹已选择"))
        await viewModel.createFile()
        let created = try XCTUnwrap(viewModel.createdFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        guard case .failed = viewModel.finderAuthorizationState else {
            return XCTFail("Successful main-app creation must not upgrade the Finder authorization state")
        }
    }

    func testChangingDestinationClearsFinderAuthorizationConfirmation() async {
        let viewModel = makeViewModel(authorizationStore: makeAuthorizationStore(defaults: defaults))
        await viewModel.saveFinderAuthorization(for: temporaryDirectory)
        XCTAssertEqual(viewModel.finderAuthorizationState, .saved)
        viewModel.destinationFolder = temporaryDirectory.appendingPathComponent("Other")
        XCTAssertEqual(viewModel.finderAuthorizationState, .notConfirmed)
        viewModel.destinationFolder = nil
        XCTAssertEqual(viewModel.finderAuthorizationState, .notConfirmed)
    }

    func testFinderContinuationRebindsRevokedSamePathGrantAndDoesNotFallBackAfterNewGrantRevoked() async throws {
        let requestedDestination = temporaryDirectory.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: requestedDestination, withIntermediateDirectories: false)
        // Resolve the complete fixture only after it exists, before selecting or requesting it.
        let destination = DirectoryPathPolicy.canonicalURL(requestedDestination)
        let grants = makeAuthorizationStore(defaults: defaults)
        _ = try grants.authorize(temporaryDirectory)
        let oldGrant = try grants.authorize(destination)
        let model = makeViewModel(authorizationStore: grants)
        try TemplateStore(defaults: defaults).saveTemplates(model.templates)
        await model.selectAuthorizedDirectory(oldGrant)
        XCTAssertEqual(model.destinationFolder, destination)
        XCTAssertTrue(try grants.revoke(oldGrant.id))

        let request = FinderAuthorizationRequest(templateID: model.selectedTemplateID,
            destinationFolder: destination, destinationIdentity: try DirectoryIdentity.capture(at: destination))
        XCTAssertEqual(request.destinationFolder, destination)
        await assertTrueAsync(await model.completeFinderAuthorizationRequest(request, authorizedDirectory: destination))
        let continuedFile = try XCTUnwrap(model.createdFileURL)
        let newGrant = try XCTUnwrap(grants.loadAuthorizedDirectories().first { $0.url == destination })
        XCTAssertNotEqual(newGrant.id, oldGrant.id)
        XCTAssertEqual(model.destinationFolder, destination)

        await model.createFile()
        let nextFile = try XCTUnwrap(model.createdFileURL)
        XCTAssertNotEqual(nextFile, continuedFile)
        let createdDirectory = nextFile.deletingLastPathComponent()
        XCTAssertEqual(DirectoryPathPolicy.canonicalURL(createdDirectory), destination)
        XCTAssertEqual(try DirectoryIdentity.capture(at: createdDirectory), try DirectoryIdentity.capture(at: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 2)

        XCTAssertTrue(try grants.revoke(newGrant.id))
        // The surviving parent grant must not hide stale provenance for the selected grant.
        XCTAssertTrue(try grants.withAccess(to: destination) { true })
        await model.createFile()
        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(model.status, .failure("无法确认目标文件夹，本次未创建文件：\(AuthorizedDirectoryStoreError.directoryNotAuthorized.localizedDescription)"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 2)
    }

    func testReboundFinderGrantIsRecheckedAtWriteAfterTemplateLoadWithoutParentFallback() async throws {
        let destination = temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let grants = makeAuthorizationStore(defaults: defaults)
        _ = try grants.authorize(temporaryDirectory)
        let oldGrant = try grants.authorize(destination)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "kept")
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates([template])
        let reboundID = LockedTestValue<UUID?>(nil)
        let loads = LockedTestValue(0)
        let model = QuickFileViewModel(templateStore: store, templates: [template], authorizedDirectoryStore: grants,
            authoritativeTemplateLoader: {
                loads.update { $0 += 1 }
                // This load runs after ordinary creation has captured the target identity.
                let id = try XCTUnwrap(reboundID.value)
                XCTAssertTrue(try grants.revoke(id))
                return [template]
            })
        await model.selectAuthorizedDirectory(oldGrant)
        XCTAssertTrue(try grants.revoke(oldGrant.id))
        let request = FinderAuthorizationRequest(templateID: template.id, destinationFolder: destination,
            destinationIdentity: try DirectoryIdentity.capture(at: destination))
        await assertTrueAsync(await model.completeFinderAuthorizationRequest(request, authorizedDirectory: destination))
        XCTAssertNotNil(model.createdFileURL)
        let newGrant = try XCTUnwrap(grants.loadAuthorizedDirectories().first { $0.url == destination })
        XCTAssertNotEqual(newGrant.id, oldGrant.id)
        reboundID.value = newGrant.id

        await model.createFile()

        XCTAssertEqual(loads.value, 1, "The rebound grant must pass initial metadata admission")
        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(model.status, .failure(AuthorizedDirectoryStoreError.directoryNotAuthorized.localizedDescription))
        XCTAssertTrue(try grants.withAccess(to: destination) { true })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 1)
    }

    func testFinderCoordinatorRejectsRevokedReturnedGrantBeforeWriteDespiteLiveParentGrant() throws {
        let destination = temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let grants = makeAuthorizationStore(defaults: defaults)
        _ = try grants.authorize(temporaryDirectory)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "never written")
        let persistedID = LockedTestValue<UUID?>(nil)
        let coordinator = FinderAuthorizationCoordinator(
            loadTemplates: { [template] },
            authorizeDirectory: { directory in
                let grant = try grants.authorize(directory)
                persistedID.value = grant.id
                XCTAssertTrue(try grants.revoke(grant.id))
                return grant.id
            },
            performWithAccess: { target, id, operation in
                XCTAssertEqual(id, persistedID.value)
                return try grants.withAccess(to: target, authorizationID: id, perform: operation)
            },
            createFile: { _ in
                XCTFail("Revoked grant must not reach creation through an overlapping grant")
                throw AuthorizedDirectoryStoreError.directoryNotAuthorized
            })
        let request = FinderAuthorizationRequest(templateID: template.id, destinationFolder: destination,
            destinationIdentity: try DirectoryIdentity.capture(at: destination))
        XCTAssertThrowsError(try coordinator.complete(request, authorizedDirectory: destination)) { error in
            guard case AuthorizedDirectoryStoreError.directoryNotAuthorized = error else {
                return XCTFail("Expected ID-bound access rejection, got \(error)")
            }
        }
        XCTAssertNotNil(persistedID.value)
        XCTAssertTrue(try grants.withAccess(to: destination) { true })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testFinderContinuationBindsNewGrantForReplacementDirectoryAndPreservesOldRecord() async throws {
        let requestedDestination = temporaryDirectory.appendingPathComponent("Target", isDirectory: true)
        let moved = temporaryDirectory.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: requestedDestination, withIntermediateDirectories: false)
        // Resolve the complete fixture only after it exists, before selecting or requesting it.
        let destination = DirectoryPathPolicy.canonicalURL(requestedDestination)
        let grants = makeAuthorizationStore(defaults: defaults)
        let originalGrant = try grants.authorize(destination)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let originalRecord = try XCTUnwrap(repository.load().first)
        let originalIdentity = try DirectoryIdentity.capture(at: destination)
        let model = makeViewModel(authorizationStore: grants)
        try TemplateStore(defaults: defaults).saveTemplates(model.templates)
        await model.selectAuthorizedDirectory(originalGrant)
        XCTAssertEqual(model.destinationFolder, destination)
        try FileManager.default.moveItem(at: destination, to: moved)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let replacementIdentity = try DirectoryIdentity.capture(at: destination)
        XCTAssertNotEqual(replacementIdentity, originalIdentity)
        let request = FinderAuthorizationRequest(templateID: model.selectedTemplateID,
            destinationFolder: destination, destinationIdentity: replacementIdentity)

        XCTAssertEqual(request.destinationFolder, destination)
        await assertTrueAsync(await model.completeFinderAuthorizationRequest(request, authorizedDirectory: destination))
        XCTAssertEqual(model.destinationFolder, destination)
        let refreshedGrant = try XCTUnwrap(grants.loadAuthorizedDirectories().first { $0.id != originalGrant.id })
        XCTAssertEqual(refreshedGrant.url, destination)
        XCTAssertNotEqual(refreshedGrant.id, originalGrant.id)
        XCTAssertEqual(try repository.load().first { $0.id == originalGrant.id }, originalRecord)
        XCTAssertEqual(try repository.load().count, 2)
        let continuedFile = try XCTUnwrap(model.createdFileURL)
        await model.createFile()
        let nextFile = try XCTUnwrap(model.createdFileURL)
        XCTAssertNotEqual(nextFile, continuedFile)
        let createdDirectory = nextFile.deletingLastPathComponent()
        XCTAssertEqual(DirectoryPathPolicy.canonicalURL(createdDirectory), destination)
        XCTAssertEqual(try DirectoryIdentity.capture(at: createdDirectory), try DirectoryIdentity.capture(at: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
        XCTAssertTrue(try grants.revoke(refreshedGrant.id))
        // Fixture bookmarks are path-based: the retained old record overlaps here.
        // The rebound selection must still fail rather than silently fall back.
        XCTAssertTrue(try grants.withAccess(to: destination) { true })
        await model.createFile()
        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 2)
        XCTAssertEqual(try repository.load(), [originalRecord])
    }

    func testFinderContinuationBindsNewAncestorGrantWithoutChangingChildDestination() async throws {
        let requestedParent = temporaryDirectory.appendingPathComponent("Parent", isDirectory: true)
        let requestedDestination = requestedParent.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: requestedDestination, withIntermediateDirectories: true)
        let parent = DirectoryPathPolicy.canonicalURL(requestedParent)
        let destination = DirectoryPathPolicy.canonicalURL(requestedDestination)
        let grants = makeAuthorizationStore(defaults: defaults)
        let oldGrant = try grants.authorize(destination)
        let model = makeViewModel(authorizationStore: grants)
        try TemplateStore(defaults: defaults).saveTemplates(model.templates)
        await model.selectAuthorizedDirectory(oldGrant)
        XCTAssertEqual(model.destinationFolder, destination)
        XCTAssertTrue(try grants.revoke(oldGrant.id))
        let request = FinderAuthorizationRequest(templateID: model.selectedTemplateID,
            destinationFolder: destination, destinationIdentity: try DirectoryIdentity.capture(at: destination))

        XCTAssertEqual(request.destinationFolder, destination)
        await assertTrueAsync(await model.completeFinderAuthorizationRequest(request, authorizedDirectory: parent))
        let parentGrant = try XCTUnwrap(grants.loadAuthorizedDirectories().first { $0.url == parent })
        XCTAssertNotEqual(parentGrant.id, oldGrant.id)
        XCTAssertEqual(model.destinationFolder, destination)
        await model.createFile()
        let created = try XCTUnwrap(model.createdFileURL)
        let createdDirectory = created.deletingLastPathComponent()
        XCTAssertEqual(DirectoryPathPolicy.canonicalURL(createdDirectory), destination)
        XCTAssertEqual(try DirectoryIdentity.capture(at: createdDirectory), try DirectoryIdentity.capture(at: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["Child"])
        XCTAssertTrue(try grants.revoke(parentGrant.id))
        await model.createFile()
        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 2)
    }

    func testCompletesFinderRequestAfterSingleAuthorizationConfirmation() async throws {
        let template = try XCTUnwrap(BuiltInTemplates.all.first)
        let authorizationStore = makeAuthorizationStore(defaults: defaults)
        let viewModel = QuickFileViewModel(
            templateStore: TemplateStore(defaults: defaults),
            templates: [template],
            authorizedDirectoryStore: authorizationStore
        )
        await viewModel.loadTemplatesIfNeeded()
        let request = FinderAuthorizationRequest(
            templateID: template.id,
            destinationFolder: temporaryDirectory
        )

        let didComplete = await viewModel.completeFinderAuthorizationRequest(
            request,
            authorizedDirectory: temporaryDirectory
        )
        XCTAssertTrue(didComplete)

        let createdFileURL = try XCTUnwrap(viewModel.createdFileURL)
        XCTAssertEqual(
            createdFileURL.deletingLastPathComponent().resolvingSymlinksInPath(),
            temporaryDirectory.resolvingSymlinksInPath()
        )
        XCTAssertEqual(viewModel.destinationFolder, temporaryDirectory)
        XCTAssertEqual(viewModel.selectedTemplateID, template.id)
        guard case let .success(message) = viewModel.status else {
            return XCTFail("Expected a success status")
        }
        XCTAssertTrue(message.contains("已授权并创建"))
    }

    func testFinderContinuationReconcilesAuthoritativeTemplatesAndSelection() async throws {
        let old = FileTemplate(name: "Old", fileExtension: "txt", content: "old")
        let current = FileTemplate(name: "Current", fileExtension: "md", content: "current")
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates([old])
        let model = QuickFileViewModel(
            templateStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults)
        )
        await model.loadTemplatesIfNeeded()
        try store.saveTemplates([current])

        let completed = await model.completeFinderAuthorizationRequest(
            FinderAuthorizationRequest(templateID: current.id, destinationFolder: temporaryDirectory),
            authorizedDirectory: temporaryDirectory
        )

        XCTAssertTrue(completed)
        XCTAssertEqual(model.templates, [current])
        XCTAssertEqual(model.selectedTemplateID, current.id)
        XCTAssertTrue(model.canCreate)
        let created = try XCTUnwrap(model.createdFileURL)
        XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), "current")
        var edited = current
        edited.name = "Edited current"
        try await model.saveTemplate(edited, replacing: current)
        XCTAssertEqual(try store.reloadTemplates(), [edited])
    }

    func testFinderContinuationCompletesWriteThenAppliesQueuedTemplateReload() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "{{clipboard}}")
        let restored = FileTemplate(name: "Restored", fileExtension: "md", content: "restored")
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates([original])
        let model = QuickFileViewModel(
            templateStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            fileCreationService: FileCreationService(clipboardProvider: { gate.blockOnce(); return "captured" })
        )
        await model.loadTemplatesIfNeeded()
        let creation = Task {
            await model.completeFinderAuthorizationRequest(
                FinderAuthorizationRequest(templateID: original.id, destinationFolder: temporaryDirectory),
                authorizedDirectory: temporaryDirectory
            )
        }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        try store.saveTemplates([restored])
        await model.reloadTemplates()
        gate.release.signal()
        let completed = await creation.value
        XCTAssertTrue(completed)
        // Reload waits for the active creation lease, then reconciles the library.
        // Creation still uses its captured body; its completion must not lose the queued reload.
        for _ in 0..<300 {
            if !model.isLoadingTemplates { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isLoadingTemplates, "Queued template reload must settle")
        XCTAssertNil(model.templateLoadFailure)
        XCTAssertEqual(model.templates, [restored])
        XCTAssertEqual(model.selectedTemplateID, restored.id)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(model.createdFileURL), encoding: .utf8), "captured")
    }

    func testRejectsAuthorizationThatDoesNotContainFinderDestination() async throws {
        let template = try XCTUnwrap(BuiltInTemplates.all.first)
        let authorizationStore = makeAuthorizationStore(defaults: defaults)
        let viewModel = QuickFileViewModel(
            templateStore: TemplateStore(defaults: defaults),
            templates: [template],
            authorizedDirectoryStore: authorizationStore
        )
        await viewModel.loadTemplatesIfNeeded()
        let unrelatedDirectory = temporaryDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Unrelated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unrelatedDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: unrelatedDirectory) }

        let didComplete = await viewModel.completeFinderAuthorizationRequest(
            FinderAuthorizationRequest(
                templateID: template.id,
                destinationFolder: temporaryDirectory
            ),
            authorizedDirectory: unrelatedDirectory
        )
        XCTAssertFalse(didComplete)

        XCTAssertNil(viewModel.createdFileURL)
        XCTAssertTrue(try authorizationStore.loadAuthorizedDirectories().isEmpty)
    }

    func testFirstWindowProcessesAuthorizationAndNavigationWhileInventoryRefreshIsBlocked() async throws {
        try await assertWindowProcessesAuthorizationDuringBlockedRefresh(openSecondWindow: false)
    }

    func testSecondWindowDoesNotStartAnotherRefreshAndCanProcessAuthorizationWhileFirstRefreshIsBlocked() async throws {
        try await assertWindowProcessesAuthorizationDuringBlockedRefresh(openSecondWindow: true)
    }

    private func assertWindowProcessesAuthorizationDuringBlockedRefresh(openSecondWindow: Bool) async throws {
        let offline = temporaryDirectory.appendingPathComponent("Offline", isDirectory: true)
        let selected = temporaryDirectory.appendingPathComponent("Selected", isDirectory: true)
        for url in [offline, selected] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let seed = makeAuthorizationStore(defaults: defaults)
        try seed.authorize(offline)
        let gate = CreationGate()
        let refreshFinished = LockedTestValue(false)
        let offlineResolutions = LockedTestValue(0)
        let grants = AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { Self.bookmarkData(for: $0) },
            transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { data in
                let resolved = try Self.resolveBookmark(data)
                if resolved.url.path == offline.path {
                    offlineResolutions.update { $0 += 1 }
                    gate.blockOnce()
                    throw TestError.bookmarkResolutionFailed
                }
                return resolved
            },
            transferBookmarkResolver: { try Self.resolveBookmark($0) },
            startAccessing: { _ in true }, stopAccessing: { _ in }
        )
        let template = FileTemplate(name: "Healthy", fileExtension: "txt", content: "created")
        let templates = TemplateStore(defaults: defaults)
        try templates.saveTemplates([template])
        let model = QuickFileViewModel(templateStore: templates, templates: [template], authorizedDirectoryStore: grants)
        let requests = makeRequestStore()
        try requests.save(FinderAuthorizationRequest(templateID: template.id, destinationFolder: selected))
        var window = QuickFileWindowPresentationState()
        var route = QuickFilePendingAppRoute()
        window.appear()
        let generation = try XCTUnwrap(window.requestAuthorizationCheck())
        XCTAssertTrue(route.receive(QuickFileAppRoute.templates.url))
        let firstWindow = ContentView(viewModel: model, authorizationRequestStore: requests)
        let refresh = Task {
            await firstWindow.viewModel.refreshAuthorizationBookmarks()
            refreshFinished.value = true
        }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        guard started else {
            gate.release.signal()
            await refresh.value
            return XCTFail("The inventory refresh never reached the blocking resolver")
        }
        // Cancellation must not release the once-only refresh slot or pretend the
        // synchronous resolver stopped. A second window shares that same slot.
        refresh.cancel()
        if openSecondWindow {
            let secondWindow = ContentView(viewModel: model, authorizationRequestStore: requests)
            await secondWindow.viewModel.refreshAuthorizationBookmarks()
        }
        XCTAssertFalse(refreshFinished.value)
        XCTAssertFalse(model.isBusy)
        var confirmations = 0
        let drained = expectation(description: "The visible window drains before the inventory resolver returns")
        let drain = Task {
            await model.processPendingFinderAuthorizationRequests(from: requests,
                isPresentationAvailable: { window.canPresent(generation) },
                confirmAuthorization: { request in
                    confirmations += 1
                    return request.destinationFolder
                })
            XCTAssertTrue(window.finishAuthorizationCheck(for: generation, isBusy: model.isBusy))
            XCTAssertFalse(window.isAwaitingAuthorizationCheck)
            XCTAssertEqual(route.takeIfReady(startupAuthorizationChecked: true, isBusy: model.isBusy), .templates)
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertFalse(refreshFinished.value, "Interactive completion must not need the inventory refresh")
        XCTAssertEqual(confirmations, 1)
        XCTAssertNotNil(model.createdFileURL)
        let interactiveStatus = model.status
        guard case .success = interactiveStatus else {
            gate.release.signal()
            await drain.value
            await refresh.value
            return XCTFail("The healthy request did not finish successfully")
        }
        gate.release.signal()
        await drain.value
        await refresh.value
        XCTAssertTrue(gate.wasReleasedBeforeTimeout)
        XCTAssertTrue(refreshFinished.value)
        XCTAssertEqual(offlineResolutions.value, 1, "Dedup and additional windows must skip the unrelated resolver")
        XCTAssertEqual(model.status, interactiveStatus, "A late inventory failure cannot overwrite newer user success")
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(try requests.takePendingRequest())
        let created = try XCTUnwrap(model.createdFileURL)
        XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), "created")
    }

    func testRefreshCommitDuringInteractiveAuthorizationFailsClosedAndRequiresNewRequest() async throws {
        let unrelated = temporaryDirectory.appendingPathComponent("Unrelated", isDirectory: true)
        let selected = temporaryDirectory.appendingPathComponent("Selected", isDirectory: true)
        for url in [unrelated, selected] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let original = try makeAuthorizationStore(defaults: defaults).authorize(unrelated)
        let refreshGate = CreationGate()
        let authorizationGate = CreationGate()
        let grants = AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { url in
                if url.path == selected.path { authorizationGate.blockOnce() }
                return Self.bookmarkData(for: url)
            },
            transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { data in
                let resolved = try Self.resolveBookmark(data)
                if resolved.url.path == unrelated.path { refreshGate.blockOnce() }
                return resolved
            },
            transferBookmarkResolver: { try Self.resolveBookmark($0) },
            startAccessing: { _ in true }, stopAccessing: { _ in }
        )
        let template = FileTemplate(name: "Healthy", fileExtension: "txt", content: "created after retry")
        let templates = TemplateStore(defaults: defaults)
        try templates.saveTemplates([template])
        let model = QuickFileViewModel(templateStore: templates, templates: [template], authorizedDirectoryStore: grants)
        let requests = makeRequestStore()
        try requests.save(FinderAuthorizationRequest(templateID: template.id, destinationFolder: selected))
        let refresh = Task { await model.refreshAuthorizationBookmarks() }
        let refreshStarted = await BackgroundWork.run { refreshGate.started.wait(timeout: .now() + 5) == .success }
        guard refreshStarted else {
            refreshGate.release.signal()
            await refresh.value
            return XCTFail("The refresh never reached the resolver")
        }
        var confirmations = 0
        let drain = Task {
            await model.processPendingFinderAuthorizationRequests(from: requests) { request in
                confirmations += 1
                return request.destinationFolder
            }
        }
        let authorizationStarted = await BackgroundWork.run { authorizationGate.started.wait(timeout: .now() + 5) == .success }
        guard authorizationStarted else {
            refreshGate.release.signal()
            authorizationGate.release.signal()
            await refresh.value
            await drain.value
            return XCTFail("Interactive authorization never captured its snapshot")
        }
        // Let the unrelated refresh commit after the explicit grant's snapshot.
        // The generation conflict must be reported, not retried on the user's behalf.
        refreshGate.release.signal()
        await refresh.value
        authorizationGate.release.signal()
        await drain.value
        XCTAssertTrue(refreshGate.wasReleasedBeforeTimeout)
        XCTAssertTrue(authorizationGate.wasReleasedBeforeTimeout)
        XCTAssertEqual(confirmations, 1)
        XCTAssertNil(model.createdFileURL)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.status, .failure(AuthorizedDirectoryStoreError.authorizationChanged.localizedDescription))
        XCTAssertNil(try requests.takePendingRequest())
        XCTAssertEqual(try grants.loadAuthorizedDirectories().map(\.id), [original.id])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: selected.path).isEmpty)

        try requests.save(FinderAuthorizationRequest(templateID: template.id, destinationFolder: selected))
        await model.processPendingFinderAuthorizationRequests(from: requests) { request in
            confirmations += 1
            return request.destinationFolder
        }
        XCTAssertEqual(confirmations, 2)
        let created = try XCTUnwrap(model.createdFileURL)
        XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), "created after retry")
        XCTAssertFalse(model.isBusy)
    }

    func testReportsTransferBookmarkRefreshFailureAfterAsyncRefresh() async throws {
        let initialStore = makeAuthorizationStore(defaults: defaults)
        try initialStore.authorize(temporaryDirectory)
        let failingStore = AuthorizedDirectoryStore(
            defaults: defaults,
            storageDirectory: defaults == nil ? nil : temporaryDirectory,
            persistentBookmarkCreator: { Self.bookmarkData(for: $0) },
            transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { _ in
                throw TestError.bookmarkResolutionFailed
            },
            transferBookmarkResolver: { try Self.resolveBookmark($0) },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )

        let viewModel = makeViewModel(authorizationStore: failingStore)
        await viewModel.refreshAuthorizationBookmarks()

        guard case let .failure(message) = viewModel.status else {
            return XCTFail("Expected a bookmark refresh failure")
        }
        XCTAssertTrue(message.contains("需要重新确认"))
    }

    func testWindowsShareTemplateEditsAndDoNotRestoreDeletedTemplates() async throws {
        let store = TemplateStore(defaults: defaults)
        let base = FileTemplate(name: "Base", fileExtension: "txt", content: "")
        try store.saveTemplates([base])
        let model = QuickFileViewModel(
            templateStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults)
        )
        await model.loadTemplatesIfNeeded()
        let requests = makeRequestStore()
        let firstWindow = ContentView(viewModel: model, authorizationRequestStore: requests)
        let secondWindow = ContentView(viewModel: model, authorizationRequestStore: requests)
        let added = FileTemplate(name: "Added", fileExtension: "md", content: "keep")

        try await firstWindow.viewModel.saveTemplate(added, replacing: nil)
        await secondWindow.viewModel.setTemplateEnabled(false, id: base.id)
        XCTAssertEqual(try store.loadTemplates().map(\.id), [base.id, added.id])
        XCTAssertFalse(firstWindow.viewModel.templates[0].isEnabled)
        await assertTrueAsync(await secondWindow.viewModel.deleteTemplate(withID: base.id))
        try await firstWindow.viewModel.saveTemplate(added, replacing: added)
        XCTAssertEqual(try store.loadTemplates(), [added])
    }

    func testStaleEditorCannotReenableDisabledTemplate() async throws {
        let store = TemplateStore(defaults: defaults)
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "before")
        try store.saveTemplates([original])
        let model = QuickFileViewModel(templateStore: store)
        await model.loadTemplatesIfNeeded()
        var draft = original
        draft.content = "draft"
        await model.setTemplateEnabled(false, id: original.id)

        await assertThrowsAsync(try await model.saveTemplate(draft, replacing: original)) { error in
            guard case QuickFileViewModel.TemplateSaveError.changed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let saved = try XCTUnwrap(store.reloadTemplates().first)
        XCTAssertFalse(saved.isEnabled)
        XCTAssertEqual(saved.content, "before")
    }

    func testStaleEditorCannotRestoreDeletedTemplate() async throws {
        let store = TemplateStore(defaults: defaults)
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "before")
        try store.saveTemplates([original])
        let model = QuickFileViewModel(templateStore: store)
        await model.loadTemplatesIfNeeded()
        await assertTrueAsync(await model.deleteTemplate(withID: original.id))

        await assertThrowsAsync(try await model.saveTemplate(original, replacing: original)) { error in
            guard case QuickFileViewModel.TemplateSaveError.deleted = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(try store.reloadTemplates().isEmpty)
    }

    func testEditorRejectsConcurrentContentEditButAllowsUnrelatedTemplateChanges() async throws {
        let store = TemplateStore(defaults: defaults)
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "before")
        let other = FileTemplate(name: "Other", fileExtension: "md", content: "other")
        try store.saveTemplates([original, other])
        let model = QuickFileViewModel(templateStore: store)
        await model.loadTemplatesIfNeeded()
        await model.setTemplateEnabled(false, id: other.id)
        var firstDraft = original
        firstDraft.content = "first window"
        try await model.saveTemplate(firstDraft, replacing: original)
        var secondDraft = original
        secondDraft.content = "second window"

        await assertThrowsAsync(try await model.saveTemplate(secondDraft, replacing: original))
        let saved = try store.reloadTemplates()
        XCTAssertEqual(saved[0], firstDraft)
        XCTAssertFalse(saved[1].isEnabled)
    }

    func testInitialReadFailureBlocksChangesUntilSuccessfulReload() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let invalidData = Data("invalid-json".utf8)
        try invalidData.write(to: storageURL)
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        let model = QuickFileViewModel(templateStore: store)
        await model.loadTemplatesIfNeeded()
        model.destinationFolder = temporaryDirectory
        let template = FileTemplate(name: "Recovered", fileExtension: "txt", content: "kept")

        XCTAssertNotNil(model.templateLoadError)
        XCTAssertTrue(model.templates.isEmpty)
        XCTAssertFalse(model.canCreate)
        await assertThrowsAsync(try await model.saveTemplate(template, replacing: nil))
        await assertFalseAsync(await model.restoreBuiltInTemplates())
        await model.createFile()
        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(try Data(contentsOf: storageURL), invalidData)

        try JSONEncoder().encode([template]).write(to: storageURL)
        await model.reloadTemplates()
        XCTAssertNil(model.templateLoadError)
        XCTAssertEqual(model.templates, [template])
        XCTAssertTrue(model.canCreate)
        var edited = template
        edited.content = "edited after recovery"
        try await model.saveTemplate(edited, replacing: template)
        XCTAssertEqual(try store.reloadTemplates(), [edited])
    }

    func testReloadFailurePreservesLastGoodListAndBlocksSubsequentSaves() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "keep")
        try store.saveTemplates([original])
        let model = QuickFileViewModel(templateStore: store)
        await model.loadTemplatesIfNeeded()
        try Data("invalid".utf8).write(to: storageURL)

        await model.reloadTemplates()
        XCTAssertEqual(model.templates, [original])
        XCTAssertNotNil(model.templateLoadError)
        await assertFalseAsync(await model.deleteTemplate(withID: original.id))
        // Recovery on disk alone must not permit a write based on the failed read.
        var recovered = original
        recovered.content = "restored from backup"
        try JSONEncoder().encode([recovered]).write(to: storageURL)
        await assertThrowsAsync(try await model.saveTemplate(original, replacing: original))
        XCTAssertEqual(try store.reloadTemplates(), [recovered])
        await model.reloadTemplates()
        XCTAssertEqual(model.templates, [recovered])
        XCTAssertNil(model.templateLoadError)
    }

    func testSaveReadFailureRequiresReloadBeforeWritingRecoveredConfiguration() async throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "keep")
        try store.saveTemplates([original])
        let model = QuickFileViewModel(templateStore: store)
        await model.loadTemplatesIfNeeded()
        model.destinationFolder = temporaryDirectory
        try Data("invalid".utf8).write(to: storageURL)

        await assertThrowsAsync(try await model.saveTemplate(original, replacing: original))
        XCTAssertNotNil(model.templateLoadError)
        XCTAssertFalse(model.canCreate)
        XCTAssertEqual(model.templates, [original])

        var recovered = original
        recovered.content = "recovered newer content"
        try JSONEncoder().encode([recovered]).write(to: storageURL)
        await assertThrowsAsync(try await model.saveTemplate(original, replacing: original))
        XCTAssertEqual(try store.reloadTemplates(), [recovered])
        await model.reloadTemplates()
        XCTAssertNil(model.templateLoadError)
        XCTAssertEqual(model.templates, [recovered])
        await assertThrowsAsync(try await model.saveTemplate(original, replacing: original))
    }

    func testAuthorizationContinuationUsesSameClipboardAsOrdinaryCreation() async throws {
        let template = FileTemplate(name: "Clipboard", fileExtension: "txt", content: "{{clipboard}}")
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates([template])
        let model = QuickFileViewModel(
            templateStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            clipboardProvider: { "copied" }
        )
        await model.loadTemplatesIfNeeded()
        model.destinationFolder = temporaryDirectory
        await model.createFile()
        let ordinaryFile = try XCTUnwrap(model.createdFileURL)

        let completed = await model.completeFinderAuthorizationRequest(
            FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory),
            authorizedDirectory: temporaryDirectory
        )
        XCTAssertTrue(completed)
        let resumedFile = try XCTUnwrap(model.createdFileURL)
        XCTAssertNotEqual(ordinaryFile, resumedFile)
        XCTAssertEqual(try String(contentsOf: ordinaryFile, encoding: .utf8), "copied")
        XCTAssertEqual(try String(contentsOf: resumedFile, encoding: .utf8), "copied")
    }

    func testTemplatesWithoutClipboardNeverReadPasteboardInEitherCreationPath() async throws {
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "plain")
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates([template])
        let model = QuickFileViewModel(
            templateStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            clipboardProvider: { XCTFail("No clipboard variable"); return "private" }
        )
        await model.loadTemplatesIfNeeded()
        model.destinationFolder = temporaryDirectory
        await model.createFile()
        XCTAssertNotNil(model.createdFileURL)
        let didComplete = await model.completeFinderAuthorizationRequest(
            FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory),
            authorizedDirectory: temporaryDirectory
        )
        XCTAssertTrue(didComplete)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(model.createdFileURL), encoding: .utf8), "plain")
    }

    func testFinderContinuationUsesLatestTemplateBeforeReadingClipboardAndRevealsFinalURL() async throws {
        var template = FileTemplate(name: "Text", fileExtension: "txt", content: "plain")
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates([template])
        var clipboardReads = 0
        var revealed: [URL] = []
        let model = QuickFileViewModel(
            templateStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            clipboardProvider: {
                XCTAssertTrue(Thread.isMainThread)
                clipboardReads += 1
                return "copied"
            },
            revealCreatedFile: { revealed.append($0) }
        )
        await model.loadTemplatesIfNeeded()
        template.content = "{{clipboard}}"
        try store.saveTemplates([template])
        let original = temporaryDirectory.appendingPathComponent("未命名.txt")
        try Data("keep".utf8).write(to: original)
        let request = FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory)
        let didComplete = await model.completeFinderAuthorizationRequest(request, authorizedDirectory: temporaryDirectory)
        XCTAssertTrue(didComplete)
        let result = try XCTUnwrap(model.createdFileURL)
        XCTAssertEqual(result.lastPathComponent, "未命名 2.txt")
        XCTAssertEqual(revealed, [result])
        XCTAssertEqual(clipboardReads, 1)
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "copied")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "keep")

        template.isEnabled = false
        try store.saveTemplates([template])
        let rejected = await model.completeFinderAuthorizationRequest(request, authorizedDirectory: temporaryDirectory)
        XCTAssertFalse(rejected)
        XCTAssertEqual(revealed, [result])
        XCTAssertEqual(clipboardReads, 1)
    }

    func testClosedWindowCancelsClaimedRequestWithSharedStatusAndLeavesLaterRequestQueued() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let directory = temporaryDirectory.appendingPathComponent("requests", isDirectory: true)
        let writer = makeRequestStore()
        let now = Date()
        let first = FinderAuthorizationRequest(templateID: BuiltInTemplates.all[0].id,
            destinationFolder: temporaryDirectory, createdAt: now.addingTimeInterval(-2))
        let second = FinderAuthorizationRequest(templateID: BuiltInTemplates.all[0].id,
            destinationFolder: temporaryDirectory, createdAt: now.addingTimeInterval(-1))
        try writer.save(first)
        try writer.save(second)
        let reader = FinderAuthorizationRequestStore(defaults: defaults, directoryURL: directory,
            fileManager: PausedRequestFileManager(gate: gate))
        let model = makeViewModel(authorizationStore: makeAuthorizationStore(defaults: defaults))
        var windowIsAvailable = true
        let drain = Task {
            await model.processPendingFinderAuthorizationRequests(from: reader,
                isPresentationAvailable: { windowIsAvailable },
                willPresent: { XCTFail("Closed windows must not switch tabs") },
                confirmAuthorization: { _ in XCTFail("Closed windows must not present a panel"); return nil })
        }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        windowIsAvailable = false
        gate.release.signal()
        await drain.value
        XCTAssertEqual(model.status, .failure("创建窗口已关闭，本次 Finder 请求已取消；请从 Finder 重新发起。其他待处理请求会在可用窗口中继续确认。"))
        XCTAssertFalse(model.isProcessingFinderAuthorizationRequests)
        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(try writer.takePendingRequest()?.id, second.id)
        XCTAssertNil(try writer.takePendingRequest())
    }

    func testBusyCreationLeavesFinderRequestQueuedUntilIdle() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let store = TemplateStore(defaults: defaults)
        var template = BuiltInTemplates.all[0]
        template.content = "{{clipboard}}"
        try store.saveTemplates([template])
        let model = QuickFileViewModel(
            templateStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            fileCreationService: FileCreationService(clipboardProvider: { gate.blockOnce(); return "" })
        )
        await model.loadTemplatesIfNeeded()
        model.destinationFolder = temporaryDirectory
        let creation = Task { await model.createFile() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        let requests = makeRequestStore()
        try requests.save(FinderAuthorizationRequest(
            templateID: BuiltInTemplates.all[0].id,
            destinationFolder: temporaryDirectory
        ))
        await model.processPendingFinderAuthorizationRequests(
            from: requests,
            willPresent: { XCTFail("A busy model must not switch the presenting window") },
            confirmAuthorization: { _ in
                XCTFail("A busy model must not consume or present a request")
                return nil
            }
        )
        XCTAssertFalse(model.isProcessingFinderAuthorizationRequests)
        gate.release.signal()
        await creation.value

        var confirmationCount = 0
        await model.processPendingFinderAuthorizationRequests(from: requests) { directory in
            confirmationCount += 1
            return directory.destinationFolder
        }
        XCTAssertEqual(confirmationCount, 1)
        XCTAssertNil(try requests.takePendingRequest())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).filter { $0.hasSuffix(".txt") }.count, 2)
    }

    func testBusyDirectoryAuthorizationLeavesFinderRequestQueuedUntilIdle() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let template = BuiltInTemplates.all[0]
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates([template])
        let authorizationStore = AuthorizedDirectoryStore(
            defaults: defaults,
            storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { url in
                gate.blockOnce()
                return Self.bookmarkData(for: url)
            },
            transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { try Self.resolveBookmark($0) },
            transferBookmarkResolver: { try Self.resolveBookmark($0) },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
        let model = QuickFileViewModel(
            templateStore: store,
            templates: [template],
            authorizedDirectoryStore: authorizationStore
        )
        let requests = makeRequestStore()
        try requests.save(FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory))
        let authorization = Task { await model.saveFinderAuthorization(for: temporaryDirectory) }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertTrue(model.isAuthorizingDirectory)

        await model.processPendingFinderAuthorizationRequests(
            from: requests,
            willPresent: { XCTFail("A busy model must not switch the presenting window") },
            confirmAuthorization: { _ in XCTFail("Authorization still owns busy admission"); return nil }
        )
        XCTAssertFalse(model.isProcessingFinderAuthorizationRequests)
        gate.release.signal()
        await authorization.value

        var confirmations = 0
        await model.processPendingFinderAuthorizationRequests(from: requests) { directory in
            confirmations += 1
            return directory.destinationFolder
        }
        XCTAssertEqual(confirmations, 1)
        XCTAssertNotNil(model.createdFileURL)
        XCTAssertNil(try requests.takePendingRequest())
        XCTAssertFalse(model.isBusy)
    }

    func testOverlappingWindowDrainsDoNotDuplicateRequestsOrRevertTemplateEdits() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let store = TemplateStore(defaults: defaults)
        var template = BuiltInTemplates.all[0]
        template.content = "{{clipboard}}"
        try store.saveTemplates([template])
        let model = QuickFileViewModel(
            templateStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            fileCreationService: FileCreationService(clipboardProvider: { gate.blockOnce(); return "" })
        )
        await model.loadTemplatesIfNeeded()
        var processingStates: [Bool] = []
        let observation = model.$isProcessingFinderAuthorizationRequests.sink { processingStates.append($0) }
        defer { observation.cancel() }
        let requests = makeRequestStore()
        try requests.save(FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory))
        var confirmations = 0
        let firstDrain = Task {
            await model.processPendingFinderAuthorizationRequests(
                from: requests,
                willPresent: {
                    XCTAssertTrue(Thread.isMainThread)
                    XCTAssertTrue(model.isProcessingFinderAuthorizationRequests)
                    XCTAssertTrue(model.isBusy)
                },
                confirmAuthorization: { directory in
                    XCTAssertTrue(Thread.isMainThread)
                    XCTAssertTrue(model.isProcessingFinderAuthorizationRequests)
                    confirmations += 1
                    return directory.destinationFolder
                }
            )
        }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertTrue(model.isProcessingFinderAuthorizationRequests)
        XCTAssertEqual(model.finderAuthorizationRequestPhase, .creatingFile)
        XCTAssertEqual(processingStates, [false, true])
        XCTAssertFalse(model.canCreate)
        let added = FileTemplate(name: "Added during creation", fileExtension: "md", content: "new")
        try await model.saveTemplate(added, replacing: nil)
        try requests.save(FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory))
        await model.processPendingFinderAuthorizationRequests(
            from: requests,
            willPresent: { XCTFail("The first window keeps presentation ownership") },
            confirmAuthorization: { _ in XCTFail("A second window must not drain concurrently"); return nil }
        )
        gate.release.signal()
        await firstDrain.value

        XCTAssertEqual(confirmations, 2)
        XCTAssertTrue(model.templates.contains(added))
        XCTAssertTrue(try store.loadTemplates().contains(added))
        XCTAssertNil(try requests.takePendingRequest())
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(processingStates, [false, true, false], "One published lease spans the whole drain")
    }

    func testFailedFinderCompletionReleasesAdmissionAndPreservesLaterQueuedRequest() async throws {
        let template = BuiltInTemplates.all[0]
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates([template])
        let model = QuickFileViewModel(
            templateStore: store,
            templates: [template],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults)
        )
        let requests = makeRequestStore()
        let now = Date()
        try requests.save(FinderAuthorizationRequest(
            templateID: UUID(), destinationFolder: temporaryDirectory,
            createdAt: now.addingTimeInterval(-2)
        ))
        try requests.save(FinderAuthorizationRequest(
            templateID: template.id, destinationFolder: temporaryDirectory,
            createdAt: now.addingTimeInterval(-1)
        ))
        var confirmations = 0
        await model.processPendingFinderAuthorizationRequests(from: requests) { directory in
            confirmations += 1
            return directory.destinationFolder
        }

        XCTAssertEqual(confirmations, 1)
        XCTAssertNil(model.createdFileURL)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isProcessingFinderAuthorizationRequests)
        guard case .failure = model.status else { return XCTFail("The failed request must keep its status") }

        await model.processPendingFinderAuthorizationRequests(from: requests) { directory in
            confirmations += 1
            return directory.destinationFolder
        }
        XCTAssertEqual(confirmations, 2)
        XCTAssertNotNil(model.createdFileURL)
        XCTAssertNil(try requests.takePendingRequest())
        XCTAssertFalse(model.isBusy)
    }

    func testCancelPausesAcrossWindowsAndNotificationsUntilExplicitContinuation() async throws {
        let template = BuiltInTemplates.all[0]
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates([template])
        let model = QuickFileViewModel(templateStore: store, templates: [template],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults))
        let requests = makeRequestStore()
        let now = Date()
        let queued = (0..<3).map { index in
            FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory,
                createdAt: now.addingTimeInterval(Double(index) - 3))
        }
        try requests.save(queued[0])
        try requests.save(queued[1])
        let retainedURL = temporaryDirectory.appendingPathComponent("requests/\(queued[1].id.uuidString).json")
        let retainedBytes = try Data(contentsOf: retainedURL)
        let firstWindow = ContentView(viewModel: model, authorizationRequestStore: requests)
        let otherWindow = ContentView(viewModel: model, authorizationRequestStore: requests)
        var processingStates: [Bool] = []
        let observation = model.$isProcessingFinderAuthorizationRequests.sink { processingStates.append($0) }
        defer { observation.cancel() }
        var confirmed: [UUID] = []
        await firstWindow.viewModel.processPendingFinderAuthorizationRequests(from: requests) { request in
            XCTAssertEqual(model.finderAuthorizationRequestPhase, .awaitingAuthorization)
            confirmed.append(request.id)
            return nil
        }
        XCTAssertEqual(confirmed, [queued[0].id])
        XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .cancelled)
        XCTAssertEqual(model.finderAuthorizationRequestPhase, .idle)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(try Data(contentsOf: retainedURL), retainedBytes)
        try requests.save(queued[2])
        // Each invocation is the common path used by activation, distributed
        // notifications and newly visible windows. None may clear explicit pause.
        for _ in 0..<5 {
            for window in [firstWindow, otherWindow] {
                await window.viewModel.processPendingFinderAuthorizationRequests(from: requests,
                    willPresent: { XCTFail("Automatic checks must not navigate while paused") },
                    confirmAuthorization: { _ in XCTFail("Automatic checks must not resume panels"); return nil })
            }
        }
        XCTAssertEqual(processingStates, [false, true, false], "Paused checks must not acquire a lease or read storage")
        XCTAssertEqual(try Data(contentsOf: retainedURL), retainedBytes)
        XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .cancelled)

        await otherWindow.viewModel.processPendingFinderAuthorizationRequests(from: requests,
            resumingPauseID: model.finderAuthorizationQueuePause?.id) { request in
                XCTAssertNil(model.finderAuthorizationQueuePause)
                confirmed.append(request.id)
                return request.destinationFolder
            }
        XCTAssertEqual(confirmed, queued.map(\.id), "Continue must resume only unclaimed requests, in order")
        XCTAssertNil(model.finderAuthorizationQueuePause)
        XCTAssertEqual(model.finderAuthorizationRequestPhase, .idle)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(try requests.takePendingRequest())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.hasSuffix(".txt") }.count, 2)
    }

    func testDelayedContinueReceiptCannotResumeNewerPauseFromAnotherWindow() async throws {
        let model = makeViewModel(authorizationStore: makeAuthorizationStore(defaults: defaults))
        let requests = makeRequestStore()
        let now = Date()
        let queued = (0..<3).map { index in
            FinderAuthorizationRequest(templateID: BuiltInTemplates.all[0].id, destinationFolder: temporaryDirectory,
                createdAt: now.addingTimeInterval(Double(index) - 3))
        }
        for request in queued { try requests.save(request) }
        await model.processPendingFinderAuthorizationRequests(from: requests) { _ in nil }
        let firstPauseID = try XCTUnwrap(model.finderAuthorizationQueuePause?.id)
        var otherWindow = QuickFileWindowPresentationState()
        otherWindow.appear()
        let otherGeneration = try XCTUnwrap(otherWindow.requestAuthorizationCheck())
        // Capture both receipts as ContentView does at the button click, before
        // the queued MainActor task receives execution time.
        let delayedContinue: @MainActor () async -> Void = {
            await model.processPendingFinderAuthorizationRequests(from: requests, resumingPauseID: firstPauseID,
                isPresentationAvailable: { otherWindow.canPresent(otherGeneration) },
                willPresent: { XCTFail("A stale pause receipt must not navigate") },
                confirmAuthorization: { _ in XCTFail("A stale pause receipt must not claim"); return nil })
        }
        await model.processPendingFinderAuthorizationRequests(from: requests, resumingPauseID: firstPauseID) { request in
            XCTAssertEqual(request.id, queued[1].id)
            return nil
        }
        let secondPause = try XCTUnwrap(model.finderAuthorizationQueuePause)
        XCTAssertNotEqual(secondPause.id, firstPauseID)
        let retainedURL = temporaryDirectory.appendingPathComponent("requests/\(queued[2].id.uuidString).json")
        let retainedBytes = try Data(contentsOf: retainedURL)
        let delayedTask = Task { await delayedContinue() }
        await delayedTask.value
        XCTAssertEqual(model.finderAuthorizationQueuePause, secondPause)
        XCTAssertEqual(try Data(contentsOf: retainedURL), retainedBytes)
        XCTAssertTrue(otherWindow.finishAuthorizationCheck(for: otherGeneration, isBusy: model.isBusy))
        XCTAssertFalse(otherWindow.isAwaitingAuthorizationCheck)
        await model.processPendingFinderAuthorizationRequests(from: requests, resumingPauseID: secondPause.id) { request in
            XCTAssertEqual(request.id, queued[2].id)
            return request.destinationFolder
        }
        XCTAssertNil(model.finderAuthorizationQueuePause)
        let finalStatus = model.status
        // A second old click also cannot start a new drain after pause has ended.
        await delayedContinue()
        XCTAssertEqual(model.status, finalStatus)
        XCTAssertNil(try requests.takePendingRequest())
    }

    func testCancellingAgainAfterContinuePausesWithoutClaimingRemainingRequest() async throws {
        let model = makeViewModel(authorizationStore: makeAuthorizationStore(defaults: defaults))
        let requests = makeRequestStore()
        let now = Date()
        let queued = (0..<3).map { index in
            FinderAuthorizationRequest(templateID: BuiltInTemplates.all[0].id, destinationFolder: temporaryDirectory,
                createdAt: now.addingTimeInterval(Double(index) - 3))
        }
        for request in queued { try requests.save(request) }
        var confirmed: [UUID] = []
        for shouldResume in [false, true] {
            await model.processPendingFinderAuthorizationRequests(from: requests,
                resumingPauseID: shouldResume ? model.finderAuthorizationQueuePause?.id : nil) { request in
                    confirmed.append(request.id)
                    return nil
                }
            XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .cancelled)
            XCTAssertFalse(model.isBusy)
        }
        XCTAssertEqual(confirmed, queued.prefix(2).map(\.id))
        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(try requests.takePendingRequest()?.id, queued[2].id)
        XCTAssertNil(try requests.takePendingRequest())
    }

    func testPausedQueueDoesNotBlockDirectCreationAndBusyContinueCannotClearPause() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let store = TemplateStore(defaults: defaults)
        var template = BuiltInTemplates.all[0]
        template.content = "{{clipboard}}"
        try store.saveTemplates([template])
        let model = QuickFileViewModel(templateStore: store, templates: [template],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            fileCreationService: FileCreationService(clipboardProvider: { gate.blockOnce(); return "direct" }))
        model.destinationFolder = temporaryDirectory
        let requests = makeRequestStore()
        try requests.save(FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory))
        await model.processPendingFinderAuthorizationRequests(from: requests) { _ in nil }
        let retained = FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory)
        try requests.save(retained)
        XCTAssertTrue(model.canCreate)
        let creation = Task { await model.createFile() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertTrue(model.isCreatingFile)
        await model.processPendingFinderAuthorizationRequests(from: requests, resumingPauseID: model.finderAuthorizationQueuePause?.id,
            willPresent: { XCTFail("Continue must not start while direct creation owns admission") },
            confirmAuthorization: { _ in XCTFail("No request may be claimed while busy"); return nil })
        XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .cancelled)
        XCTAssertFalse(model.isProcessingFinderAuthorizationRequests)
        gate.release.signal()
        await creation.value
        XCTAssertTrue(gate.wasReleasedBeforeTimeout)
        XCTAssertNotNil(model.createdFileURL)
        XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .cancelled, "A newer direct result must not resume the queue")
        await model.processPendingFinderAuthorizationRequests(from: requests) { _ in
            XCTFail("Busy-release notifications must retain the pause")
            return nil
        }
        XCTAssertEqual(try requests.takePendingRequest()?.id, retained.id)
        XCTAssertNil(try requests.takePendingRequest())
        let directCreationStatus = model.status
        await model.processPendingFinderAuthorizationRequests(from: requests,
            resumingPauseID: model.finderAuthorizationQueuePause?.id) { _ in
                XCTFail("The test already removed the remaining request")
                return nil
            }
        XCTAssertEqual(model.status, directCreationStatus, "An empty Continue cannot clear a newer direct result")
        XCTAssertNil(model.finderAuthorizationQueuePause)
    }

    func testPausedQueueAllowsNavigationAndStaleWindowCannotResumeAfterReopening() async throws {
        let model = makeViewModel(authorizationStore: makeAuthorizationStore(defaults: defaults))
        let requests = makeRequestStore()
        try requests.save(FinderAuthorizationRequest(templateID: BuiltInTemplates.all[0].id,
            destinationFolder: temporaryDirectory))
        var window = QuickFileWindowPresentationState()
        var route = QuickFilePendingAppRoute()
        window.appear()
        let original = try XCTUnwrap(window.requestAuthorizationCheck())
        route.receive(QuickFileAppRoute.templates.url)
        await model.processPendingFinderAuthorizationRequests(from: requests,
            isPresentationAvailable: { window.canPresent(original) }) { _ in nil }
        XCTAssertTrue(window.finishAuthorizationCheck(for: original, isBusy: model.isBusy))
        XCTAssertFalse(window.isAwaitingAuthorizationCheck)
        XCTAssertEqual(route.takeIfReady(startupAuthorizationChecked: true, isBusy: model.isBusy), .templates)
        let retained = FinderAuthorizationRequest(templateID: BuiltInTemplates.all[0].id,
            destinationFolder: temporaryDirectory)
        try requests.save(retained)
        window.disappear()
        window.appear()
        await model.processPendingFinderAuthorizationRequests(from: requests, resumingPauseID: model.finderAuthorizationQueuePause?.id,
            isPresentationAvailable: { window.canPresent(original) },
            willPresent: { XCTFail("A stale Continue callback cannot navigate") },
            confirmAuthorization: { _ in XCTFail("A stale Continue callback cannot claim"); return nil })
        XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .cancelled)
        let current = try XCTUnwrap(window.requestAuthorizationCheck())
        route.receive(QuickFileAppRoute.diagnostics.url)
        var presented: [UUID] = []
        await model.processPendingFinderAuthorizationRequests(from: requests, resumingPauseID: model.finderAuthorizationQueuePause?.id,
            isPresentationAvailable: { window.canPresent(current) }) { request in
                presented.append(request.id)
                XCTAssertEqual(route.route, .diagnostics, "Authorization must not consume an external route")
                return request.destinationFolder
            }
        XCTAssertEqual(presented, [retained.id])
        XCTAssertTrue(window.finishAuthorizationCheck(for: current, isBusy: model.isBusy))
        XCTAssertEqual(route.takeIfReady(startupAuthorizationChecked: true, isBusy: model.isBusy), .diagnostics)
        XCTAssertNil(model.finderAuthorizationQueuePause)
    }

    func testContinueOnEmptyQueueClearsPauseWithoutAnAllClearOrClaim() async throws {
        let model = makeViewModel(authorizationStore: makeAuthorizationStore(defaults: defaults))
        let requests = makeRequestStore()
        try requests.save(FinderAuthorizationRequest(templateID: BuiltInTemplates.all[0].id,
            destinationFolder: temporaryDirectory))
        await model.processPendingFinderAuthorizationRequests(from: requests) { _ in nil }
        XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .cancelled)
        XCTAssertTrue(try XCTUnwrap(model.finderAuthorizationQueuePause).message.contains("如有"))
        await model.processPendingFinderAuthorizationRequests(from: requests, resumingPauseID: model.finderAuthorizationQueuePause?.id,
            willPresent: { XCTFail("Empty queue should not change pages") },
            confirmAuthorization: { _ in XCTFail("There is no request to present"); return nil })
        XCTAssertNil(model.finderAuthorizationQueuePause)
        XCTAssertEqual(model.finderAuthorizationRequestPhase, .idle)
        XCTAssertNil(model.status, "An empty retry clears only old pause feedback; it must not invent a global all-clear result")
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.createdFileURL)
    }

    func testSuccessfulRetryWithFutureDatedRecordDoesNotClaimAnAllClear() async throws {
        let model = makeViewModel(authorizationStore: makeAuthorizationStore(defaults: defaults))
        let unavailable = FinderAuthorizationRequestStore(defaults: nil, directoryURL: nil)
        await model.processPendingFinderAuthorizationRequests(from: unavailable) { _ in
            XCTFail("An unavailable queue must not present a request")
            return nil
        }
        XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .readFailed(.unavailable))
        let requests = makeRequestStore()
        let future = FinderAuthorizationRequest(templateID: BuiltInTemplates.all[0].id,
            destinationFolder: temporaryDirectory, createdAt: Date().addingTimeInterval(60))
        try requests.save(future)
        let futureURL = temporaryDirectory.appendingPathComponent("requests/\(future.id.uuidString).json")
        let originalBytes = try Data(contentsOf: futureURL)
        await model.processPendingFinderAuthorizationRequests(from: requests,
            resumingPauseID: model.finderAuthorizationQueuePause?.id,
            willPresent: { XCTFail("No currently claimable request means no navigation") },
            confirmAuthorization: { _ in XCTFail("A future-dated request must not be claimed yet"); return nil })
        XCTAssertNil(model.finderAuthorizationQueuePause)
        XCTAssertNil(model.status, "Successful read clears only its stale failure; retained items prevent an all-clear")
        XCTAssertNil(model.createdFileURL)
        XCTAssertEqual(try Data(contentsOf: futureURL), originalBytes)
        XCTAssertEqual(try requests.takePendingRequest(referenceDate: future.createdAt)?.id, future.id)
    }

    func testQueueReadFailureClassificationIsBoundedAndDoesNotExposeRawDetails() {
        typealias Failure = QuickFileViewModel.FinderAuthorizationQueueReadFailure
        typealias StoreError = FinderAuthorizationRequestStore.StoreError
        XCTAssertEqual(Failure(StoreError.sharedStoreUnavailable), .unavailable)
        XCTAssertEqual(Failure(StoreError.persistenceFailed(StoreError.requestTooLarge)), .oversizedRequest)
        let wrapped = NSError(domain: "QueueRead", code: 1,
            userInfo: [NSUnderlyingErrorKey: StoreError.sharedStoreUnavailable])
        XCTAssertEqual(Failure(StoreError.persistenceFailed(wrapped)), .unavailable)
        let oversized = NSError(domain: "QueueRead", code: 2,
            userInfo: [NSUnderlyingErrorKey: StoreError.requestTooLarge])
        XCTAssertEqual(Failure(oversized), .oversizedRequest)
        var nested: Error = StoreError.requestTooLarge
        for _ in 0..<8 { nested = StoreError.persistenceFailed(nested) }
        XCTAssertEqual(Failure(nested), .unreadable, "Unknown/deep wrapping must use finite generic recovery")
        let secret = "/private/user-folder/request-identity.json"
        let error = NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret])
        let failure = Failure(StoreError.persistenceFailed(error))
        XCTAssertEqual(failure, .unreadable)
        XCTAssertFalse(failure.message.contains(secret))
        XCTAssertTrue(Failure.oversizedRequest.message.contains("原始记录仍保留"))
    }

    func testPinnedQueueReadAllowsDirectCreationButKeepsClaimLeaseUntilReturnAfterTaskCancellation() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let requests = makeRequestStore()
        let requestDirectory = temporaryDirectory.appendingPathComponent("requests", isDirectory: true)
        // A fresh queue first takes the migration/fallback path. Complete that
        // prerequisite before saving the fixture so this test actually enters
        // the out-of-lock pinned payload reader rather than its locked fallback.
        XCTAssertNil(try requests.takePendingRequest())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: requestDirectory.appendingPathComponent(".legacy-v1-migrated").path))
        let pinnedReadCount = LockedTestValue(0)
        let request = FinderAuthorizationRequest(templateID: BuiltInTemplates.all[0].id,
            destinationFolder: temporaryDirectory)
        try requests.save(request)
        let reader = FinderAuthorizationRequestStore(defaults: defaults, directoryURL: requestDirectory,
            readPinnedRequestData: { descriptor, _ in
                pinnedReadCount.update { $0 += 1 }
                gate.blockOnce()
                return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
            })
        let template = BuiltInTemplates.all[0]
        let templateStore = TemplateStore(defaults: defaults)
        try templateStore.saveTemplates([template])
        let model = QuickFileViewModel(templateStore: templateStore, templates: [template],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults))
        model.destinationFolder = temporaryDirectory
        model.requestedFilename = "direct-during-read"
        var windowAvailable = true
        var phases: [QuickFileViewModel.FinderAuthorizationRequestPhase] = []
        let observation = model.$finderAuthorizationRequestPhase.sink { phases.append($0) }
        defer { observation.cancel() }
        let drain = Task {
            await model.processPendingFinderAuthorizationRequests(from: reader,
                isPresentationAvailable: { windowAvailable },
                confirmAuthorization: { _ in XCTFail("The originating window closed"); return nil })
        }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        guard started else {
            windowAvailable = false
            gate.release.signal()
            await drain.value
            return XCTFail("The fixture never entered the pinned payload reader; no busy-admission assertions ran")
        }
        XCTAssertEqual(pinnedReadCount.value, 1, "The blocked probe must be the actual pinned-read path")
        XCTAssertEqual(model.finderAuthorizationRequestPhase, .readingQueue)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.canCreate)
        XCTAssertTrue(model.isAuthorizationCheckBusy)
        drain.cancel()
        windowAvailable = false
        await model.processPendingFinderAuthorizationRequests(from: requests) { _ in
            XCTFail("A second window cannot steal the active claim lease")
            return nil
        }
        await model.createFile()
        let directURL = try XCTUnwrap(model.createdFileURL)
        let directStatus = model.status
        XCTAssertEqual(directURL.lastPathComponent, "direct-during-read.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directURL.path))
        XCTAssertEqual(pinnedReadCount.value, 1)
        XCTAssertTrue(model.isProcessingFinderAuthorizationRequests,
            "Cancellation is not proof that a synchronous descriptor read has ended")
        // A producer can still save while the pinned payload is blocked outside
        // flock, but this does not release the app's separate processing admission.
        let retained = FinderAuthorizationRequest(templateID: BuiltInTemplates.all[0].id,
            destinationFolder: temporaryDirectory)
        try requests.save(retained)
        gate.release.signal()
        await drain.value
        XCTAssertTrue(gate.wasReleasedBeforeTimeout)
        XCTAssertEqual(phases, [.idle, .readingQueue, .idle])
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.finderAuthorizationQueuePause, "Window loss retains the existing closure-stop policy")
        XCTAssertEqual(model.createdFileURL, directURL)
        XCTAssertEqual(model.status, directStatus, "Late window loss cannot replace the independent result")
        XCTAssertEqual(try requests.takePendingRequest()?.id, retained.id)
        XCTAssertNil(try requests.takePendingRequest())
    }

    func testLateClaimWaitsForDirectCreationAndPreservesNewerFormEdits() async throws {
        try await assertLateClaimWaitsForDirectCreation(closeWhileWaiting: false)
    }

    func testWindowClosingWhileLateClaimWaitsPreservesDirectResultAndRemainingQueue() async throws {
        try await assertLateClaimWaitsForDirectCreation(closeWhileWaiting: true)
    }

    private func assertLateClaimWaitsForDirectCreation(closeWhileWaiting: Bool) async throws {
        let readGate = CreationGate()
        let createGate = CreationGate()
        defer { readGate.release.signal(); createGate.release.signal() }
        let finderTemplate = FileTemplate(name: "Finder", fileExtension: "txt", content: "Finder")
        let directTemplate = FileTemplate(name: "Direct", fileExtension: "md", content: "{{clipboard}}")
        let templateStore = TemplateStore(defaults: defaults)
        try templateStore.saveTemplates([finderTemplate, directTemplate])
        let requests = makeRequestStore()
        XCTAssertNil(try requests.takePendingRequest()) // Finish migration before the pinned-read fixture.
        let first = FinderAuthorizationRequest(templateID: finderTemplate.id, destinationFolder: temporaryDirectory,
            createdAt: Date().addingTimeInterval(-2))
        let second = FinderAuthorizationRequest(templateID: finderTemplate.id, destinationFolder: temporaryDirectory,
            createdAt: Date().addingTimeInterval(-1))
        try requests.save(first)
        try requests.save(second)
        let retainedURL = temporaryDirectory.appendingPathComponent("requests/\(second.id.uuidString).json")
        let retainedBytes = try Data(contentsOf: retainedURL)
        let reads = LockedTestValue(0)
        let reader = FinderAuthorizationRequestStore(defaults: defaults,
            directoryURL: temporaryDirectory.appendingPathComponent("requests"),
            readPinnedRequestData: { descriptor, _ in
                reads.update { $0 += 1 }
                readGate.blockOnce()
                return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
            })
        let model = QuickFileViewModel(templateStore: templateStore, templates: [finderTemplate, directTemplate],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            fileCreationService: FileCreationService(clipboardProvider: { createGate.blockOnce(); return "direct" }))
        model.destinationFolder = temporaryDirectory
        model.requestedFilename = "before-read"
        var available = true
        var confirmations: [UUID] = []
        let waiting = expectation(description: "Claim waits for independent create")
        let waitingObservation = model.$finderAuthorizationRequestPhase
            .filter { $0 == .waitingForCurrentOperation }.prefix(1).sink { _ in waiting.fulfill() }
        defer { waitingObservation.cancel() }
        let drain = Task {
            await model.processPendingFinderAuthorizationRequests(from: reader,
                isPresentationAvailable: { available },
                willPresent: {
                    XCTAssertFalse(model.isCreatingFile)
                    XCTAssertFalse(model.isAuthorizingDirectory)
                    XCTAssertTrue(model.isBusy, "Claim reserves admission before navigation and modal reentry")
                    if confirmations.isEmpty {
                        XCTAssertEqual(model.createdFileURL?.lastPathComponent, "direct-name.md")
                    }
                },
                confirmAuthorization: { request in
                    confirmations.append(request.id)
                    return request.id == first.id ? request.destinationFolder : nil
                })
        }
        let readStarted = await BackgroundWork.run { readGate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(readStarted)
        model.selectedTemplateID = directTemplate.id
        model.requestedFilename = "direct-name"
        let directCreation = Task { await model.createFile() }
        let createStarted = await BackgroundWork.run { createGate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(createStarted)
        // Returning to a byte-distinct spelling must still count as a newer edit.
        model.requestedFilename = "Cafe\u{301}"
        readGate.release.signal()
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertEqual(model.finderAuthorizationRequestPhase, .waitingForCurrentOperation)
        XCTAssertTrue(model.isCreatingFile)
        XCTAssertTrue(model.isProcessingFinderAuthorizationRequests)
        XCTAssertTrue(confirmations.isEmpty)
        XCTAssertEqual(try Data(contentsOf: retainedURL), retainedBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            temporaryDirectory.appendingPathComponent("requests/\(first.id.uuidString).json").path))
        let readsWhileWaiting = reads.value
        for _ in 0..<10 {
            await model.processPendingFinderAuthorizationRequests(from: reader) { _ in
                XCTFail("Notifications and other windows cannot take the waiting claim"); return nil
            }
        }
        await model.createFile()
        await model.selectDestinationFolder(temporaryDirectory.appendingPathComponent("not-selected"))
        XCTAssertEqual(model.destinationFolder, temporaryDirectory)
        XCTAssertEqual(reads.value, readsWhileWaiting, "The pump cannot read the next request while one claim waits")
        if closeWhileWaiting { available = false; drain.cancel(); directCreation.cancel() }
        createGate.release.signal()
        await directCreation.value
        await drain.value
        XCTAssertTrue(readGate.wasReleasedBeforeTimeout)
        XCTAssertTrue(createGate.wasReleasedBeforeTimeout)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isProcessingFinderAuthorizationRequests)
        XCTAssertEqual(model.selectedTemplateID, directTemplate.id)
        XCTAssertEqual(Array(model.requestedFilename.utf8), Array("Cafe\u{301}".utf8))
        let directURL = temporaryDirectory.appendingPathComponent("direct-name.md")
        XCTAssertEqual(try String(contentsOf: directURL, encoding: .utf8), "direct")
        if closeWhileWaiting {
            XCTAssertTrue(confirmations.isEmpty)
            // F_GETPATH and Foundation may retain different /var aliases.
            // Require the exact fixture filename and the same regular file object.
            let returnedURL = try XCTUnwrap(model.createdFileURL)
            XCTAssertTrue(returnedURL.isFileURL)
            XCTAssertEqual(returnedURL.lastPathComponent, directURL.lastPathComponent)
            var expectedIdentity = stat()
            var returnedIdentity = stat()
            XCTAssertEqual(lstat(directURL.path, &expectedIdentity), 0)
            XCTAssertEqual(lstat(returnedURL.path, &returnedIdentity), 0)
            XCTAssertEqual(expectedIdentity.st_mode & S_IFMT, S_IFREG)
            XCTAssertEqual(returnedIdentity.st_mode & S_IFMT, S_IFREG)
            XCTAssertEqual(returnedIdentity.st_dev, expectedIdentity.st_dev)
            XCTAssertEqual(returnedIdentity.st_ino, expectedIdentity.st_ino)
            XCTAssertEqual(model.status, .success("已创建 direct-name.md"))
            XCTAssertNil(model.finderAuthorizationQueuePause)
            XCTAssertEqual(try requests.takePendingRequest()?.id, second.id)
        } else {
            XCTAssertEqual(confirmations, [first.id, second.id])
            XCTAssertEqual(model.createdFileURL?.lastPathComponent, "未命名.txt")
            XCTAssertEqual(try String(contentsOf: XCTUnwrap(model.createdFileURL), encoding: .utf8), "Finder")
            XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .cancelled)
            XCTAssertNil(try requests.takePendingRequest())
        }
    }

    func testLateClaimWaitsForSavingFinderAuthorizationBeforeOpeningPanel() async throws {
        try await assertLateClaimWaitsForDirectoryOperation(selectSaved: false)
    }

    func testLateClaimWaitsForSavedDirectoryResolutionBeforeOpeningPanel() async throws {
        try await assertLateClaimWaitsForDirectoryOperation(selectSaved: true)
    }

    private func assertLateClaimWaitsForDirectoryOperation(selectSaved: Bool) async throws {
        let readGate = CreationGate()
        let directoryGate = CreationGate()
        defer { readGate.release.signal(); directoryGate.release.signal() }
        let mayBlock = LockedTestValue(false)
        let authorizationStore = AuthorizedDirectoryStore(defaults: defaults, storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { url in
                if !selectSaved && mayBlock.value { directoryGate.blockOnce() }
                return Self.bookmarkData(for: url)
            },
            transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { data in
                if selectSaved && mayBlock.value { directoryGate.blockOnce() }
                return try Self.resolveBookmark(data)
            },
            transferBookmarkResolver: { try Self.resolveBookmark($0) },
            startAccessing: { _ in true }, stopAccessing: { _ in })
        let saved = try authorizationStore.authorize(temporaryDirectory)
        mayBlock.update { $0 = true }
        let requests = makeRequestStore()
        XCTAssertNil(try requests.takePendingRequest())
        let request = FinderAuthorizationRequest(templateID: BuiltInTemplates.all[0].id, destinationFolder: temporaryDirectory)
        try requests.save(request)
        let reader = FinderAuthorizationRequestStore(defaults: defaults,
            directoryURL: temporaryDirectory.appendingPathComponent("requests"),
            readPinnedRequestData: { descriptor, _ in
                readGate.blockOnce()
                return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
            })
        let model = makeViewModel(authorizationStore: authorizationStore)
        var confirmations = 0
        let waiting = expectation(description: "Claim waits for directory operation")
        let observation = model.$finderAuthorizationRequestPhase
            .filter { $0 == .waitingForCurrentOperation }.prefix(1).sink { _ in waiting.fulfill() }
        defer { observation.cancel() }
        let drain = Task {
            await model.processPendingFinderAuthorizationRequests(from: reader) { received in
                confirmations += 1
                XCTAssertEqual(received.id, request.id)
                XCTAssertFalse(model.isAuthorizingDirectory)
                XCTAssertTrue(model.isBusy)
                XCTAssertEqual(model.finderAuthorizationState, .saved)
                return nil
            }
        }
        let readStarted = await BackgroundWork.run { readGate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(readStarted)
        let selection = Task {
            if selectSaved { await model.selectAuthorizedDirectory(saved) }
            else { await model.saveFinderAuthorization(for: temporaryDirectory) }
        }
        let operationStarted = await BackgroundWork.run { directoryGate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(operationStarted)
        readGate.release.signal()
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertEqual(confirmations, 0)
        XCTAssertTrue(model.isAuthorizingDirectory)
        XCTAssertTrue(model.isProcessingFinderAuthorizationRequests)
        directoryGate.release.signal()
        await selection.value
        await drain.value
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(directoryGate.wasReleasedBeforeTimeout)
        XCTAssertTrue(readGate.wasReleasedBeforeTimeout)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.destinationFolder, temporaryDirectory)
        XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .cancelled)
    }

    func testLateReadFailurePreservesCompletedDirectCreationAndUsesPauseBanner() async throws {
        try await assertLateReadFailurePreservesDirectCreation(finishCreationFirst: true)
    }

    func testLateReadFailureDoesNotTakeResultOwnershipFromRunningDirectCreation() async throws {
        try await assertLateReadFailurePreservesDirectCreation(finishCreationFirst: false)
    }

    private func assertLateReadFailurePreservesDirectCreation(finishCreationFirst: Bool) async throws {
        let readGate = CreationGate()
        let createGate = CreationGate()
        defer { readGate.release.signal(); createGate.release.signal() }
        let template = FileTemplate(name: "Direct", fileExtension: "txt", content: "{{clipboard}}")
        let templateStore = TemplateStore(defaults: defaults)
        try templateStore.saveTemplates([template])
        let model = QuickFileViewModel(templateStore: templateStore, templates: [template],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            fileCreationService: FileCreationService(clipboardProvider: { createGate.blockOnce(); return "direct" }))
        model.destinationFolder = temporaryDirectory
        model.requestedFilename = "success"
        let requests = makeRequestStore()
        XCTAssertNil(try requests.takePendingRequest())
        let request = FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory)
        try requests.save(request)
        let sourceURL = temporaryDirectory.appendingPathComponent("requests/\(request.id.uuidString).json")
        let source = try Data(contentsOf: sourceURL)
        let reader = FinderAuthorizationRequestStore(defaults: defaults,
            directoryURL: temporaryDirectory.appendingPathComponent("requests"),
            readPinnedRequestData: { _, _ in
                readGate.blockOnce()
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
            })
        let drain = Task {
            await model.processPendingFinderAuthorizationRequests(from: reader,
                willPresent: { XCTFail("Late queue error must not change the user's tab") },
                confirmAuthorization: { _ in XCTFail("The unread request cannot be presented"); return nil })
        }
        let readStarted = await BackgroundWork.run { readGate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(readStarted)
        let direct = Task { await model.createFile() }
        let createStarted = await BackgroundWork.run { createGate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(createStarted)
        if finishCreationFirst { createGate.release.signal(); await direct.value }
        let statusBeforeFailure = model.status
        let resultBeforeFailure = model.createdFileURL
        readGate.release.signal()
        await drain.value
        XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .readFailed(.unreadable))
        XCTAssertEqual(model.status, statusBeforeFailure)
        XCTAssertEqual(model.createdFileURL, resultBeforeFailure)
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
        let pause = try XCTUnwrap(model.finderAuthorizationQueuePause)
        if !finishCreationFirst {
            XCTAssertTrue(model.isCreatingFile)
            await model.processPendingFinderAuthorizationRequests(from: requests, resumingPauseID: pause.id) { _ in
                XCTFail("A running direct create prevents an explicit retry from clearing pause"); return nil
            }
            XCTAssertEqual(model.finderAuthorizationQueuePause, pause)
            createGate.release.signal()
            await direct.value
        }
        XCTAssertEqual(model.status, .success("已创建 success.txt"))
        XCTAssertEqual(model.createdFileURL?.lastPathComponent, "success.txt")
        // Cancel the recovered claim explicitly; automatic notifications must not
        // retry the failed reader or clear the session-wide error pause.
        await model.processPendingFinderAuthorizationRequests(from: requests) { _ in
            XCTFail("The pause must survive automatic retries"); return nil
        }
        XCTAssertEqual(model.finderAuthorizationQueuePause, pause)
        await model.processPendingFinderAuthorizationRequests(from: requests, resumingPauseID: pause.id) { received in
            XCTAssertEqual(received.id, request.id)
            return nil
        }
        XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .cancelled)
        XCTAssertNotEqual(model.finderAuthorizationQueuePause?.id, pause.id)
        XCTAssertEqual(model.createdFileURL?.lastPathComponent, "success.txt")
        XCTAssertTrue(readGate.wasReleasedBeforeTimeout)
        XCTAssertTrue(createGate.wasReleasedBeforeTimeout)
    }

    func testEmptyExplicitRetryCannotClearNewerDirectSelectionOrSuccess() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let template = FileTemplate(name: "Direct", fileExtension: "txt", content: "direct")
        let templateStore = TemplateStore(defaults: defaults)
        try templateStore.saveTemplates([template])
        let model = QuickFileViewModel(templateStore: templateStore, templates: [template],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults))
        let unavailable = FinderAuthorizationRequestStore(defaults: nil, directoryURL: nil)
        await model.processPendingFinderAuthorizationRequests(from: unavailable) { _ in nil }
        let pause = try XCTUnwrap(model.finderAuthorizationQueuePause)
        let reader = FinderAuthorizationRequestStore(defaults: defaults,
            directoryURL: temporaryDirectory.appendingPathComponent("requests"),
            fileManager: PausedRequestFileManager(gate: gate))
        let drain = Task {
            await model.processPendingFinderAuthorizationRequests(from: reader, resumingPauseID: pause.id,
                willPresent: { XCTFail("An empty retry must not navigate") },
                confirmAuthorization: { _ in XCTFail("There is no claim"); return nil })
        }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        await model.selectDestinationFolder(temporaryDirectory)
        model.requestedFilename = "newer"
        await model.createFile()
        let status = model.status
        let result = try XCTUnwrap(model.createdFileURL)
        gate.release.signal()
        await drain.value
        XCTAssertNil(model.finderAuthorizationQueuePause)
        XCTAssertEqual(model.status, status)
        XCTAssertEqual(model.createdFileURL, result)
        XCTAssertEqual(model.requestedFilename, "newer")
        XCTAssertFalse(model.isAuthorizationCheckBusy)
        XCTAssertTrue(gate.wasReleasedBeforeTimeout)
    }

    func testDirectFolderPanelsReserveAdmissionBeforeChooserAndReleaseOnCancel() async throws {
        let model = makeViewModel(authorizationStore: makeAuthorizationStore(defaults: defaults))
        await model.selectDestinationFolder(temporaryDirectory)
        let status = model.status
        var selections = 0
        await model.selectDestinationFolder(choosing: {
            selections += 1
            XCTAssertTrue(model.isAuthorizingDirectory)
            XCTAssertTrue(model.isBusy)
            return nil
        })
        XCTAssertEqual(model.status, status)
        XCTAssertEqual(model.destinationFolder, temporaryDirectory)
        XCTAssertFalse(model.isBusy)
        await model.saveFinderAuthorization(choosing: {
            selections += 1
            XCTAssertTrue(model.isAuthorizingDirectory)
            XCTAssertTrue(model.isBusy)
            return nil
        })
        XCTAssertEqual(selections, 2)
        XCTAssertEqual(model.status, status)
        XCTAssertEqual(model.finderAuthorizationState, .notConfirmed)
        XCTAssertFalse(model.isBusy)
    }

    func testDirectFolderPanelSelectionAndAuthorizationKeepExistingSemantics() async throws {
        let authorizationStore = makeAuthorizationStore(defaults: defaults)
        let model = makeViewModel(authorizationStore: authorizationStore)
        await model.selectDestinationFolder(choosing: { temporaryDirectory })
        XCTAssertEqual(model.destinationFolder, temporaryDirectory)
        XCTAssertEqual(model.finderAuthorizationState, .notConfirmed)
        XCTAssertFalse(model.isBusy)
        await model.saveFinderAuthorization(choosing: { temporaryDirectory })
        XCTAssertEqual(model.destinationFolder, temporaryDirectory)
        XCTAssertEqual(model.finderAuthorizationState, .saved)
        XCTAssertFalse(model.isBusy)
    }

    func testLateClaimCannotPresentDuringDirectDestinationChooser() async throws {
        try await assertLateClaimWaitsForChooser(saveAuthorization: false)
    }

    func testLateClaimCannotPresentDuringFinderAuthorizationChooser() async throws {
        try await assertLateClaimWaitsForChooser(saveAuthorization: true)
    }

    private func assertLateClaimWaitsForChooser(saveAuthorization: Bool) async throws {
        let readGate = CreationGate()
        defer { readGate.release.signal() }
        let requests = makeRequestStore()
        XCTAssertNil(try requests.takePendingRequest())
        let request = FinderAuthorizationRequest(templateID: BuiltInTemplates.all[0].id, destinationFolder: temporaryDirectory)
        try requests.save(request)
        let reader = FinderAuthorizationRequestStore(defaults: defaults,
            directoryURL: temporaryDirectory.appendingPathComponent("requests"),
            readPinnedRequestData: { descriptor, _ in
                readGate.blockOnce()
                return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
            })
        let model = makeViewModel(authorizationStore: makeAuthorizationStore(defaults: defaults))
        let chooserStarted = expectation(description: "Direct chooser owns interactive admission")
        let claimWaiting = expectation(description: "Returned claim waits behind direct chooser")
        let observation = model.$finderAuthorizationRequestPhase
            .filter { $0 == .waitingForCurrentOperation }.prefix(1).sink { _ in claimWaiting.fulfill() }
        defer { observation.cancel() }
        let chooserGate = AsyncTestGate<URL?>()
        defer { chooserGate.release(nil) }
        var confirmations = 0
        let drain = Task {
            await model.processPendingFinderAuthorizationRequests(from: reader) { _ in
                XCTAssertFalse(model.isAuthorizingDirectory)
                XCTAssertTrue(model.isBusy)
                confirmations += 1
                return nil
            }
        }
        let started = await BackgroundWork.run { readGate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        let chooser: @MainActor () async -> URL? = {
            XCTAssertTrue(model.isAuthorizingDirectory)
            XCTAssertTrue(model.isBusy)
            chooserStarted.fulfill()
            return await chooserGate.wait()
        }
        let direct = Task {
            if saveAuthorization { _ = await model.saveFinderAuthorization(choosing: chooser) }
            else { await model.selectDestinationFolder(choosing: chooser) }
        }
        await fulfillment(of: [chooserStarted], timeout: 5)
        readGate.release.signal()
        await fulfillment(of: [claimWaiting], timeout: 5)
        XCTAssertEqual(confirmations, 0)
        XCTAssertTrue(model.isAuthorizingDirectory)
        XCTAssertEqual(model.finderAuthorizationRequestPhase, .waitingForCurrentOperation)
        var competingChooserCalls = 0
        await model.selectDestinationFolder(choosing: { competingChooserCalls += 1; return nil })
        await model.saveFinderAuthorization(choosing: { competingChooserCalls += 1; return nil })
        XCTAssertEqual(competingChooserCalls, 0)
        // Simulate Cancel, including cancellation of the caller's waiting Task.
        // It must still own the chooser until the awaited operation really returns.
        direct.cancel()
        drain.cancel()
        XCTAssertTrue(model.isAuthorizingDirectory)
        XCTAssertTrue(model.isProcessingFinderAuthorizationRequests)
        chooserGate.release(nil)
        await direct.value
        await drain.value
        XCTAssertEqual(confirmations, 1)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isAuthorizationCheckBusy)
        XCTAssertNil(model.destinationFolder)
        XCTAssertEqual(model.finderAuthorizationState, .notConfirmed)
        XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .cancelled)
        XCTAssertTrue(readGate.wasReleasedBeforeTimeout)
    }

    func testReopenedWindowRetainsOneRetryAndPendingRouteWhileQueueReadLeavesFormUsable() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let template = BuiltInTemplates.all[0]
        let templateStore = TemplateStore(defaults: defaults)
        try templateStore.saveTemplates([template])
        let model = QuickFileViewModel(templateStore: templateStore, templates: [template],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults))
        model.destinationFolder = temporaryDirectory
        let requests = makeRequestStore()
        XCTAssertNil(try requests.takePendingRequest())
        let first = FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory,
            createdAt: Date().addingTimeInterval(-2))
        let second = FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory,
            createdAt: Date().addingTimeInterval(-1))
        try requests.save(first)
        try requests.save(second)
        let reader = FinderAuthorizationRequestStore(defaults: defaults,
            directoryURL: temporaryDirectory.appendingPathComponent("requests"),
            readPinnedRequestData: { descriptor, _ in
                gate.blockOnce()
                return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
            })
        var window = QuickFileWindowPresentationState()
        window.appear()
        let oldGeneration = try XCTUnwrap(window.requestAuthorizationCheck())
        let firstDrain = Task {
            await model.processPendingFinderAuthorizationRequests(from: reader,
                isPresentationAvailable: { window.canPresent(oldGeneration) },
                confirmAuthorization: { _ in XCTFail("An old window generation cannot borrow the reopened window"); return nil })
        }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.isAuthorizationCheckBusy)
        window.disappear()
        window.appear()
        let reopenedGeneration = try XCTUnwrap(window.requestAuthorizationCheck())
        var route = QuickFilePendingAppRoute()
        route.receive(QuickFileAppRoute.templates.url)
        await model.processPendingFinderAuthorizationRequests(from: reader,
            isPresentationAvailable: { window.canPresent(reopenedGeneration) },
            confirmAuthorization: { _ in XCTFail("The old read still owns the single claim lease"); return nil })
        XCTAssertTrue(window.finishAuthorizationCheck(for: reopenedGeneration, isBusy: model.isAuthorizationCheckBusy))
        XCTAssertTrue(window.isAwaitingAuthorizationCheck)
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: model.isAuthorizationCheckBusy))
        XCTAssertNil(route.takeIfReady(startupAuthorizationChecked: true, isBusy: model.isAuthorizationCheckBusy))
        await model.createFile()
        let directStatus = model.status
        XCTAssertNotNil(model.createdFileURL)
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: model.isAuthorizationCheckBusy),
            "Direct operation release is not release of the existing queue read")
        gate.release.signal()
        await firstDrain.value
        XCTAssertEqual(model.status, directStatus)
        XCTAssertFalse(window.finishAuthorizationCheck(for: oldGeneration, isBusy: model.isAuthorizationCheckBusy))
        XCTAssertTrue(window.shouldResumeAuthorizationCheck(isBusy: model.isAuthorizationCheckBusy))
        let retryGeneration = try XCTUnwrap(window.requestAuthorizationCheck())
        var received: [UUID] = []
        await model.processPendingFinderAuthorizationRequests(from: reader,
            isPresentationAvailable: { window.canPresent(retryGeneration) }) { request in
                received.append(request.id)
                return nil
            }
        XCTAssertEqual(received, [second.id])
        XCTAssertTrue(window.finishAuthorizationCheck(for: retryGeneration, isBusy: model.isAuthorizationCheckBusy))
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: model.isAuthorizationCheckBusy))
        XCTAssertFalse(window.isAwaitingAuthorizationCheck)
        XCTAssertEqual(route.takeIfReady(startupAuthorizationChecked: true, isBusy: model.isAuthorizationCheckBusy), .templates)
        XCTAssertNil(try requests.takePendingRequest())
        XCTAssertTrue(gate.wasReleasedBeforeTimeout)
    }

    func testUnchangedFormStillUsesConfirmedFinderSelectionAndClearsFilenameAfterSlowRead() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let original = FileTemplate(name: "Original", fileExtension: "md", content: "original")
        let finder = FileTemplate(name: "Finder", fileExtension: "txt", content: "finder")
        let templateStore = TemplateStore(defaults: defaults)
        try templateStore.saveTemplates([original, finder])
        let model = QuickFileViewModel(templateStore: templateStore, templates: [original, finder],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults))
        model.requestedFilename = "unchanged"
        let requests = makeRequestStore()
        XCTAssertNil(try requests.takePendingRequest())
        try requests.save(FinderAuthorizationRequest(templateID: finder.id, destinationFolder: temporaryDirectory))
        let reader = FinderAuthorizationRequestStore(defaults: defaults,
            directoryURL: temporaryDirectory.appendingPathComponent("requests"),
            readPinnedRequestData: { descriptor, _ in
                gate.blockOnce()
                return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
            })
        let drain = Task {
            await model.processPendingFinderAuthorizationRequests(from: reader) { $0.destinationFolder }
        }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertFalse(model.isBusy)
        gate.release.signal()
        await drain.value
        XCTAssertEqual(model.selectedTemplateID, finder.id)
        XCTAssertEqual(model.requestedFilename, "")
        XCTAssertEqual(model.createdFileURL?.lastPathComponent, "未命名.txt")
        XCTAssertTrue(gate.wasReleasedBeforeTimeout)
    }

    func testLateClaimResumesAfterDirectCreationPreflightFailureWithoutLeakingWaiter() async throws {
        let readGate = CreationGate()
        let loadGate = CreationGate()
        defer { readGate.release.signal(); loadGate.release.signal() }
        let template = FileTemplate(name: "Direct", fileExtension: "txt", content: "direct")
        let templateStore = TemplateStore(defaults: defaults)
        try templateStore.saveTemplates([template])
        let requests = makeRequestStore()
        XCTAssertNil(try requests.takePendingRequest())
        try requests.save(FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory))
        let reader = FinderAuthorizationRequestStore(defaults: defaults,
            directoryURL: temporaryDirectory.appendingPathComponent("requests"),
            readPinnedRequestData: { descriptor, _ in
                readGate.blockOnce()
                return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
            })
        var model: QuickFileViewModel? = QuickFileViewModel(templateStore: templateStore, templates: [template],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            authoritativeTemplateLoader: {
                loadGate.blockOnce()
                throw TemplateStore.StoreError.sharedDefaultsUnavailable
            })
        weak var weakModel = model
        model?.destinationFolder = temporaryDirectory
        let waiting = expectation(description: "Claim waits for failing direct preflight")
        var observation: AnyCancellable? = model?.$finderAuthorizationRequestPhase
            .filter { $0 == .waitingForCurrentOperation }.prefix(1).sink { _ in waiting.fulfill() }
        var confirmations = 0
        var drain: Task<Void, Never>? = Task { [model] in
            _ = await model?.processPendingFinderAuthorizationRequests(from: reader) { request in
                confirmations += 1
                XCTAssertFalse(model?.isCreatingFile ?? true)
                XCTAssertNil(model?.createdFileURL)
                XCTAssertEqual(model?.templateLoadFailure, .storageUnavailable)
                return request.destinationFolder
            }
        }
        let started = await BackgroundWork.run { readGate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        var direct: Task<Void, Never>? = Task { [model] in _ = await model?.createFile() }
        let loading = await BackgroundWork.run { loadGate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(loading)
        readGate.release.signal()
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertEqual(confirmations, 0)
        loadGate.release.signal()
        await direct?.value
        await drain?.value
        XCTAssertEqual(confirmations, 1)
        XCTAssertNotNil(model?.createdFileURL, "Finder's independent authoritative loader still succeeds")
        XCTAssertNil(model?.templateLoadFailure)
        XCTAssertFalse(model?.isBusy ?? true)
        observation?.cancel()
        observation = nil
        direct = nil
        drain = nil
        model = nil
        for _ in 0..<20 where weakModel != nil { await Task.yield() }
        XCTAssertNil(weakModel, "A settled waiter must not retain the model or completed tasks")
        XCTAssertTrue(readGate.wasReleasedBeforeTimeout)
        XCTAssertTrue(loadGate.wasReleasedBeforeTimeout)
    }

    func testUnreadableRequestDoesNotBlockHealthyDrainAndRecoversOnce() async throws {
        let model = makeViewModel(authorizationStore: makeAuthorizationStore(defaults: defaults))
        let writer = makeRequestStore()
        let now = Date()
        let requests = (0..<3).map { index in
            FinderAuthorizationRequest(
                templateID: BuiltInTemplates.all[0].id,
                destinationFolder: temporaryDirectory,
                createdAt: now.addingTimeInterval(Double(index) - 3)
            )
        }
        for request in requests { try writer.save(request) }
        let requestDirectory = temporaryDirectory.appendingPathComponent("requests", isDirectory: true)
        let blockedURL = requestDirectory.appendingPathComponent("\(requests[0].id.uuidString).json")
        let originalData = try Data(contentsOf: blockedURL)
        let readFailure = NSError(domain: "QuickFileTests.RequestRead", code: 1)
        let readAttempts = LockedTestValue(0)
        let reader = FinderAuthorizationRequestStore(
            defaults: defaults,
            directoryURL: requestDirectory,
            readRequestData: { url in
                readAttempts.update { $0 += 1 }
                if url.lastPathComponent == blockedURL.lastPathComponent { throw readFailure }
                return try Data(contentsOf: url)
            }
        )
        var confirmations = 0
        await model.processPendingFinderAuthorizationRequests(from: reader) { directory in
            confirmations += 1
            return directory.destinationFolder
        }

        XCTAssertEqual(confirmations, 2)
        XCTAssertEqual(try Data(contentsOf: blockedURL), originalData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.hasSuffix(".txt") }.count, 2)
        XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .readFailed(.unreadable))
        XCTAssertEqual(model.status, .failure(QuickFileViewModel.FinderAuthorizationQueueReadFailure.unreadable.message))
        XCTAssertFalse(model.isBusy)
        // Another activation while the fault persists must not retry storage or confirmations.
        let attemptsBeforeActivation = readAttempts.value
        await model.processPendingFinderAuthorizationRequests(from: reader) { _ in
            XCTFail("The unreadable request must not be presented")
            return nil
        }
        XCTAssertEqual(readAttempts.value, attemptsBeforeActivation)
        let firstFailurePauseID = try XCTUnwrap(model.finderAuthorizationQueuePause?.id)
        await model.processPendingFinderAuthorizationRequests(from: reader, resumingPauseID: firstFailurePauseID) { _ in
            XCTFail("A failed retry must not fabricate a readable request")
            return nil
        }
        XCTAssertGreaterThan(readAttempts.value, attemptsBeforeActivation)
        XCTAssertEqual(model.finderAuthorizationQueuePause?.reason, .readFailed(.unreadable))
        XCTAssertNotEqual(model.finderAuthorizationQueuePause?.id, firstFailurePauseID)
        let newerFailurePause = model.finderAuthorizationQueuePause
        await model.processPendingFinderAuthorizationRequests(from: writer, resumingPauseID: firstFailurePauseID) { _ in
            XCTFail("A delayed retry must not clear a newer failure pause, even after storage recovers")
            return nil
        }
        XCTAssertEqual(model.finderAuthorizationQueuePause, newerFailurePause)
        XCTAssertEqual(try Data(contentsOf: blockedURL), originalData)
        await model.processPendingFinderAuthorizationRequests(from: writer, resumingPauseID: model.finderAuthorizationQueuePause?.id) { directory in
            confirmations += 1
            return directory.destinationFolder
        }
        XCTAssertEqual(confirmations, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.hasSuffix(".txt") }.count, 3)
        XCTAssertNil(try writer.takePendingRequest())
        XCTAssertFalse(model.isBusy)
    }

    func testBusyRecheckDuringEmptyReadDrainsRequestSavedBeforeProcessingResumes() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let fileManager = PausedRequestFileManager(gate: gate)
        let requestDirectory = temporaryDirectory.appendingPathComponent("requests", isDirectory: true)
        try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: true)
        let reader = FinderAuthorizationRequestStore(
            defaults: defaults,
            directoryURL: requestDirectory,
            fileManager: fileManager
        )
        let model = makeViewModel(authorizationStore: makeAuthorizationStore(defaults: defaults))
        var confirmations = 0
        let drain = Task {
            await model.processPendingFinderAuthorizationRequests(from: reader) { directory in
                confirmations += 1
                return directory.destinationFolder
            }
        }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        guard started else {
            XCTFail("The empty request read did not reach the gate")
            gate.release.signal()
            await drain.value
            return
        }
        await model.processPendingFinderAuthorizationRequests(from: reader) { _ in
            XCTFail("The existing processor owns the request queue")
            return nil
        }
        // The paused enumeration holds the queue's flock. Request a recheck first,
        // then release that lock before saving through the real store. This test
        // stays on MainActor until save returns, so the empty-read continuation
        // cannot consume the recheck flag before the new request is persisted.
        gate.release.signal()
        let saveResult = Result {
            try makeRequestStore().save(FinderAuthorizationRequest(
                templateID: BuiltInTemplates.all[0].id,
                destinationFolder: temporaryDirectory
            ))
        }
        await drain.value
        try saveResult.get()

        XCTAssertTrue(gate.wasReleasedBeforeTimeout, "The empty read must not escape through the gate timeout")
        XCTAssertEqual(confirmations, 1)
        XCTAssertNotNil(model.createdFileURL)
        XCTAssertNil(try makeRequestStore().takePendingRequest())
        XCTAssertFalse(model.isBusy)
    }

    func testIndependentViewModelsRejectStaleSaveAndRecoverAfterReload() async throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let firstStore = TemplateStore(defaults: defaults, storageURL: url)
        let secondStore = TemplateStore(defaults: defaults, storageURL: url)
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        try firstStore.saveTemplates([original])
        let first = QuickFileViewModel(templateStore: firstStore)
        await first.loadTemplatesIfNeeded()
        let second = QuickFileViewModel(templateStore: secondStore)
        await second.loadTemplatesIfNeeded()
        let added = FileTemplate(name: "Added", fileExtension: "md", content: "new")
        try await first.saveTemplate(added, replacing: nil)

        await assertFalseAsync(await second.deleteTemplate(withID: original.id))
        XCTAssertEqual(second.templates, [original])
        XCTAssertNotNil(second.templateLoadError)
        XCTAssertEqual(try secondStore.reloadTemplates(), [original, added])
        await second.reloadTemplates()
        XCTAssertNil(second.templateLoadError)
        await assertTrueAsync(await second.deleteTemplate(withID: original.id))
        XCTAssertEqual(try firstStore.reloadTemplates(), [added])
    }

    func testInjectedTemplatesDoNotReadTemplateStorageDuringInitialization() async throws {
        let trackingDefaults = try XCTUnwrap(TemplateReadTrackingDefaults(suiteName: suiteName))
        let store = TemplateStore(defaults: trackingDefaults)
        let model = QuickFileViewModel(templateStore: store, templates: [])

        XCTAssertEqual(trackingDefaults.templateReadCount, 0)
        XCTAssertTrue(model.templates.isEmpty)
        XCTAssertNil(model.templateLoadError)
    }

    func testInjectedEmptySnapshotCanSaveAgainstExplicitlySeededStorage() async throws {
        let store = TemplateStore(defaults: defaults)
        try store.saveTemplates([])
        let model = QuickFileViewModel(templateStore: store, templates: [])
        let added = FileTemplate(name: "Added", fileExtension: "txt", content: "new")
        try await model.saveTemplate(added, replacing: nil)
        XCTAssertEqual(try store.reloadTemplates(), [added])
    }

    func testFinderCompletionPreservesFormEditedWhileCreatingEvenAfterReturningToOriginalValues() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let store = TemplateStore(defaults: defaults)
        var finderTemplate = BuiltInTemplates.all[0]
        finderTemplate.content = "{{clipboard}}"
        let formTemplate = FileTemplate(name: "Form", fileExtension: "md", content: "form")
        try store.saveTemplates([finderTemplate, formTemplate])
        let model = QuickFileViewModel(
            templateStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            fileCreationService: FileCreationService(clipboardProvider: { gate.blockOnce(); return "" })
        )
        await model.loadTemplatesIfNeeded()
        model.selectedTemplateID = formTemplate.id
        model.requestedFilename = "draft"
        let task = Task {
            await model.completeFinderAuthorizationRequest(
                FinderAuthorizationRequest(templateID: finderTemplate.id, destinationFolder: temporaryDirectory),
                authorizedDirectory: temporaryDirectory
            )
        }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        model.selectedTemplateID = finderTemplate.id
        model.selectedTemplateID = formTemplate.id
        model.requestedFilename = "edited"
        model.requestedFilename = "draft"
        gate.release.signal()
        let completed = await task.value
        XCTAssertTrue(completed)
        XCTAssertEqual(model.selectedTemplateID, formTemplate.id)
        XCTAssertEqual(model.requestedFilename, "draft")
        XCTAssertNotNil(model.createdFileURL)
    }

    func testFinderCompletionPreservesCanonicallyEquivalentByteDistinctFilenameEdit() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let store = TemplateStore(defaults: defaults)
        var template = BuiltInTemplates.all[0]
        template.content = "{{clipboard}}"
        try store.saveTemplates([template])
        let model = QuickFileViewModel(
            templateStore: store,
            templates: [template],
            authorizedDirectoryStore: makeAuthorizationStore(defaults: defaults),
            fileCreationService: FileCreationService(clipboardProvider: { gate.blockOnce(); return "" })
        )
        let composed = "caf\u{00e9}"
        let decomposed = "cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertFalse(composed.utf8.elementsEqual(decomposed.utf8))
        model.requestedFilename = composed
        let task = Task {
            await model.completeFinderAuthorizationRequest(
                FinderAuthorizationRequest(templateID: template.id, destinationFolder: temporaryDirectory),
                authorizedDirectory: temporaryDirectory
            )
        }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        model.requestedFilename = decomposed
        gate.release.signal()
        let completed = await task.value
        XCTAssertTrue(completed)
        XCTAssertTrue(gate.wasReleasedBeforeTimeout)
        XCTAssertTrue(model.requestedFilename.utf8.elementsEqual(decomposed.utf8))
        XCTAssertFalse(model.requestedFilename.utf8.elementsEqual(composed.utf8))
        XCTAssertNotNil(model.createdFileURL)
    }

    func testInitializationMigrationAndSaveKeepMainActorResponsiveWhileAnotherProcessHoldsLock() async throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        defaults.set(try JSONEncoder().encode([original]), forKey: "templates.v1")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        let model = QuickFileViewModel(templateStore: store)
        XCTAssertTrue(model.templates.isEmpty)
        XCTAssertFalse(model.canCreate)

        try await withExternalTemplateLock(url) {
            let heartbeatStart = ProcessInfo.processInfo.systemUptime
            let load = Task { await model.loadTemplatesIfNeeded() }
            try await Task.sleep(nanoseconds: 150_000_000)
            let heartbeatDelay = ProcessInfo.processInfo.systemUptime - heartbeatStart
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertLessThan(heartbeatDelay, 0.9, "MainActor must resume before the 1.2-second lock releases")
            print("Template load MainActor heartbeat: \(heartbeatDelay * 1_000) ms")
            XCTAssertTrue(model.isLoadingTemplates)
            XCTAssertTrue(model.templates.isEmpty)
            await load.value
        }
        XCTAssertEqual(model.templates, [original])

        let added = FileTemplate(name: "Added", fileExtension: "md", content: "new")
        try await withExternalTemplateLock(url) {
            let heartbeatStart = ProcessInfo.processInfo.systemUptime
            let save = Task { try await model.saveTemplate(added, replacing: nil) }
            try await Task.sleep(nanoseconds: 150_000_000)
            let heartbeatDelay = ProcessInfo.processInfo.systemUptime - heartbeatStart
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertLessThan(heartbeatDelay, 0.9, "MainActor must resume before the 1.2-second lock releases")
            print("Template save MainActor heartbeat: \(heartbeatDelay * 1_000) ms")
            XCTAssertTrue(model.isSavingTemplates)
            XCTAssertEqual(model.templates, [original])
            await assertThrowsAsync(try await model.saveTemplate(added, replacing: nil)) { error in
                guard case QuickFileViewModel.TemplateSaveError.busy = error else {
                    return XCTFail("Expected duplicate submission to be rejected: \(error)")
                }
            }
            await model.reloadTemplates()
            XCTAssertEqual(model.templates, [original])
            model.selectedTemplateID = added.id
            model.requestedFilename = "next form"
            try await save.value
        }
        XCTAssertFalse(model.isSavingTemplates)
        XCTAssertEqual(model.templates, [original, added])
        XCTAssertEqual(model.selectedTemplateID, added.id)
        XCTAssertEqual(model.requestedFilename, "next form")
        XCTAssertEqual(try store.reloadTemplates(), [original, added])
    }

    func testCreationPreflightIsInvalidatedAsSoonAsSaveStarts() async throws {
        let readGate = CreationGate()
        let writeGate = CreationGate()
        defer { readGate.release.signal(); writeGate.release.signal() }
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        let writer = TemplateStore(defaults: defaults, storageURL: url)
        try writer.saveTemplates([original])
        let store = TemplateStore(
            defaults: defaults, storageURL: url,
            fileManager: PausedTemplateFileManager(gate: writeGate)
        )
        let model = QuickFileViewModel(
            templateStore: store, templates: [original],
            authoritativeTemplateLoader: {
                let snapshot = try writer.reloadTemplates()
                readGate.blockOnce()
                return snapshot
            }
        )
        model.destinationFolder = temporaryDirectory
        let creation = Task { await model.createFile() }
        let readStarted = await BackgroundWork.run { readGate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(readStarted)
        var disabled = original
        disabled.isEnabled = false
        let save = Task { try await model.saveTemplate(disabled, replacing: original) }
        let writeStarted = await BackgroundWork.run { writeGate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(writeStarted)
        readGate.release.signal()
        await creation.value
        XCTAssertNil(model.createdFileURL)
        XCTAssertTrue(model.isSavingTemplates)
        writeGate.release.signal()
        try await save.value
        XCTAssertEqual(model.templates, [disabled])
    }

    func testSaveRepairsSelectionDisabledWhileAnotherWindowChangesIt() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let first = FileTemplate(name: "First", fileExtension: "txt", content: "")
        let second = FileTemplate(name: "Second", fileExtension: "md", content: "")
        let writer = TemplateStore(defaults: defaults, storageURL: url)
        try writer.saveTemplates([first, second])
        let store = TemplateStore(defaults: defaults, storageURL: url, fileManager: PausedTemplateFileManager(gate: gate))
        let model = QuickFileViewModel(templateStore: store, templates: [first, second])
        let save = Task { await model.setTemplateEnabled(false, id: second.id) }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        model.selectedTemplateID = second.id
        model.requestedFilename = "keep draft"
        gate.release.signal()
        await save.value
        XCTAssertEqual(model.selectedTemplateID, first.id)
        XCTAssertEqual(model.selectedTemplate, first)
        XCTAssertEqual(model.requestedFilename, "keep draft")
    }

    func testReloadRepairsSelectionDeletedWhileAnotherWindowChangesIt() async throws {
        let gate = CreationGate()
        defer { gate.release.signal() }
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let first = FileTemplate(name: "First", fileExtension: "txt", content: "")
        let second = FileTemplate(name: "Second", fileExtension: "md", content: "")
        // Migration uses the injected directory gate; an existing v2 file reload
        // intentionally bypasses that operation and would not pause here.
        defaults.set(try JSONEncoder().encode([first]), forKey: "templates.v1")
        let store = TemplateStore(defaults: defaults, storageURL: url, fileManager: PausedTemplateFileManager(gate: gate))
        let model = QuickFileViewModel(templateStore: store, templates: [first, second])
        let reload = Task { await model.reloadTemplates() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        model.selectedTemplateID = second.id
        gate.release.signal()
        await reload.value
        XCTAssertEqual(model.selectedTemplateID, first.id)
        XCTAssertEqual(model.selectedTemplate, first)
    }

    private func withExternalTemplateLock(
        _ url: URL, operation: () async throws -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "open(my $f, '>>', $ARGV[0]) or die $!; flock($f, 2) or die $!; $|=1; print \"locked\\n\"; select(undef, undef, undef, 1.2);", url.appendingPathExtension("lock").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let ready = await BackgroundWork.run { pipe.fileHandleForReading.availableData }
        XCTAssertEqual(String(data: ready, encoding: .utf8), "locked\n")
        let start = Date()
        try await operation()
        await BackgroundWork.run { process.waitUntilExit() }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 1.0)
    }

    private func assertThrowsAsync<Value>(
        _ expression: @autoclosure () async throws -> Value,
        file: StaticString = #filePath, line: UInt = #line,
        _ check: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected an error", file: file, line: line)
        } catch { check(error) }
    }

    private func assertTrueAsync(
        _ expression: @autoclosure () async -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let value = await expression()
        XCTAssertTrue(value, file: file, line: line)
    }

    private func assertFalseAsync(
        _ expression: @autoclosure () async -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let value = await expression()
        XCTAssertFalse(value, file: file, line: line)
    }

    private func makeRequestStore() -> FinderAuthorizationRequestStore {
        FinderAuthorizationRequestStore(
            defaults: defaults,
            directoryURL: temporaryDirectory.appendingPathComponent("requests", isDirectory: true)
        )
    }

    private func makeViewModel(
        authorizationStore: AuthorizedDirectoryStore
    ) -> QuickFileViewModel {
        QuickFileViewModel(
            templateStore: TemplateStore(defaults: defaults),
            templates: [FileTemplate(name: "Text", fileExtension: "txt", content: "")],
            authorizedDirectoryStore: authorizationStore
        )
    }

    private func makeAuthorizationStore(defaults: UserDefaults?) -> AuthorizedDirectoryStore {
        AuthorizedDirectoryStore(
            defaults: defaults,
            storageDirectory: defaults == nil ? nil : temporaryDirectory,
            persistentBookmarkCreator: { Self.bookmarkData(for: $0) },
            transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { try Self.resolveBookmark($0) },
            transferBookmarkResolver: { try Self.resolveBookmark($0) },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
    }

    nonisolated private static func bookmarkData(for url: URL) -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    nonisolated private static func resolveBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
        let path = try XCTUnwrap(String(data: data, encoding: .utf8))
        return ResolvedSecurityScopedBookmark(
            url: URL(fileURLWithPath: path, isDirectory: true),
            isStale: false
        )
    }
}

/// Writes occur on BackgroundWork; the counter's mutable state is lock-protected.
private final class TemplateWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCount
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        recordedCount += 1
    }
}

private final class CreationGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didBlock = false
    private var releaseSucceeded = false

    var wasReleasedBeforeTimeout: Bool {
        lock.lock()
        defer { lock.unlock() }
        return releaseSucceeded
    }

    func blockOnce() {
        lock.lock()
        let shouldBlock = !didBlock
        didBlock = true
        lock.unlock()
        if shouldBlock {
            started.signal()
            let succeeded = release.wait(timeout: .now() + 10) == .success
            lock.lock()
            releaseSucceeded = succeeded
            lock.unlock()
        }
    }
}

private final class PausedRequestFileManager: FileManager, @unchecked Sendable {
    private let gate: CreationGate

    init(gate: CreationGate) {
        self.gate = gate
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        let snapshot = try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        gate.blockOnce()
        return snapshot
    }
}

private final class TemplateReadTrackingDefaults: UserDefaults, @unchecked Sendable {
    private(set) var templateReadCount = 0

    override func string(forKey defaultName: String) -> String? {
        if defaultName == "templates.revision.v2" { templateReadCount += 1 }
        return super.string(forKey: defaultName)
    }

    override func data(forKey defaultName: String) -> Data? {
        if defaultName == "templates.v1" { templateReadCount += 1 }
        return super.data(forKey: defaultName)
    }
}

private final class PausedTemplateFileManager: FileManager, @unchecked Sendable {
    private let gate: CreationGate

    init(gate: CreationGate) {
        self.gate = gate
        super.init()
    }

    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        gate.blockOnce()
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
