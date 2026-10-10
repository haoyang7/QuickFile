import Combine
import Foundation
import QuickFileCore
import QuickFileInfrastructure

@MainActor
protocol FinderVerificationClient: AnyObject {
    func begin(in identity: DirectoryIdentity, timeout: TimeInterval) async -> FinderFirstUseVerificationStatus
    func check(timeout: TimeInterval) async -> FinderFirstUseVerificationStatus
    func cancel()
}

extension FinderFirstUseVerification: FinderVerificationClient {}

@MainActor
final class FinderIntegrationViewModel: ObservableObject {
    enum VerificationState: Equatable {
        case idle, preparing, awaitingCreation, creationReported, confirmed, unavailable, responseUnavailable, expired, cancelled
        case destinationUnavailable
    }

    enum SetupAction: Equatable {
        case openSettings, refreshStatus, chooseFolder, saveAuthorization, manageTemplates, startVerification, checkVerification, openFolder, confirmVisible, none
    }

    struct SetupPresentation: Equatable {
        let message: String
        let detail: String
        let action: SetupAction
        let actionTitle: String
    }

    /// Only guide history is persisted. Runtime response, authorization and receipts
    /// are deliberately absent, so relaunching cannot restore a "ready" result.
    struct GuidePreferences {
        var loadCompleted: () -> Bool = { false }
        var saveCompleted: (Bool) -> Void = { _ in }

        static var live: GuidePreferences {
            let key = "finder.firstUseGuideCompleted.v1"
            return GuidePreferences(
                loadCompleted: { UserDefaults.standard.bool(forKey: key) },
                saveCompleted: { UserDefaults.standard.set($0, forKey: key) }
            )
        }
    }

    enum AuthorizationInventoryState: Equatable {
        case idle, loading, loaded, busy
        case failed(String)
    }

    @Published private(set) var hasCompletedGuide: Bool
    @Published var isGuideExpanded: Bool
    @Published private(set) var authorizedDirectories: [AuthorizedDirectory] = []
    @Published private(set) var unavailableAuthorizationCount = 0
    @Published private(set) var authorizationInventoryState: AuthorizationInventoryState = .idle
    @Published private(set) var isEnabled: Bool
    @Published private(set) var snapshot: FinderExtensionDiagnosticSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var verificationState: VerificationState = .idle
    @Published private(set) var isCheckingVerification = false
    @Published private(set) var isVerificationOperationInFlight = false

    private let guidePreferences: GuidePreferences
    private let authorizationInventoryLoader: @Sendable () throws -> AuthorizedDirectoryInventory
    private let inventoryReadGate: DiagnosticsInventoryReadGate
    private let statusProvider: () -> Bool
    private let runtimeProvider: (Bool) async -> FinderExtensionDiagnosticSnapshot
    private let managementOpener: () -> Void
    private let verificationClientProvider: () async -> (any FinderVerificationClient)?
    private let directoryIdentityProvider: @Sendable (URL) throws -> DirectoryIdentity
    private let folderOpener: (URL) -> Bool
    private var verificationClient: (any FinderVerificationClient)?
    private var verificationFolder: URL?
    private var verificationGeneration: UInt64 = 0
    private var visibleWindows: Set<UUID> = []

    convenience init() {
        self.init(
            statusProvider: { FinderIntegrationAdapter.isEnabled },
            runtimeProvider: { await FinderExtensionRuntimeInspector.snapshot(enabled: $0) },
            managementOpener: { FinderIntegrationAdapter.openManagement() },
            verificationClientProvider: {
                let installation = await BackgroundWork.run { FinderExtensionInstallationInspector.inspect() }
                return installation.extensionURL.map { FinderFirstUseVerification(extensionURL: $0) }
            },
            folderOpener: AppKitFileActions.openFolder,
            guidePreferences: .live,
            authorizationInventoryLoader: { try AuthorizedDirectoryStore().loadAuthorizedDirectoryInventory() }
        )
    }

