import XCTest
@testable import QuickFileInfrastructure

final class QuickFileConfigurationTests: XCTestCase {
    func testUsesConfiguredProductionIdentifiers() {
        XCTAssertEqual(QuickFileConfiguration.appBundleIdentifier, "com.haoyoung.QuickFile")
        XCTAssertEqual(
            QuickFileConfiguration.finderExtensionBundleIdentifier,
            "com.haoyoung.QuickFile.FinderExtension"
        )
        XCTAssertEqual(QuickFileConfiguration.appGroupIdentifier, "group.com.haoyoung.QuickFile")
    }

    func testConfiguredIdentifiersAreNotPlaceholders() {
        XCTAssertFalse(QuickFileConfiguration.usesPlaceholderIdentifiers)
    }

    func testFolderServiceAdvertisesOnlyFoldersWithoutAReservedShortcut() throws {
        let services = try XCTUnwrap(Bundle.main.infoDictionary?["NSServices"] as? [[String: Any]])
        let service = try XCTUnwrap(services.first)
        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(service["NSSendFileTypes"] as? [String], ["public.folder"])
        XCTAssertNil(service["NSSendTypes"], "A broad pasteboard type would also advertise the folder service for ordinary files")
        XCTAssertNil(service["NSKeyEquivalent"], "Users choose their own service shortcut in macOS settings")
        XCTAssertEqual(service["NSMessage"] as? String, "newFileWithQuickFile")
        XCTAssertEqual(service["NSPortName"] as? String, "QuickFile")
        XCTAssertEqual((service["NSRequiredContext"] as? [String: Any])?.count, 0)
    }

    func testFolderServiceMenuHasBothShippedTranslations() throws {
        for (language, title) in [
            ("en", "New File with QuickFile…"),
            ("zh-Hans", "使用 QuickFile 新建文件…")
        ] {
            let folder = try XCTUnwrap(Bundle.main.url(forResource: language, withExtension: "lproj"))
            let bundle = try XCTUnwrap(Bundle(url: folder))
            XCTAssertEqual(bundle.localizedString(forKey: "New File with QuickFile…", value: nil,
                                                table: "ServicesMenu"), title)
        }
    }
}
