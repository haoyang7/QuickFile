import XCTest
import Sparkle
@testable import QuickFile

final class UpdateConfigurationTests: XCTestCase {
    private var validInfo: [String: Any] {
        [
            "QuickFileUpdatesEnabled": "YES",
            "SUFeedURL": "https://updates.example.org/appcast.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()
        ]
    }

    func testUpdatesRequireExplicitOptInFromBuildConfiguration() {
        XCTAssertNotNil(UpdateConfiguration(info: validInfo))
        var info = validInfo
        info["QuickFileUpdatesEnabled"] = false
        XCTAssertNil(UpdateConfiguration(info: info))
        info.removeValue(forKey: "QuickFileUpdatesEnabled")
        XCTAssertNil(UpdateConfiguration(info: info))
    }

    func testRejectsInsecureOrMalformedFeedAndInvalidPublicKey() {
        for feed in ["", "http://updates.example.org/appcast.xml", "https:///appcast.xml", "https://user:password@updates.example.org/appcast.xml", "https://updates.example.org/appcast.xml#fragment"] {
            var info = validInfo
            info["SUFeedURL"] = feed
            XCTAssertNil(UpdateConfiguration(info: info), feed)
        }
        for key in ["", "not-base64", Data(repeating: 1, count: 31).base64EncodedString()] {
            var info = validInfo
            info["SUPublicEDKey"] = key
            XCTAssertNil(UpdateConfiguration(info: info))
        }
    }
}

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testBackgroundChecksUseCurrentPreferenceAndManualChecksRemainAvailable() throws {
        let suite = "QuickFileUpdateTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: app)
        }
        let info: [String: Any] = [
            "CFBundleIdentifier": suite, "CFBundleVersion": "8", "CFBundleName": "Update Tests",
            "SUDefaultsDomain": suite, "SUEnableAutomaticChecks": false
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: app))
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                                 userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: nil)
        let controller = UpdateController(defaults: defaults, isTesting: true)

        XCTAssertThrowsError(try controller.updater(updater, mayPerform: .updatesInBackground))
        XCTAssertNoThrow(try controller.updater(updater, mayPerform: .updates))
        controller.setReceivesBetaUpdates(true)
        updater.automaticallyChecksForUpdates = true
        XCTAssertNoThrow(try controller.updater(updater, mayPerform: .updatesInBackground))
        updater.automaticallyChecksForUpdates = false
        XCTAssertThrowsError(try controller.updater(updater, mayPerform: .updatesInBackground))
        XCTAssertNoThrow(try controller.updater(updater, mayPerform: .updates))
    }

    func testTestBuildNeverStartsUpdaterAndBetaChoiceIsRetained() {
        let suite = "QuickFileUpdateTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = UpdateController(defaults: defaults, isTesting: true)
        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.receivesBetaUpdates)
        controller.checkForUpdates()
        controller.setAutomaticallyChecksForUpdates(true)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
        controller.setReceivesBetaUpdates(true)
        let replacement = UpdateController(defaults: defaults, isTesting: true)
        XCTAssertTrue(replacement.receivesBetaUpdates)
        XCTAssertFalse(replacement.isAvailable)
    }
}
