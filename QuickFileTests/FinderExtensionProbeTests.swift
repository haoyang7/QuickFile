import XCTest
@testable import QuickFileInfrastructure

@MainActor
final class FinderExtensionProbeTests: XCTestCase {
    func testProbeReceivesMatchingInstallationResponse() async {
        let responder = FinderExtensionProbeResponder()
        let received = await FinderExtensionProbe.check(extensionURL: Bundle.main.bundleURL)
        XCTAssertTrue(received)
        withExtendedLifetime(responder) {}
    }

    func testSuccessfulProbeReleasesBeforeItsTimeout() async {
        let responder = FinderExtensionProbeResponder()
        let identity = FinderProbeNotification.identity(
            for: Bundle.main.bundleURL,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        )
        var probe: FinderExtensionProbe? = FinderExtensionProbe(identity: identity)
        weak let releasedProbe = probe
        let received = await probe!.run(timeout: 5)
        XCTAssertTrue(received)
        probe = nil
        await Task.yield()
        XCTAssertNil(releasedProbe, "A successful probe must not remain alive until the five-second deadline")
        withExtendedLifetime(responder) {}
    }

    func testTimedOutProbeReleasesAfterFinishing() async {
        var probe: FinderExtensionProbe? = FinderExtensionProbe(identity: "unmatched-installation")
        weak let releasedProbe = probe
        let received = await probe!.run(timeout: 0.01)
        XCTAssertFalse(received)
        probe = nil
        await Task.yield()
        XCTAssertNil(releasedProbe)
    }

    func testOtherInstallationCannotSatisfyProbeAndRequestTimesOut() async {
        let responder = FinderExtensionProbeResponder()
        let otherInstallation = Bundle.main.bundleURL.appendingPathComponent("AnotherCopy.appex")
        let received = await FinderExtensionProbe.check(extensionURL: otherInstallation, timeout: 0.1)
        XCTAssertFalse(received)
        withExtendedLifetime(responder) {}
    }

    func testOldBuildAtSameInstallationCannotSatisfyProbeAfterReplacement() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".appex")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let plistURL = contents.appendingPathComponent("Info.plist")
        func install(build: String) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": build],
                format: .xml, options: 0
            )
            try data.write(to: plistURL, options: .atomic)
        }
        try install(build: "7")
        let oldResponder = FinderExtensionProbeResponder(extensionURL: url, version: "0.1.0", build: "7")
        let initialResponse = await FinderExtensionProbe.check(extensionURL: url, timeout: 0.1)
        XCTAssertTrue(initialResponse)
        try install(build: "8")
        let oldResponse = await FinderExtensionProbe.check(extensionURL: url, timeout: 0.1)
        XCTAssertFalse(oldResponse)
        let newResponder = FinderExtensionProbeResponder(extensionURL: url, version: "0.1.0", build: "8")
        let newResponse = await FinderExtensionProbe.check(extensionURL: url, timeout: 0.1)
        XCTAssertTrue(newResponse)
        withExtendedLifetime((oldResponder, newResponder)) {}
    }
}
