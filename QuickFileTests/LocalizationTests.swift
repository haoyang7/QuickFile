import XCTest
@testable import QuickFile
import QuickFileCore
@testable import QuickFileInfrastructure

final class LocalizationTests: XCTestCase {
    func testBothBundlesShipEnglishAndChineseAndPreserveInterpolation() throws {
        let app = Bundle.main
        let extensionURL = try XCTUnwrap(app.builtInPlugInsURL).appendingPathComponent("FinderExtension.appex")
        let finder = try XCTUnwrap(Bundle(url: extensionURL))
        for bundle in [app, finder] {
            let english = try XCTUnwrap(Bundle(path: try XCTUnwrap(bundle.path(forResource: "en", ofType: "lproj"))))
            let chinese = try XCTUnwrap(Bundle(path: try XCTUnwrap(bundle.path(forResource: "zh-Hans", ofType: "lproj"))))
            XCTAssertEqual(String(localized: "新建文件", bundle: english), "New File")
            XCTAssertEqual(String(localized: "新建文件", bundle: chinese), "新建文件")
            let error = "TEST-DETAIL"
            XCTAssertEqual(String(localized: "文件已创建，但无法自动打开：\(error)", bundle: english),
                           "The file was created, but could not be opened automatically: TEST-DETAIL")
            XCTAssertEqual(String(localized: "创建后自动打开", bundle: english), "Open files after creation")
        }
    }
}

@MainActor
final class LocalizationSwitchingTests: XCTestCase {
    override func tearDown() { QuickFileLocalization.apply(.system); super.tearDown() }

    func testStoredBuiltInNamesFollowLanguageWithoutChangingEncodedDataOrCustomNames() throws {
        QuickFileLocalization.apply(.simplifiedChinese)
        let templates = BuiltInTemplates.all
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(templates)
        let entries = FinderMenuModelBuilder().entries(from: templates)
        var renamed = templates[0]
        renamed.name = "我的报告"
        let custom = FileTemplate(name: "Word 文档", fileExtension: "docx", content: "")
        QuickFileLocalization.apply(.english)
        XCTAssertEqual(Array(templates.prefix(4)).map(\.displayName),
                       ["Word Document", "Excel Workbook", "PowerPoint Presentation", "Text Document"])
        XCTAssertEqual(entries[0].title, "Word Document (.docx)")
        XCTAssertEqual(renamed.displayName, "我的报告")
        XCTAssertEqual(custom.displayName, "Word 文档")
        XCTAssertEqual(try encoder.encode(templates), encoded)
        let english = BuiltInTemplates.all
        QuickFileLocalization.apply(.simplifiedChinese)
        XCTAssertEqual(english[0].displayName, "Word 文档")
        XCTAssertEqual(entries[0].title, "Word 文档 (.docx)")
    }

