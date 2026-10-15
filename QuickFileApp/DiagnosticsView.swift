import AppKit
import FinderSync
import QuickFileCore
import QuickFileInfrastructure
import SwiftUI

struct DiagnosticsView: View {
    @Environment(\.locale) private var quickFileLocale
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: DiagnosticsViewModel
    @State private var isManagingDirectories = false
    @State private var showsDirectoryTest = false
    @State private var showsAdvancedDetails = false

    init(viewModel: DiagnosticsViewModel? = nil) {
        _viewModel = StateObject(
            wrappedValue: viewModel ?? DiagnosticsViewModel(
                extensionEnabledProvider: { FIFinderSyncController.isExtensionEnabled }
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                finderExtensionSection
                authorizedDirectoriesSection
                directorySection
                advancedDetailsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $isManagingDirectories) {
            AuthorizationManagementView(viewModel: viewModel, addDirectory: chooseAuthorizedDirectory)
        }
        .task {
            await viewModel.refreshRuntimeStatus()
        }
        .onAppear { viewModel.directoryDiagnosticsDidAppear() }
        .onDisappear { viewModel.directoryDiagnosticsDidDisappear() }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                Task {
                    await viewModel.refreshRuntimeStatus()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("诊断")
                .font(.title2)
                .fontWeight(.semibold)
            Text("检查 Finder 状态与文件夹权限")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    private var identifiersSection: some View {
        GroupBox(label: Label("工程标识", systemImage: "signature")) {
            VStack(alignment: .leading, spacing: 8) {
                DiagnosticValueRow(
                    title: "App Bundle ID",
                    value: Bundle.main.bundleIdentifier ?? QuickFileLocalization.text(.init("未知"))
                )
                DiagnosticValueRow(
                    title: "Finder Extension",
                    value: embeddedExtensionIdentifiersText
                )
                DiagnosticValueRow(
                    title: QuickFileLocalization.text(.init("共享存储类型")),
                    value: QuickFileStorageMode.current.displayName + QuickFileLocalization.text(.init("（主应用与 Finder 扩展共用）"))
                )

                if QuickFileConfiguration.usesPlaceholderIdentifiers {
                    Label(
                        "当前仍使用 com.example 占位标识；Finder 扩展启用和共享存储结果不能作为发布验证。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundColor(.orange)
                } else {
                    Label(
                        "工程标识已配置；请结合当前扩展状态和活动记录验证签名与共享存储访问。",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundColor(.green)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var embeddedExtensionIdentifiersText: String {
        viewModel.extensionSnapshot.map { snapshot in
            snapshot.embeddedIdentifiers.isEmpty
                ? (snapshot.embeddingKnown ? QuickFileLocalization.text(.init("未发现嵌入扩展")) : QuickFileLocalization.text(.init("无法读取")))
                : snapshot.embeddedIdentifiers.joined(separator: ", ")
        } ?? QuickFileLocalization.text(.init("检测中"))
    }

    private var finderExtensionSection: some View {
        GroupBox(label: Label("当前 Finder 状态", systemImage: "puzzlepiece.extension")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: viewModel.extensionSnapshot?.state == .responding ? "checkmark.circle.fill" : "questionmark.circle.fill")
                        .foregroundColor(viewModel.extensionSnapshot?.state == .responding ? .green : .secondary)
                    Text(viewModel.extensionSnapshot?.state.displayName
                         ?? (viewModel.isRefreshingRuntimeStatus ? QuickFileLocalization.text(.init("正在检查…")) : QuickFileLocalization.text(.init("尚未检测"))))
                    Spacer()
                }

                Text("响应仅确认当前安装版本的扩展收到检查请求，不代表目录可写；未响应也不等于崩溃。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let guidance = viewModel.extensionSnapshot?.state.recoveryGuidance {
                    Text(guidance)
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if viewModel.hasLoadedActivityStoreStatus {
                    DiagnosticBooleanRow(title: QuickFileLocalization.text(.init("共享存储可用")), value: viewModel.isSharedStoreAvailable)
                } else if viewModel.isRefreshingRuntimeStatus {
                    DiagnosticValueRow(title: QuickFileLocalization.text(.init("共享存储")), value: QuickFileLocalization.text(.init("正在检查…")))
                } else {
                    DiagnosticValueRow(title: QuickFileLocalization.text(.init("共享存储")), value: QuickFileLocalization.text(.init("尚未检测")))
                }

                HStack {
                    Button("刷新状态") {
                        Task {
                            await viewModel.refreshRuntimeStatus()
                        }
                    }
                    .disabled(viewModel.isRefreshingRuntimeStatus)
                    Button("打开扩展管理…") {
                        FIFinderSyncController.showExtensionManagementInterface()
                    }
                    Button("复制诊断摘要") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(viewModel.diagnosticSummary, forType: .string)
                    }
                    .help(QuickFileLocalization.text(.init("仅复制状态、标识和计数，不含路径、错误原文、书签或模板内容。")))
                    ProgressView()
                        .controlSize(.small)
                        .opacity(viewModel.isRefreshingRuntimeStatus ? 1 : 0)
                        .accessibilityHidden(!viewModel.isRefreshingRuntimeStatus)
                    Spacer()
                }

                if let message = viewModel.runtimeStatusMessage {
                    Label(message, systemImage: "hourglass")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let activityStoreMessage = viewModel.activityStoreMessage {
                    Label(
                        activityStoreMessage,
                        systemImage: viewModel.activityStoreHasError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .foregroundColor(viewModel.activityStoreHasError ? .red : .green)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var advancedDetailsSection: some View {
        DisclosureGroup(QuickFileLocalization.text(.init("高级技术详情")), isExpanded: $showsAdvancedDetails) {
            VStack(alignment: .leading, spacing: 12) {
                identifiersSection
                extensionTechnicalRecordsSection
            }
            .padding(.top, 10)
        }
    }

    private var extensionTechnicalRecordsSection: some View {
        GroupBox(label: Label("扩展技术记录", systemImage: "list.bullet.rectangle")) {
            VStack(alignment: .leading, spacing: 10) {
                if let snapshot = viewModel.extensionSnapshot {
                    DiagnosticValueRow(title: QuickFileLocalization.text(.init("注册证据")), value: snapshot.registrationEvidence)
                }
                Text("响应仅说明当前安装路径及版本的扩展收到探针；未响应可能是旧版扩展仍在运行、扩展尚未运行、主线程忙或系统限制，不能据此判定崩溃。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let extensionActivity = viewModel.extensionActivity {
                    DiagnosticValueRow(
                        title: QuickFileLocalization.text(.init("最近活动（历史）")),
                        value: QuickFileLocalization.text(.init("\(extensionActivity.kind.displayName) · \(formattedTimestamp(extensionActivity.timestamp))"))
                    )
                    if let failure = extensionActivity.failure {
                        DiagnosticValueRow(title: QuickFileLocalization.text(.init("失败类别")), value: failure.reason.displayName)
                    }
                } else {
                    DiagnosticValueRow(title: QuickFileLocalization.text(.init("最近活动（历史）")), value: QuickFileLocalization.text(.init("尚未收到活动记录")))
                }
                Text("活动记录不代表当前健康状态。最近失败最多保留 20 条、14 天，不包含操作路径或文件名。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !viewModel.recentExtensionFailures.isEmpty {
                    Text("最近失败记录（\(viewModel.recentExtensionFailures.count)）")
                        .font(.headline)
                    ForEach(Array(viewModel.recentExtensionFailures.enumerated()), id: \.offset) { _, activity in
                        recentFailureRow(activity)
                    }
                }
                HStack {
                    Button("打开 Console…") { openConsole() }
                    if !viewModel.recentExtensionFailures.isEmpty || viewModel.activityStoreHasError {
                        Button("清空失败历史") {
                            Task { await viewModel.clearFailureHistory() }
                        }
                        .disabled(viewModel.isRefreshingRuntimeStatus)
                    }
                    Spacer()
                }
                Text("详细日志由 macOS 统一日志管理；可在 Console 中按子系统 com.haoyoung.QuickFile 筛选。诊断摘要不包含路径、错误原文、书签或模板内容。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    private var authorizationCount: Int {
        viewModel.authorizedDirectories.count + viewModel.unavailableAuthorizedDirectories.count
    }

    private var authorizationsNeedingAttention: Int {
        viewModel.unavailableAuthorizedDirectories.count
            + viewModel.authorizedDirectories.filter { $0.isBookmarkStale }.count
    }

    private var authorizedDirectoriesSection: some View {
        GroupBox(label: Label("文件夹授权", systemImage: "folder.badge.gearshape")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(authorizationCount == 0 ? QuickFileLocalization.text(.init("尚未保存 Finder 目录授权")) : QuickFileLocalization.text(.init("已保存 \(authorizationCount) 个目录授权")))
                        .foregroundColor(.secondary)
                    if authorizationsNeedingAttention > 0 {
                        Label("\(authorizationsNeedingAttention) 个需处理", systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    if viewModel.isManagingAuthorizations {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(QuickFileLocalization.text(.init("正在更新授权")))
                    }
                }

                HStack {
                    Button("添加授权目录…") {
                        chooseAuthorizedDirectory()
                    }
                    .disabled(viewModel.isManagingAuthorizations || viewModel.isRefreshingRuntimeStatus || viewModel.isLoadingAuthorizationInventory)

                    Button("管理授权…") {
                        isManagingDirectories = true
                    }

                    Menu("存储修复") {
                        Button("修复授权记录权限…") {
                            Task {
                                await viewModel.repairAuthorizationPermissions {
                                    AppKitFileActions.confirmStoragePermissionRepair(details: QuickFileLocalization.text(.init("将本地共享目录及授权记录、迁移标记和锁文件恢复为仅当前用户可读写。不会删除、替换或解析书签。链接、所有者异常或目录身份变化时停止，失败时可能已调整部分权限。")))
                                }
                            }
                        }
                        .disabled(viewModel.isManagingAuthorizations || viewModel.isLoadingAuthorizationInventory)
                        if let url = viewModel.authorizationStorageURL {
                            Button("在 Finder 中显示存储目录") { AppKitFileActions.reveal(url) }
                        }
                    }

                    ProgressView()
                        .controlSize(.small)
                        .opacity(viewModel.isLoadingAuthorizationInventory ? 1 : 0)
                        .accessibilityLabel(QuickFileLocalization.text(.init("正在刷新目录授权列表…")))
                        .accessibilityHidden(!viewModel.isLoadingAuthorizationInventory)

                    Spacer()
                }

                Text("Finder 只在明确授权的目录及其子目录中写入；创建时也可按提示授权。授权仅保存在本机，不会上传。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !viewModel.unavailableAuthorizedDirectories.isEmpty {
                    Text("不可用授权可能来自离线磁盘。可在“管理授权”中移除记录，不会删除文件；若无其他有效授权覆盖，再次使用时需重新授权。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let message = viewModel.authorizationInventoryMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                if let authorizationMessage = viewModel.authorizationMessage {
                    Label(
                        authorizationMessage,
                        systemImage: viewModel.authorizationHasError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .foregroundColor(viewModel.authorizationHasError ? .red : .green)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var directorySection: some View {
        DisclosureGroup(isExpanded: $showsDirectoryTest) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("选择文件夹并测试…") {
                        chooseFolderAndRunDiagnostics()
                    }
                    .disabled(viewModel.isInspectingDirectory)

                    if viewModel.isInspectingDirectory {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在诊断…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                if let message = viewModel.directoryInspectionMessage {
                    Label(message, systemImage: "hourglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let report = viewModel.report {
                    Divider()
                    DiagnosticValueRow(title: QuickFileLocalization.text(.init("路径")), value: report.folderURL.path)
                    DiagnosticValueRow(title: QuickFileLocalization.text(.init("位置类型")), value: report.storageDescription)
                    DiagnosticValueRow(title: QuickFileLocalization.text(.init("卷名称")), value: report.volumeName ?? QuickFileLocalization.text(.init("未知")))
                    DiagnosticOptionalBooleanRow(title: QuickFileLocalization.text(.init("路径存在")), value: report.existenceKnown ? report.exists : nil, unknownLabel: QuickFileLocalization.text(.init("无法确定")))
                    DiagnosticOptionalBooleanRow(title: QuickFileLocalization.text(.init("是文件夹")), value: report.existenceKnown ? report.isDirectory : nil, unknownLabel: QuickFileLocalization.text(.init("无法确定")))
                    DiagnosticBooleanRow(title: QuickFileLocalization.text(.init("FileManager 可写")), value: report.isWritableByFileManager)
                    DiagnosticOptionalBooleanRow(title: QuickFileLocalization.text(.init("实际写入探针")), value: report.writeProbeSucceeded)
                    DiagnosticOptionalBooleanRow(title: QuickFileLocalization.text(.init("只读卷")), value: report.volumeIsReadOnly, inverted: true)

                    if report.issues.isEmpty {
                        Label("未发现目录写入问题。", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(report.issues, id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label("测试文件夹写入（可选）", systemImage: "externaldrive.badge.checkmark")
                    if viewModel.isInspectingDirectory {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(QuickFileLocalization.text(.init("正在诊断所选文件夹")))
                    }
                }
                Text("测试会在所选文件夹中创建一个隐藏临时文件并立即删除，用于验证真实写入权限。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func recentFailureRow(_ activity: FinderExtensionActivity) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.failure.map(failureDescription) ?? activity.kind.displayName)
                Text(formattedTimestamp(activity.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func openConsole() {
        viewModel.openConsole {
            guard let consoleURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Console"
            ) else {
                return false
            }
            return NSWorkspace.shared.open(consoleURL)
        }
    }

    private func formattedTimestamp(_ timestamp: Date) -> String {
        timestamp.formatted(date: .numeric, time: .standard)
    }

    private func failureDescription(_ failure: FinderExtensionActivityFailure) -> String {
        guard let errorDomain = failure.errorDomain, let errorCode = failure.errorCode else {
            return failure.reason.displayName
        }

        return "\(failure.reason.displayName)（\(errorDomain) \(errorCode)）"
    }

    private func chooseFolderAndRunDiagnostics() {
        let panel = NSOpenPanel()
        panel.title = QuickFileLocalization.text(.init("选择要诊断的文件夹"))
        panel.prompt = QuickFileLocalization.text(.init("测试此文件夹"))
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard AppModalPresentationGate.shared.present({ panel.runModal() }) == .OK, let folderURL = panel.url else {
            return
        }

        viewModel.startDirectoryInspection(folderURL)
    }

    private func chooseAuthorizedDirectory() {
        let panel = NSOpenPanel()
        panel.title = QuickFileLocalization.text(.init("授权 Finder Extension 可写目录"))
        panel.message = QuickFileLocalization.text(.init("QuickFile Finder Extension 将能够在所选目录及其子目录中创建文件。"))
        panel.prompt = QuickFileLocalization.text(.init("授权"))
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard AppModalPresentationGate.shared.present({ panel.runModal() }) == .OK, let directoryURL = panel.url else {
            return
        }

        Task {
            await viewModel.authorizeDirectory(directoryURL)
        }
    }
}

enum AuthorizationListFilter: String, CaseIterable {
    case all, needsAttention

    var title: String {
        switch self {
        case .all: return QuickFileLocalization.text(.init("全部"))
        case .needsAttention: return QuickFileLocalization.text(.init("需处理"))
        }
    }

    func matches(_ directory: AuthorizedDirectory, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (self == .all || directory.isBookmarkStale)
            && (query.isEmpty || directory.url.path.localizedStandardContains(query))
    }

    func matches(_ directory: UnavailableAuthorizedDirectory, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || QuickFileLocalization.text(.init("授权暂不可用")).localizedStandardContains(query)
            || directory.id.uuidString.localizedStandardContains(query)
    }
}

private struct AuthorizationManagementView: View {
    @Environment(\.locale) private var quickFileLocale
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: DiagnosticsViewModel
    let addDirectory: () -> Void
    @State private var search = ""
    @State private var filter = AuthorizationListFilter.all

    private var directories: [AuthorizedDirectory] {
        viewModel.authorizedDirectories.filter { filter.matches($0, search: search) }
    }

    private var unavailableDirectories: [UnavailableAuthorizedDirectory] {
        viewModel.unavailableAuthorizedDirectories.filter { filter.matches($0, search: search) }
    }

    private var resultCount: Int { directories.count + unavailableDirectories.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Finder 写入授权").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("授权覆盖所选目录及其子目录。移除只针对所选记录，不会删除文件；若另有同目录或父目录授权，该位置仍可能可写。重叠记录不会自动合并或移除。")
                .font(.caption).foregroundColor(.secondary)

            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("搜索目录名称或路径", text: $search)
                        .textFieldStyle(.plain)
                        .accessibilityLabel(QuickFileLocalization.text(.init("搜索已授权目录")))
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(QuickFileLocalization.text(.init("清除目录搜索")))
                    }
                }
                .padding(7)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Picker("授权状态", selection: $filter) {
                    ForEach(AuthorizationListFilter.allCases, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            HStack {
                Button("添加授权目录…", action: addDirectory)
                    .disabled(viewModel.isManagingAuthorizations || viewModel.isRefreshingRuntimeStatus || viewModel.isLoadingAuthorizationInventory)
                if !viewModel.unavailableAuthorizedDirectories.isEmpty {
                    Button("移除不可用授权（\(viewModel.unavailableAuthorizedDirectories.count)）") {
                        Task { await viewModel.revokeUnavailableAuthorizations() }
                    }
                    .disabled(viewModel.isManagingAuthorizations)
                    .help(QuickFileLocalization.text(.init("清理全部当前仍不可用的授权记录，不受搜索或筛选影响；不删除文件。")))
                }
                Spacer()
                if viewModel.isManagingAuthorizations {
                    ProgressView().controlSize(.small).accessibilityLabel(QuickFileLocalization.text(.init("正在更新授权")))
                }
                Text("\(resultCount) / \(viewModel.authorizedDirectories.count + viewModel.unavailableAuthorizedDirectories.count) 个目录")
                    .font(.caption).foregroundColor(.secondary)
            }

            List {
                ForEach(unavailableDirectories) { directory in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("授权暂不可用", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            DisclosureGroup(QuickFileLocalization.text(.init("记录详情"))) {
                                Text("记录标识：\(directory.id.uuidString)")
                                    .font(.caption).foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("移除") {
                            Task { await viewModel.revokeAuthorization(directory.id) }
                        }
                        .disabled(viewModel.isManagingAuthorizations)
                        .accessibilityLabel(QuickFileLocalization.text(.init("移除不可用授权 \(directory.id.uuidString)")))
                    }
                    .padding(.vertical, 5)
                }
                ForEach(directories) { directory in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(directory.url.lastPathComponent.isEmpty ? directory.url.path : directory.url.lastPathComponent,
                                  systemImage: "folder")
                                .fontWeight(.medium)
                            Text(directory.url.path)
                                .font(.caption).foregroundColor(.secondary)
                                .lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled).help(directory.url.path)
                            if directory.isBookmarkStale {
                                Label("授权需要更新，请重新添加此目录。", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundColor(.orange)
                            } else {
                                Text("该目录及其子目录已授权")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("移除") {
                            Task { await viewModel.revokeAuthorization(directory.id) }
                        }
                        .disabled(viewModel.isManagingAuthorizations)
                        .accessibilityLabel(QuickFileLocalization.text(.init("移除目录授权 \(directory.url.path)")))
                    }
                    .padding(.vertical, 5)
                }
            }
            .listStyle(.inset)
            .overlay {
                if resultCount == 0 {
                    VStack(spacing: 8) {
                        Image(systemName: "folder").font(.title).foregroundColor(.secondary)
                        Text(viewModel.authorizedDirectories.isEmpty && viewModel.unavailableAuthorizedDirectories.isEmpty
                             ? QuickFileLocalization.text(.init("尚未添加目录授权")) : QuickFileLocalization.text(.init("没有符合条件的授权")))
                        Text("可添加目录，或调整搜索与筛选条件。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .allowsHitTesting(false)
                }
            }

            if viewModel.isLoadingAuthorizationInventory {
                Label("正在刷新目录授权列表…", systemImage: "hourglass")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let message = viewModel.authorizationInventoryMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
            if let message = viewModel.authorizationMessage {
                Label(message, systemImage: viewModel.authorizationHasError
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(viewModel.authorizationHasError ? .orange : .green)
            }
        }
        .padding(20)
        .frame(width: 660, height: 500)
    }
}

private struct DiagnosticValueRow: View {
    @Environment(\.locale) private var quickFileLocale
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundColor(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DiagnosticBooleanRow: View {
    @Environment(\.locale) private var quickFileLocale
    let title: String
    let value: Bool

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
                .frame(width: 150, alignment: .leading)
            Label(value ? QuickFileLocalization.text(.init("是")) : QuickFileLocalization.text(.init("否")), systemImage: value ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(value ? .green : .red)
            Spacer()
        }
    }
}

private struct DiagnosticOptionalBooleanRow: View {
    @Environment(\.locale) private var quickFileLocale
    let title: String
    let value: Bool?
    var inverted = false
    var unknownLabel = QuickFileLocalization.text(.init("未测试"))

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
                .frame(width: 150, alignment: .leading)

            if let value {
                let isPositive = inverted ? !value : value
                Label(value ? QuickFileLocalization.text(.init("是")) : QuickFileLocalization.text(.init("否")), systemImage: isPositive ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isPositive ? .green : .red)
            } else {
                Label(unknownLabel, systemImage: "minus.circle")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}