    init(
        statusProvider: @escaping () -> Bool,
        runtimeProvider: @escaping (Bool) async -> FinderExtensionDiagnosticSnapshot,
        managementOpener: @escaping () -> Void,
        verificationClientProvider: @escaping () async -> (any FinderVerificationClient)? = { nil },
        directoryIdentityProvider: @escaping @Sendable (URL) throws -> DirectoryIdentity = { try FinderIntegrationViewModel.captureDirectoryIdentity($0) },
        folderOpener: @escaping (URL) -> Bool = { _ in false },
        guidePreferences: GuidePreferences = GuidePreferences(),
        authorizationInventoryLoader: @escaping @Sendable () throws -> AuthorizedDirectoryInventory = {
            AuthorizedDirectoryInventory(availableDirectories: [], unavailableDirectories: [])
        },
        inventoryReadGate: DiagnosticsInventoryReadGate? = nil
    ) {
        let completedGuide = guidePreferences.loadCompleted()
        self.guidePreferences = guidePreferences
        self.hasCompletedGuide = completedGuide
        self.isGuideExpanded = false
        self.authorizationInventoryLoader = authorizationInventoryLoader
        self.inventoryReadGate = inventoryReadGate ?? .shared
        self.statusProvider = statusProvider
        self.runtimeProvider = runtimeProvider
        self.managementOpener = managementOpener
        self.verificationClientProvider = verificationClientProvider
        self.directoryIdentityProvider = directoryIdentityProvider
        self.folderOpener = folderOpener
        self.isEnabled = statusProvider()
    }

    var statusText: String {
        if isRefreshing { return "正在检查扩展响应…" }
        if !isEnabled, snapshot?.state == .unknown {
            return "尚未启用；安装或注册状态待确认"
        }
        return snapshot?.state.displayName ?? (isEnabled ? "已启用，尚未检查响应" : "扩展未获用户启用")
    }

    var isResponding: Bool { isEnabled && !isRefreshing && snapshot?.state == .responding }

    var isCurrentVerificationConfirmed: Bool {
        verificationState == .confirmed && isResponding
    }

    var guideHistoryText: String {
        hasCompletedGuide ? "曾完成首次使用引导；当前状态仍需单独检查" : "可选设置，不影响在此创建文件"
    }

    func refreshAuthorizedDirectories() async {
        guard !Task.isCancelled, authorizationInventoryState != .loading else { return }
        guard inventoryReadGate.tryBegin() else {
            authorizationInventoryState = .busy
            return
        }
        authorizationInventoryState = .loading
        defer {
            // Cancellation cannot release the global slot while synchronous bookmark
            // resolution is still running. BackgroundWork returns only after it ends.
            inventoryReadGate.finish()
            if authorizationInventoryState == .loading { authorizationInventoryState = .idle }
        }
        let load = authorizationInventoryLoader
        let result = await BackgroundWork.result { try load() }
        guard !Task.isCancelled else { return }
        switch result {
        case let .success(inventory):
            authorizedDirectories = inventory.availableDirectories
            unavailableAuthorizationCount = inventory.unavailableDirectories.count
            authorizationInventoryState = .loaded
        case let .failure(error):
            authorizedDirectories = []
            unavailableAuthorizationCount = 0
            authorizationInventoryState = .failed(error.localizedDescription)
        }
    }

