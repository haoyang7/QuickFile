import QuickFileCore
import SwiftUI

@MainActor
struct TemplateEditorView: View {
    @Environment(\.locale) private var quickFileLocale
    @Environment(\.presentationMode) private var presentationMode
    @State private var editor: TemplateEditorState
    @StateObject private var preview = TemplatePreviewController()
    @State private var confirmsDiscard = false
    @State private var showsVariableHelp = false

    private let isEditing: Bool
    private let isCopy: Bool
    private let onSave: (FileTemplate) async throws -> Void
    private let onSaveAsNew: ((FileTemplate) async throws -> Void)?
    private let copyDraft: @MainActor (String) -> Void

    init(
        template: FileTemplate?,
        isCopy: Bool = false,
        onSaveAsNew: ((FileTemplate) async throws -> Void)? = nil,
        copyDraft: @escaping @MainActor (String) -> Void = { AppKitFileActions.copyTemplateDraft($0) },
        onSave: @escaping (FileTemplate) async throws -> Void
    ) {
        _editor = State(initialValue: TemplateEditorState(template: template, isCopy: isCopy))
        isEditing = template != nil && !isCopy
        self.isCopy = isCopy
        self.onSave = onSave
        self.onSaveAsNew = onSaveAsNew
        self.copyDraft = copyDraft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isCopy ? QuickFileLocalization.text(.init("复制模板")) : (isEditing ? QuickFileLocalization.text(.init("编辑模板")) : QuickFileLocalization.text(.init("新增模板"))))
                    .font(.title2)
                    .fontWeight(.semibold)
                if editor.isDirty { Text("未保存").font(.caption).foregroundColor(.secondary) }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isCopy {
                        Text("保存后新增一个模板；取消将丢弃本次副本。")
                            .font(.callout).foregroundColor(.secondary)
                    }
                    templateFields

