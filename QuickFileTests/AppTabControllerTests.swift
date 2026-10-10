import AppKit
import SwiftUI
import XCTest
@testable import QuickFile
@testable import QuickFileCore
@testable import QuickFileInfrastructure

@MainActor
final class AppTabControllerTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var model: QuickFileViewModel!
    private var integration: FinderIntegrationViewModel!
    private var diagnostics: DiagnosticsViewModel!

    override func setUpWithError() throws {
        suite = "QuickFileTests.AppTabController.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let grants = AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: directory.appendingPathComponent("grants"),
            persistentBookmarkCreator: { Data($0.path.utf8) }, transferBookmarkCreator: { Data($0.path.utf8) },
            persistentBookmarkResolver: { _ in throw CocoaError(.fileReadCorruptFile) },
            transferBookmarkResolver: { _ in throw CocoaError(.fileReadCorruptFile) }
        )
        model = QuickFileViewModel(
            templateStore: TemplateStore(defaults: defaults, storageURL: directory.appendingPathComponent("templates.json"),
                                         changeNotificationName: suite),
            templates: [FileTemplate(name: "Owned template", fileExtension: "txt", content: "fixture")],
            authorizedDirectoryStore: grants, clipboardProvider: { nil }, revealCreatedFile: { _ in }
        )
        integration = FinderIntegrationViewModel(statusProvider: { false }, runtimeProvider: { _ in
            FinderExtensionDiagnosticSnapshot(embeddedIdentifiers: [], embeddingKnown: true, registration: .unknown,
                registrationEvidence: "fixture", enabled: false, responded: nil)
        }, managementOpener: {})
        diagnostics = DiagnosticsViewModel(extensionEnabledProvider: { false }, runtimeProvider: { _ in
            FinderExtensionDiagnosticSnapshot(embeddedIdentifiers: [], embeddingKnown: true, registration: .unknown,
                registrationEvidence: "fixture", enabled: false, responded: nil)
        }, extensionActivityStore: FinderExtensionActivityStore(defaults: defaults,
            failureHistoryFileURL: directory.appendingPathComponent("failures.json")), authorizedDirectoryStore: grants)
    }

    override func tearDownWithError() throws {
        model = nil
        integration = nil
        diagnostics = nil
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    private func controller() -> AppTabController {
        AppTabController(viewModel: model, finderIntegrationViewModel: integration,
                         diagnosticsViewModel: diagnostics, scenePhase: .active)
    }

    func testRepeatedTabChangesKeepPageControllersAndHostingViews() {
        let controller = controller()
        let pages = controller.tabViewItems.map { $0.viewController! }
        let views = pages.map { $0.view }
        XCTAssertEqual(controller.tabViewItems.map(\.label), ["创建文件", "模板管理", "诊断"])
        XCTAssertEqual(controller.tabViewItems.map { $0.identifier as? String }, AppTab.allCases.map(\.rawValue))
        for _ in 0..<5 {
            for tab in AppTab.allCases { controller.selectedTab = tab }
        }
        for index in pages.indices {
            XCTAssertTrue(controller.tabViewItems[index].viewController === pages[index])
            XCTAssertTrue(controller.tabViewItems[index].view === views[index])
        }
    }

    func testToolbarSelectionPublishesAndProgrammaticSelectionDoesNotWriteBack() {
        let controller = controller()
        _ = controller.view
        var selected = AppTab.templates
        var writeCount = 0
        let binding = Binding(get: { selected }, set: { selected = $0; writeCount += 1 })
        controller.synchronizeSelection(with: binding)
        XCTAssertEqual(controller.selectedTab, .templates)
        XCTAssertEqual(writeCount, 0)
        controller.selectedTab = .diagnostics
        XCTAssertEqual(selected, .diagnostics)
        XCTAssertEqual(writeCount, 1)
        controller.synchronizeSelection(with: binding)
        XCTAssertEqual(writeCount, 1)
        // Finder's pending authorization callback switches the binding to creation.
        selected = .create
        controller.synchronizeSelection(with: binding)
        XCTAssertEqual(controller.selectedTab, .create)
        XCTAssertEqual(writeCount, 1)
        AppTabsView.dismantleNSViewController(controller, coordinator: ())
        XCTAssertNil(controller.selectionChanged)
    }

    func testSelectionCallbackCanApplyNewerSelectionWithoutLeavingOldPageVisible() async {
        let controller = controller()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }
        _ = controller.view
        var selected = AppTab.create
        let binding = Binding(get: { selected }, set: { selected = $0 })
        controller.synchronizeSelection(with: binding)
        XCTAssertTrue(controller.tabViewItems[0].view?.superview === controller.tabView)
        let reconciled = expectation(description: "newer selection reconciled")
        controller.selectionChanged = { _ in
            // A SwiftUI synchronization can carry a newer programmatic intent.
            selected = .create
            controller.synchronizeSelection(with: binding)
            reconciled.fulfill()
        }
        defer { controller.selectionChanged = nil }
        controller.selectedTab = .templates
        await fulfillment(of: [reconciled], timeout: 5)
        XCTAssertEqual(controller.selectedTab, .create)
        XCTAssertEqual(controller.tabView.selectedTabViewItem?.identifier as? String, "create")
        XCTAssertTrue(controller.tabViewItems[0].view?.superview === controller.tabView)
        XCTAssertNil(controller.tabViewItems[1].view?.superview)
    }

    func testPendingNavigationWaitsThroughAuthorizationAndRetainsExistingPages() throws {
        let receiving = controller()
        let other = controller()
        let pages = receiving.tabViewItems.map { $0.viewController! }
        other.selectedTab = .templates
        var pending = QuickFilePendingAppRoute()
        pending.receive(QuickFileAppRoute.templates.url)
        XCTAssertNil(pending.takeIfReady(startupAuthorizationChecked: false, isBusy: false))
        // The authorization callback may select creation while its panel/worker runs.
        receiving.selectedTab = .create
        XCTAssertNil(pending.takeIfReady(startupAuthorizationChecked: true, isBusy: true))
        pending.receive(QuickFileAppRoute.diagnostics.url)
        XCTAssertNil(pending.takeIfReady(startupAuthorizationChecked: true, isBusy: true))
        let route = try XCTUnwrap(pending.takeIfReady(startupAuthorizationChecked: true, isBusy: false))
        receiving.selectedTab = AppTab(route: route)
        XCTAssertEqual(receiving.selectedTab, .diagnostics)
        XCTAssertEqual(other.selectedTab, .templates)
        for index in pages.indices {
            XCTAssertTrue(receiving.tabViewItems[index].viewController === pages[index])
        }
        XCTAssertNil(pending.route)
    }

    func testNewerNativeTabSelectionSupersedesPendingRouteButAuthorizationSelectionDoesNot() {
        let controller = controller()
        _ = controller.view
        var selected = AppTab.templates
        var pending = QuickFilePendingAppRoute()
        let binding = Binding(get: { selected }, set: { selected = $0; pending.discard() })
        controller.synchronizeSelection(with: binding)
        pending.receive(QuickFileAppRoute.templates.url)
        // Like willPresent, programmatic selection changes the binding's value
        // directly and synchronization deliberately does not publish it back.
        selected = .create
        controller.synchronizeSelection(with: binding)
        XCTAssertEqual(pending.route, .templates)
        // Native toolbar selection is newer explicit user intent.
        controller.selectedTab = .diagnostics
        XCTAssertEqual(selected, .diagnostics)
        XCTAssertNil(pending.route)
    }

    func testSeparateWindowsHaveIndependentPageControllersAndSelection() {
        let first = controller()
        let second = controller()
        first.selectedTab = .diagnostics
        second.selectedTab = .templates
        XCTAssertEqual(first.selectedTab, .diagnostics)
        XCTAssertEqual(second.selectedTab, .templates)
        for index in AppTab.allCases.indices {
            XCTAssertFalse(first.tabViewItems[index].viewController === second.tabViewItems[index].viewController)
        }
    }

    func testScenePhaseChangesPreserveControllersAndReleaseAfterWindowLifetime() {
        weak var released: AppTabController?
        weak var releasedPage: NSViewController?
        autoreleasepool {
            let controller = controller()
            released = controller
            let pages = controller.tabViewItems.map { $0.viewController! }
            releasedPage = pages[1]
            controller.updateScenePhase(.inactive)
            controller.updateScenePhase(.active)
            controller.updateScenePhase(.active)
            for index in pages.indices {
                XCTAssertTrue(controller.tabViewItems[index].viewController === pages[index])
            }
        }
        XCTAssertNil(released)
        XCTAssertNil(releasedPage)
    }
}
