import Foundation

/// Presentation only. This never changes templates or authorizes a creation action.
public struct FinderMenuDisplayLimit: Equatable, Sendable {
    public let maximumCount: Int?
    public static let all = FinderMenuDisplayLimit()

    public enum ValidationError: LocalizedError {
        case positiveIntegerRequired
        public var errorDescription: String? { "请输入大于 0 的整数，或选择“全部”。" }
    }

    private init() { maximumCount = nil }

    public init(maximumCount: Int?) throws {
        if let maximumCount, maximumCount <= 0 { throw ValidationError.positiveIntegerRequired }
        self.maximumCount = maximumCount
    }

    public static func parse(_ text: String) throws -> Self {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let count = Int(value) else { throw ValidationError.positiveIntegerRequired }
        return try Self(maximumCount: count)
    }
}
