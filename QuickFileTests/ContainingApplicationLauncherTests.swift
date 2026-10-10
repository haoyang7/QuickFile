import AppKit
import XCTest
@testable import QuickFileCore

@MainActor
final class ContainingApplicationLauncherTests: XCTestCase {
    func testLaunchConfigurationRejectsAnotherRunningInstallation() {
        let configuration = ContainingApplicationLauncher.openConfiguration()
        XCTAssertTrue(configuration.activates)
        XCTAssertFalse(configuration.allowsRunningApplicationSubstitution)
    }

    func testUsesExactContainingApplicationIncludingSpaces() {
        let extensionURL = URL(fileURLWithPath: "/Applications/Quick File.app/Contents/PlugIns/FinderExtension.appex")
        XCTAssertEqual(ContainingApplicationLauncher.applicationURL(for: extensionURL),
                       URL(fileURLWithPath: "/Applications/Quick File.app", isDirectory: true))
    }

    func testRejectsUnexpectedLayoutInsteadOfFindingAnotherRegisteredApplication() {
        for path in [
            "/tmp/FinderExtension.appex", "/Applications/QuickFile.app/PlugIns/FinderExtension.appex",
            "/Applications/QuickFile.app/Contents/Frameworks/FinderExtension.appex",
            "/Applications/QuickFile/Contents/PlugIns/FinderExtension.appex",
            "/Applications/QuickFile.app/Contents/PlugIns/FinderExtension.bundle"
        ] {
            XCTAssertNil(ContainingApplicationLauncher.applicationURL(for: URL(fileURLWithPath: path)), path)
        }
        XCTAssertNil(ContainingApplicationLauncher.applicationURL(
            for: URL(string: "https://example.invalid/QuickFile.app/Contents/PlugIns/FinderExtension.appex")!
        ))
    }

    func testUnavailableContainingBundleReportsFailureWithoutLaunchingDefaultHandler() {
        var receivedError: Error?
        ContainingApplicationLauncher.open(.templates,
            extensionURL: URL(fileURLWithPath: "/tmp/Not an embedded extension.appex")) { error in
                receivedError = error
            }
        XCTAssertNotNil(receivedError)
    }
}
