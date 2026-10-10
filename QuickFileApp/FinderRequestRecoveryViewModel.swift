import Combine
import Foundation
import QuickFileInfrastructure

/// A window's bounded recovery presentation. The store owns process-wide admission,
/// descriptor lifetime and final identity validation; this model never handles a
/// source/destination path or descriptor and never resumes the request pump. Only
/// a verified generated archive location may appear in its last committed receipt.
@MainActor
final class FinderRequestRecoveryViewModel: ObservableObject {
    typealias Candidate = FinderAuthorizationRequestStore.RecoveryCandidate
    typealias Inspection = FinderAuthorizationRequestStore.RecoveryInspection
    typealias Ticket = FinderAuthorizationRequestStore.PreparedRecovery
    typealias ArchiveResult = FinderAuthorizationRequestStore.RecoveryResult

    struct Backend: Sendable {
        let inspect: @Sendable () throws -> Inspection
        let prepare: @Sendable (String) throws -> Ticket
        let cancel: @Sendable (Ticket) -> Void
        let commit: @Sendable (Ticket) throws -> ArchiveResult

        init(store: FinderAuthorizationRequestStore) {
            inspect = { try store.inspectRecoveryCandidates() }
            prepare = { try store.prepareRecovery(candidateID: $0) }
            cancel = { store.cancelRecovery($0) }
            commit = { try store.commitRecovery($0) }
        }

        init(
            inspect: @escaping @Sendable () throws -> Inspection,
            prepare: @escaping @Sendable (String) throws -> Ticket,
            cancel: @escaping @Sendable (Ticket) -> Void,
            commit: @escaping @Sendable (Ticket) throws -> ArchiveResult
        ) {
            self.inspect = inspect
            self.prepare = prepare
            self.cancel = cancel
            self.commit = commit
        }
    }

    enum Operation: Equatable {
        case inspecting, preparing, confirming, archiving

        var message: String {
            switch self {
            case .inspecting: return "正在检查有限数量的队列记录…"
            case .preparing: return "正在重新核对所选原始记录…"
            case .confirming: return "等待归档确认；取消会保留原始记录。"
            case .archiving: return "正在归档原件，请等待结果…"
            }
        }
    }

    enum Status: Equatable {
        case information(String)
        case failure(String)
        case archived(durabilityWarning: Bool)

        var message: String {
            switch self {
            case let .information(message), let .failure(message): return message
            case .archived(false):
                return "已将所选原始记录移至本机的隐藏私有归档目录，移出待办。没有创建文件或恢复自动处理。关闭后可在暂停提示中点击“重试读取”。"
            case .archived(true):
                return "原始记录已移至归档并移出待办，但未能完整确认归档的位置或持久化状态。不要重复归档本条记录；请先保留当前状态并检查本机存储。自动处理仍暂停，没有创建文件。"
            }
        }
    }

    @Published private(set) var isPresented = false
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var isTruncated = false
    @Published private(set) var legacyRecoveryUnsupported = false
    @Published private(set) var hasInspected = false
    @Published private(set) var operation: Operation?
    @Published private(set) var status: Status?
    @Published private(set) var selectedCandidateID: String?
    // Exactly one committed receipt survives sheet close/reopen. It is separate
    // from generation-scoped inspection and never reselects or retries a request.
    @Published private(set) var lastArchive: ArchiveResult?

    private static let finishingMessage = "上次操作仍在结束。结束后可点击“重新检查”；关闭窗口不会强行中断磁盘操作。"
    private let backend: Backend
    private let canOperate: @MainActor () -> Bool
    private var generation = UUID()
    private var preparedTicket: Ticket?

    init(backend: Backend, canOperate: @escaping @MainActor () -> Bool = { true }) {
        self.backend = backend
        self.canOperate = canOperate
    }

    deinit {
        // Tasks retain the model while synchronous I/O runs. A settled, discarded
        // model must not strand an already-prepared ticket or its process permit.
        if let preparedTicket { backend.cancel(preparedTicket) }
    }

    var isOperationInFlight: Bool { operation != nil }
    var selectedCandidate: Candidate? { candidates.first { $0.id == selectedCandidateID } }
    var canInspect: Bool { isPresented && !isOperationInFlight && canOperate() }
    var canPrepareSelection: Bool {
        canInspect && selectedCandidate?.canPrepare == true
    }

    func open() {
        guard !isPresented else { return }
        generation = UUID()
        isPresented = true
        clearInspection()
        status = isOperationInFlight
            ? .information(Self.finishingMessage)
            : nil
    }

    func close() {
        generation = UUID()
        isPresented = false
        cancelPreparedTicket()
        clearInspection()
        status = nil
        // Deliberately do not clear operation. BackgroundWork is not cancellable:
        // a closed/reopened sheet cannot admit a second operation before it ends.
    }

    func select(_ candidateID: String?) {
        guard !isOperationInFlight, selectedCandidateID != candidateID else { return }
        generation = UUID()
        cancelPreparedTicket()
        selectedCandidateID = candidateID.flatMap { id in candidates.contains { $0.id == id } ? id : nil }
        status = nil
    }

    func inspect() async {
        guard !Task.isCancelled, canInspect else { return }
        generation = UUID()
        let currentGeneration = generation
        cancelPreparedTicket()
        operation = .inspecting
        clearInspection()
        status = nil
        defer { finishOperation() }
        let inspect = backend.inspect
        let result = await BackgroundWork.result { try inspect() }
        guard isCurrent(currentGeneration), !Task.isCancelled else { return }
        switch result {
        case let .success(inspection):
            candidates = inspection.candidates
            isTruncated = inspection.isTruncated
            legacyRecoveryUnsupported = inspection.legacyRecoveryUnsupported
            hasInspected = true
        case let .failure(error):
            status = .failure(Self.safeMessage(for: error))
        }
    }

