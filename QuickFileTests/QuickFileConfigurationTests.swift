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
}
