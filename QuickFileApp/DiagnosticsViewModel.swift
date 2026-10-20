import Combine
import Foundation
import QuickFileCore
import QuickFileInfrastructure

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published private(set) var isFinderExtensionEnabled = false
    var runtimeStatusMessage: String? { runtimeStatusMessagePresentation?.value }
    @Published private var runtimeStatusMessagePresentation: LocalizedPresentation<String?>?
    @Published private(set) var extensionSnapshot: FinderExtensionDiagnosticSnapshot?
    @Published private(set) var extensionActivity: FinderExtensionActivity?
    @Published private(set) var latestActivityReadFailed = false
    @Published private(set) var recentExtensionFailures: [FinderExtensionActivity] = []
    @Published private(set) var isSharedStoreAvailable = false
    var activityStoreMessage: String? {
        let messages = [
            latestActivityReadFailed ? QuickFileLocalization.text(.init("无法读取最近活动，请稍后刷新。")) : nil,
            failureHistoryReadErrorPresentation?.value,
            activityStoreMessagePresentation?.value
        ].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    @Published private var failureHistoryReadErrorPresentation: LocalizedPresentation<String?>?
    @Published private var activityStoreMessagePresentation: LocalizedPresentation<String?>?
    @Published private(set) var activityStoreHasError = false
    @Published private(set) var authorizedDirectories: [AuthorizedDirectory] = []
    var authorizationMessage: String? { authorizationMessagePresentation?.value }
    @Published private(set) var authorizationMessagePresentation: LocalizedPresentation<String?>?
    @Published private(set) var authorizationHasError = false
    @Published private(set) var report: DirectoryDiagnosticReport?
    @Published private(set) var isInspectingDirectory = false
    var directoryInspectionMessage: String? { directoryInspectionMessagePresentation?.value }
    @Published private var directoryInspectionMessagePresentation: LocalizedPresentation<String?>?
    @Published private(set) var unavailableAuthorizedDirectories: [UnavailableAuthorizedDirectory] = []
    @Published private(set) var isRefreshingRuntimeStatus = false
    @Published private(set) var isManagingAuthorizations = false
    @Published private(set) var isLoadingAuthorizationInventory = false
    @Published private(set) var authorizationInventoryReadFailed = false
    var authorizationInventoryMessage: String? { authorizationInventoryMessagePresentation?.value }
    @Published private var authorizationInventoryMessagePresentation: LocalizedPresentation<String?>?
    @Published private(set) var hasLoadedActivityStoreStatus = false

    private let extensionEnabledProvider: () -> Bool
    private let runtimeProvider: ((Bool) async -> FinderExtensionDiagnosticSnapshot)?
    private let diagnosticsService: DirectoryDiagnosticsService
    private let extensionActivityStore: FinderExtensionActivityStore
    private let authorizedDirectoryStore: AuthorizedDirectoryStore
    private let inventoryReadGate: DiagnosticsInventoryReadGate
    private let runtimeReadGate: DiagnosticsRuntimeReadGate
    private let writeProbeGate: DiagnosticsWriteProbeGate
    private var directoryPresentationGeneration: UUID? = UUID()
    private var directoryInspectionTask: Task<Void, Never>?
    // One coalesced intent per retained page, tagged with its presentation.
    // Closing discards old intent; a reopened page can request new work while
    // the previous generation still owns non-cancellable synchronous I/O.
    private var pendingRuntimeRefreshGeneration: UUID?
    private var pendingInventoryRefreshGeneration: UUID?
    private var authorizationRevision = 0
    private var revocationObservation: AnyCancellable?
    private final class InventoryRead {
        let revision: Int
        let generation: UUID
        var revokedIDs: Set<AuthorizedDirectory.ID> = []
        init(revision: Int, generation: UUID) {
            self.revision = revision
            self.generation = generation
        }
    }
    // Bookmark inventory and authorization reads share admission, independently
    // of runtime probes. Retain removals only for the current inventory read.
    private var inventoryRead: InventoryRead?
    // All diagnostics windows live on the main actor. Publish only committed removals;
    // each window filters them out of inventory work already in flight.
    private static let committedRevocations = PassthroughSubject<Set<AuthorizedDirectory.ID>, Never>()

    init(
        extensionEnabledProvider: @escaping () -> Bool,
        runtimeProvider: ((Bool) async -> FinderExtensionDiagnosticSnapshot)? = nil,
        diagnosticsService: DirectoryDiagnosticsService = DirectoryDiagnosticsService(),
        extensionActivityStore: FinderExtensionActivityStore = FinderExtensionActivityStore(),
        authorizedDirectoryStore: AuthorizedDirectoryStore = AuthorizedDirectoryStore(),
        inventoryReadGate: DiagnosticsInventoryReadGate? = nil,
        writeProbeGate: DiagnosticsWriteProbeGate? = nil,
        runtimeReadGate: DiagnosticsRuntimeReadGate? = nil
    ) {
        self.extensionEnabledProvider = extensionEnabledProvider
        self.runtimeProvider = runtimeProvider
        self.diagnosticsService = diagnosticsService
        self.extensionActivityStore = extensionActivityStore
        self.authorizedDirectoryStore = authorizedDirectoryStore
        self.inventoryReadGate = inventoryReadGate ?? .shared
        self.runtimeReadGate = runtimeReadGate ?? .shared
        self.writeProbeGate = writeProbeGate ?? .shared
        revocationObservation = Self.committedRevocations.sink { [weak self] ids in
            guard let self else { return }
            self.authorizationRevision += 1
            self.inventoryRead?.revokedIDs.formUnion(ids)
            self.authorizedDirectories.removeAll { ids.contains($0.id) }
            let unavailableCount = self.unavailableAuthorizedDirectories.count
            self.unavailableAuthorizedDirectories.removeAll { ids.contains($0.id) }
            if self.authorizationInventoryMessage == QuickFileLocalization.text(.init("有 \(unavailableCount) 个目录授权暂不可用。")) {
                let remainingCount = self.unavailableAuthorizedDirectories.count
                self.authorizationInventoryMessagePresentation = LocalizedPresentation(remainingCount == 0 ? nil
                    : QuickFileLocalization.text(.init("有 \(remainingCount) 个目录授权暂不可用。")))
            }
        }
    }

    func refreshRuntimeStatus() async {
        guard !Task.isCancelled, let generation = directoryPresentationGeneration else { return }
        guard !isRefreshingRuntimeStatus else {
            let enabledNow = extensionEnabledProvider()
            if enabledNow != isFinderExtensionEnabled {
                isFinderExtensionEnabled = enabledNow
                extensionSnapshot = nil
            }
            pendingRuntimeRefreshGeneration = generation
            return
        }
        isRefreshingRuntimeStatus = true
        await runAdmittedRefresh(generation: generation)
    }

    private func runAdmittedRefresh(generation: UUID) async {
        await refreshRuntimePasses(generation: generation)
        guard !Task.isCancelled, directoryPresentationGeneration == generation else { return }
        // Release runtime admission before awaiting bookmark resolution. A new
        // same-window probe can run even while this inventory is still blocked.
        if let read = beginInventoryRefresh(generation: generation) {
            await performInventoryRefresh(read)
        }
    }

    private func refreshRuntimePasses(generation: UUID) async {
        defer { finishRuntimeRefresh(generation: generation) }
        guard !Task.isCancelled, directoryPresentationGeneration == generation else { return }
        // Repeated same-presentation requests merge into at most one follow-up.
        for _ in 0..<2 {
            if pendingRuntimeRefreshGeneration == generation {
                pendingRuntimeRefreshGeneration = nil
            }
            await refreshRuntimeEvidence(generation: generation)
            guard !Task.isCancelled, directoryPresentationGeneration == generation else { return }
            if pendingRuntimeRefreshGeneration != generation { break }
        }
        if pendingRuntimeRefreshGeneration == generation, extensionSnapshot == nil,
           runtimeStatusMessage == nil {
            // Keep the two-pass bound even if the enabled state never settles.
            // The page's refresh action can start another bounded attempt.
            runtimeStatusMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("扩展状态持续变化，请稍后刷新。")))
        }
    }

    private func finishRuntimeRefresh(generation: UUID, includeSameGeneration: Bool = false) {
        isRefreshingRuntimeStatus = false
        let pending = pendingRuntimeRefreshGeneration
        pendingRuntimeRefreshGeneration = nil
        guard let pending, pending == directoryPresentationGeneration,
              pending != generation || (includeSameGeneration && !Task.isCancelled) else { return }
        // Transfer one permit before starting a fresh task. It must not inherit
        // the closed caller's cancellation, nor enqueue a task per request.
        isRefreshingRuntimeStatus = true
        Task { await runAdmittedRefresh(generation: pending) }
    }

    private func beginInventoryRefresh(generation: UUID) -> InventoryRead? {
        if let read = inventoryRead {
            if read.generation != generation {
                pendingInventoryRefreshGeneration = generation
            }
            return nil
        }
        guard beginInventoryRead() else { return nil }
        let read = InventoryRead(revision: authorizationRevision, generation: generation)
        inventoryRead = read
        isLoadingAuthorizationInventory = true
        return read
    }

    private func performInventoryRefresh(_ read: InventoryRead) async {
        defer { finishInventoryRead(read) }
        guard !Task.isCancelled, directoryPresentationGeneration == read.generation else { return }
        let store = authorizedDirectoryStore
        let result = await BackgroundWork.result { try store.loadAuthorizedDirectoryInventory() }
        guard !Task.isCancelled, directoryPresentationGeneration == read.generation else { return }
        apply(result, for: read)
    }

    private func finishInventoryRead(_ read: InventoryRead) {
        inventoryRead = nil
        isLoadingAuthorizationInventory = false
        inventoryReadGate.finish()
        let pending = pendingInventoryRefreshGeneration
        pendingInventoryRefreshGeneration = nil
        guard let pending, pending != read.generation,
              pending == directoryPresentationGeneration,
              let nextRead = beginInventoryRefresh(generation: pending) else { return }
        // Only a new presentation can retain an inventory intent. Same-page
        // refreshes never queue duplicate readers behind a slow/offline volume.
        Task { await performInventoryRefresh(nextRead) }
    }

    private func refreshRuntimeEvidence(generation: UUID) async {
        let enabledAtStart = extensionEnabledProvider()
        if enabledAtStart != isFinderExtensionEnabled { extensionSnapshot = nil }
        isFinderExtensionEnabled = enabledAtStart
        guard runtimeReadGate.tryBegin() else {
            runtimeStatusMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("另一项扩展状态检查仍在进行，请稍后刷新。")))
            return
        }
        defer { runtimeReadGate.finish() }
        // Keep the last completed result visible during a same-state refresh.
        // Clearing it collapses the retained page whenever its tab reappears.
        let snapshot: FinderExtensionDiagnosticSnapshot
        if let runtimeProvider {
            snapshot = await runtimeProvider(enabledAtStart)
        } else {
            snapshot = await FinderExtensionRuntimeInspector.snapshot(enabled: enabledAtStart)
        }
        guard !Task.isCancelled, directoryPresentationGeneration == generation else { return }
        let enabledAfterProbe = extensionEnabledProvider()
        isFinderExtensionEnabled = enabledAfterProbe
        guard enabledAfterProbe == enabledAtStart else {
            extensionSnapshot = nil
            pendingRuntimeRefreshGeneration = generation
            return
        }
        runtimeStatusMessagePresentation = nil
        extensionSnapshot = snapshot

        let store = extensionActivityStore
        let (activityResult, historyResult) = await BackgroundWork.run {
            (Result { try store.latestActivity() }, Result { try store.recentFailures() })
        }
        guard !Task.isCancelled, directoryPresentationGeneration == generation else { return }
        isSharedStoreAvailable = false
        hasLoadedActivityStoreStatus = true
        switch activityResult {
        case let .success(activity):
            extensionActivity = activity
            latestActivityReadFailed = false
        case .failure:
            latestActivityReadFailed = true
        }
        activityStoreMessagePresentation = nil
        switch historyResult {
        case let .success(failures):
            isSharedStoreAvailable = store.isAvailable && !latestActivityReadFailed
            recentExtensionFailures = failures
            failureHistoryReadErrorPresentation = nil
            activityStoreHasError = latestActivityReadFailed
        case let .failure(error):
            failureHistoryReadErrorPresentation = LocalizedPresentation(QuickFileLocalization.text(.init("无法读取失败历史：\(error.localizedDescription)")))
            activityStoreHasError = true
        }
        let enabledAtEnd = extensionEnabledProvider()
        isFinderExtensionEnabled = enabledAtEnd
        if enabledAtEnd != enabledAtStart {
            extensionSnapshot = nil
            pendingRuntimeRefreshGeneration = generation
        }
    }

    // Explicit allowlist: never serialize URLs, localized errors, bookmarks, or template content.
    var diagnosticSummary: String {
        let snapshot = extensionSnapshot
        func safeIdentifier(_ identifier: String) -> String {
            identifier.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }
                ? identifier : "[invalid identifier]"
        }
        let identifiers = (snapshot?.embeddedIdentifiers ?? []).map(safeIdentifier).joined(separator: ", ")
        let activityTimestamp = extensionActivity.map { ISO8601DateFormatter().string(from: $0.timestamp) } ?? "none"
        return """
        QuickFile diagnostics v2
        appBundleIdentifier: \(safeIdentifier(Bundle.main.bundleIdentifier ?? "unknown"))
        distributionChannel: \(QuickFileDistributionChannel.current?.rawValue ?? "unknown")
        storageMode: \(QuickFileStorageMode.current.rawValue)
        embeddedIdentifiers: \(identifiers)
        state: \(snapshot?.state.rawValue ?? "unknown")
        registration: \(snapshot?.registration.rawValue ?? "unknown")
        enabled: \(isFinderExtensionEnabled)
        probeResponded: \(snapshot?.responded.map(String.init) ?? "not-tested")
        sharedStoreAvailable: \(isSharedStoreAvailable)
        authorizedDirectoryCount: \(authorizedDirectories.count)
        unavailableAuthorizationCount: \(unavailableAuthorizedDirectories.count)
        latestActivityKind: \(extensionActivity?.kind.rawValue ?? "none")
        latestActivityTimestamp: \(activityTimestamp)
        latestActivityReadFailed: \(latestActivityReadFailed)
        recentFailureReasons: \(recentExtensionFailures.compactMap { $0.failure?.reason.rawValue }.joined(separator: ", "))
        writeProbeSucceeded: \(report?.writeProbeSucceeded.map(String.init) ?? "not-tested")
        """
    }

    func clearFailureHistory() async {
        guard !Task.isCancelled, let generation = directoryPresentationGeneration,
              !isRefreshingRuntimeStatus else { return }
        guard runtimeReadGate.tryBegin() else {
            activityStoreMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("另一项扩展状态检查或历史清理仍在进行，请稍后重试。")))
            return
        }
        isRefreshingRuntimeStatus = true
        defer {
            runtimeReadGate.finish()
            finishRuntimeRefresh(generation: generation, includeSameGeneration: true)
        }

        let store = extensionActivityStore
        let result = await BackgroundWork.result { try store.clearFailureHistory() }
        guard !Task.isCancelled, directoryPresentationGeneration == generation else { return }
        switch result {
        case .success:
            recentExtensionFailures = []
            failureHistoryReadErrorPresentation = nil
            activityStoreMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("失败历史已清空；最近扩展活动状态仍保留。")))
            activityStoreHasError = latestActivityReadFailed
        case let .failure(error):
            activityStoreMessagePresentation = LocalizedPresentation(error.localizedDescription)
            activityStoreHasError = true
        }
    }

    func openConsole(using opener: () -> Bool) {
        guard opener() else {
            activityStoreMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("无法打开 Console，请从“应用程序 > 实用工具”手动打开。")))
            activityStoreHasError = true
            return
        }

        activityStoreMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("Console 已打开，请筛选子系统 com.haoyoung.QuickFile。")))
        activityStoreHasError = latestActivityReadFailed || failureHistoryReadErrorPresentation != nil
    }

    func directoryDiagnosticsDidAppear() {
        if directoryPresentationGeneration == nil {
            directoryPresentationGeneration = UUID()
        }
    }

    func directoryDiagnosticsDidDisappear() {
        directoryPresentationGeneration = nil
        pendingRuntimeRefreshGeneration = nil
        pendingInventoryRefreshGeneration = nil
        directoryInspectionTask?.cancel()
        // The task and admission remain owned until synchronous I/O, including
        // descriptor-relative probe cleanup, actually returns.
    }

    @discardableResult
    func startDirectoryInspection(_ folderURL: URL) -> Task<Void, Never>? {
        guard !Task.isCancelled, let generation = beginDirectoryInspection() else { return nil }
        let task = Task {
            await performDirectoryInspection(folderURL, generation: generation)
        }
        directoryInspectionTask = task
        return task
    }

    func inspectDirectory(_ folderURL: URL) async {
        guard !Task.isCancelled, let generation = beginDirectoryInspection() else { return }
        await performDirectoryInspection(folderURL, generation: generation)
    }

    private func beginDirectoryInspection() -> UUID? {
        guard let generation = directoryPresentationGeneration, !isInspectingDirectory else { return nil }
        guard writeProbeGate.tryBegin() else {
            directoryInspectionMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("另一项文件夹写入测试仍在进行，请稍后重试。")))
            return nil
        }

        isInspectingDirectory = true
        directoryInspectionMessagePresentation = nil
        return generation
    }

    private func performDirectoryInspection(_ folderURL: URL, generation: UUID) async {
        defer {
            isInspectingDirectory = false
            directoryInspectionTask = nil
            writeProbeGate.finish()
        }
        // A managed task can be cancelled after admission but before it starts.
        guard !Task.isCancelled, directoryPresentationGeneration == generation else { return }
        let service = diagnosticsService
        let result = await BackgroundWork.run {
            service.inspect(folderURL: folderURL, performWriteProbe: true)
        }
        guard !Task.isCancelled, directoryPresentationGeneration == generation else { return }
        report = result
    }

    func authorizeDirectory(_ directoryURL: URL) async {
        guard !Task.isCancelled, let generation = directoryPresentationGeneration,
              !isManagingAuthorizations, !isRefreshingRuntimeStatus,
              !isLoadingAuthorizationInventory else { return }
        guard beginInventoryRead() else { return }
        isManagingAuthorizations = true
        let read = InventoryRead(revision: authorizationRevision, generation: generation)
        inventoryRead = read
        defer { finishInventoryRead(read) }
        let store = authorizedDirectoryStore
        let result = await BackgroundWork.result { try store.authorize(directoryURL) }
        isManagingAuthorizations = false
        guard !Task.isCancelled, directoryPresentationGeneration == generation,
              inventoryRead === read else { return }

        switch result {
        case let .success(authorization):
            // Commit feedback and its known row must not wait for all bookmarks.
            // A removal committed in another window still wins over this result.
            if !read.revokedIDs.contains(authorization.id) {
                authorizedDirectories.removeAll { $0.id == authorization.id }
                unavailableAuthorizedDirectories.removeAll { $0.id == authorization.id }
                authorizedDirectories.append(authorization)
                authorizedDirectories.sort {
                    $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                }
                authorizationMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("目录授权已保存。")))
                authorizationHasError = false
            }
            isLoadingAuthorizationInventory = true
            let inventoryResult = await BackgroundWork.result {
                try store.loadAuthorizedDirectoryInventory()
            }
            guard !Task.isCancelled, directoryPresentationGeneration == generation,
                  inventoryRead === read else { return }
            apply(inventoryResult, for: read)
        case let .failure(error):
            // Another window's removal does not supersede this operation's error.
            authorizationMessagePresentation = LocalizedPresentation(error.localizedDescription)
            authorizationHasError = true
        }
    }

    func revokeAuthorization(_ authorizationID: AuthorizedDirectory.ID) async {
        guard !isManagingAuthorizations else {
            return
        }
        let removedDirectory = authorizedDirectories.first { $0.id == authorizationID }
        isManagingAuthorizations = true
        // Preserve this operation's feedback even if an older refresh later returns.
        authorizationRevision += 1
        defer { isManagingAuthorizations = false }

        let store = authorizedDirectoryStore
        let result = await BackgroundWork.result {
            try store.revoke(authorizationID)
        }

        switch result {
        case .success:
            Self.committedRevocations.send([authorizationID])
            if let removedDirectory, let overlap = authorizationOverlapPresentation(for: removedDirectory) {
                authorizationMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("目录授权已移除。")) + " " + (overlap.value ?? ""))
            } else {
                authorizationMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("目录授权已移除。")))
            }
            authorizationHasError = false
        case let .failure(error):
            authorizationMessagePresentation = LocalizedPresentation(error.localizedDescription)
            authorizationHasError = true
        }
    }

    func authorizationOverlapMessage(for directory: AuthorizedDirectory) -> String? {
        authorizationOverlapPresentation(for: directory)?.value
    }

    private func authorizationOverlapPresentation(for directory: AuthorizedDirectory) -> LocalizedPresentation<String?>? {
        // These canonical paths came from completed bookmark inventory/grants.
        // Compare components only: resolving symlinks or bookmarks here could
        // block MainActor. This is qualified UI evidence, never permission.
        let components = directory.url.pathComponents
        let covering = authorizedDirectories.filter {
            $0.id != directory.id && components.starts(with: $0.url.pathComponents)
        }
        if !directory.isBookmarkStale, let other = covering.first(where: { !$0.isBookmarkStale }) {
            return LocalizedPresentation(QuickFileLocalization.text(.init("最近读取的记录中，此位置也由“\(other.url.path)”授权；该记录仍会保留，实际写入时会重新验证。")))
        }
        if !covering.isEmpty {
            return LocalizedPresentation(QuickFileLocalization.text(.init("另有路径重叠的授权记录，但书签需要更新，无法确认此位置是否仍获授权。")))
        }
        return nil
    }

    func revokeUnavailableAuthorizations() async {
        guard !Task.isCancelled, !isManagingAuthorizations, !unavailableAuthorizedDirectories.isEmpty else { return }
        // Bulk cleanup re-resolves bookmarks and can block just like an inventory
        // read. Single-ID revocation above needs no resolver and stays independent.
        guard beginInventoryRead() else { return }
        let candidateIDs = Set(unavailableAuthorizedDirectories.map(\.id))
        isManagingAuthorizations = true
        authorizationRevision += 1
        defer {
            isManagingAuthorizations = false
            inventoryReadGate.finish()
        }

        let store = authorizedDirectoryStore
        let result = await BackgroundWork.result {
            try store.revokeUnavailableAuthorizations(candidateIDs)
        }
        switch result {
        case let .success(removedIDs):
            if !removedIDs.isEmpty {
                Self.committedRevocations.send(removedIDs)
            }
            if removedIDs.count == candidateIDs.count {
                authorizationMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("已移除 \(removedIDs.count) 个不可用授权。")))
            } else {
                authorizationMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("已移除 \(removedIDs.count) 个不可用授权；其余记录可能已恢复或更新，请刷新状态查看。")))
            }
            authorizationHasError = false
        case let .failure(error):
            authorizationMessagePresentation = LocalizedPresentation(error.localizedDescription)
            authorizationHasError = true
        }
    }

    var authorizationStorageURL: URL? { authorizedDirectoryStore.storageDirectoryURL }

    func repairAuthorizationPermissions(confirm: () -> Bool) async {
        guard !isManagingAuthorizations, !isLoadingAuthorizationInventory, confirm() else { return }
        guard !isManagingAuthorizations, !isLoadingAuthorizationInventory else { return }
        isManagingAuthorizations = true
        defer { isManagingAuthorizations = false }
        let store = authorizedDirectoryStore
        let result = await BackgroundWork.result { try store.repairStoragePermissions() }
        switch result {
        case .success:
            authorizationHasError = false
            authorizationMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("授权记录权限已修复，原始书签未更改。请刷新授权列表；不可用目录仍需重新授权。")))
        case .failure:
            authorizationHasError = true
            authorizationMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("未能完成权限修复。文件内容未更改，部分权限可能已调整。请在 Finder 的“显示简介 → 共享与权限”中检查当前用户的读写权限，再重试。")))
        }
    }

    private func beginInventoryRead() -> Bool {
        guard inventoryReadGate.tryBegin() else {
            authorizationInventoryMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("另一项目录授权检查仍在进行，请稍后刷新或重试。")))
            return false
        }
        return true
    }

    private func apply(_ result: Result<AuthorizedDirectoryInventory, Error>, for read: InventoryRead) {
        switch result {
        case let .success(inventory):
            // Even the first load must retain other, still-valid records. Only
            // committed removals are filtered; a failed removal keeps its row.
            let filtered = AuthorizedDirectoryInventory(
                availableDirectories: inventory.availableDirectories.filter { !read.revokedIDs.contains($0.id) },
                unavailableDirectories: inventory.unavailableDirectories.filter { !read.revokedIDs.contains($0.id) }
            )
            authorizedDirectories = filtered.availableDirectories
            unavailableAuthorizedDirectories = filtered.unavailableDirectories
            authorizationInventoryReadFailed = false
            authorizationInventoryMessagePresentation = LocalizedPresentation(filtered.unavailableDirectories.isEmpty ? nil
                : QuickFileLocalization.text(.init("有 \(filtered.unavailableDirectories.count) 个目录授权暂不可用。")))
        case let .failure(error):
            // A repository read failure says nothing about a completed mutation.
            // Keep known rows (including the newly committed grant) and report
            // this separately rather than turning a saved grant into a failure.
            guard read.revision == authorizationRevision else { return }
            authorizationInventoryReadFailed = true
            authorizationInventoryMessagePresentation = LocalizedPresentation(QuickFileLocalization.text(.init("无法刷新目录授权列表：\(error.localizedDescription)")))
        }
    }

}

