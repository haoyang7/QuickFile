import Foundation
import QuickFileCore

/// Admits work only when it can start. There is no unbounded pending-work queue.
/// Two creations let a local operation proceed while one destination is slow; an
/// independent, single-slot handoff cannot be held behind file-system creation.
final class FinderOperationScheduler: @unchecked Sendable {
    enum Admission: Equatable {
        case accepted, targetBusy, capacityReached
    }

    private let lock = NSLock()
    // Used only for admission, never to choose a write destination. A conservative
    // collision rejects concurrent clicks; it cannot send a file to another folder.
    private struct AdmissionKey: Equatable {
        let context: FinderMenuContext
        let target: URL?
        let firstSelection: URL?

        init(_ action: FinderMenuAction) {
            context = action.context
            switch action.target {
            case let .directory(url):
                target = url
                firstSelection = nil
            case let .selection(targetedURL, selectedItemURLs):
                target = targetedURL
                firstSelection = selectedItemURLs.first
            }
        }
    }

    private var activeCreations: [UUID: AdmissionKey] = [:]
    private var authorizationInFlight = false
    private let creationQueue = DispatchQueue(
        label: "com.haoyoung.QuickFile.finder-file-creation",
        qos: .userInitiated, attributes: .concurrent
    )
    private let authorizationQueue = DispatchQueue(
        label: "com.haoyoung.QuickFile.finder-authorization-transfer", qos: .userInitiated
    )

    var hasCreationCapacity: Bool {
        lock.lock(); defer { lock.unlock() }
        return activeCreations.count < 2
    }

    func submitCreation(_ action: FinderMenuAction, operation: @escaping @Sendable () -> Void) -> Admission {
        let key = AdmissionKey(action)
        lock.lock()
        guard !activeCreations.values.contains(key) else {
            lock.unlock()
            return .targetBusy
        }
        guard activeCreations.count < 2 else {
            lock.unlock()
            return .capacityReached
        }
        let id = UUID()
        activeCreations[id] = key
        lock.unlock()

        creationQueue.async { [weak self] in
            defer {
                if let self {
                    self.lock.lock()
                    self.activeCreations.removeValue(forKey: id)
                    self.lock.unlock()
                }
            }
            operation()
        }
        return .accepted
    }

    func submitAuthorization(operation: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard !authorizationInFlight else { lock.unlock(); return false }
        authorizationInFlight = true
        lock.unlock()
        authorizationQueue.async { [weak self] in
            defer {
                if let self {
                    self.lock.lock()
                    self.authorizationInFlight = false
                    self.lock.unlock()
                }
            }
            operation()
        }
        return true
    }
}