    func setupPresentation(
        hasDestination: Bool,
        authorization: QuickFileViewModel.FinderAuthorizationState,
        hasTemplates: Bool
    ) -> SetupPresentation {
        func presentation(_ message: String, _ detail: String, _ action: SetupAction, _ title: String) -> SetupPresentation {
            SetupPresentation(message: message, detail: detail, action: action, actionTitle: title)
        }
        if snapshot?.state == .notEmbedded {
            return presentation("此应用副本未包含 Finder 扩展", "请重新安装包含 Finder 扩展的完整 QuickFile 应用，然后再检查。", .refreshStatus, "重新检查")
        }
        if snapshot?.state == .notRegistered {
            return presentation("尚未找到此扩展的注册记录", "请从“应用程序”文件夹启动完整 QuickFile 应用，然后再检查。", .refreshStatus, "重新检查")
        }
        if !isEnabled {
            return presentation("1. 启用 Finder 右键菜单", "打开系统扩展设置后，找到并启用 QuickFile；返回这里会重新检查。", .openSettings, "打开扩展设置…")
        }
        guard hasDestination else {
            return presentation("2. 选择 Finder 将要使用的文件夹", "先选择目标文件夹，再单独保存 Finder 授权。无需完全磁盘访问。", .chooseFolder, "选择文件夹…")
        }
        switch authorization {
        case .saving:
            return presentation("正在保存文件夹授权…", "保存完成后再进行 Finder 验证。", .none, "")
        case .notConfirmed:
            return presentation("2. 确认 Finder 的文件夹授权", "这里直接创建无需保存 Finder 授权。若要使用 Finder 菜单，请通过系统面板另行确认。", .saveAuthorization, "保存 Finder 授权…")
        case let .failed(message):
            return presentation("Finder 文件夹授权未保存", message, .saveAuthorization, "重试保存 Finder 授权…")
        case .saved: break
        }
        guard hasTemplates else {
            return presentation("还没有可用模板", "请在“模板管理”中启用一个模板；读取失败时先重新加载。", .manageTemplates, "打开模板管理")
        }
        if isVerificationOperationInFlight, verificationState == .idle || verificationState == .cancelled {
            return presentation("正在结束上次位置检查…", "文件系统检查可能仍在等待目标卷；结束后才能开始新的验证。", .none, "")
        }
        if verificationState == .confirmed, !isResponding {
            return presentation("曾完成引导，当前扩展状态仍需检查", "历史完成记录不代表扩展现在可用；重新检查响应后可再次验证。", .refreshStatus, "检查当前状态")
        }
        if snapshot?.state == .unknown {
            return presentation("当前扩展状态尚未确认", "首次引导的历史记录不会替代本次检查。直接创建文件仍可继续。", .refreshStatus, "重新检查")
        }
        switch verificationState {
        case .idle:
            return presentation("3. 在 Finder 创建第一个文件", "开始后会打开所选文件夹。请在空白处右键，选择“新建文件”中的模板，再返回这里。", .startVerification, "在 Finder 中验证")
        case .preparing:
            return presentation("正在准备本次 Finder 验证…", "只检查所选位置和扩展响应，不会自动创建文件。", .none, "")
        case .awaitingCreation:
            return presentation("等待你从 Finder 右键菜单创建文件", "若主 App 已代为创建，请先检查已有文件，避免重复；本次仍在等待扩展直接创建。菜单准备中时请稍后重开。", .checkVerification, "检查本次验证")
        case .creationReported:
            return presentation("扩展报告已在所选位置创建文件", "这是当前安装版本的扩展反馈；还需你确认 Finder 中已出现新文件。", .confirmVisible, "我已看到新文件")
        case .confirmed:
            return presentation("已完成本次 Finder 首次验证", "扩展报告创建成功，你已确认看到文件；这不保证其他目录或以后每次都可用。", .startVerification, "再次验证")
        case .unavailable:
            return presentation("本次未收到扩展响应", "请先在所选文件夹打开 Finder 右键菜单，再回来重试；未响应不代表扩展崩溃。", .openFolder, "打开所选文件夹")
        case .responseUnavailable:
            return presentation("本次验证检查未收到响应", "文件可能已经创建，请先查看文件夹，避免重复创建。可以再次检查同一次验证。", .checkVerification, "再次检查本次验证")
        case .expired:
            return presentation("本次验证已结束或扩展已重新启动", "没有确认本次扩展创建结果。已有文件不会被删除；重新开始前先检查文件夹，避免重复创建。", .startVerification, "重新开始 Finder 验证")
        case .cancelled:
            return presentation("已取消本次 Finder 验证", "已经发出的文件创建不会因此取消。重新开始前请先检查文件夹，避免重复创建。", .startVerification, "重新开始 Finder 验证")
        case .destinationUnavailable:
            return presentation("无法确认所选文件夹", "文件夹可能已移动、被替换或无法访问。请重新选择一个有效文件夹。", .chooseFolder, "重新选择文件夹…")
        }
    }

