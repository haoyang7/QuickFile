import AppKit
import QuickFileCore
import QuickFileInfrastructure

/// One optional handoff per process, independent of the file-creation scheduler.
/// A deadline ends presentation waiting, not the non-cancellable system operation.
/// The slot and scope remain owned until its callback; a timeout never admits another.
@MainActor
final class AutomaticFileOpener {
    static let shared = AutomaticFileOpener()

    enum Failure: LocalizedError {
        case busy, timedOut
        var errorDescription: String? {
            switch self {
            case .busy:
                return QuickFileLocalization.text(.init("上一次自动打开仍在等待系统响应。请在 Finder 中打开此文件；如持续无响应，请重新启动 QuickFile 或 Finder。"))
            case .timedOut:
                return QuickFileLocalization.text(.init("自动打开等待系统响应超时，文件已保留。请在 Finder 中打开；为避免积累系统请求，收到响应前暂停后续自动打开。"))
            }
        }
    }

    struct Prepared: Sendable {
        let release: @Sendable () -> Void
    }
    typealias Prepare = @Sendable (URL, UUID?, Bool) throws -> Prepared?
    typealias Open = @MainActor (URL, @escaping @Sendable (Error?) -> Void) -> Void
    private let prepare: Prepare
    private let open: Open
    private let timeoutNanoseconds: UInt64
    private final class Request {
        var continuation: CheckedContinuation<Error?, Never>?
        var deadline: Task<Void, Never>?
        init(_ continuation: CheckedContinuation<Error?, Never>) { self.continuation = continuation }
        func reply(_ error: Error?) {
            let reply = continuation
            continuation = nil
            reply?.resume(returning: error)
        }
    }
    private var current: Request?
    var isOccupied: Bool { current != nil }

    init(timeoutNanoseconds: UInt64 = 15_000_000_000,
         prepare: @escaping Prepare = { try AutomaticFileOpener.prepareLive($0, $1, $2) },
         open: @escaping Open = AutomaticFileOpener.openLive) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.prepare = prepare
        self.open = open
    }

    func openCreatedFile(_ creation: FileCreationResult, authorizationID: UUID? = nil, requiresAuthorization: Bool) async -> Error? {
        guard current == nil else { return Failure.busy }
        return await withCheckedContinuation { continuation in
            let request = Request(continuation)
            current = request
            let timeout = timeoutNanoseconds
            request.deadline = Task { [weak self, weak request] in
                do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                guard let self, let request, self.current === request else { return }
                request.reply(Failure.timedOut)
            }
            let prepare = self.prepare
            // Blocking settings/bookmark I/O must not occupy the main actor or the
            // Finder creation scheduler. Admission remains held if it stalls.
            Task.detached { [self] in
                let result = Result {
                    let prepared = try prepare(creation.fileURL, authorizationID, requiresAuthorization)
                    if let prepared {
                        do {
                            // Settings and bookmark resolution may stall. Recheck the
                            // actual published file after those waits, before handoff.
                            try creation.validateFileIdentity()
                        } catch {
                            prepared.release()
                            throw error
                        }
                    }
                    return prepared
                }
                // NSWorkspace accepts a URL, so replacement after this last check
                // and before the system consumes the path remains possible.
                await didPrepare(result, url: creation.fileURL, request: request)
            }
        }
    }

    private func didPrepare(_ result: Result<Prepared?, Error>, url: URL, request: Request) {
        switch result {
        case let .failure(error): finish(request, error: error)
        case .success(nil): finish(request, error: nil)
        case let .success(prepared?):
            guard request.continuation != nil else {
                // The deadline expired before handoff: do not unexpectedly open later.
                prepared.release()
                finish(request, error: nil)
                return
            }
            open(url) { [self] error in
                prepared.release()
                Task { @MainActor in finish(request, error: error) }
            }
        }
    }

    private func finish(_ request: Request, error: Error?) {
        guard current === request else { return }
        request.deadline?.cancel()
        request.deadline = nil
        current = nil
        request.reply(error)
    }

    nonisolated private static func prepareLive(_ url: URL, _ id: UUID?, _ requiresAuthorization: Bool) throws -> Prepared? {
        guard try FileCreationSettingsStore().loadAutomaticallyOpen() else { return nil }
        guard !requiresAuthorization || id != nil else {
            throw AuthorizedDirectoryStore.StoreError.directoryNotAuthorized
        }
        // Direct panel selections already hold their own access. Only saved grants
        // need another lease; passing the known ID avoids resolving every bookmark.
        let access = (requiresAuthorization || id != nil)
            ? try AuthorizedDirectoryStore().beginAccess(to: url.deletingLastPathComponent(), authorizationID: id)
            : nil
        return Prepared { access?.release() }
    }

    private static func openLive(_ url: URL, completion: @escaping @Sendable (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in completion(error) }
    }
}
