import Foundation
import QuickFileCore
import QuickFileInfrastructure

/// Coalesces settings reads on one worker queue. Menu use only schedules a stale
/// refresh; it never waits for preferences or loads translation resources.
final class FinderLanguageSettings: @unchecked Sendable {
    private let load: @Sendable () throws -> QuickFileLanguage
    private let apply: @Sendable (QuickFileLanguage) -> Void
    private let queue = DispatchQueue(label: "com.haoyoung.QuickFile.finder-language", qos: .utility)
    private let lock = NSLock()
    private var inFlight = false
    private var needsRefresh = false
    private var generation: UInt64 = 0
    private var lastRead: TimeInterval = -.infinity
    private let refreshInterval: TimeInterval
    private var observer: DarwinTemplateNotificationObserver?

    init(load: @escaping @Sendable () throws -> QuickFileLanguage = { try LanguageSettingsStore().load() },
         apply: @escaping @Sendable (QuickFileLanguage) -> Void = { QuickFileLocalization.apply($0) },
         notificationName: String? = LanguageSettingsStore.notificationName,
         refreshInterval: TimeInterval = 5) {
        self.load = load
        self.apply = apply
        self.refreshInterval = refreshInterval
        QuickFileLocalization.prepareResources()
        if let notificationName {
            observer = DarwinTemplateNotificationObserver(name: notificationName) { [weak self] in
                self?.requestRefresh()
            }
        }
        requestRefresh()
    }

    func refreshIfNeeded() {
        lock.lock()
        if !inFlight, ProcessInfo.processInfo.systemUptime - lastRead >= refreshInterval { startReadLocked() }
        lock.unlock()
    }

    func requestRefresh() {
        lock.lock()
        generation &+= 1
        if inFlight { needsRefresh = true } else { startReadLocked() }
        lock.unlock()
    }

    private func startReadLocked() {
        inFlight = true
        let readGeneration = generation
        queue.async { [weak self] in
            guard let self else { return }
            let result = try? self.load()
            // Bundles were prepared before menus can run. Publication is memory-only;
            // the apply closure must not perform I/O or call back into this cache.
            self.lock.lock()
            if readGeneration == self.generation, let result { self.apply(result) }
            self.lastRead = ProcessInfo.processInfo.systemUptime
            self.inFlight = false
            if self.needsRefresh {
                self.needsRefresh = false
                self.startReadLocked()
            }
            self.lock.unlock()
        }
    }
}
