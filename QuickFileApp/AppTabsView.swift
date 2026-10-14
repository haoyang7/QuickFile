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
    private var pendingResumePauseID: UUID?

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
        pendingResumePauseID = nil
    }

    func canPresent(_ expectedGeneration: UUID) -> Bool {
        generation == expectedGeneration
    }

    /// Coalesce repeated notifications while this window has a queued/running
    /// check. At most one task and one extra-check intent exist per window.
    mutating func requestAuthorizationCheck(resumingPauseID: UUID? = nil) -> UUID? {
        guard let generation else { return nil }
        // Automatic checks never erase an explicit, already-received resume.
        if let resumingPauseID { pendingResumePauseID = resumingPauseID }
        guard !isAuthorizationCheckScheduled else {
            needsAuthorizationCheckWhenIdle = true
            return nil
        }
        isAuthorizationCheckScheduled = true
        needsAuthorizationCheckWhenIdle = false
        return generation
    }

    mutating func takeAuthorizationResumePauseID(for expectedGeneration: UUID, currentPauseID: UUID?) -> UUID? {
        guard canPresent(expectedGeneration) else { return nil }
        let pauseID = pendingResumePauseID
        pendingResumePauseID = nil
        return pauseID == currentPauseID ? pauseID : nil
    }

    @discardableResult
    mutating func finishAuthorizationCheck(
        for expectedGeneration: UUID, isBusy: Bool,
        resumingPauseID: UUID? = nil, currentPauseID: UUID? = nil
    ) -> Bool {
        guard canPresent(expectedGeneration) else { return false }
        isAuthorizationCheckScheduled = false
        // An app-scoped operation may have rejected this window's check. Keep
        // exactly one retry intent until that operation publishes its release.
        if isBusy {
            needsAuthorizationCheckWhenIdle = true
            // Only a rejected check may return its still-current receipt. A
            // completed resume must not automatically replay a later pause.
            if pendingResumePauseID == nil, resumingPauseID == currentPauseID {
                pendingResumePauseID = resumingPauseID
            }
        }
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
            scenePhase: context.environment.scenePhase,
            locale: context.environment.locale
        )
        controller.synchronizeSelection(with: $selectedTab)
        return controller
    }

    func updateNSViewController(_ controller: AppTabController, context: Context) {
        controller.updateEnvironment(scenePhase: context.environment.scenePhase, locale: context.environment.locale)
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
    private(set) var locale: Locale

    init(
        viewModel: QuickFileViewModel,
        finderIntegrationViewModel: FinderIntegrationViewModel,
        finderMenuSettings: FinderMenuSettingsViewModel? = nil,
        diagnosticsViewModel: DiagnosticsViewModel? = nil,
        scenePhase: ScenePhase,
        locale: Locale = Locale(identifier: QuickFileLocalization.identifier)
    ) {
        self.scenePhase = scenePhase
        self.locale = locale
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = []
        let bundle = QuickFileLocalization.resourceBundle(for: locale.identifier)
        addPage(CreateFileView(viewModel: viewModel, finderIntegrationViewModel: finderIntegrationViewModel,
                               showTemplateManager: { [weak self] in self?.selectedTab = .templates }),
                tab: .create, title: String(localized: "创建文件", bundle: bundle), symbol: "doc.badge.plus")
        addPage(TemplateManagerView(viewModel: viewModel, finderMenuSettings: finderMenuSettings),
                tab: .templates, title: String(localized: "模板管理", bundle: bundle), symbol: "list.bullet.rectangle")
        addPage(DiagnosticsView(viewModel: diagnosticsViewModel),
                tab: .diagnostics, title: String(localized: "诊断", bundle: bundle), symbol: "stethoscope")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(viewModel:finderIntegrationViewModel:diagnosticsViewModel:scenePhase:)") }

    var selectedTab: AppTab {
        get {
            _ = view
            return AppTab(rawValue: tabView.selectedTabViewItem!.identifier as! String)!
        }
        set {
            _ = view
            let item = tabViewItems[AppTab.allCases.firstIndex(of: newValue)!]
            // The visible NSTabView item is authoritative. Finder authorization
            // can enter a modal run loop immediately after SwiftUI navigation.
            if tabView.selectedTabViewItem !== item { tabView.selectTabViewItem(item) }
            synchronizeToolbarSelection()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        synchronizeToolbarSelection()
    }

    private func synchronizeToolbarSelection() {
        guard isViewLoaded, let identifier = tabView.selectedTabViewItem?.identifier as? String else { return }
        view.window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(identifier)
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
        updateEnvironment(scenePhase: phase, locale: locale)
    }

    func updateEnvironment(scenePhase phase: ScenePhase, locale: Locale) {
        guard scenePhase != phase || self.locale != locale else { return }
        scenePhase = phase
        self.locale = locale
        let bundle = QuickFileLocalization.resourceBundle(for: locale.identifier)
        let titles = [String(localized: "创建文件", bundle: bundle),
                      String(localized: "模板管理", bundle: bundle),
                      String(localized: "诊断", bundle: bundle)]
        for (item, title) in zip(tabViewItems, titles) {
            item.label = title
            item.image?.accessibilityDescription = title
            // NSTabViewController caches toolbar items after creating the window.
            if let toolbarItem = view.window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == item.identifier as? String }) {
                toolbarItem.label = title
                toolbarItem.paletteLabel = title
                toolbarItem.toolTip = title
            }
        }
        for (index, content) in pageContents.enumerated() {
            let hosting = tabViewItems[index].viewController as! NSHostingController<AnyView>
            hosting.rootView = AnyView(content.environment(\.scenePhase, phase).environment(\.locale, locale))
        }
    }

    private func addPage<Content: View>(_ content: Content, tab: AppTab, title: String, symbol: String) {
        let page = AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity))
        pageContents.append(page)
        let hosting = NSHostingController(rootView: AnyView(page.environment(\.scenePhase, scenePhase).environment(\.locale, locale)))
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
        // A callback can apply a newer route. Read the final selected item,
        // rather than highlighting the item passed to this older callback.
        synchronizeToolbarSelection()
    }
}
