import AppKit
import QuickFileCore

/// Keeps non-creation actions separate from the registry's positive creation tags.
/// Navigation dispatches a dedicated selector and never asks Finder for a target.
struct FinderMenuPresentation {
    enum RecoveryRoute {
        case create, templates
    }

    /// Slow preparation offers an immediate way to continue in the containing app.
    enum UnavailableState: CaseIterable, Equatable {
        case operationInProgress
        case sidebarSelectionUnavailable
        case mixedSelection
        case destinationMissing
        case destinationLoading
        case destinationBusy
        case destinationUnavailable
        case templatesLoading
        case templateReadFailed
        case noEnabledTemplates

        var explanation: String {
            switch self {
            case .operationInProgress:
                return "已有文件请求正在处理，请稍后重新打开菜单"
            case .sidebarSelectionUnavailable:
                return "请先打开边栏中的文件夹，再右键创建"
            case .mixedSelection:
                return "所选项目来自不同文件夹，请先打开要创建文件的文件夹"
            case .destinationMissing:
                return "当前位置不可用，请重新选择文件夹"
            case .destinationLoading:
                return "正在确认创建位置…"
            case .destinationBusy:
                return "创建位置暂时繁忙"
            case .destinationUnavailable:
                return "无法确认当前位置，请打开文件夹后重新右键"
            case .templatesLoading:
                return "正在加载模板…"
            case .templateReadFailed:
                return "暂时无法加载模板，请在 QuickFile 中重新加载"
            case .noEnabledTemplates:
                return "暂无启用的模板，请添加或启用模板"
            }
        }

        var recoveryRoute: RecoveryRoute? {
            switch self {
            case .templateReadFailed, .noEnabledTemplates:
                return .templates
            case .destinationLoading, .destinationBusy, .destinationUnavailable, .templatesLoading:
                return .create
            default:
                return nil
            }
        }
    }

    let target: AnyObject
    let createAction: Selector
    let openCreateAction: Selector
    let openTemplatesAction: Selector

    func unavailable(_ state: UnavailableState) -> NSMenu {
        let (menu, submenu) = rootMenu()
        submenu.addItem(disabledMessage(state.explanation))
        if let route = state.recoveryRoute { appendNavigation(route, to: submenu) }
        return menu
    }

    func templates(
        _ presentation: FinderTemplateMenuPresentation,
        register: ([FinderTemplateMenuEntry]) -> [Int]
    ) -> NSMenu {
        let tags = register(presentation.entries)
        precondition(tags.count == presentation.entries.count)
        guard !presentation.entries.isEmpty else {
            return unavailable(.noEnabledTemplates)
        }
        let (menu, submenu) = rootMenu()
        for (entry, tag) in zip(presentation.entries, tags) {
            let item = NSMenuItem(title: entry.title, action: createAction, keyEquivalent: "")
            item.target = target
            item.tag = tag
            submenu.addItem(item)
        }
        return menu
    }

    private func rootMenu() -> (NSMenu, NSMenu) {
        let menu = NSMenu(title: "QuickFile")
        let root = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "新建文件")
        submenu.autoenablesItems = false
        root.submenu = submenu
        menu.addItem(root)
        return (menu, submenu)
    }

    private func disabledMessage(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func appendNavigation(_ route: RecoveryRoute, to menu: NSMenu) {
        let action: Selector
        let title: String
        switch route {
        case .create:
            action = openCreateAction
            title = QuickFileAppRoute.create.menuTitle
        case .templates:
            action = openTemplatesAction
            title = QuickFileAppRoute.templates.menuTitle
        }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        // Explicit zero is deliberately outside FinderMenuActionRegistry's range.
        item.tag = 0
        menu.addItem(item)
    }
}

extension FinderExtensionFailureReason {
    /// Recovery only navigates. In particular an already-created result must never
    /// offer a retry or issue another creation request.
    var recoveryRoute: QuickFileAppRoute {
        switch self {
        case .templateUnavailable, .templateReadFailed, .templateStorageUnavailable,
             .templateWriteFailed, .renderedContentTooLarge:
            return .templates
        case .directoryNotAuthorized, .authorizationUnavailable, .permissionDenied,
             .readOnlyVolume, .writeFailed, .createdFileLocationUnavailable:
            return .diagnostics
        case .menuContextUnavailable, .destinationUnavailable, .operationInProgress,
             .destinationMissing, .invalidFilename, .conflictLimitReached:
            return .create
        }
    }
}
