import AppKit
import QuickFileCore
import SwiftUI

enum AppTab: String, CaseIterable {
    case create, templates, diagnostics

    init(route: QuickFileAppRoute) {
        switch route {
        case .create: self = .create
        case .templates: self = .templates
        case .diagnostics: self = .diagnostics
        }
    }
}

/// One receiving window owns one slot. A newer valid navigation intent supersedes
/// the previous one; malformed input cannot clear it. Authorization completion may
/// temporarily select the create page, but must not consume this pending intent.
struct QuickFilePendingAppRoute: Equatable, Sendable {
    private(set) var route: QuickFileAppRoute?

    init() {}

    @discardableResult
    mutating func receive(_ url: URL) -> Bool {
        guard let accepted = QuickFileAppRoute(url: url) else { return false }
        route = accepted
        return true
    }

    mutating func discard() { route = nil }

    mutating func takeIfReady(startupAuthorizationChecked: Bool, isBusy: Bool) -> QuickFileAppRoute? {
        guard startupAuthorizationChecked, !isBusy else { return nil }
        defer { route = nil }
        return route
    }
}

/// The generation belongs to one visible window incarnation. A callback captured
/// before close must not become valid again if the same SwiftUI state reappears.
/// A single deferred-check bit allows a reopened window to resume after another
/// window's drain exits, without polling an empty queue on every busy transition.
struct QuickFileWindowPresentationState: Equatable, Sendable {
    private(set) var generation: UUID?
    private var isAuthorizationCheckScheduled = false
    private var needsAuthorizationCheckWhenIdle = false

    var isAwaitingAuthorizationCheck: Bool {
        isAuthorizationCheckScheduled || needsAuthorizationCheckWhenIdle
    }

    mutating func appear() {
        if generation == nil { generation = UUID() }
    }

    mutating func disappear() {
        generation = nil
        isAuthorizationCheckScheduled = false
        needsAuthorizationCheckWhenIdle = false
    }

    func canPresent(_ expectedGeneration: UUID) -> Bool {
        generation == expectedGeneration
    }

    /// Coalesce repeated notifications while this window has a queued/running
    /// check. At most one task and one extra-check intent exist per window.
    mutating func requestAuthorizationCheck() -> UUID? {
        guard let generation else { return nil }
        guard !isAuthorizationCheckScheduled else {
            needsAuthorizationCheckWhenIdle = true
            return nil
        }
        isAuthorizationCheckScheduled = true
        needsAuthorizationCheckWhenIdle = false
        return generation
    }

    @discardableResult
    mutating func finishAuthorizationCheck(for expectedGeneration: UUID, isBusy: Bool) -> Bool {
        guard canPresent(expectedGeneration) else { return false }
        isAuthorizationCheckScheduled = false
        // An app-scoped operation may have rejected this window's check. Keep
        // exactly one retry intent until that operation publishes its release.
        if isBusy { needsAuthorizationCheckWhenIdle = true }
        return true
    }

    func shouldResumeAuthorizationCheck(isBusy: Bool) -> Bool {
        generation != nil && !isBusy && !isAuthorizationCheckScheduled && needsAuthorizationCheckWhenIdle
    }
}

// Each window owns its page controllers. Model publications update the individual
// SwiftUI pages without rebuilding tab metadata or their hosting view hierarchy.
struct AppTabsView: NSViewControllerRepresentable {
    let viewModel: QuickFileViewModel
    let finderIntegrationViewModel: FinderIntegrationViewModel
    var finderMenuSettings: FinderMenuSettingsViewModel? = nil
    var diagnosticsViewModel: DiagnosticsViewModel? = nil
    @Binding var selectedTab: AppTab

    func makeNSViewController(context: Context) -> AppTabController {
        let controller = AppTabController(
            viewModel: viewModel,
            finderIntegrationViewModel: finderIntegrationViewModel,
            finderMenuSettings: finderMenuSettings,
            diagnosticsViewModel: diagnosticsViewModel,
            scenePhase: context.environment.scenePhase
        )
        controller.synchronizeSelection(with: $selectedTab)
        return controller
    }

    func updateNSViewController(_ controller: AppTabController, context: Context) {
        controller.updateScenePhase(context.environment.scenePhase)
        controller.synchronizeSelection(with: $selectedTab)
    }

    static func dismantleNSViewController(_ controller: AppTabController, coordinator: ()) {
        controller.selectionChanged = nil
    }
}

@MainActor
final class AppTabController: NSTabViewController {
    var selectionChanged: ((AppTab) -> Void)?
    private var pageContents: [AnyView] = []
    private var scenePhase: ScenePhase

    init(
        viewModel: QuickFileViewModel,
        finderIntegrationViewModel: FinderIntegrationViewModel,
        finderMenuSettings: FinderMenuSettingsViewModel? = nil,
        diagnosticsViewModel: DiagnosticsViewModel? = nil,
        scenePhase: ScenePhase
    ) {
        self.scenePhase = scenePhase
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = []
        addPage(CreateFileView(viewModel: viewModel, finderIntegrationViewModel: finderIntegrationViewModel,
                               showTemplateManager: { [weak self] in self?.selectedTab = .templates }),
                tab: .create, title: "创建文件", symbol: "doc.badge.plus")
        addPage(TemplateManagerView(viewModel: viewModel, finderMenuSettings: finderMenuSettings),
                tab: .templates, title: "模板管理", symbol: "list.bullet.rectangle")
        addPage(DiagnosticsView(viewModel: diagnosticsViewModel),
                tab: .diagnostics, title: "诊断", symbol: "stethoscope")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(viewModel:finderIntegrationViewModel:diagnosticsViewModel:scenePhase:)") }

    var selectedTab: AppTab {
        get { AppTab.allCases[selectedTabViewItemIndex] }
        set {
            let index = AppTab.allCases.firstIndex(of: newValue)!
            if selectedTabViewItemIndex != index { selectedTabViewItemIndex = index }
        }
    }

    func synchronizeSelection(with selection: Binding<AppTab>) {
        // A programmatic selection already came from SwiftUI. Do not publish back
        // during updateNSViewController; native toolbar actions publish afterward.
        selectionChanged = nil
        selectedTab = selection.wrappedValue
        selectionChanged = { tab in
            if selection.wrappedValue != tab { selection.wrappedValue = tab }
        }
    }

    func updateScenePhase(_ phase: ScenePhase) {
        guard scenePhase != phase else { return }
        scenePhase = phase
        for (index, content) in pageContents.enumerated() {
            let hosting = tabViewItems[index].viewController as! NSHostingController<AnyView>
            hosting.rootView = AnyView(content.environment(\.scenePhase, phase))
        }
    }

    private func addPage<Content: View>(_ content: Content, tab: AppTab, title: String, symbol: String) {
        let page = AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity))
        pageContents.append(page)
        let hosting = NSHostingController(rootView: AnyView(page.environment(\.scenePhase, scenePhase)))
        let item = NSTabViewItem(viewController: hosting)
        // AppKit also uses this identifier as an NSToolbarItem.Identifier.
        item.identifier = tab.rawValue
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let identifier = tabViewItem?.identifier as? String, let tab = AppTab(rawValue: identifier) {
            selectionChanged?(tab)
        }
    }
}