    func testFirstSaveAfterLanguageSwitchWorksAcrossStoresForAddEditAndToggle() throws {
        let directory = try templateTestDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        for (languageIndex, languages) in [
            (QuickFileLanguage.simplifiedChinese, QuickFileLanguage.english),
            (QuickFileLanguage.english, QuickFileLanguage.simplifiedChinese)
        ].enumerated() {
            for operation in 0..<3 {
                let root = directory.appendingPathComponent("\(languageIndex)-\(operation)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
                let local = LocalSharedStorage(root: root.resolvingSymlinksInPath())
                let url = local.root.appendingPathComponent("templates.v2.json")
                let reader = TemplateStore(defaults: nil, storageURL: url, localStorage: local)
                QuickFileLocalization.apply(languages.0)
                let baseline = try reader.reloadTemplates()
                QuickFileLocalization.apply(languages.1)
                let writer = TemplateStore(defaults: nil, storageURL: url, localStorage: local)
                XCTAssertNotEqual(try writer.reloadTemplates()[0].name, baseline[0].name)
                var edited = baseline
                switch operation {
                case 0: edited.append(FileTemplate(name: "My template", fileExtension: "txt", content: "keep"))
                case 1:
                    edited[0].name = "我的报告"
                    edited[0].defaultFilename = "Report"
                default: edited[0].isEnabled = false
                }
                try writer.saveTemplates(edited, expectedTemplates: baseline)
                let saved = try reader.reloadTemplates()
                XCTAssertEqual(saved.map(TransferTemplate.init), edited.map(TransferTemplate.init))
                XCTAssertEqual(saved[0].officeFormat, .docx)
                let document = try XCTUnwrap(JSONSerialization.jsonObject(with: local.read(url)) as? [String: Any])
                XCTAssertEqual(document["version"] as? Int, 4)
            }
        }
    }

    func testFirstUseCASRejectsModifiedOrMixedLanguageDefaultBaselines() throws {
        let directory = try templateTestDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let local = LocalSharedStorage(root: directory)
        let url = local.root.appendingPathComponent("templates.v2.json")
        let store = TemplateStore(defaults: nil, storageURL: url, localStorage: local)
        QuickFileLocalization.apply(.simplifiedChinese)
        let baseline = try store.reloadTemplates()
        QuickFileLocalization.apply(.english)
        var renamed = baseline
        renamed[0].name = "Custom"
        var mixed = baseline
        mixed[0].name = BuiltInTemplates.all[0].name
        var disabled = baseline
        disabled[0].isEnabled = false
        var plainOffice = baseline
        plainOffice[0].officeFormat = nil
        var changedBody = baseline
        changedBody[3].content = "unpersisted edit"
        var defaultFilename = baseline
        defaultFilename[0].defaultFilename = "Report"
        for invalid in [renamed, mixed, disabled, plainOffice, changedBody, defaultFilename,
                        Array(baseline.reversed()), Array(baseline.dropLast())] {
            XCTAssertThrowsError(try store.saveTemplates([], expectedTemplates: invalid)) {
                guard case TemplateStore.StoreError.configurationChanged = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.root.appendingPathComponent("templates.persistence.v1.json").path))
    }

    func testLanguageCompatibleFirstUseBaselineCannotOverrideAnExternalSaveOrPersistenceMarker() throws {
        let directory = try templateTestDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        for markerOnly in [false, true] {
            let root = directory.appendingPathComponent(markerOnly ? "marker" : "saved", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let local = LocalSharedStorage(root: root.resolvingSymlinksInPath())
            let url = local.root.appendingPathComponent("templates.v2.json")
            let store = TemplateStore(defaults: nil, storageURL: url, localStorage: local)
            QuickFileLocalization.apply(.simplifiedChinese)
            let baseline = try store.reloadTemplates()
            QuickFileLocalization.apply(.english)
            if markerOnly {
                try local.write(Data("{\"version\":1}".utf8),
                                to: local.root.appendingPathComponent("templates.persistence.v1.json"))
            } else {
                let other = TemplateStore(defaults: nil, storageURL: url, localStorage: local)
                let english = try other.reloadTemplates()
                try other.saveTemplates(english, expectedTemplates: english)
            }
            XCTAssertThrowsError(try store.saveTemplates(baseline, expectedTemplates: baseline)) { error in
                if markerOnly {
                    guard case TemplateStore.StoreError.savedConfigurationMissing = error else { return XCTFail("\(error)") }
                } else {
                    guard case TemplateStore.StoreError.configurationChanged = error else { return XCTFail("\(error)") }
                }
            }
            if !markerOnly { XCTAssertEqual(try store.reloadTemplates(), BuiltInTemplates.all) }
        }
    }

    private func templateTestDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/Temporary/LocalizationTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return directory.resolvingSymlinksInPath()
    }

    func testSavedMenuFeedbackAndErrorsRefreshWithoutRepeatingPersistence() async {
        QuickFileLocalization.apply(.simplifiedChinese)
        let saves = LockedTestValue(0)
        let model = FinderMenuSettingsViewModel(load: { .all }, save: { _ in saves.update { $0 += 1 } })
        await model.reload()
        model.showsAll = false
        model.maximumCountText = "3"
        let saved = await model.save()
        XCTAssertTrue(saved)
        QuickFileLocalization.apply(.english)
        XCTAssertEqual(model.status, .success("Finder menu settings saved."))
        XCTAssertEqual(model.maximumCountText, "3")
        XCTAssertEqual(saves.value, 1)
        let error = LanguageSettingsViewModel(load: { throw LanguageSettingsStore.StoreError.malformed }, save: { _ in })
        await error.reload()
        let englishError = error.errorMessage
        QuickFileLocalization.apply(.simplifiedChinese)
        XCTAssertNotEqual(error.errorMessage, englishError)
        XCTAssertEqual(model.status, .success("Finder 菜单设置已保存。"))
        XCTAssertEqual(saves.value, 1)
    }

    func testFinderAuthorizationFailureRefreshesWithoutRepeatingAuthorization() async throws {
        QuickFileLocalization.apply(.simplifiedChinese)
        let suite = "QuickFileTests.AuthorizationLocalization.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/Temporary/\(suite)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let attempts = LockedTestValue(0)
        let store = AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: directory.appendingPathComponent("grants"),
            persistentBookmarkCreator: { _ in
                attempts.update { $0 += 1 }
                throw CocoaError(.fileWriteNoPermission)
            },
            transferBookmarkCreator: { _ in XCTFail("Failed grant must not create a transfer bookmark"); return Data() },
            persistentBookmarkResolver: { _ in throw CocoaError(.fileReadCorruptFile) },
            transferBookmarkResolver: { _ in throw CocoaError(.fileReadCorruptFile) }
        )
        let model = QuickFileViewModel(templateStore: TemplateStore(defaults: defaults), templates: [],
                                       authorizedDirectoryStore: store)
        let integration = FinderIntegrationViewModel(statusProvider: { true },
            runtimeProvider: { _ in fatalError("Language switching must not probe Finder") }, managementOpener: {})
        await model.saveFinderAuthorization(for: directory)
        let chinese = model.finderAuthorizationState
        let failure = AuthorizedDirectoryStoreError.bookmarkCreationFailed(CocoaError(.fileWriteNoPermission))
        for language in [QuickFileLanguage.english, .simplifiedChinese, .english] {
            QuickFileLocalization.apply(language)
            XCTAssertEqual(model.finderAuthorizationState, .failed(failure.localizedDescription))
            let presentation = integration.setupPresentation(hasDestination: true,
                authorization: model.finderAuthorizationState, hasTemplates: true)
            XCTAssertEqual(presentation.detail, failure.localizedDescription)
            XCTAssertEqual(presentation.action, .saveAuthorization)
            XCTAssertEqual(model.destinationFolder, directory)
            XCTAssertEqual(attempts.value, 1)
            if language == .english { XCTAssertNotEqual(model.finderAuthorizationState, chinese) }
            else { XCTAssertEqual(model.finderAuthorizationState, chinese) }
        }
        XCTAssertTrue(try store.loadAuthorizedDirectories().isEmpty)
        model.destinationFolder = nil
        XCTAssertEqual(model.finderAuthorizationState, .notConfirmed)
    }