    /// The native confirmation executes on MainActor only after a fresh preparation.
    /// Its nested event loop may close the window, so approval is revalidated before
    /// the background commit. Never turn a stale approval into a new prepare/retry.
    @discardableResult
    func prepareSelected(confirm: @MainActor (Candidate) -> Bool) async -> Bool {
        guard !Task.isCancelled, canPrepareSelection, let selectedCandidate else { return false }
        return await prepare(candidateID: selectedCandidate.id, requiresSelection: true, confirm: confirm)
    }

    /// A user-supplied identifier can reach an original beyond the bounded listing.
    /// It still goes through the same fresh prepare, confirmation and pinned commit.
    @discardableResult
    func prepareRequest(withID input: String, confirm: @MainActor (Candidate) -> Bool) async -> Bool {
        guard !Task.isCancelled, canInspect else { return false }
        let id = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.utf8.count <= 64, UUID(uuidString: id) != nil else {
            status = .failure("请输入完整的请求标识（UUID），不含路径或 .json 后缀。")
            return false
        }
        // Preserve exact spelling: case-sensitive queues may contain both forms.
        generation = UUID()
        return await prepare(candidateID: id, requiresSelection: false, confirm: confirm)
    }

    private func prepare(
        candidateID selectedID: String, requiresSelection: Bool,
        confirm: @MainActor (Candidate) -> Bool
    ) async -> Bool {
        let currentGeneration = generation
        operation = .preparing
        status = nil
        defer { finishOperation() }
        let prepare = backend.prepare
        let preparation = await BackgroundWork.result { try prepare(selectedID) }
        let ticket: Ticket
        switch preparation {
        case let .success(value): ticket = value
        case let .failure(error):
            if isCurrent(currentGeneration), !Task.isCancelled {
                clearInspection()
                status = .failure(Self.safeMessage(for: error))
            }
            return false
        }
        guard isCurrent(currentGeneration), !Task.isCancelled,
              (!requiresSelection || self.selectedCandidateID == selectedID), canOperate(),
              ticket.candidate.id == selectedID, ticket.candidate.canPrepare else {
            backend.cancel(ticket)
            if isCurrent(currentGeneration), !Task.isCancelled {
                clearInspection()
                status = .failure("当前操作或所选记录已变化。原件未归档；请重新检查后再选择。")
            }
            return false
        }
        preparedTicket = ticket
        operation = .confirming
        let approved = confirm(ticket.candidate)
        guard isCurrent(currentGeneration), !Task.isCancelled,
              preparedTicket?.id == ticket.id, canOperate() else {
            // close() may already have cancelled this ticket. Cancellation is
            // idempotent at the store; never release a later ticket by identifier.
            cancelPreparedTicket()
            backend.cancel(ticket)
            if isCurrent(currentGeneration), !Task.isCancelled {
                clearInspection()
                status = .failure("应用状态已变化，本次归档未提交。请稍后重新检查。")
            }
            return false
        }
        guard approved else {
            cancelPreparedTicket()
            status = .information("已取消归档，所选原始记录未改动。自动处理仍暂停。")
            return false
        }

        // Transfer the one prepared ticket to the actual commit. close() cannot
        // release it while synchronous commit work is still running.
        preparedTicket = nil
        operation = .archiving
        let commit = backend.commit
        let cancel = backend.cancel
        let result = await BackgroundWork.result {
            // A backend error must also release a ticket, including injected
            // backends. Production commit/cancel are safely idempotent.
            defer { cancel(ticket) }
            return try commit(ticket)
        }
        if case let .success(receipt) = result {
            lastArchive = receipt
        }
        guard isCurrent(currentGeneration) else {
            // A completed archive is real even if its sheet closed. Preserve only
            // its bounded receipt; never publish old candidates or selection.
            if case .success = result { return true }
            return false
        }
        // Once commit started, caller cancellation cannot undo it. Report its real
        // outcome in the still-current presentation rather than imply no change.
        switch result {
        case let .success(receipt):
            candidates.removeAll { $0.id == selectedID }
            selectedCandidateID = nil
            status = .archived(durabilityWarning: receipt.durabilityWarning)
            return true
        case let .failure(error):
            clearInspection()
            status = .failure(Self.safeMessage(for: error))
            return false
        }
    }

    private func finishOperation() {
        operation = nil
        if isPresented, status == .information(Self.finishingMessage) {
            status = .information("上次操作已结束。请重新检查当前队列；自动处理仍暂停。")
        }
    }

    private func isCurrent(_ value: UUID) -> Bool {
        isPresented && generation == value
    }

    private func cancelPreparedTicket() {
        guard let ticket = preparedTicket else { return }
        preparedTicket = nil
        backend.cancel(ticket)
    }

    private func clearInspection() {
        candidates = []
        selectedCandidateID = nil
        hasInspected = false
        isTruncated = false
        legacyRecoveryUnsupported = false
    }

    static func safeMessage(for error: Error) -> String {
        if let recoveryError = error as? FinderAuthorizationRequestStore.RecoveryError {
            return recoveryError.localizedDescription
        }
        // Arbitrary errors can include file paths or payloads. Only the store's
        // closed recovery error vocabulary is safe to show in this limited UI.
        return "未能完成此次恢复操作。不会改用删除或清空队列；请保留原始数据并重新检查。"
    }
}
