import XCTest
import Combine
import AppKit
import SwiftUI
import QuickFileCore
#if !QUICKFILE_COMMUNITY
import Sparkle
#endif
@testable import QuickFile

final class UpdateConfigurationTests: XCTestCase {
    private var validInfo: [String: Any] {
        [
            "QuickFileDistributionChannel": "developer-id",
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

    func testOnlyDeveloperIDChannelCanEnableUpdates() {
        for channel in ["community", "development", "", "other"] {
            var info = validInfo
            info["QuickFileDistributionChannel"] = channel
            XCTAssertNil(UpdateConfiguration(info: info))
        }
        var info = validInfo
        info.removeValue(forKey: "QuickFileDistributionChannel")
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
    #if !QUICKFILE_COMMUNITY
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
    #endif

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

    func testCommunityChecksAreManualAndRepeatedClicksHaveOneOwner() async throws {
        let fixture = try CommunityControllerFixture()
        defer { fixture.remove() }
        let calls = CommunityCheckCalls()
        let presented = expectation(description: "manual result presented")
        let controller = UpdateController(bundle: fixture.bundle, defaults: fixture.defaults, isTesting: false,
            checkCommunityRelease: { version, build, releaseTag, betas in
                await calls.append(version: version, build: build, releaseTag: releaseTag, betas: betas)
                return .upToDate
            }, presentCommunityResult: { status in
                XCTAssertEqual(status, .checked(.upToDate))
                presented.fulfill()
            })
        XCTAssertTrue(controller.usesGitHubReleases)
        XCTAssertTrue(controller.isAvailable)
        XCTAssertTrue(controller.canCheckForUpdates)
        XCTAssertFalse(controller.receivesBetaUpdates)
        controller.setAutomaticallyChecksForUpdates(true)
        controller.setReceivesBetaUpdates(true)
        await Task.yield()
        let before = await calls.values
        XCTAssertEqual(before.count, 0, "Startup and preference changes must not check GitHub")
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
        for _ in 0..<100 { controller.checkForUpdates() }
        XCTAssertTrue(controller.isCheckingForUpdates)
        XCTAssertFalse(controller.canCheckForUpdates)
        await fulfillment(of: [presented], timeout: 2)
        let after = await calls.values
        XCTAssertEqual(after, [.init(version: "0.1.0", build: "100", releaseTag: nil, betas: true)])
        XCTAssertFalse(controller.isCheckingForUpdates)
        XCTAssertTrue(controller.canCheckForUpdates)
        let reloaded = UpdateController(bundle: fixture.bundle, defaults: fixture.defaults, isTesting: true)
        XCTAssertTrue(reloaded.receivesBetaUpdates)
        XCTAssertFalse(reloaded.isAvailable)
    }

    func testInstalledReleaseTagIsPassedUnchangedWhenBetaPreferenceChanges() async throws {
        for releaseTag in ["v0.1.0-beta.7", "v0.1.0", nil, "", " v0.1.0-beta.7 "] as [String?] {
            let fixture = try CommunityControllerFixture(releaseTag: releaseTag)
            defer { fixture.remove() }
            let calls = CommunityCheckCalls()
            let controller = UpdateController(bundle: fixture.bundle, defaults: fixture.defaults, isTesting: false,
                checkCommunityRelease: { version, build, releaseTag, betas in
                    await calls.append(version: version, build: build, releaseTag: releaseTag, betas: betas)
                    return .upToDate
                })
            for betas in [false, true] {
                controller.setReceivesBetaUpdates(betas)
                let completed = expectation(description: "installed tag check completed")
                let subscription = controller.$isCheckingForUpdates.dropFirst().filter { !$0 }
                    .sink { _ in completed.fulfill() }
                controller.checkForUpdates()
                await fulfillment(of: [completed], timeout: 2)
                subscription.cancel()
                XCTAssertEqual(controller.communityCheckStatus, .checked(.upToDate))
            }
            let recorded = await calls.values
            XCTAssertEqual(recorded, [false, true].map {
                .init(version: "0.1.0", build: "100", releaseTag: releaseTag, betas: $0)
            })
        }
    }

    func testChangingChannelCancelsButHoldsSlotAndDiscardsLateResult() async throws {
        let fixture = try CommunityControllerFixture()
        defer { fixture.remove() }
        let barrier = CommunityCheckBarrier(entered: expectation(description: "check entered"))
        defer { Task { await barrier.release() } }
        var presentations = 0
        let controller = UpdateController(bundle: fixture.bundle, defaults: fixture.defaults, isTesting: false,
            checkCommunityRelease: { _, _, _, _ in await barrier.check() },
            presentCommunityResult: { _ in presentations += 1 })
        let finished = expectation(description: "cancelled transport returned")
        let subscription = controller.$isCheckingForUpdates.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        controller.checkForUpdates()
        await fulfillment(of: [barrier.entered], timeout: 2)
        controller.setReceivesBetaUpdates(true)
        controller.setReceivesBetaUpdates(false)
        for _ in 0..<100 { controller.checkForUpdates() }
        XCTAssertTrue(controller.isCheckingForUpdates)
        XCTAssertFalse(controller.canCheckForUpdates)
        let inFlight = await barrier.count
        XCTAssertEqual(inFlight, 1)
        await barrier.release()
        await fulfillment(of: [finished], timeout: 2)
        subscription.cancel()
        XCTAssertNil(controller.communityCheckStatus)
        XCTAssertEqual(presentations, 0, "A result for an invalidated choice must never be presented")
        XCTAssertTrue(controller.canCheckForUpdates)
        let retried = expectation(description: "explicit retry completed")
        let retrySubscription = controller.$isCheckingForUpdates.dropFirst().filter { !$0 }.sink { _ in retried.fulfill() }
        controller.checkForUpdates()
        await fulfillment(of: [retried], timeout: 2)
        retrySubscription.cancel()
        XCTAssertEqual(controller.communityCheckStatus, .checked(.upToDate))
        XCTAssertEqual(presentations, 1)
        let total = await barrier.count
        XCTAssertEqual(total, 2, "Cancelled work must not enqueue an automatic replacement")
    }

    func testCommunityFailureIsVisibleAndCanBeRetried() async throws {
        let fixture = try CommunityControllerFixture()
        defer { fixture.remove() }
        let calls = CommunityCheckCalls()
        let presented = expectation(description: "failures presented")
        presented.expectedFulfillmentCount = 2
        let controller = UpdateController(bundle: fixture.bundle, defaults: fixture.defaults, isTesting: false,
            checkCommunityRelease: { version, build, releaseTag, betas in
                await calls.append(version: version, build: build, releaseTag: releaseTag, betas: betas)
                throw CommunityReleaseCheckError.rateLimited
            }, presentCommunityResult: { _ in presented.fulfill() })
        let first = expectation(description: "first failure completed")
        let subscription = controller.$isCheckingForUpdates.dropFirst().filter { !$0 }.sink { _ in first.fulfill() }
        controller.checkForUpdates()
        await fulfillment(of: [first], timeout: 2)
        subscription.cancel()
        XCTAssertEqual(controller.communityCheckStatus, .failed(.rateLimited))
        XCTAssertTrue(controller.canCheckForUpdates)
        controller.checkForUpdates()
        await fulfillment(of: [presented], timeout: 2)
        let total = await calls.values.count
        XCTAssertEqual(total, 2)
        XCTAssertEqual(controller.communityCheckStatus, .failed(.rateLimited))
        controller.setReceivesBetaUpdates(true)
        XCTAssertNil(controller.communityCheckStatus)
    }

    func testCommunityControllerDoesNotRetainItselfWhileRequestIsSuspended() async throws {
        let fixture = try CommunityControllerFixture()
        defer { fixture.remove() }
        let barrier = CommunityCheckBarrier(entered: expectation(description: "check entered"))
        defer { Task { await barrier.release() } }
        var controller: UpdateController? = UpdateController(bundle: fixture.bundle, defaults: fixture.defaults, isTesting: false,
            checkCommunityRelease: { _, _, _, _ in await barrier.check() })
        weak var weakController = controller
        controller?.checkForUpdates()
        await fulfillment(of: [barrier.entered], timeout: 2)
        controller = nil
        XCTAssertNil(weakController)
        await barrier.release()
    }

    func testCommunityTestModeAndMissingVersionCannotEnableChecks() throws {
        let fixture = try CommunityControllerFixture()
        defer { fixture.remove() }
        let controller = UpdateController(bundle: fixture.bundle, defaults: fixture.defaults, isTesting: true)
        XCTAssertTrue(controller.usesGitHubReleases)
        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.canCheckForUpdates)
        let missing = try CommunityControllerFixture(version: nil)
        defer { missing.remove() }
        let invalid = UpdateController(bundle: missing.bundle, defaults: missing.defaults, isTesting: false)
        XCTAssertFalse(invalid.isAvailable)
        invalid.checkForUpdates()
        XCTAssertFalse(invalid.isCheckingForUpdates)
    }

    func testVisibleCommunityResultFollowsLanguageWithoutRepeatingCheck() async throws {
        let fixture = try CommunityControllerFixture()
        defer { fixture.remove() }
        let calls = CommunityCheckCalls()
        let presented = expectation(description: "version result ready")
        let release = CommunityRelease(tag: "v0.2.0-beta.12", version: "0.2.0", build: "123",
                                       pageURL: CommunityReleaseChecker.releasesPage.appendingPathComponent("tag/v0.2.0-beta.12"))
        let controller = UpdateController(bundle: fixture.bundle, defaults: fixture.defaults, isTesting: false,
            checkCommunityRelease: { version, build, releaseTag, betas in
                await calls.append(version: version, build: build, releaseTag: releaseTag, betas: betas)
                return .updateAvailable(release)
            }, presentCommunityResult: { _ in presented.fulfill() })
        controller.checkForUpdates()
        await fulfillment(of: [presented], timeout: 2)
        QuickFileLocalization.apply(.english)
        defer { QuickFileLocalization.apply(.system) }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let section = UpdateSettingsView(updates: controller)
        let host = NSHostingView(rootView: section.environment(\.locale, Locale(identifier: "en")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 488, height: 490),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for (language, expected) in [(QuickFileLanguage.english, "Version v0.2.0-beta.12 (build 123) is available."),
                                     (.simplifiedChinese, "发现新版本 v0.2.0-beta.12（build 123）"),
                                     (.english, "Version v0.2.0-beta.12 (build 123) is available.")] {
            QuickFileLocalization.apply(language)
            host.rootView = section.environment(\.locale, Locale(identifier: language.resolvedIdentifier()))
            for _ in 0..<3 {
                try await Task.sleep(nanoseconds: 20_000_000)
                host.layoutSubtreeIfNeeded()
            }
            let text = accessibilityText(host).joined(separator: "\n")
            XCTAssertTrue(text.contains(expected), text)
            XCTAssertTrue(text.contains(QuickFileLocalization.text(.init("打开发行页"))), text)
            XCTAssertFalse(text.contains(QuickFileLocalization.text(.init("自动检查更新"))), text)
        }
        let total = await calls.values.count
        XCTAssertEqual(total, 1, "Changing the display language must not repeat a network check")
        XCTAssertEqual(controller.communityCheckStatus, .checked(.updateAvailable(release)))
    }

    private func accessibilityText(_ element: Any) -> [String] {
        guard let node = element as? NSObject else { return [] }
        func attribute(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }
        let children = attribute("accessibilityChildren") as? [Any]
            ?? node.accessibilityAttributeValue(.children) as? [Any] ?? (node as? NSView)?.subviews ?? []
        return [attribute("accessibilityLabel") as? String, attribute("accessibilityValue") as? String,
                node.accessibilityAttributeValue(.value) as? String].compactMap { $0 }
            + children.flatMap(accessibilityText)
    }
}

private struct CommunityControllerFixture {
    let directory: URL
    let bundle: Bundle
    let defaults: UserDefaults
    let suite: String

    init(version: String? = "0.1.0", releaseTag: String? = nil) throws {
        suite = "org.example.QuickFile.CommunityControllerTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/Temporary/community-controller-tests-" + suite)
        let url = directory.appendingPathComponent("Fixture.bundle")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        var info = ["CFBundleIdentifier": suite, "CFBundlePackageType": "BNDL", "CFBundleVersion": "100",
                    "QuickFileDistributionChannel": "community"]
        info["CFBundleShortVersionString"] = version
        info["QuickFileReleaseTag"] = releaseTag
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        bundle = try XCTUnwrap(Bundle(url: url))
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor CommunityCheckCalls {
    struct Call: Equatable {
        let version: String
        let build: String
        let releaseTag: String?
        let betas: Bool
    }
    private(set) var values: [Call] = []
    func append(version: String, build: String, releaseTag: String?, betas: Bool) {
        values.append(Call(version: version, build: build, releaseTag: releaseTag, betas: betas))
    }
}

private actor CommunityCheckBarrier {
    nonisolated let entered: XCTestExpectation
    private(set) var count = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(entered: XCTestExpectation) { self.entered = entered }

    func check() async -> CommunityReleaseCheckResult {
        count += 1
        if count == 1 {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }
        return .upToDate
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