    func testAuthorizationInventoryFailureRefreshesWithoutReloadAndCanRetry() async {
        QuickFileLocalization.apply(.simplifiedChinese)
        let attempts = LockedTestValue(0)
        let model = FinderIntegrationViewModel(statusProvider: { true },
            runtimeProvider: { _ in fatalError("Language switching must not probe Finder") }, managementOpener: {},
            authorizationInventoryLoader: {
                let attempt = attempts.update { $0 += 1; return $0 }
                if attempt == 1 { throw AuthorizedDirectoryStoreError.sharedDefaultsUnavailable }
                return AuthorizedDirectoryInventory(availableDirectories: [], unavailableDirectories: [])
            }, inventoryReadGate: DiagnosticsInventoryReadGate())
        await model.refreshAuthorizedDirectories()
        let chinese = model.authorizationInventoryState
        for language in [QuickFileLanguage.english, .simplifiedChinese, .english] {
            QuickFileLocalization.apply(language)
            XCTAssertEqual(model.authorizationInventoryState,
                           .failed(AuthorizedDirectoryStoreError.sharedDefaultsUnavailable.localizedDescription))
            XCTAssertEqual(attempts.value, 1)
            if language == .english { XCTAssertNotEqual(model.authorizationInventoryState, chinese) }
            else { XCTAssertEqual(model.authorizationInventoryState, chinese) }
        }
        await model.refreshAuthorizedDirectories()
        XCTAssertEqual(model.authorizationInventoryState, .loaded)
        XCTAssertEqual(attempts.value, 2)
        QuickFileLocalization.apply(.simplifiedChinese)
        XCTAssertEqual(model.authorizationInventoryState, .loaded)
    }

