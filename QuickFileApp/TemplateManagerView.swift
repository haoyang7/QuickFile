import QuickFileCore
import QuickFileInfrastructure
import SwiftUI

private struct TemplateEditorPresentation: Identifiable {
    let id = UUID()
    let template: FileTemplate?
    var isCopy = false
}

private enum TemplateManagerConfirmation: Identifiable {
    case delete(FileTemplate.ID, String)
    case restoreDefaults
    case exportAll

    var id: Int {
        switch self {
        case .delete: return 0
        case .restoreDefaults: return 1
        case .exportAll: return 2
        }
    }
}

/// Window-local selection repair. All inputs describe the state after persistence
/// completes; never retain a template inventory across the asynchronous deletion.
enum TemplateManagerSelection {
    static func afterDeletion(
        of deletedID: FileTemplate.ID,
        succeeded: Bool,
        currentSelectionID: FileTemplate.ID?,
        firstVisibleID: FileTemplate.ID?
    ) -> FileTemplate.ID? {
        guard succeeded, currentSelectionID == deletedID else { return currentSelectionID }
        // Filters and inventory may have changed while saving. Deliberately pick
        // the first currently visible survivor, or nil when the list is empty.
        return firstVisibleID
    }
}

/// A retained tab must not present work completed for an earlier appearance.
struct TemplatePresentationLifetime {
    private(set) var token: UUID?

    mutating func activate() { if token == nil { token = UUID() } }
    mutating func deactivate() { token = nil }
    func accepts(_ token: UUID) -> Bool { self.token == token }
}

@MainActor
struct TemplateManagerView: View {
    @ObservedObject var viewModel: QuickFileViewModel
    @StateObject private var finderMenuSettings: FinderMenuSettingsViewModel
    @State private var selectedTemplateID: FileTemplate.ID?
    @State private var editorPresentation: TemplateEditorPresentation?
    @State private var importPreview: QuickFileViewModel.TemplateImportPreview?
    @State private var recoveryPreview: QuickFileViewModel.TemplateRecoveryPreview?
    @State private var confirmation: TemplateManagerConfirmation?
    @State private var search = ""
    @State private var enabledOnly = false
    @State private var reorderState = TemplateReorderState()
    @State private var presentationLifetime = TemplatePresentationLifetime()

    init(
        viewModel: QuickFileViewModel,
        finderMenuSettings: FinderMenuSettingsViewModel? = nil
    ) {
        self.viewModel = viewModel
        _finderMenuSettings = StateObject(
            // Standalone fixtures must never open production App Group storage.
            wrappedValue: finderMenuSettings ?? FinderMenuSettingsViewModel(load: { .all }, save: { _ in })
        )
    }

    private var visibleTemplates: [FileTemplate] {
        viewModel.filteredTemplates(search: search, enabledOnly: enabledOnly)
    }

    private var selectedTemplate: FileTemplate? {
        visibleTemplates.first { $0.id == selectedTemplateID }
    }

    private var templatesUnavailable: Bool {
        viewModel.templateLoadError != nil || viewModel.isLoadingTemplates || viewModel.isSavingTemplates
    }