                    if editor.draft.officeFormat == nil {
                        DisclosureGroup(QuickFileLocalization.text(.init("可用变量")), isExpanded: $showsVariableHelp) {
                            Text("{{date}}、{{time}}、{{year}}、{{folderName}}、{{clipboard}}、{{sequence}}")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                    }

                    if let message = editor.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(editor.didCopyDraft ? QuickFileLocalization.text(.init("已复制草稿")) : QuickFileLocalization.text(.init("复制草稿"))) {
                                editor.copyDraft(using: copyDraft)
                            }
                            if editor.offersConflictRecovery, onSaveAsNew != nil {
                                Button("另存为新模板") { Task { await save(asNew: true) } }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("取消", action: requestDismissal)
                    .keyboardShortcut(.cancelAction)
                Button("保存") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(editor.isSaving)
        // Escape uses the Cancel action; implicit dismissal cannot discard a dirty draft.
        .interactiveDismissDisabled(editor.isSaving || editor.isDirty)
        .overlay { if editor.isSaving { ProgressView(QuickFileLocalization.text(.init("正在保存…"))) } }
        .alert(QuickFileLocalization.text(.init("放弃未保存的修改？")), isPresented: $confirmsDiscard) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃修改", role: .destructive) {
                guard !editor.isSaving else { return }
                presentationMode.wrappedValue.dismiss()
            }
        } message: {
            Text("当前草稿将被丢弃，已保存的模板不会更改。")
        }
        .padding(24)
        .frame(width: 580, height: 580)
        .onAppear { preview.activate() }
        .onDisappear { preview.deactivate() }
        .onChange(of: quickFileLocale) { _ in preview.invalidate() }
    }

    // Invalidate at the actual write boundary. String onChange would miss
    // canonically equivalent edits whose UTF-8 bytes differ.
    private var draftBinding: Binding<TemplateDraft> {
        Binding(get: { editor.draft }, set: { draft in
            preview.invalidate()
            editor.draft = draft
        })
    }

    private var templateFields: some View {
        Form {
            VStack(alignment: .leading, spacing: 4) {
                TextField("模板名称", text: draftBinding.name)
                capacityHint(TemplateEditorCapacityGuidance.name)
            }
            if let format = editor.draft.officeFormat {
                Text("文件扩展名：.\(format.rawValue)")
                capacityHint(QuickFileLocalization.text(.init("创建\(format.blankDocumentDescription)。创建后可在对应的 Office 应用中编辑内容。")))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("文件扩展名（可选）", text: draftBinding.fileExtension)
                    capacityHint(QuickFileLocalization.text(.init("留空时不追加扩展名。")) + " " + TemplateEditorCapacityGuidance.fileExtension)
                }
            }
            Toggle("在创建菜单中启用", isOn: draftBinding.isEnabled)
            VStack(alignment: .leading, spacing: 4) {
                TextField("默认文件名（可选）", text: draftBinding.defaultFilename)
                capacityHint(QuickFileLocalization.text(.init("未输入本次名称时使用；留空则使用“未命名”。按原文使用，不展开变量。")))
                capacityHint(TemplateEditorCapacityGuidance.defaultFilename)
            }
            if editor.draft.officeFormat == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("初始内容（可留空）")
                    TextEditor(text: draftBinding.content)
                        .accessibilityLabel(QuickFileLocalization.text(.init("初始内容（可留空）")))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                        .border(Color.secondary.opacity(0.3))
                    capacityHint(TemplateEditorCapacityGuidance.content)
                }
                previewSection
            }
            capacityHint(TemplateEditorCapacityGuidance.collection)
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("预览内容") {
                    preview.request(content: editor.draft.content, fileExtension: editor.draft.fileExtension)
                }
                .disabled(preview.isWorking)
                if preview.isWorking { ProgressView(QuickFileLocalization.text(.init("正在生成示例…"))).controlSize(.small) }
                if preview.result != nil {
                    Button("收起预览") { preview.invalidate() }
                }
            }
            capacityHint(QuickFileLocalization.text(.init("使用 2026-01-01 12:00:00（UTC）、示例文件夹、示例剪贴板和序号 1。修改草稿后可重新预览。")))
            if preview.busyElsewhere {
                capacityHint(QuickFileLocalization.text(.init("另一个预览正在处理，请稍后重试。")))
            }
            if let result = preview.result {
                switch result {
                case let .success(output):
                    if output.text.isEmpty {
                        Text("示例内容为空。")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            Text(verbatim: output.text)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(height: 160)
                        .border(Color.secondary.opacity(0.3))
                        .accessibilityLabel(QuickFileLocalization.text(.init("模板示例内容")))
                    }
                    if output.jsonStatus != .nonJSON {
                        Text(output.jsonStatus == .valid ? QuickFileLocalization.text(.init("示例结果是有效 JSON。")) : QuickFileLocalization.text(.init("示例结果不是有效 JSON，请检查语法和变量所在位置。")))
                            .font(.caption)
                            .foregroundColor(output.jsonStatus == .valid ? .secondary : .orange)
                        capacityHint(QuickFileLocalization.text(.init("实际变量值可能不同；此提示不影响保存。")))
                    }
                case let .failure(error):
                    Text(previewErrorMessage(error))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func previewErrorMessage(_ error: TemplatePreviewError) -> String {
        switch error {
        case .inputTooLarge: return QuickFileLocalization.text(.init("正文超过 64 KiB，未生成预览；保存仍使用原有容量限制。"))
        case .fileExtensionTooLarge: return QuickFileLocalization.text(.init("扩展名超过 255 字节，请缩短后重新预览。"))
        case .outputTooLarge: return QuickFileLocalization.text(.init("示例展开结果超过 128 KiB，未生成预览；未截取部分内容。"))
        case .renderingFailed: return QuickFileLocalization.text(.init("无法生成示例，请修改后重试。"))
        }
    }

    private func capacityHint(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func requestDismissal() {
        switch editor.requestDismissal() {
        case .dismiss: presentationMode.wrappedValue.dismiss()
        case .confirmDiscard: confirmsDiscard = true
        case .blocked: break
        }
    }

    private func save(asNew: Bool = false) async {
        guard editor.beginSave() else { return }
        preview.invalidate()
        do {
            let template = try editor.makeTemplate()
            if asNew, let onSaveAsNew {
                try await onSaveAsNew(template)
            } else {
                try await onSave(template)
            }
            editor.finishSave()
            presentationMode.wrappedValue.dismiss()
        } catch {
            editor.finishSave(error: error)
        }
    }
}

/// Static save guidance shares the store's default transfer budgets. It never
/// inspects a draft or adds a per-keystroke body count, and is not a paste limit.
enum TemplateEditorCapacityGuidance {
    private static let limits = TemplateTransferLimits.default

    static var name: String { QuickFileLocalization.text(.init("名称保存上限：\(limits.maximumNameBytes) UTF-8 字节")) }
    static var defaultFilename: String { QuickFileLocalization.text(.init("默认文件名保存上限：\(limits.maximumNameBytes) UTF-8 字节")) }
    static var fileExtension: String { QuickFileLocalization.text(.init("扩展名保存上限：\(limits.maximumExtensionBytes) UTF-8 字节")) }
    static var content: String { QuickFileLocalization.text(.init("正文保存上限：\(byteLimit(limits.maximumContentBytes))（按 UTF-8 字节计算，非字符数）")) }
    static var collection: String { QuickFileLocalization.text(.init("整库保存另有 \(limits.maximumTemplates) 个模板及 \(byteLimit(limits.maximumFileBytes)) 的备份格式编码上限（含 JSON 转义）。历史超限配置仍可按原规则删除、排序、启停或逐步缩减修复。")) }

    private static func byteLimit(_ bytes: Int) -> String {
        let mebibyte = 1024 * 1024
        return bytes % mebibyte == 0 ? "\(bytes / mebibyte) MiB" : QuickFileLocalization.text(.init("\(bytes) 字节"))
    }
}