    func testSelectedLanguageControlsPluralRulesEvenWhenSystemLanguageDiffers() {
        QuickFileLocalization.apply(.simplifiedChinese)
        // Retain the resource before switching; resolving it must use the new
        // language while keeping the operation's original count.
        let resources: [LocalizedStringResource] = [1, 2].map { count in
            .init("template.import.appended", defaultValue: "已追加导入 \(count) 个模板。")
        }
        QuickFileLocalization.apply(.english)
        XCTAssertEqual(resources.map(QuickFileLocalization.text), ["Appended 1 template.", "Appended 2 templates."])
        QuickFileLocalization.apply(.simplifiedChinese)
        XCTAssertEqual(resources.map(QuickFileLocalization.text), ["已追加导入 1 个模板。", "已追加导入 2 个模板。"])
    }

    func testResourceCapturesLiteralArgumentsWithoutReinterpretingUserText() {
        var name = "用户 %@ {{clipboard}}"
        let resource = LocalizedStringResource("删除“\(name)”？")
        name = "a newer draft"
        QuickFileLocalization.apply(.english)
        XCTAssertEqual(QuickFileLocalization.text(resource), "Delete “用户 %@ {{clipboard}}”?")
        QuickFileLocalization.apply(.simplifiedChinese)
        XCTAssertEqual(QuickFileLocalization.text(resource), "删除“用户 %@ {{clipboard}}”？")
    }

    func testSavedMenuValidationRefreshesAndNeverPersistsAnInvalidDraft() async {
        QuickFileLocalization.apply(.simplifiedChinese)
        let saves = LockedTestValue(0)
        let model = FinderMenuSettingsViewModel(load: { .all }, save: { _ in saves.update { $0 += 1 } })
        await model.reload()
        model.showsAll = false
        model.maximumCountText = "0"
        let saved = await model.save()
        XCTAssertFalse(saved)
        let chinese = model.status
        QuickFileLocalization.apply(.english)
        XCTAssertNotEqual(model.status, chinese)
        QuickFileLocalization.apply(.simplifiedChinese)
        XCTAssertEqual(model.status, chinese)
        XCTAssertEqual(model.maximumCountText, "0")
        XCTAssertEqual(saves.value, 0)
    }

    func testDiagnosticEvidenceKeepsFactsAndRendersInCurrentLanguage() {
        QuickFileLocalization.apply(.simplifiedChinese)
        let evidence = FinderExtensionInstallationInspector.interpretRegistrationEvidence(
            exitCode: 1, output: "Permission denied: /private/fixture", identifier: "fixture")
        let original = evidence.1.message
        QuickFileLocalization.apply(.english)
        XCTAssertNotEqual(evidence.1.message, original)
        XCTAssertFalse(evidence.1.message.contains("/private/fixture"))
        XCTAssertEqual(evidence.0, .unknown)
    }

    func testDisabledExtensionGuidanceFollowsLanguageWithoutChangingEvidence() throws {
        let snapshot = FinderExtensionDiagnosticSnapshot(
            embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
            registration: .unknown, evidence: .queryFailed(1, .unknownFailure),
            enabled: false, responded: nil
        )
        QuickFileLocalization.apply(.simplifiedChinese)
        let chinese = try XCTUnwrap(snapshot.state.recoveryGuidance)
        XCTAssertTrue(chinese.contains("开启 QuickFile 开关"))
        QuickFileLocalization.apply(.english)
        let english = try XCTUnwrap(snapshot.state.recoveryGuidance)
        XCTAssertTrue(english.contains("turn on QuickFile"))
        XCTAssertNotEqual(english, chinese)
        XCTAssertEqual(snapshot.state, .disabled)
        XCTAssertEqual(snapshot.registration, .unknown)
        XCTAssertNil(snapshot.responded)
    }

    func testLanguageChoicesAreExactlyShippedResourcesAndKeepVersionOneEncoding() throws {
        let identifiers = Set(Bundle.main.localizations.filter { $0 != "Base" })
        XCTAssertEqual(Set(QuickFileLanguage.allCases.filter { $0 != .system }.map(\.rawValue)), identifiers)
        XCTAssertEqual(String(data: try JSONEncoder().encode(QuickFileLanguage.english), encoding: .utf8), "\"en\"")
        for language in QuickFileLanguage.allCases where language != .system {
            XCTAssertFalse(language.nativeName.isEmpty)
        }
        XCTAssertNil(QuickFileLanguage(rawValue: "not-shipped"))
    }
}
