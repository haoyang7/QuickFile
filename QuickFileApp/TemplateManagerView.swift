import AppKit
import QuickFileCore
import QuickFileInfrastructure
import SwiftUI

struct TemplateEditorPresentation: Identifiable {
    let id = UUID()
    let template: FileTemplate?
    var isCopy = false
}

enum TemplateManagerConfirmation: Identifiable {
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
/// completes; never retain a template inventory across an asynchronous mutation.
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

    static func afterRestore(
        succeeded: Bool,
        originalSelectionID: FileTemplate.ID?,
        currentSelectionID: FileTemplate.ID?,
        visibleIDs: [FileTemplate.ID]
    ) -> FileTemplate.ID? {
        guard succeeded, currentSelectionID == originalSelectionID else { return currentSelectionID }
        if let currentSelectionID, visibleIDs.contains(currentSelectionID) { return currentSelectionID }
        return visibleIDs.first
    }
}

/// A retained tab must not present work completed for an earlier appearance.
struct TemplatePresentationLifetime {
    private(set) var token: UUID?

    mutating func activate() { if token == nil { token = UUID() } }
    mutating func deactivate() { token = nil }
    func accepts(_ token: UUID) -> Bool { self.token == token }
}

/// Owned by one window and shared with its route receiver. Preparation spans the
/// native picker and asynchronous read so there is no idle gap before a preview.
@MainActor
final class TemplateModalPresentation: NSObject, ObservableObject {
    @Published var editorPresentation: TemplateEditorPresentation?
    @Published var importPreview: QuickFileViewModel.TemplateImportPreview?
    @Published var recoveryPreview: QuickFileViewModel.TemplateRecoveryPreview?
    @Published var confirmation: TemplateManagerConfirmation?
    @Published private var preparations: Set<UUID> = []
    private weak var owner: NSWindow?

    var isActive: Bool {
        editorPresentation != nil || importPreview != nil || recoveryPreview != nil
            || confirmation != nil || !preparations.isEmpty
    }

