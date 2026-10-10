import Foundation
import QuickFileCore
import QuickFileInfrastructure

/// Independent of template availability: malformed preferences never block creation.
/// At most one background read, with last-known-good (initially all) memory-only snapshots.
final class FinderMenuSettingsCache: @unchecked Sendable {
    private let load: @Sendable () throws -> FinderMenuDisplayLimit
    private let queue = DispatchQueue(label: "com.haoyoung.QuickFile.finder-menu-settings", qos: .utility)
    private let lock = NSLock()
    private var limit: FinderMenuDisplayLimit
    private var inFlight = false
    private var needsRefresh = false
    private var generation: UInt64 = 0
    private var lastRead: TimeInterval = -.infinity
    private let refreshInterval: TimeInterval
    private var observer: DarwinTemplateNotificationObserver?

    convenience init(store: FinderMenuSettingsStore = FinderMenuSettingsStore(), refreshInterval: TimeInterval = 5) {
        self.init(load: { try store.load() }, notificationName: store.changeNotificationName,
                  refreshInterval: refreshInterval)
    }

    init(load: @escaping @Sendable () throws -> FinderMenuDisplayLimit,
         notificationName: String? = nil, initialLimit: FinderMenuDisplayLimit = .all,
         refreshInterval: TimeInterval = 5) {
        self.load = load
        self.limit = initialLimit
        self.refreshInterval = refreshInterval
        if let notificationName {
            observer = DarwinTemplateNotificationObserver(name: notificationName) { [weak self] in
                self?.requestRefresh()
            }
        }
        requestRefresh()
    }

    func currentLimit() -> FinderMenuDisplayLimit {
        lock.lock()
        let value = limit
        if !inFlight, ProcessInfo.processInfo.systemUptime - lastRead >= refreshInterval {
            startReadLocked()
        }
        lock.unlock()
        return value
    }

    /// Invalidate before queueing; an older in-flight read cannot publish after a notification.
    func requestRefresh() {
        lock.lock()
        generation &+= 1
        if inFlight { needsRefresh = true }
        else { startReadLocked() }
        lock.unlock()
    }

    private func startReadLocked() {
        inFlight = true
        let readGeneration = generation
        let load = load
        queue.async { [weak self] in
            let result = try? load()
            self?.complete(result, generation: readGeneration)
        }
    }

    private func complete(_ result: FinderMenuDisplayLimit?, generation readGeneration: UInt64) {
        lock.lock()
        if readGeneration == generation, let result { limit = result }
        lastRead = ProcessInfo.processInfo.systemUptime
        inFlight = false
        if needsRefresh {
            needsRefresh = false
            startReadLocked()
        }
        lock.unlock()
    }
}
