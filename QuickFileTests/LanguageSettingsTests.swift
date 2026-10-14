import XCTest
@testable import QuickFile
import QuickFileCore
@testable import QuickFileInfrastructure

final class LanguageSettingsStoreTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/Temporary/language-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return root.resolvingSymlinksInPath()
    }

    func testDefaultAndEveryChoicePersistWithoutRewritingOtherSettings() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalSharedStorage(root: root)
        let writer = LanguageSettingsStore(storage: storage)
        let reader = LanguageSettingsStore(storage: storage)
        XCTAssertEqual(try reader.load(), .system)
        let creation = FileCreationSettingsStore(storage: storage)
        try creation.saveAutomaticallyOpen(true)
        let original = try Data(contentsOf: root.appendingPathComponent("file-creation-settings.v1.json"))
        for language in QuickFileLanguage.allCases {
            try writer.save(language)
            XCTAssertEqual(try reader.load(), language)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file-creation-settings.v1.json")), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("language-settings.v1.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testInvalidAndLinkedPreferencesAreNotSilentlyRewritten() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalSharedStorage(root: root)
        let store = LanguageSettingsStore(storage: storage)
        let url = root.appendingPathComponent("language-settings.v1.json")
        for text in ["{}", #"{"version":1,"language":"qf-unsupported"}"#, #"{"version":2,"language":"en"}"#] {
            let data = Data(text.utf8)
            try storage.write(data, to: url)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        let outside = root.appendingPathComponent("untouched.json")
        let sentinel = Data(#"{"version":1,"language":"en"}"#.utf8)
        try sentinel.write(to: outside)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(.simplifiedChinese))
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
    }

    func testSystemLanguageResolutionAndExplicitOverride() {
        XCTAssertEqual(QuickFileLanguage.system.resolvedIdentifier(preferredLanguages: ["en-GB", "zh-Hans"]), "en")
        XCTAssertEqual(QuickFileLanguage.system.resolvedIdentifier(preferredLanguages: ["zh-Hans-CN", "en"]), "zh-Hans")
        XCTAssertEqual(QuickFileLanguage.english.resolvedIdentifier(preferredLanguages: ["zh-Hans"]), "en")
        XCTAssertEqual(QuickFileLanguage.simplifiedChinese.resolvedIdentifier(preferredLanguages: ["en"]), "zh-Hans")
    }
}

@MainActor
final class LanguageSettingsViewModelTests: XCTestCase {
    override func tearDown() { QuickFileLocalization.apply(.system); super.tearDown() }

    func testSavedChoiceLoadsAndFailedSaveKeepsVisibleAndRuntimeLanguage() async {
        let saved = LockedTestValue(QuickFileLanguage.english)
        let fail = LockedTestValue(true)
        let model = LanguageSettingsViewModel(load: { saved.value }, save: { value in
            if fail.value { throw CocoaError(.fileWriteNoPermission) }
            saved.update { $0 = value }
        })
        await model.reload()
        XCTAssertEqual(model.language, .english)
        XCTAssertEqual(model.locale.identifier, "en")
        XCTAssertEqual(String(localized: "新建文件", bundle: QuickFileLocalization.bundle), "New File")
        await model.select(.simplifiedChinese)
        XCTAssertEqual(model.language, .english)
        XCTAssertEqual(QuickFileLocalization.identifier, "en")
        XCTAssertNotNil(model.errorMessage)
        fail.update { $0 = false }
        await model.select(.simplifiedChinese)
        XCTAssertEqual(model.language, .simplifiedChinese)
        XCTAssertEqual(QuickFileLocalization.identifier, "zh-Hans")
        XCTAssertNil(model.errorMessage)
        let reopened = LanguageSettingsViewModel(load: { saved.value }, save: { _ in })
        await reopened.reload()
        XCTAssertEqual(reopened.language, .simplifiedChinese)
    }

    func testBrokenSettingsAllowExplicitRepairWithoutBlockingAppStartup() async {
        let saved = LockedTestValue<QuickFileLanguage?>(nil)
        let model = LanguageSettingsViewModel(load: { throw LanguageSettingsStore.StoreError.malformed },
                                              save: { value in saved.update { $0 = value } })
        await model.reload()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.language, .system)
        XCTAssertNotNil(model.errorMessage)
        await model.select(.english)
        XCTAssertEqual(saved.value, .english)
        XCTAssertNil(model.errorMessage)
    }
}
