import AppKit
import Foundation
import notify

/// Notification callbacks never own the app model. Cancellation unregisters both
/// sources; a callback already queued during teardown only holds the weak handler.
final class TemplateRefreshObserver: @unchecked Sendable {
    private let darwinToken: Int32?
    private let activationToken: NSObjectProtocol

    init(name: String, handler: @escaping @Sendable (Bool) -> Void) {
        var token: Int32 = 0
        let result = notify_register_dispatch(name, &token, .main) { _ in handler(true) }
        darwinToken = result == NOTIFY_STATUS_OK ? token : nil
        activationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in handler(false) }
    }

    deinit {
        if let darwinToken { notify_cancel(darwinToken) }
        NotificationCenter.default.removeObserver(activationToken)
    }
}
