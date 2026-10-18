import Combine
import Foundation

/// Native panels share app-wide admission. The single Finder request
/// pump may reserve the next presentation; other callers never enqueue panels.
@MainActor
final class AppModalPresentationGate: ObservableObject {
    static let shared = AppModalPresentationGate()
    @Published private(set) var isPresenting = false
    private(set) var isFinderReserved = false
    private var finderWaiter: CheckedContinuation<Void, Never>?

    func tryBegin() -> Bool {
        guard !isPresenting, !isFinderReserved else { return false }
        isPresenting = true
        return true
    }

    func finish() {
        precondition(isPresenting)
        isPresenting = false
        let waiter = finderWaiter
        finderWaiter = nil
        waiter?.resume()
    }

    func present<Value>(_ operation: () -> Value) -> Value? {
        guard tryBegin() else { return nil }
        defer { finish() }
        return operation()
    }

    func presentAsync<Value>(_ operation: () async -> Value) async -> Value? {
        guard tryBegin() else { return nil }
        defer { finish() }
        return await operation()
    }

    /// Only the application-scoped pump calls this. Reserve before waiting so
    /// another window cannot steal the slot before its continuation resumes.
    /// The caller rechecks its window after waiting, before navigation or UI.
    func withFinderPresentation<Value>(_ operation: () async -> Value) async -> Value {
        precondition(!isFinderReserved, "The application owns only one Finder request pump")
        isFinderReserved = true
        defer { isFinderReserved = false }
        if isPresenting {
            await withCheckedContinuation { finderWaiter = $0 }
        }
        isPresenting = true
        defer { finish() }
        return await operation()
    }
}
