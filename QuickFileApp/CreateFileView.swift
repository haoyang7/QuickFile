import QuickFileCore
import QuickFileInfrastructure
import SwiftUI

struct CreateFileView: View {
    @ObservedObject var viewModel: QuickFileViewModel
    @ObservedObject var finderIntegrationViewModel: FinderIntegrationViewModel
    var showTemplateManager: () -> Void = {}
    @State private var showsSavedAuthorizations = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let error = viewModel.templateLoadError {
                    Text(error).foregroundColor(.red)
                    Button("重新加载模板") { Task { await viewModel.reloadTemplates() } }
                        .disabled(viewModel.isLoadingTemplates || viewModel.isSavingTemplates)
                }
                if viewModel.isLoadingTemplates { ProgressView("正在加载模板…") }
                destinationSection
                fileSection
                actionSection
                Divider()
                finderIntegrationSection
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .task { await finderIntegrationViewModel.refreshAuthorizedDirectories() }
    }

    private var header: some View {
        Text("新建文件")
            .font(.title2)
            .fontWeight(.semibold)
    }

    private var hasActiveFinderVerification: Bool {
        switch finderIntegrationViewModel.verificationState {
        case .preparing, .awaitingCreation, .creationReported, .responseUnavailable:
            return true
        default:
            return false
        }
    }

    private var showsFinderVerificationFeedback: Bool {
        finderIntegrationViewModel.verificationState != .idle
            && finderIntegrationViewModel.verificationState != .confirmed
    }

    private var finderIntegrationSection: some View {
        let setup = finderIntegrationViewModel.setupPresentation(
            hasDestination: viewModel.destinationFolder != nil,
            authorization: viewModel.finderAuthorizationState,
            hasTemplates: !viewModel.enabledTemplates.isEmpty && viewModel.templateLoadError == nil
        )
        let showsCurrentConfirmation = finderIntegrationViewModel.isCurrentVerificationConfirmed
            && setup.action == .startVerification
        return VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $finderIntegrationViewModel.isGuideExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if !showsFinderVerificationFeedback {
                        setupActionRow(setup, isConfirmed: showsCurrentConfirmation)
                        Text(setup.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(finderIntegrationViewModel.guideHistoryText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        Text("当前：\(finderIntegrationViewModel.statusText)")
                            .foregroundColor(.secondary)
                        Spacer()
                        Menu("扩展帮助") {
                            Button("检查扩展响应") { Task { await finderIntegrationViewModel.refresh() } }
                                .disabled(finderIntegrationViewModel.isRefreshing)
                            Button("打开扩展设置…") { finderIntegrationViewModel.openManagement() }
                        }
                        .fixedSize()
                    }
                    .font(.caption)
                }
                .padding(.top, 8)
            } label: {
                Label("Finder 右键菜单设置（可选）", systemImage: "puzzlepiece.extension")
            }

            // The optional guide can collapse, but an active verification keeps
            // its current step, continuation and cancellation controls visible.
            if showsFinderVerificationFeedback {
                setupActionRow(setup, isConfirmed: false)
                Text(setup.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if hasActiveFinderVerification {
                    Button("取消本次验证") { finderIntegrationViewModel.cancelUserVerification() }
                }
            } else if showsCurrentConfirmation && !finderIntegrationViewModel.isGuideExpanded {
                Label(setup.message, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
    }

    private func setupActionRow(
        _ setup: FinderIntegrationViewModel.SetupPresentation,
        isConfirmed: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Label(setup.message, systemImage: isConfirmed ? "checkmark.circle" : "info.circle")
                .foregroundColor(isConfirmed ? .green : .primary)
            Spacer()
            if setup.action != .none {
                Button(setup.actionTitle) { performSetupAction(setup.action) }
                    .disabled(viewModel.isBusy || finderIntegrationViewModel.isVerificationOperationInFlight)
            }
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("文件夹")
                    .frame(width: 60, alignment: .leading)
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                    Text(viewModel.destinationFolder?.path ?? "尚未选择文件夹")
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundColor(viewModel.destinationFolder == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(viewModel.destinationFolder?.path ?? "选择用于创建文件的文件夹")
                }

                Button {
                    chooseDestinationFolder()
                } label: {
                    if viewModel.isAuthorizingDirectory {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在检查…")
                        }
                    } else {
                        Text("选择文件夹…")
                    }
                }
                .disabled(viewModel.isBusy)
                .help("选择后即可在这里创建文件；不会自动保存 Finder 授权。")
            }

            DisclosureGroup("使用已保存的文件夹授权", isExpanded: $showsSavedAuthorizations) {
                savedAuthorizationMenu
                    .padding(.top, 6)
            }
            .font(.caption)
            .padding(.leading, 72)
        }
    }

    private var savedAuthorizationMenu: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Menu("选择已授权文件夹") {
                    ForEach(finderIntegrationViewModel.authorizedDirectories) { directory in
                        Button(directory.url.path + (directory.isBookmarkStale ? "（需重新授权）" : "")) {
                            finderIntegrationViewModel.cancelVerification()
                            Task { await viewModel.selectAuthorizedDirectory(directory) }
                        }
                        .disabled(directory.isBookmarkStale)
                    }
                }
                .disabled(viewModel.isBusy
                    || finderIntegrationViewModel.authorizedDirectories.isEmpty
                    || finderIntegrationViewModel.authorizationInventoryState != .loaded)
                Button("刷新列表") {
                    Task { await finderIntegrationViewModel.refreshAuthorizedDirectories() }
                }
                .disabled(finderIntegrationViewModel.authorizationInventoryState == .loading || viewModel.isBusy)
                if finderIntegrationViewModel.authorizationInventoryState == .loading {
                    ProgressView().controlSize(.small)
                }
            }
            Group {
                switch finderIntegrationViewModel.authorizationInventoryState {
                case .idle:
                    Text("可刷新已保存的授权列表。")
                case .loading:
                    Text("正在读取已保存的文件夹授权…")
                case .busy:
                    Text("其他窗口正在检查授权；本次未开始读取，请稍后刷新。")
                case let .failed(message):
                    Text("授权列表读取失败：\(message)")
                case .loaded:
                    if finderIntegrationViewModel.authorizedDirectories.isEmpty {
                        Text("暂无可用的已保存授权，可直接选择文件夹。")
                    } else {
                        Text("已保存授权在选择和创建时都会重新检查；列表不保证权限仍然有效。")
                    }
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            if finderIntegrationViewModel.unavailableAuthorizationCount > 0 {
                Text("另有 \(finderIntegrationViewModel.unavailableAuthorizationCount) 个授权不可用，可在“诊断”中管理。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text("选择文件夹不会自动保存 Finder 授权；新增授权需在下方 Finder 设置中明确确认。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("模板")
                    .frame(width: 60, alignment: .leading)
                Picker("模板", selection: $viewModel.selectedTemplateID) {
                    ForEach(viewModel.enabledTemplates) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)

                if viewModel.enabledTemplates.isEmpty {
                    Text("请先在“模板管理”中启用模板")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                Text("文件名")
                    .frame(width: 60, alignment: .leading)
                TextField(defaultFilenameHint, text: $viewModel.requestedFilename)
                    .accessibilityLabel("文件名")
                    .onSubmit {
                        guard viewModel.canCreate else { return }
                        Task { await viewModel.createFile() }
                    }
                if !viewModel.extensionHint.isEmpty {
                    Text(viewModel.extensionHint)
                        .foregroundColor(.secondary)
                        .frame(minWidth: 48, alignment: .leading)
                }
            }

            Text("文件名留空时使用模板默认名称；未设置则使用“未命名”。按模板补齐扩展名，重名时添加序号。")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 72)
        }
    }

    private var defaultFilenameHint: String {
        let filename = viewModel.selectedTemplate?.defaultFilename ?? ""
        return filename.isEmpty ? "未命名" : filename
    }

    private var actionSection: some View {
        let status = statusPresentation
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    Task {
                        await viewModel.createFile()
                    }
                } label: {
                    if viewModel.isCreatingFile {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在创建…")
                        }
                    } else {
                        Text("创建文件")
                    }
                }
                .disabled(!viewModel.canCreate)

                Button("在 Finder 中显示") {
                    if let createdFileURL = viewModel.createdFileURL {
                        AppKitFileActions.reveal(createdFileURL)
                    }
                }
                .disabled(viewModel.createdFileURL == nil || viewModel.isBusy)

                Spacer()
            }

            // Keep result controls alive across attempts so accessibility observers
            // do not have to be destroyed and recreated for every result.
            Label(status.message, systemImage: status.image)
                .foregroundColor(status.color)
        }
    }

    private var statusPresentation: (message: String, image: String, color: Color) {
        switch viewModel.status {
        case let .success(message):
            return (message, "checkmark.circle.fill", .green)
        case let .failure(message):
            return (message, "exclamationmark.triangle.fill", .red)
        case nil:
            return (
                viewModel.isBusy ? "正在处理…" : "选择目标文件夹和模板后即可创建文件。",
                "info.circle",
                .secondary
            )
        }
    }

    private func chooseDestinationFolder() {
        Task {
            await viewModel.selectDestinationFolder(choosing: {
                let folder = AppKitFileActions.chooseDestinationFolder(startingAt: viewModel.destinationFolder)
                if folder != nil { finderIntegrationViewModel.cancelVerification() }
                return folder
            })
        }
    }

    private func performSetupAction(_ action: FinderIntegrationViewModel.SetupAction) {
        switch action {
        case .openSettings:
            finderIntegrationViewModel.openManagement()
        case .refreshStatus:
            Task { await finderIntegrationViewModel.refresh() }
        case .chooseFolder:
            chooseDestinationFolder()
        case .saveAuthorization:
            Task {
                let attemptedSave = await viewModel.saveFinderAuthorization(choosing: {
                    let folder = AppKitFileActions.chooseFinderAuthorizationFolder(startingAt: viewModel.destinationFolder)
                    if folder != nil { finderIntegrationViewModel.cancelVerification() }
                    return folder
                })
                if attemptedSave { await finderIntegrationViewModel.refreshAuthorizedDirectories() }
            }
        case .manageTemplates:
            showTemplateManager()
        case .startVerification:
            guard let folder = viewModel.destinationFolder else { return }
            Task { await finderIntegrationViewModel.startVerification(in: folder) }
        case .checkVerification:
            Task { await finderIntegrationViewModel.checkVerification() }
        case .openFolder:
            if let folder = viewModel.destinationFolder { finderIntegrationViewModel.openSelectedFolder(folder) }
        case .confirmVisible:
            Task { await finderIntegrationViewModel.confirmVisibleFile() }
        case .none: break
        }
    }
}