    func startVerification(in folder: URL) async {
        guard !isVerificationOperationInFlight else { return }
        isVerificationOperationInFlight = true
        defer { isVerificationOperationInFlight = false }
        cancelVerification()
        isEnabled = statusProvider()
        guard isEnabled else { return }
        let generation = verificationGeneration
        verificationFolder = folder
        verificationState = .preparing
        let capture = directoryIdentityProvider
        let identityResult = await BackgroundWork.result { try capture(folder) }
        guard generation == verificationGeneration else { return }
        guard case let .success(identity) = identityResult else {
            verificationState = .destinationUnavailable
            return
        }
        guard let client = await verificationClientProvider() else {
            guard generation == verificationGeneration else { return }
            verificationState = .unavailable
            return
        }
        guard generation == verificationGeneration else { client.cancel(); return }
        verificationClient = client
        let result = await client.begin(in: identity, timeout: 1.5)
        guard generation == verificationGeneration else { return }
        guard statusProvider() else { isEnabled = false; cancelVerification(); return }
        applyVerificationResult(result)
        if result == .awaitingCreation, !folderOpener(folder) {
            cancelVerification()
            verificationState = .destinationUnavailable
        }
    }

    func checkVerification() async {
        guard verificationState == .awaitingCreation || verificationState == .creationReported || verificationState == .responseUnavailable,
              !isVerificationOperationInFlight,
              let client = verificationClient else { return }
        guard statusProvider() else { isEnabled = false; cancelVerification(); return }
        let generation = verificationGeneration
        isVerificationOperationInFlight = true
        isCheckingVerification = true
        defer {
            isVerificationOperationInFlight = false
            if generation == verificationGeneration { isCheckingVerification = false }
        }
        let result = await client.check(timeout: 1.5)
        guard generation == verificationGeneration else { return }
        guard statusProvider() else { isEnabled = false; cancelVerification(); return }
        applyVerificationResult(result, isCheck: true)
    }

    func confirmVisibleFile() async {
        guard verificationState == .creationReported, !isVerificationOperationInFlight else { return }
        let generation = verificationGeneration
        // A displayed receipt may have expired or belong to a replaced/restarted extension.
        // Recheck once when the user confirms; never turn stale UI into a completed attempt.
        await checkVerification()
        guard generation == verificationGeneration, verificationState == .creationReported else { return }
        verificationClient?.cancel()
        verificationClient = nil
        verificationState = .confirmed
        hasCompletedGuide = true
        isGuideExpanded = false
        guidePreferences.saveCompleted(true)
    }

    func cancelVerification() {
        verificationGeneration &+= 1
        verificationClient?.cancel()
        verificationClient = nil
        verificationFolder = nil
        isCheckingVerification = false
        verificationState = .idle
    }

    func cancelUserVerification() {
        cancelVerification()
        verificationState = .cancelled
    }

    func destinationDidChange(to folder: URL?) {
        if folder != verificationFolder { cancelVerification() }
    }

    func windowDidAppear(_ id: UUID) { visibleWindows.insert(id) }

    func windowDidDisappear(_ id: UUID) {
        guard visibleWindows.remove(id) != nil, visibleWindows.isEmpty else { return }
        cancelVerification()
    }

    func openSelectedFolder(_ folder: URL) {
        cancelVerification()
        if !folderOpener(folder) { verificationState = .destinationUnavailable }
    }

    private func applyVerificationResult(_ result: FinderFirstUseVerificationStatus, isCheck: Bool = false) {
        switch result {
        case .awaitingCreation: verificationState = .awaitingCreation
        case .creationReported: verificationState = .creationReported
        case .expiredOrMissing: verificationState = .expired
        case .unavailable: verificationState = isCheck ? .responseUnavailable : .unavailable
        }
    }

    nonisolated static func captureDirectoryIdentity(_ folder: URL) throws -> DirectoryIdentity {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        return try DirectoryIdentity.capture(at: folder)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let enabledAtStart = statusProvider()
        isEnabled = enabledAtStart
        snapshot = nil
        let result = await runtimeProvider(enabledAtStart)
        // Other actions may update isEnabled while this probe is suspended. Compare
        // against this probe's immutable input, never the mutable published state.
        let currentEnabled = statusProvider()
        if currentEnabled == enabledAtStart { snapshot = result }
        isEnabled = currentEnabled
        if !currentEnabled || (verificationState == .confirmed && snapshot?.state != .responding) {
            cancelVerification()
        }
    }

    func openManagement() {
        managementOpener()
    }
}
