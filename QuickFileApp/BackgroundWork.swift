import Foundation

enum BackgroundWork {
    private static let queue = DispatchQueue(
        label: "com.haoyoung.QuickFile.background-work",
        qos: .utility,
        attributes: .concurrent
    )

    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }

    static func result<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async -> Result<Value, Error> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Result(catching: operation))
            }
        }
    }
}
