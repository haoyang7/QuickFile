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

    func testDiagnosticsExposesRepairAfterReadFailureWithoutExpandingMaintenance() async throws {
        QuickFileLocalization.apply(.english)
        defer { QuickFileLocalization.apply(.system) }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }

        let grantsURL = directory.appendingPathComponent("grants/authorizedDirectories.v2.json")
        try FileManager.default.createDirectory(at: grantsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unreadable inventory".utf8).write(to: grantsURL)
        await diagnostics.refreshRuntimeStatus()
        let host = NSHostingView(rootView: DiagnosticsView(viewModel: diagnostics)
            .environment(\.locale, Locale(identifier: "en")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await settleLayout(host)
        let failedText = accessibilityText(host).joined(separator: "\n")
        XCTAssertTrue(failedText.contains("Saved folder access could not be read"))
        XCTAssertTrue(failedText.contains("Repair Authorization Permissions"), failedText)
        XCTAssertFalse(failedText.contains("No Finder folder access saved"))

        try FileManager.default.removeItem(at: grantsURL)
        await diagnostics.refreshRuntimeStatus()
        await settleLayout(host)
        let recoveredText = accessibilityText(host).joined(separator: "\n")
        XCTAssertTrue(recoveredText.contains("No Finder folder access saved"), recoveredText)
        XCTAssertFalse(recoveredText.contains("Repair Authorization Permissions"), "Healthy inventory leaves maintenance collapsed")
    }

    func testUnrecognizedTabIdentifierReturnsNoSelectionInsteadOfCrashing() {
        let controller = controller()
        _ = controller.view
        controller.tabView.selectedTabViewItem?.identifier = 42
        XCTAssertNil(controller.selectedTab)
        controller.tabView.selectedTabViewItem?.identifier = "unrecognized"
        XCTAssertNil(controller.selectedTab)
        controller.selectedTab = .diagnostics
        XCTAssertEqual(controller.selectedTab, .diagnostics)
    }

    func testVisibleSavedMenuSummaryTracksLanguageWithoutReloadingOrSaving() async {
        QuickFileLocalization.apply(.english)
        defer { QuickFileLocalization.apply(.system) }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let reads = LockedTestValue(0)
        let writes = LockedTestValue(0)
        let settings = FinderMenuSettingsViewModel(load: {
            reads.update { $0 += 1 }
            return .all
        }, save: { _ in writes.update { $0 += 1 } })
        await settings.loadIfNeeded()
        // Preserve the same child value, as the retained tab does. Updating only
        // the locale must invalidate its dynamic summary, without a model event.
        let section = FinderMenuSettingsSection(viewModel: settings)
        let host = NSHostingView(rootView: section.environment(\.locale, Locale(identifier: "en")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for (language, expected) in [(QuickFileLanguage.english, "Saved: All templates"),
                                     (.simplifiedChinese, "已保存：全部模板"),
                                     (.english, "Saved: All templates")] {
            QuickFileLocalization.apply(language)
            host.rootView = section.environment(\.locale, Locale(identifier: language.resolvedIdentifier()))
            await settleLayout(host)
            XCTAssertTrue(accessibilityText(host).contains { $0.contains(expected) }, "Visible summary: \(accessibilityText(host))")
        }
        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(writes.value, 0)
    }

    func testVisibleTemplatePickerTracksLanguageWithoutReplacingPageOrDraft() async throws {
        QuickFileLocalization.apply(.simplifiedChinese)
        defer { QuickFileLocalization.apply(.system) }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let templates = BuiltInTemplates.all + [FileTemplate(name: "自定义名称", fileExtension: "txt", content: "")]
        let storeURL = directory.appendingPathComponent("picker-templates.json")
        let pickerModel = QuickFileViewModel(
            templateStore: TemplateStore(defaults: defaults, storageURL: storeURL), templates: templates)
        pickerModel.requestedFilename = "Unsaved draft"
        let controller = AppTabController(viewModel: pickerModel, finderIntegrationViewModel: integration,
                                          diagnosticsViewModel: diagnostics, scenePhase: .active)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }
        let page = try XCTUnwrap(controller.tabViewItems.first?.viewController)
        for (index, chinese, english) in [(0, "Word 文档", "Word Document"),
                                          (3, "文本文档", "Text Document"),
                                          (8, "自定义名称", "自定义名称")] {
            pickerModel.selectedTemplateID = templates[index].id
            for language in [QuickFileLanguage.simplifiedChinese, .english, .simplifiedChinese] {
                QuickFileLocalization.apply(language)
                controller.updateEnvironment(scenePhase: .active, locale: Locale(identifier: language.resolvedIdentifier()))
                await settleLayout(controller.view)
                let text = accessibilityText(page.view)
                XCTAssertTrue(text.contains(language == .english ? english : chinese), "Visible picker: \(text)")
                XCTAssertTrue(controller.tabViewItems.first?.viewController === page)
                XCTAssertEqual(pickerModel.selectedTemplateID, templates[index].id)
                XCTAssertEqual(pickerModel.requestedFilename, "Unsaved draft")
                XCTAssertEqual(pickerModel.templates, templates)
                XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
            }
        }
    }

    private func settleLayout(_ view: NSView) async {
        // Allow SwiftUI's scheduled environment and layout transactions to run.
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            view.layoutSubtreeIfNeeded()
        }
    }

    private func accessibilityText(_ element: Any) -> [String] {
        // SwiftUI's virtual accessibility nodes implement the relevant selectors
        // without declaring conformance to the full AppKit protocol.
        guard let node = element as? NSObject else { return [] }
        func attribute(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }
        let children = attribute("accessibilityChildren") as? [Any]
            ?? node.accessibilityAttributeValue(.children) as? [Any] ?? (node as? NSView)?.subviews ?? []
        return [attribute("accessibilityLabel") as? String,
                attribute("accessibilityValue") as? String,
                node.accessibilityAttributeValue(.value) as? String].compactMap { $0 }
            + children.flatMap(accessibilityText)
    }

    func testToolbarHighlightMatchesVisiblePageThroughSelectionAndLanguageChanges() async {
        QuickFileLocalization.apply(.simplifiedChinese)
        defer { QuickFileLocalization.apply(.system) }
        let controller = controller()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }
        for language in [QuickFileLanguage.english, .simplifiedChinese] {
            QuickFileLocalization.apply(language)
            controller.updateEnvironment(scenePhase: .active, locale: Locale(identifier: language.resolvedIdentifier()))
            for tab in [AppTab.diagnostics, .create, .templates, .diagnostics] {
                controller.selectedTab = tab
                await settleLayout(controller.view)
                XCTAssertEqual(window.toolbar?.selectedItemIdentifier?.rawValue, tab.rawValue)
                XCTAssertEqual(controller.tabView.selectedTabViewItem?.identifier as? String, tab.rawValue)
                XCTAssertTrue(controller.tabView.selectedTabViewItem?.view?.superview === controller.tabView)
                // Re-synchronize after AppKit restores an obsolete highlight.
                window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab == .create ? "diagnostics" : "create")
                controller.synchronizeSelection(with: .constant(tab))
                XCTAssertEqual(window.toolbar?.selectedItemIdentifier?.rawValue, tab.rawValue)
            }
        }
    }

    func testNativeToolbarActionKeepsNewerProgrammaticSelectionHighlighted() async throws {
        let controller = controller()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }
        await settleLayout(controller.view)
        let item = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == AppTab.templates.rawValue })
        controller.selectionChanged = { _ in
            controller.synchronizeSelection(with: .constant(.diagnostics))
        }
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        await settleLayout(controller.view)
        XCTAssertEqual(controller.selectedTab, .diagnostics)
        XCTAssertEqual(controller.tabView.selectedTabViewItem?.identifier as? String, "diagnostics")
        XCTAssertEqual(window.toolbar?.selectedItemIdentifier?.rawValue, "diagnostics")
    }

    func testEmbeddedToolbarTracksNativeClicksAndSwiftUISelection() async throws {
        QuickFileLocalization.apply(.simplifiedChinese)
        defer { QuickFileLocalization.apply(.system) }
        let state = TabTestState()
        let host = NSHostingController(rootView: TabTestHost(state: state, model: model,
            integration: integration, diagnostics: diagnostics))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderFront(nil)
        defer { window.close() }
        await settleLayout(host.view)
        func findTabs(_ view: NSView) -> AppTabController? {
            if let tabs = view.nextResponder as? AppTabController { return tabs }
            return view.subviews.compactMap(findTabs).first
        }
        let controller = try XCTUnwrap(findTabs(host.view))
        func assertVisibleSelection(_ tab: AppTab, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(controller.selectedTab, tab, file: file, line: line)
            XCTAssertEqual(window.toolbar?.selectedItemIdentifier?.rawValue, tab.rawValue, file: file, line: line)
            for (index, item) in controller.tabViewItems.enumerated() {
                XCTAssertEqual(item.view?.superview != nil, AppTab.allCases[index] == tab,
                               "Only the selected page may remain attached", file: file, line: line)
            }
        }
        for language in [QuickFileLanguage.english, .simplifiedChinese] {
            QuickFileLocalization.apply(language)
            state.locale = Locale(identifier: language.resolvedIdentifier())
            for tab in [AppTab.diagnostics, .create, .templates, .diagnostics] {
                state.tab = tab
                await settleLayout(host.view)
                XCTAssertEqual(controller.selectedTab, tab)
                XCTAssertEqual(window.toolbar?.selectedItemIdentifier?.rawValue, tab.rawValue)
                for target in [AppTab.create, tab] {
                    let item = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == target.rawValue })
                    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
                    await settleLayout(host.view)
                    XCTAssertEqual(state.tab, target)
                    XCTAssertEqual(controller.tabView.selectedTabViewItem?.identifier as? String, target.rawValue)
                    XCTAssertEqual(window.toolbar?.selectedItemIdentifier?.rawValue, target.rawValue)
                }
            }
        }
        // Finder authorization changes the tab immediately before entering an
        // AppKit modal loop. Queue feedback also changes the surrounding layout.
        for response in [NSApplication.ModalResponse.cancel, .OK] {
            state.tab = .diagnostics
            await settleLayout(host.view)
            assertVisibleSelection(.diagnostics)
            state.showsQueueFeedback = true
            state.phase = .inactive
            state.tab = .create
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                                styleMask: [.titled], backing: .buffered, defer: false)
            let finish = Timer(timeInterval: 0.1, repeats: false) { _ in
                MainActor.assumeIsolated {
                    state.phase = .active
                    NSApp.stopModal(withCode: response)
                }
            }
            RunLoop.main.add(finish, forMode: .modalPanel)
            XCTAssertEqual(NSApp.runModal(for: panel), response)
            finish.invalidate()
            panel.orderOut(nil)
            await settleLayout(host.view)
            assertVisibleSelection(.create)
            state.showsQueueFeedback = false
            await settleLayout(host.view)
            assertVisibleSelection(.create)
        }
    }

    func testLanguageSwitchUpdatesNativeToolbarAndPreservesPagesAndDraft() async {
        QuickFileLocalization.apply(.simplifiedChinese)
        defer { QuickFileLocalization.apply(.system) }
        let controller = controller()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        _ = controller.view
        let pages = controller.tabViewItems.map { $0.viewController! }
        let views = pages.map { $0.view }
        controller.selectedTab = .templates
        model.requestedFilename = "用户草稿"
        await model.reloadTemplates()
        let templateID = model.selectedTemplateID
        XCTAssertEqual(model.status, .success("模板已重新加载。"))
        for (language, titles) in [(QuickFileLanguage.english, ["Create File", "Templates", "Diagnostics"]),
                                  (.simplifiedChinese, ["创建文件", "模板管理", "诊断"])] {
            QuickFileLocalization.apply(language)
            let locale = Locale(identifier: language.resolvedIdentifier())
            controller.updateEnvironment(scenePhase: .active, locale: locale)
            XCTAssertEqual(controller.locale, locale)
            XCTAssertEqual(controller.tabViewItems.map(\.label), titles)
            let toolbarItems = window.toolbar?.items.filter { item in
                AppTab.allCases.contains { $0.rawValue == item.itemIdentifier.rawValue }
            } ?? []
            XCTAssertEqual(toolbarItems.count, 3)
            XCTAssertEqual(toolbarItems.map(\.label), titles)
            for index in pages.indices {
                XCTAssertTrue(controller.tabViewItems[index].viewController === pages[index])
                XCTAssertTrue(controller.tabViewItems[index].view === views[index])
            }
            XCTAssertEqual(controller.selectedTab, .templates)
            XCTAssertEqual(model.requestedFilename, "用户草稿")
            XCTAssertEqual(model.selectedTemplateID, templateID)
            if language == .english {
                XCTAssertTrue(model.filteredTemplates(search: "Document").contains { $0.displayName == "Word Document" })
            }
            XCTAssertEqual(model.status, .success(language == .english ? "Templates reloaded." : "模板已重新加载。"))
        }
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

@MainActor
private final class TabTestState: ObservableObject {
    @Published var tab = AppTab.create
    @Published var locale = Locale(identifier: "zh-Hans")
    @Published var showsQueueFeedback = false
    @Published var phase = ScenePhase.active
}

@MainActor
private struct TabTestHost: View {
    @ObservedObject var state: TabTestState
    let model: QuickFileViewModel
    let integration: FinderIntegrationViewModel
    let diagnostics: DiagnosticsViewModel

    var body: some View {
        VStack(spacing: 0) {
            if state.showsQueueFeedback {
                HStack { ProgressView(); Text(verbatim: "Fixture authorization request") }.padding()
            }
            AppTabsView(viewModel: model, finderIntegrationViewModel: integration,
                        diagnosticsViewModel: diagnostics, selectedTab: $state.tab)
        }
        .frame(minWidth: 720, minHeight: 520)
        .environment(\.locale, state.locale)
        .environment(\.scenePhase, state.phase)
    }
}