// All diagnostic bookmark-resolving callers are MainActor-isolated. Admission
// is immediate and retains no waiting tasks or windows; the single owner releases
// only after its I/O returns. Direct single-ID revocation never takes this gate.
@MainActor
final class DiagnosticsInventoryReadGate {
    static let shared = DiagnosticsInventoryReadGate()
    private(set) var isReading = false

    func tryBegin() -> Bool {
        guard !isReading else { return false }
        isReading = true
        return true
    }

    func finish() {
        isReading = false
    }
}

// Every window uses this process-wide slot for actual write probes. Admission
// is immediate: rejected windows retain no task or URL waiting for the owner.
// It is independent of bookmark resolution and committed authorization changes.
@MainActor
final class DiagnosticsWriteProbeGate {
    static let shared = DiagnosticsWriteProbeGate()
    private(set) var isRunning = false

    func tryBegin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    func finish() {
        isRunning = false
    }
}

// Runtime probing/history reads and clears share a process-wide slot. Rejected
// windows do not enqueue work, and cancellation retains admission until return.
@MainActor
final class DiagnosticsRuntimeReadGate {
    static let shared = DiagnosticsRuntimeReadGate()
    private(set) var isReading = false

    func tryBegin() -> Bool {
        guard !isReading else { return false }
        isReading = true
        return true
    }

    func finish() {
        isReading = false
    }
}