    func beginPreparation(for owner: NSWindow? = nil) -> UUID {
        if let owner, self.owner !== owner {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: self.owner)
            invalidateTransferPresentations()
            self.owner = owner
            NotificationCenter.default.addObserver(self, selector: #selector(ownerWillClose),
                name: NSWindow.willCloseNotification, object: owner)
        }
        let token = UUID()
        preparations.insert(token)
        return token
    }

    func acceptsPreparation(_ token: UUID) -> Bool { preparations.contains(token) }

    func finishPreparation(_ token: UUID) { preparations.remove(token) }

    @objc private func ownerWillClose(_ notification: Notification) {
        // A retained hosting controller may not disappear before this same
        // window reopens. Revoke old operation identities synchronously, before
        // a worker can resume or SwiftUI can enqueue its completed preview.
        invalidateTransferPresentations()
    }

    private func invalidateTransferPresentations() {
        preparations.removeAll()
        importPreview = nil
        recoveryPreview = nil
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

@MainActor
struct TemplateManagerView: View {
    @Environment(\.locale) private var quickFileLocale
    @ObservedObject var viewModel: QuickFileViewModel
    @StateObject private var finderMenuSettings: FinderMenuSettingsViewModel
    @State private var selectedTemplateID: FileTemplate.ID?
    @StateObject private var presentation: TemplateModalPresentation
    @State private var search = ""
    @State private var enabledOnly = false
    @State private var reorderState = TemplateReorderState()
    @State private var presentationLifetime = TemplatePresentationLifetime()
    private let presentationWindow: @MainActor () -> NSWindow?

    init(
        viewModel: QuickFileViewModel,
        finderMenuSettings: FinderMenuSettingsViewModel? = nil,
        presentation: TemplateModalPresentation? = nil,
        presentationWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow }
    ) {
        self.viewModel = viewModel
        self.presentationWindow = presentationWindow
        _presentation = StateObject(wrappedValue: presentation ?? TemplateModalPresentation())
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
            return QuickFileLocalization.text(.init("模板暂不可用，请按上方提示处理后重新加载。"))
        }
        if viewModel.isLoadingTemplates { return QuickFileLocalization.text(.init("正在读取模板…")) }
        if viewModel.templates.isEmpty { return QuickFileLocalization.text(.init("暂无模板。点击“新增”添加模板。")) }
        if enabledOnly && !viewModel.templates.contains(where: \.isEnabled) {
            return QuickFileLocalization.text(.init("暂无启用的模板。取消“仅启用”以查看全部模板。"))
        }
        return QuickFileLocalization.text(.init("没有匹配的模板。"))
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
            if viewModel.isLoadingTemplates { ProgressView(QuickFileLocalization.text(.init("正在读取模板…"))) }
            if viewModel.isSavingTemplates { ProgressView(QuickFileLocalization.text(.init("正在保存模板…"))) }
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
            presentation.importPreview = nil
            presentation.recoveryPreview = nil
            reorderState.cancel()
        }
        .onChange(of: search) { _ in reorderState.cancel() }
        .onChange(of: enabledOnly) { _ in reorderState.cancel() }
        .onChange(of: templatesUnavailable) { unavailable in
            if unavailable { reorderState.cancel() }
        }
        .sheet(item: $presentation.editorPresentation) { presentation in
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
        .sheet(item: $presentation.importPreview) { preview in
            TemplateTransferPreviewView(
                title: QuickFileLocalization.text(.init("导入模板预览")), explanation: QuickFileLocalization.text(.init("确认后追加到现有模板末尾，保留原模板与排序。重复项将跳过。")),
                templates: preview.plan.additions.map(\.template),
                renamedNames: Dictionary(uniqueKeysWithValues: preview.plan.additions.filter(\.wasRenamed).map { ($0.id, $0.originalName) }),
                skippedCount: preview.plan.skippedCount, clipboardCount: preview.clipboardCount,
                isRecovery: false
            ) { try await viewModel.importTemplates(preview) }
        }
        .sheet(item: $presentation.recoveryPreview) { preview in
            TemplateTransferPreviewView(
                title: preview.title, explanation: preview.explanation,
                templates: preview.templates, renamedNames: [:], skippedCount: 0,
                clipboardCount: preview.clipboardCount, isRecovery: true,
                confirmationActionTitle: preview.confirmationActionTitle
            ) { try await viewModel.recoverTemplates(preview) }
        }
        .alert(item: $presentation.confirmation) { action in
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
                    message: Text("当前自定义模板和排序会被 \(BuiltInTemplates.all.count) 个内置模板替换。"),
                    primaryButton: .destructive(Text("恢复")) {
                        let selection = selectedTemplateID
                        Task {
                            let succeeded = await viewModel.restoreBuiltInTemplates()
                            selectedTemplateID = TemplateManagerSelection.afterRestore(
                                succeeded: succeeded,
                                originalSelectionID: selection,
                                currentSelectionID: selectedTemplateID,
                                visibleIDs: visibleTemplates.map(\.id)
                            )
                        }
                    }, secondaryButton: .cancel())
            case .exportAll:
                return Alert(title: Text("导出全部模板？"),
                    message: Text("导出包含全部启用和停用模板、当前顺序与原始正文。正文可能含有个人信息或密钥，请谨慎选择本地保存位置。变量不会展开，也不会读取剪贴板；不包含目录授权或历史记录。"),
                    primaryButton: .default(Text("选择保存位置…")) {
                        chooseExport()
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
            Button("新增") { presentation.editorPresentation = TemplateEditorPresentation(template: nil) }
                .buttonStyle(.borderedProminent)
                .disabled(templatesUnavailable)
            templateActionsMenu
                .disabled(templatesUnavailable)
        }
    }

    private var selectedTemplateActions: some View {
        AdaptiveActionRow {
            HStack(spacing: 8) {
                Button("编辑") { editSelected() }.disabled(selectedTemplate == nil)
                Button("复制") {
                    if let id = selectedTemplate?.id { copyTemplate(withID: id) }
                }.disabled(selectedTemplate == nil)
                Button("删除") {
                    if let selectedTemplate { presentation.confirmation = .delete(selectedTemplate.id, selectedTemplate.displayName) }
                }.disabled(selectedTemplate == nil)
            }
            HStack(spacing: 8) {
                Button("上移") { moveSelected(offset: -1) }
                    .disabled(!viewModel.canMoveTemplate(withID: selectedTemplate?.id, offset: -1))
                    .help(QuickFileLocalization.text(.init("在完整模板列表中上移")))
                Button("下移") { moveSelected(offset: 1) }
                    .disabled(!viewModel.canMoveTemplate(withID: selectedTemplate?.id, offset: 1))
                    .help(QuickFileLocalization.text(.init("在完整模板列表中下移")))
            }
            Text("显示 \(visibleTemplates.count) / 共 \(viewModel.templates.count) 个模板")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .disabled(templatesUnavailable)
    }

    private var templateActionsMenu: some View {
        Menu(QuickFileLocalization.text(.init("更多"))) {
            Button("重新加载模板") { viewModel.requestTemplateReload() }
            Divider()
            Button("导入模板…", action: chooseImport)
            Button("导出全部模板…") { presentation.confirmation = .exportAll }
            Divider()
            Button("移至顶部") { moveSelected(to: .first) }
                .disabled(!viewModel.canMoveTemplate(withID: selectedTemplate?.id, offset: -1))
            Button("移至底部") { moveSelected(to: .last) }
                .disabled(!viewModel.canMoveTemplate(withID: selectedTemplate?.id, offset: 1))
            Divider()
            Button("恢复默认模板…", role: .destructive) { presentation.confirmation = .restoreDefaults }
            if let directory = viewModel.templateStorageDirectoryURL {
                Divider()
                // Marker/lock permissions can prevent saves while reads still succeed.
                Button("修复存储权限…", action: repairStoragePermissions)
                    .disabled(viewModel.isBusy)
                Button("在 Finder 中显示存储文件夹") { AppKitFileActions.reveal(directory) }
            }
        }
        .fixedSize()
        .accessibilityLabel(QuickFileLocalization.text(.init("更多模板操作")))
    }

    private func templateRecoverySection(failure: QuickFileViewModel.TemplateLoadFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
            AdaptiveActionRow {
                Button("重新加载模板") { viewModel.requestTemplateReload() }
                if let recoveryTitle = failure.recoveryActionTitle {
                    Menu(recoveryTitle) {
                        Button("从默认模板恢复…") { prepareRecovery() }
                        Button("从模板备份文件恢复…", action: chooseRecoveryBackup)
                    }
                    .fixedSize()
                }
                if failure == .permissionDenied, viewModel.templateStorageDirectoryURL != nil {
                    Button("修复存储权限…", action: repairStoragePermissions)
                        .disabled(viewModel.isBusy)
                }
                if let directory = viewModel.templateStorageDirectoryURL {
                    Button("在 Finder 中显示存储文件夹") { AppKitFileActions.reveal(directory) }
                        .help("无法自动恢复时，请保留现有文件。在 Finder 的“显示简介 → 共享与权限”中检查当前用户的读写权限，或取回原始配置，再重新加载。")
                }
            }
            .disabled(viewModel.isLoadingTemplates || viewModel.isSavingTemplates)
        }
    }

    private func repairStoragePermissions() {
        guard AppKitFileActions.confirmStoragePermissionRepair() else { return }
        Task { await viewModel.repairTemplateStoragePermissions() }
    }

    private func templateRow(_ template: FileTemplate) -> some View {
        // Deferred row callbacks need only these values, not the template body.
        // Keep the displayed name for delete confirmation; editing resolves the ID afresh.
        let id = template.id
        let name = template.displayName
        let isEnabled = template.isEnabled
        return HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .accessibilityLabel(QuickFileLocalization.text(.init("拖动排序“\(name)”")))
                .help(QuickFileLocalization.text(.init("拖动调整顺序，也可使用下方的上移和下移按钮")))
                .onDrag { beginReorder(withID: id) }
            Toggle("", isOn: Binding(get: { isEnabled }, set: { enabled in
                Task { await viewModel.setTemplateEnabled(enabled, id: id) }
            }))
            .labelsHidden()
            .accessibilityLabel(QuickFileLocalization.text(.init("启用模板“\(name)”")))
            .help(isEnabled ? QuickFileLocalization.text(.init("在创建菜单中停用")) : QuickFileLocalization.text(.init("在创建菜单中启用")))
            VStack(alignment: .leading, spacing: 2) {
                Text(template.displayName)
                Text(template.officeFormat?.blankDocumentDescription
                     ?? (template.content.isEmpty ? QuickFileLocalization.text(.init("不预填内容")) : contentSummary(template.content)))
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
            presentation.editorPresentation = TemplateEditorPresentation(template: current)
        })
        .contextMenu {
            Button("编辑") {
                guard let current = viewModel.template(withID: id) else { return }
                selectedTemplateID = id
                presentation.editorPresentation = TemplateEditorPresentation(template: current)
            }
            Button("复制") { copyTemplate(withID: id) }
            Button("删除") { presentation.confirmation = .delete(id, name) }
        }
    }

    private func editSelected() {
        guard let selectedTemplate else { return }
        presentation.editorPresentation = TemplateEditorPresentation(template: selectedTemplate)
    }

    private func copyTemplate(withID id: FileTemplate.ID) {
        guard !templatesUnavailable, let source = viewModel.template(withID: id) else { return }
        selectedTemplateID = id
        presentation.editorPresentation = TemplateEditorPresentation(template: source, isCopy: true)
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

    private func chooseExport() {
        guard let token = presentationLifetime.token, let owner = presentationWindow() else { return }
        let preparation = presentation.beginPreparation(for: owner)
        Task {
            defer { presentation.finishPreparation(preparation) }
            guard presentationLifetime.accepts(token), presentation.acceptsPreparation(preparation),
                  let url = await AppKitFileActions.chooseTemplateExportFile(for: owner),
                  presentationLifetime.accepts(token), presentation.acceptsPreparation(preparation) else { return }
            try? await viewModel.exportTemplates(to: url)
        }
    }

    private func chooseImport() {
        guard let token = presentationLifetime.token, let owner = presentationWindow() else { return }
        let preparation = presentation.beginPreparation(for: owner)
        Task {
            defer { presentation.finishPreparation(preparation) }
            guard presentationLifetime.accepts(token), presentation.acceptsPreparation(preparation),
                  let url = await AppKitFileActions.chooseTemplateImportFile(for: owner),
                  presentationLifetime.accepts(token), presentation.acceptsPreparation(preparation) else { return }
            let preview = try? await viewModel.prepareTemplateImport(from: url)
            guard presentationLifetime.accepts(token), presentation.acceptsPreparation(preparation) else { return }
            presentation.importPreview = preview
        }
    }

    private func chooseRecoveryBackup() {
        guard let token = presentationLifetime.token, let owner = presentationWindow() else { return }
        let preparation = presentation.beginPreparation(for: owner)
        Task {
            defer { presentation.finishPreparation(preparation) }
            guard presentationLifetime.accepts(token), presentation.acceptsPreparation(preparation),
                  let url = await AppKitFileActions.chooseTemplateImportFile(for: owner),
                  presentationLifetime.accepts(token), presentation.acceptsPreparation(preparation) else { return }
            prepareRecovery(from: url, appearance: token)
        }
    }

    private func prepareRecovery(from url: URL? = nil, appearance: UUID? = nil) {
        guard let token = appearance ?? presentationLifetime.token,
              presentationLifetime.accepts(token), let owner = presentationWindow() else { return }
        let preparation = presentation.beginPreparation(for: owner)
        Task {
            defer { presentation.finishPreparation(preparation) }
            guard presentationLifetime.accepts(token), presentation.acceptsPreparation(preparation) else { return }
            let preview = try? await viewModel.prepareTemplateRecovery(from: url)
            guard presentationLifetime.accepts(token), presentation.acceptsPreparation(preparation) else { return }
            presentation.recoveryPreview = preview
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
