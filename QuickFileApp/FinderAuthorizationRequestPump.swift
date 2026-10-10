import Foundation
import QuickFileCore

/// Sequential request-drain orchestration owned by the app-scoped QuickFileViewModel.
/// The ViewModel admits one drain and owns all published busy/form/result state; this
/// helper owns only its recheck signal, never stores callbacks, and never starts a task.
/// Queue claims run on BackgroundWork; panel, cancellation, failure, and completion
/// callbacks run on MainActor. Storage and authorization/creation policy stay elsewhere.
@MainActor
final class FinderAuthorizationRequestPump {
    private var needsRecheck = false
    private let presentationGate: AppModalPresentationGate

    init(presentationGate: AppModalPresentationGate? = nil) {
        self.presentationGate = presentationGate ?? .shared
    }

    /// Called by the owner when another window/notification arrives during its drain.
    func requestRecheck() {
        needsRecheck = true
    }

    /// The owner must hold its processing admission through this entire awaited call.
    func drain(
        takePendingRequest: @escaping @Sendable () throws -> FinderAuthorizationRequest?,
        willReadQueue: @MainActor () -> Void = {},
        prepareForPresentation: @MainActor () async -> Void = {},
        willPresent: @MainActor () -> Void,
        confirmAuthorization: @MainActor (FinderAuthorizationRequest) -> URL?,
        complete: @MainActor (FinderAuthorizationRequest, URL) async -> Bool,
        didCancel: @MainActor () -> Void,
        didFail: @MainActor (Error) -> Void,
        didFindNoClaimableRequest: @MainActor () -> Void = {},
        isPresentationAvailable: @MainActor () -> Bool = { true },
        didCancelForUnavailableWindow: @MainActor (FinderAuthorizationRequest) -> Void = { _ in }
    ) async {
        while true {
            // A closed/replaced window must not claim queued work merely to cancel it.
            guard isPresentationAvailable() else { return }
            needsRecheck = false
            willReadQueue()
            let result = await BackgroundWork.result(takePendingRequest)
            // The synchronous queue claim may finish after the initiating window closes.
            // Cancel only that already-claimed request. Never drain the rest, present a
            // stale panel, or blindly requeue into a queue whose capacity may have changed.
            guard isPresentationAvailable() else {
                if case let .success(pending) = result, let pending {
                    didCancelForUnavailableWindow(pending)
                }
                return
            }
            let request: FinderAuthorizationRequest
            switch result {
            case let .success(pending):
                guard let pending else {
                    // Do not lose a notification that arrived during an empty queue read.
                    if needsRecheck { continue }
                    didFindNoClaimableRequest()
                    return
                }
                request = pending
            case let .failure(error):
                // Queue feedback is app-wide and must not navigate an independent
                // operation to another tab merely because background I/O failed.
                didFail(error)
                return
            }

            // At most this one claim waits behind an already-running direct
            // operation. Its owner reserves admission before waiting and does not
            // treat Task cancellation as proof that the underlying I/O ended.
            await prepareForPresentation()
            guard isPresentationAvailable() else {
                didCancelForUnavailableWindow(request)
                return
            }
            let directory = await presentationGate.withFinderPresentation {
                guard isPresentationAvailable() else { return nil as URL? }
                willPresent()
                guard isPresentationAvailable() else { return nil }
                return confirmAuthorization(request)
            }
            // NSOpenPanel.runModal may process window-close events before returning.
            // A stale panel result must not begin an unstarted creation operation.
            guard isPresentationAvailable() else {
                didCancelForUnavailableWindow(request)
                return
            }
            guard let directory else {
                didCancel()
                return
            }
            // Cancellation ends this drain after only its claimed request. The owner
            // keeps the app-wide pause until an explicit user continuation. A failed
            // completion also leaves all requests not yet claimed for a later drain.
            if !(await complete(request, directory)) { return }
        }
    }
}