    private var emptyListMessage: String {
        if viewModel.templateLoadError != nil {
            return "模板暂不可用，请按上方提示处理后重新加载。"
        }
        if viewModel.isLoadingTemplates { return "正在读取模板…" }
        if viewModel.templates.isEmpty { return "暂无模板。点击“新增”添加模板。" }
        if enabledOnly && !viewModel.templates.contains(where: \.isEnabled) {
            return "暂无启用的模板。取消“仅启用”以查看全部模板。"
        }
        return "没有匹配的模板。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            templateHeader

            HStack {
                TextField("搜索名称或扩展名", text: $search)
                    .textFieldStyle(.roundedBorder)
                Toggle("仅启用", isOn: $enabledOnly)
            }

            if let failure = viewModel.templateLoadFailure {
                templateRecoverySection(failure: failure)
            }

            List(selection: $selectedTemplateID) {
                if visibleTemplates.isEmpty {
                    Text(emptyListMessage)
                        .foregroundColor(.secondary)
                }
                ForEach(visibleTemplates) { template in
                    templateRow(template)
                }
            }
            .frame(minHeight: 100)
            .disabled(templatesUnavailable)

            selectedTemplateActions

            Divider()
            FinderMenuSettingsSection(viewModel: finderMenuSettings)

            if let backupURL = viewModel.recoveryBackupURL {
                HStack {
                    Text("恢复前状态的本地备份：\(backupURL.path)")
                        .font(.caption).textSelection(.enabled)
                    Button("显示备份") { AppKitFileActions.reveal(backupURL) }
                }
            }
            if viewModel.isLoadingTemplates { ProgressView("正在读取模板…") }
            if viewModel.isSavingTemplates { ProgressView("正在保存模板…") }
            statusView
        }
        .padding(24)
        .task { await finderMenuSettings.loadIfNeeded() }
        .onAppear {
            presentationLifetime.activate()
            if selectedTemplateID == nil { selectedTemplateID = viewModel.templates.first?.id }
        }
        .onDisappear {
            presentationLifetime.deactivate()
            importPreview = nil
            recoveryPreview = nil
            reorderState.cancel()
        }
        .onChange(of: search) { _ in reorderState.cancel() }
        .onChange(of: enabledOnly) { _ in reorderState.cancel() }
        .onChange(of: templatesUnavailable) { unavailable in
            if unavailable { reorderState.cancel() }
        }
        .sheet(item: $editorPresentation) { presentation in
            TemplateEditorView(template: presentation.template, isCopy: presentation.isCopy, onSaveAsNew: { draft in
                selectedTemplateID = try await viewModel.saveTemplateAsNew(draft)
            }) { template in
                if presentation.isCopy {
                    selectedTemplateID = try await viewModel.saveTemplateAsNew(template)
                } else {
                    try await viewModel.saveTemplate(template, replacing: presentation.template)
                    selectedTemplateID = template.id
                }
            }
        }
        .sheet(item: $importPreview) { preview in
            TemplateTransferPreviewView(
                title: "导入模板预览", explanation: "确认后追加到现有模板末尾，保留原模板与排序。重复项将跳过。",
                templates: preview.plan.additions.map(\.template),
                renamedNames: Dictionary(uniqueKeysWithValues: preview.plan.additions.filter(\.wasRenamed).map { ($0.id, $0.originalName) }),
                skippedCount: preview.plan.skippedCount, clipboardCount: preview.clipboardCount,
                isRecovery: false
            ) { try await viewModel.importTemplates(preview) }
        }
        .sheet(item: $recoveryPreview) { preview in
            TemplateTransferPreviewView(
                title: preview.title, explanation: preview.explanation,
                templates: preview.templates, renamedNames: [:], skippedCount: 0,
                clipboardCount: preview.clipboardCount, isRecovery: true,
                confirmationActionTitle: preview.confirmationActionTitle
            ) { try await viewModel.recoverTemplates(preview) }
        }
        .alert(item: $confirmation) { action in
            switch action {
            case let .delete(id, name):
                return Alert(title: Text("删除“\(name)”？"), message: Text("删除后 Finder 菜单也会移除此模板。"),
                    primaryButton: .destructive(Text("删除")) {
                        Task {
                            let succeeded = await viewModel.deleteTemplate(withID: id)
                            selectedTemplateID = TemplateManagerSelection.afterDeletion(
                                of: id,
                                succeeded: succeeded,
                                currentSelectionID: selectedTemplateID,
                                firstVisibleID: visibleTemplates.first?.id
                            )
                        }
                    }, secondaryButton: .cancel())
            case .restoreDefaults:
                return Alert(title: Text("恢复默认模板？"),
                    message: Text("当前自定义模板和排序会被 6 个内置模板替换。"),
                    primaryButton: .destructive(Text("恢复")) {
                        let selection = selectedTemplateID
                        Task {
                            if await viewModel.restoreBuiltInTemplates(), selectedTemplateID == selection {
                                selectedTemplateID = viewModel.templates.first?.id
                            }
                        }
                    }, secondaryButton: .cancel())
            case .exportAll:
                return Alert(title: Text("导出全部模板？"),
                    message: Text("导出包含全部启用和停用模板、当前顺序与原始正文。正文可能含有个人信息或密钥，请谨慎选择本地保存位置。变量不会展开，也不会读取剪贴板；不包含目录授权或历史记录。"),
                    primaryButton: .default(Text("选择保存位置…")) {
                        guard let url = AppKitFileActions.chooseTemplateExportFile() else { return }
                        Task { try? await viewModel.exportTemplates(to: url) }
                    }, secondaryButton: .cancel())
            }
        }
    }

    private var templateHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("模板管理").font(.title2).fontWeight(.semibold)
                Text("管理用于创建文件的模板。")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("新增") { editorPresentation = TemplateEditorPresentation(template: nil) }
                .disabled(templatesUnavailable)
            templateActionsMenu
                .disabled(templatesUnavailable)
        }
    }

    private var selectedTemplateActions: some View {
        HStack(spacing: 10) {
            Button("编辑") { editSelected() }.disabled(selectedTemplate == nil)
            Button("复制") {
                if let id = selectedTemplate?.id { copyTemplate(withID: id) }
            }.disabled(selectedTemplate == nil)
            Button("删除") {
                if let selectedTemplate { confirmation = .delete(selectedTemplate.id, selectedTemplate.name) }
            }.disabled(selectedTemplate == nil)
            Divider().frame(height: 16)
            Button("上移") { moveSelected(offset: -1) }
                .disabled(!viewModel.canMoveTemplate(withID: selectedTemplate?.id, offset: -1))
                .help("在完整模板列表中上移")
            Button("下移") { moveSelected(offset: 1) }
                .disabled(!viewModel.canMoveTemplate(withID: selectedTemplate?.id, offset: 1))
                .help("在完整模板列表中下移")
            Spacer()
            Text("显示 \(visibleTemplates.count) / 共 \(viewModel.templates.count) 个模板")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .disabled(templatesUnavailable)
    }

    private var templateActionsMenu: some View {
        Menu("更多") {
            Button("导入模板…", action: chooseImport)
            Button("导出全部模板…") { confirmation = .exportAll }
            Divider()
            Button("移至顶部") { moveSelected(to: .first) }
                .disabled(!viewModel.canMoveTemplate(withID: selectedTemplate?.id, offset: -1))
            Button("移至底部") { moveSelected(to: .last) }
                .disabled(!viewModel.canMoveTemplate(withID: selectedTemplate?.id, offset: 1))
            Divider()
            Button("恢复默认模板…", role: .destructive) { confirmation = .restoreDefaults }
        }
        .fixedSize()
        .accessibilityLabel("更多模板操作")
    }

    private func templateRecoverySection(failure: QuickFileViewModel.TemplateLoadFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("重新加载模板") { Task { await viewModel.reloadTemplates() } }
                if let recoveryTitle = failure.recoveryActionTitle {
                    Menu(recoveryTitle) {
                        Button("从默认模板恢复…") { prepareRecovery() }
                        Button("从模板备份文件恢复…", action: chooseRecoveryBackup)
                    }
                    .fixedSize()
                }
            }
            .disabled(viewModel.isLoadingTemplates || viewModel.isSavingTemplates)
        }
    }

    private func templateRow(_ template: FileTemplate) -> some View {
        // Deferred row callbacks need only these values, not the template body.
        // Keep the displayed name for delete confirmation; editing resolves the ID afresh.
        let id = template.id
        let name = template.name
        let isEnabled = template.isEnabled
        return HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .accessibilityLabel("拖动排序“\(name)”")
                .help("拖动调整顺序，也可使用下方的上移和下移按钮")
                .onDrag { beginReorder(withID: id) }
            Toggle("", isOn: Binding(get: { isEnabled }, set: { enabled in
                Task { await viewModel.setTemplateEnabled(enabled, id: id) }
            }))
            .labelsHidden()
            .accessibilityLabel("启用模板“\(name)”")
            .help(isEnabled ? "在创建菜单中停用" : "在创建菜单中启用")
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                Text(template.content.isEmpty ? "不预填内容" : contentSummary(template.content))
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if let label = extensionLabel(template.fileExtension) {
                Text(label).font(.system(.body, design: .monospaced)).foregroundColor(.secondary)
            }
        }
        .tag(id)
        .contentShape(Rectangle())
        .overlay(alignment: .top) { insertionIndicator(for: id, placement: .before) }
        .overlay(alignment: .bottom) { insertionIndicator(for: id, placement: .after) }
        .onDrop(of: [TemplateReorderState.typeIdentifier], delegate: TemplateRowDropDelegate(
            viewModel: viewModel, state: $reorderState, targetID: id
        ))
        // SwiftUI's row gesture can consume List's native selection click on macOS.
        // Select explicitly; simultaneous recognition preserves the row's Toggle.
        .simultaneousGesture(TapGesture().onEnded { selectedTemplateID = id })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard let current = viewModel.template(withID: id) else { return }
            selectedTemplateID = id
            editorPresentation = TemplateEditorPresentation(template: current)
        })
        .contextMenu {
            Button("编辑") {
                guard let current = viewModel.template(withID: id) else { return }
                selectedTemplateID = id
                editorPresentation = TemplateEditorPresentation(template: current)
            }
            Button("复制") { copyTemplate(withID: id) }
            Button("删除") { confirmation = .delete(id, name) }
        }
    }

    private func editSelected() {
        guard let selectedTemplate else { return }
        editorPresentation = TemplateEditorPresentation(template: selectedTemplate)
    }

    private func copyTemplate(withID id: FileTemplate.ID) {
        guard !templatesUnavailable, let source = viewModel.template(withID: id) else { return }
        selectedTemplateID = id
        editorPresentation = TemplateEditorPresentation(template: source, isCopy: true)
    }

    private func beginReorder(withID id: FileTemplate.ID) -> NSItemProvider {
        guard !templatesUnavailable else { return NSItemProvider() }
        let payload = reorderState.begin(sourceID: id)
        let provider = NSItemProvider()
        // The payload is an opaque, window-local token, never template text.
        provider.registerDataRepresentation(forTypeIdentifier: TemplateReorderState.typeIdentifier, visibility: .ownProcess) {
            completion in
            completion(payload, nil)
            return nil
        }
        selectedTemplateID = id
        return provider
    }

    @ViewBuilder
    private func insertionIndicator(for id: UUID, placement: QuickFileViewModel.TemplatePlacement) -> some View {
        if reorderState.destination?.targetID == id, reorderState.destination?.placement == placement {
            Rectangle().fill(Color.accentColor).frame(height: 2)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func moveSelected(offset: Int) {
        guard let id = selectedTemplate?.id else { return }
        Task { _ = await viewModel.moveTemplate(withID: id, offset: offset) }
    }

    private func moveSelected(to position: QuickFileViewModel.TemplatePosition) {
        guard let id = selectedTemplate?.id else { return }
        Task { _ = await viewModel.moveTemplate(withID: id, to: position) }
    }

    private func chooseImport() {
        guard let token = presentationLifetime.token,
              let url = AppKitFileActions.chooseTemplateImportFile(),
              presentationLifetime.accepts(token) else { return }
        Task {
            guard presentationLifetime.accepts(token) else { return }
            let preview = try? await viewModel.prepareTemplateImport(from: url)
            guard presentationLifetime.accepts(token) else { return }
            importPreview = preview
        }
    }

    private func chooseRecoveryBackup() {
        guard let token = presentationLifetime.token,
              let url = AppKitFileActions.chooseTemplateImportFile(),
              presentationLifetime.accepts(token) else { return }
        prepareRecovery(from: url, appearance: token)
    }

    private func prepareRecovery(from url: URL? = nil, appearance: UUID? = nil) {
        guard let token = appearance ?? presentationLifetime.token,
              presentationLifetime.accepts(token) else { return }
        Task {
            guard presentationLifetime.accepts(token) else { return }
            let preview = try? await viewModel.prepareTemplateRecovery(from: url)
            guard presentationLifetime.accepts(token) else { return }
            recoveryPreview = preview
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let status = viewModel.status {
            switch status {
            case let .success(message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            case let .failure(message):
                // Load failures already have visible recovery actions and bounded details.
                // Preserve any different operation failure while recovery is available.
                if message != viewModel.templateLoadError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }

    private func extensionLabel(_ fileExtension: String) -> String? {
        let normalizedExtension = fileExtension.trimmingCharacters(
            in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines)
        )
        guard !normalizedExtension.isEmpty else {
            return nil
        }
        return ".\(normalizedExtension)"
    }

    private func contentSummary(_ content: String) -> String {
        TemplateContentPreview.summary(content)
    }
}

/// Small window-local drag state. Hovering never retains or mutates the library.
struct TemplateReorderState {
    static let typeIdentifier = "com.haoyoung.QuickFile.template-order"

    struct Session {
        let token: UUID
        let sourceID: UUID
    }
    struct Destination: Equatable {
        let targetID: UUID
        let placement: QuickFileViewModel.TemplatePlacement
    }
    struct Drop {
        let session: Session
        let destination: Destination
    }
    private(set) var active: Session?
    private(set) var destination: Destination?
    private(set) var pending: Drop?

    mutating func begin(sourceID: UUID) -> Data {
        cancel()
        let session = Session(token: UUID(), sourceID: sourceID)
        active = session
        return Data(session.token.uuidString.utf8)
    }

    mutating func hover(targetID: UUID, placement: QuickFileViewModel.TemplatePlacement) {
        guard let active, active.sourceID != targetID else {
            destination = nil
            return
        }
        destination = Destination(targetID: targetID, placement: placement)
    }

    mutating func leave(targetID: UUID) {
        if destination?.targetID == targetID { destination = nil }
    }

    mutating func stage() -> Drop? {
        guard let active, let destination else { return nil }
        let drop = Drop(session: active, destination: destination)
        pending = drop
        self.active = nil
        self.destination = nil
        return drop
    }

    mutating func finish(token: UUID, payload: Data?) -> Drop? {
        guard let pending, pending.session.token == token else { return nil }
        self.pending = nil
        guard payload == Data(token.uuidString.utf8) else { return nil }
        return pending
    }

    mutating func cancel() {
        active = nil
        destination = nil
        pending = nil
    }
}

@MainActor
private struct TemplateRowDropDelegate: DropDelegate {
    let viewModel: QuickFileViewModel
    @Binding var state: TemplateReorderState
    let targetID: UUID

    private var available: Bool {
        viewModel.templateLoadError == nil && !viewModel.isLoadingTemplates && !viewModel.isSavingTemplates
    }

    func validateDrop(info: DropInfo) -> Bool {
        available && state.active != nil && info.hasItemsConforming(to: [TemplateReorderState.typeIdentifier])
    }

    private func updateDestination() {
        guard available, let sourceID = state.active?.sourceID,
              let sourceIndex = viewModel.templates.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = viewModel.templates.firstIndex(where: { $0.id == targetID }) else {
            state.leave(targetID: targetID)
            return
        }
        state.hover(targetID: targetID, placement: sourceIndex < targetIndex ? .after : .before)
    }

    func dropEntered(info: DropInfo) { updateDestination() }
    func dropExited(info: DropInfo) { state.leave(targetID: targetID) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: [TemplateReorderState.typeIdentifier])
        guard providers.count == 1 else { return false }
        updateDestination()
        guard let drop = state.stage() else { return false }
        providers[0].loadDataRepresentation(forTypeIdentifier: TemplateReorderState.typeIdentifier) { payload, error in
            Task { @MainActor in
                guard let accepted = state.finish(token: drop.session.token, payload: error == nil ? payload : nil),
                      available else { return }
                _ = await viewModel.moveTemplate(
                    withID: accepted.session.sourceID,
                    relativeTo: accepted.destination.targetID,
                    placement: accepted.destination.placement
                )
            }
        }
        return true
    }
}
