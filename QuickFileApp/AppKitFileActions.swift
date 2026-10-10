import AppKit
import Foundation
import QuickFileCore
import UniformTypeIdentifiers

@MainActor
enum AppKitFileActions {
    static var applicationDidBecomeActiveNotification: Notification.Name {
        NSApplication.didBecomeActiveNotification
    }

    static func chooseDestinationFolder(startingAt directoryURL: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择新文件的保存位置"
        panel.prompt = "选择文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = directoryURL
        panel.message = "选择后即可在此创建文件。本次选择不会自动保存 Finder 授权；需要 Finder 右键菜单时，可在下方单独设置。"

        guard AppModalPresentationGate.shared.present({ panel.runModal() }) == .OK else { return nil }
        return panel.url
    }

    static func chooseFinderAuthorizationFolder(startingAt directoryURL: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "保存 Finder 文件夹授权"
        panel.message = "仅保存所选文件夹及其子文件夹的 Finder 创建权限，不会创建文件。可在“诊断”中撤销。无需完全磁盘访问。"
        panel.prompt = "保存 Finder 授权"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directoryURL

        guard AppModalPresentationGate.shared.present({ panel.runModal() }) == .OK else { return nil }
        return panel.url
    }

    static func confirmFinderAuthorization(
        for request: FinderAuthorizationRequest,
        templateName: String?
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "授权并继续本次 Finder 创建"
        panel.message = "请核对下方请求及授权说明；较长内容可滚动查看。"
        panel.accessoryView = finderAuthorizationDetails(for: request, templateName: templateName)
        panel.isAccessoryViewDisclosed = true
        panel.prompt = "授权并创建"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = request.destinationFolder

        // The request pump owns the modal slot before navigation and this call.
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // Display only explicit request context, never template body, clipboard, bookmarks
    // or arbitrary file contents. Creation still reloads authoritative template data.
    static func finderAuthorizationMessage(
        for request: FinderAuthorizationRequest,
        templateName: String?
    ) -> String {
        let template = templateName
            ?? "模板 \(request.templateID.uuidString)（将重新确认是否可用）"
        return """
        模板：\(template)
        目标：\(request.destinationFolderPath)
        请求：\(request.id.uuidString)
        确认后会保存所选文件夹及其子文件夹的 Finder 授权，后续创建也可使用；可在“诊断”中撤销。随后只继续本次请求，创建一个文件。取消仅取消当前请求，并暂停自动确认；其他待处理请求（如有）未被取消，需在 QuickFile 中点击“继续处理”后再逐个确认。只授权你需要的文件夹范围。
        """
    }

    private static func finderAuthorizationDetails(
        for request: FinderAuthorizationRequest,
        templateName: String?
    ) -> NSScrollView {
        // NSOpenPanel.message truncates each explicit line. Keep the complete
        // target and cancellation scope readable without enlarging the panel
        // beyond the screen when a request contains a long path.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 220))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let details = NSTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        details.isEditable = false
        details.isSelectable = true
        details.drawsBackground = false
        details.isHorizontallyResizable = false
        details.isVerticallyResizable = true
        details.autoresizingMask = [.width]
        details.textContainerInset = NSSize(width: 4, height: 4)
        details.textContainer?.widthTracksTextView = true
        details.textContainer?.lineFragmentPadding = 0
        details.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        details.textColor = .labelColor
        details.string = finderAuthorizationMessage(for: request, templateName: templateName)
        details.setAccessibilityLabel("本次 Finder 请求和授权说明")
        scrollView.documentView = details
        if let container = details.textContainer, let layout = details.layoutManager {
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height) + 8
            details.setFrameSize(NSSize(width: scrollView.contentSize.width, height: height))
            scrollView.setFrameSize(NSSize(width: 560, height: min(220, max(80, height))))
        }
        return scrollView
    }

    static func chooseTemplateImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "导入 QuickFile 模板"
        panel.prompt = "预览导入"
        panel.message = "选择模板 JSON 文件。先查看并确认导入预览，不会立即修改现有模板。"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard AppModalPresentationGate.shared.present({ panel.runModal() }) == .OK else { return nil }
        return panel.url
    }

    static func chooseTemplateExportFile() -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出 QuickFile 模板"
        panel.prompt = "导出"
        panel.message = "导出模板配置，不会读取剪贴板，也不包含 Finder 文件夹授权。模板正文可能包含你自行写入的私人信息。"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "QuickFile-templates.json"
        panel.canCreateDirectories = true
        guard AppModalPresentationGate.shared.present({ panel.runModal() }) == .OK else { return nil }
        return panel.url
    }

    // Panels return a URL only. Callers start/stop security scope around their actual
    // selected-file read/write, and never hold it for the lifetime of a preview sheet.
    static func copyTemplateDraft(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func reveal(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    static func openFolder(_ folderURL: URL) -> Bool {
        // Ask Finder to open a location, never dispatch a replaced path as an executable/document.
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folderURL.path)
    }

    static func clipboardString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
