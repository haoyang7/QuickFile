import Foundation

// Shared by dependency-injection tests. Mutable captured values are only read or
// changed under this lock; callbacks must not re-enter the same value while updating it.
final class LockedTestValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }

    @discardableResult
    func update<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}

// MainActor-only suspension for callback tests. Release is remembered even when
// an expectation times out before the callback starts, so cleanup cannot strand
// a late checked continuation and hang the test runner.
@MainActor
final class AsyncTestGate<Value: Sendable> {
    private enum State {
        case pending
        case released(Value)
    }
    private var state = State.pending
    private var continuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        if case let .released(value) = state { return value }
        return await withCheckedContinuation { pending in
            precondition(continuation == nil, "Only one pending waiter is supported")
            continuation = pending
        }
    }

    func release(_ value: Value) {
        guard case .pending = state else { return }
        state = .released(value)
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }
}
