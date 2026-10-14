import Foundation

/// Retains the facts of a completed operation, resolving its display text in the
/// current language when a view reads it. Capture immutable result values, never
/// a view model or a draft; rendering must not repeat work or change state.
/// Transitional adapter for existing feedback. Prefer semantic results/errors or
/// LocalizedStringResource values in new code; resolve through QuickFileLocalization.
struct LocalizedPresentation<Value> {
    private let resolve: @MainActor () -> Value

    init(_ value: @autoclosure @escaping @MainActor () -> Value) {
        resolve = value
    }

    @MainActor var value: Value { resolve() }
}
