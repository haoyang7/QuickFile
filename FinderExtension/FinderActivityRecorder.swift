import Foundation
import OSLog
import QuickFileCore
import QuickFileInfrastructure

/// Activity storage must never delay Finder feedback or wait on the creation queue.
final class FinderActivityRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.haoyoung.QuickFile.finder-activity", qos: .utility)
    private let persist: @Sendable (FinderExtensionActivityKind, FinderExtensionActivityFailure?, Date) throws -> Void
    private let logger = Logger(subsystem: QuickFileConfiguration.appBundleIdentifier, category: "FinderActivity")
    private let pending = PendingRecords()

    // One writer, at most 20 waiting failures, one success and one menu/launch state.
    // Success/menu storms cannot evict failures. Overflow keeps the newest failures,
    // matching the persisted history limit. No pending block retains the recorder.
    private final class PendingRecords: @unchecked Sendable {
        let lock = NSLock()
        var failures: [FinderExtensionActivity] = []
        var success: FinderExtensionActivity?
        var status: FinderExtensionActivity?
        var isDraining = false
        var isClosed = false

        func next() -> FinderExtensionActivity? {
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return nil }
            let event: FinderExtensionActivity?
            if !failures.isEmpty {
                event = failures.removeFirst()
            } else if let created = success {
                event = created
                success = nil
            } else {
                event = status
                status = nil
            }
            if event == nil { isDraining = false }
            return event
        }
    }

    init(store: FinderExtensionActivityStore = FinderExtensionActivityStore()) {
        persist = { kind, failure, timestamp in try store.record(kind, failure: failure, at: timestamp) }
    }

    init(persist: @escaping @Sendable (FinderExtensionActivityKind, FinderExtensionActivityFailure?, Date) throws -> Void) {
        self.persist = persist
    }

    func record(_ kind: FinderExtensionActivityKind, failure: FinderExtensionActivityFailure? = nil) {
        pending.lock.lock()
        let event = FinderExtensionActivity(kind: kind, timestamp: Date(), failure: failure)
        // Clear superseded state at insertion, preserving arrival order even when
        // two events have identical wall-clock timestamps.
        if failure != nil || kind == .fileCreationFailed {
            if pending.failures.count == FinderExtensionActivityStore.defaultMaximumFailureCount {
                pending.failures.removeFirst()
            }
            pending.failures.append(event)
            pending.success = nil
            pending.status = nil
        } else if kind == .fileCreated {
            pending.success = event
            pending.status = nil
        } else {
            pending.status = event
        }
        let shouldStart = !pending.isDraining
        pending.isDraining = true
        pending.lock.unlock()
        guard shouldStart else { return }

        queue.async { [pending, persist, logger] in
            while let event = pending.next() {
                do {
                    try persist(event.kind, event.failure, event.timestamp)
                } catch {
                    let error = error as NSError
                    logger.error("Unable to persist activity: domain=\(error.domain, privacy: .public) code=\(error.code)")
                }
            }
        }
    }

    deinit {
        pending.lock.lock()
        pending.isClosed = true
        pending.failures.removeAll()
        pending.success = nil
        pending.status = nil
        pending.lock.unlock()
    }
}
