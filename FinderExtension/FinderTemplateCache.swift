import Foundation
import notify
import QuickFileCore
import QuickFileInfrastructure

/// Keeps Finder menu readiness bounded despite App Group file-system latency.
/// A stalled read occupies at most one utility-queue operation while menus report loading or
/// refresh failure from the in-memory snapshot.
final class FinderTemplateCache: @unchecked Sendable {
    enum Snapshot: Equatable {
        case loading(previous: [FinderTemplateMenuEntry])
        case ready([FinderTemplateMenuEntry])
        case refreshFailed(previous: [FinderTemplateMenuEntry])

        var entries: [FinderTemplateMenuEntry] {
            switch self {
            case let .loading(templates), let .ready(templates), let .refreshFailed(templates):
                return templates
            }
        }
    }

    private let loadForCreation: @Sendable (UUID) throws -> TemplateStore.CreationSnapshot
    private let loadMenuEntries: @Sendable () throws -> [FinderTemplateMenuEntry]
    private let refreshQueue = DispatchQueue(
        label: "com.haoyoung.QuickFile.finder-template-cache",
        qos: .utility
    )
    private let lock = NSLock()
    private let refreshCompletion = DispatchGroup()
    private var snapshot: Snapshot
    private var isRefreshInFlight = false
    private var refreshRequested = false
    private let refreshInterval: TimeInterval
    private var lastRefreshTime = ProcessInfo.processInfo.systemUptime
    private var refreshGeneration: UInt64 = 0
    private var notificationObserver: DarwinTemplateNotificationObserver?

    convenience init() {
        // The reusable menu reader retains only a digest and display metadata.
        // Execution validates every record with a separate operation-scoped reader,
        // retaining only the requested body and fresh menu metadata.
        let menuStore = TemplateStore(cachesReads: false, cachesMenuReads: true)
        self.init(
            loadForCreation: { try TemplateStore(cachesReads: false).reloadCreationSnapshot(templateID: $0) },
            loadMenuEntries: { try menuStore.reloadMenuEntries() }
        )
    }

    init(
        loadForCreation: @escaping @Sendable (UUID) throws -> TemplateStore.CreationSnapshot,
        loadMenuEntries: @escaping @Sendable () throws -> [FinderTemplateMenuEntry],
        changeNotificationName: String = QuickFileConfiguration.templatesDidChangeDarwinNotification,
        initialTemplates: [FileTemplate] = [],
        refreshInterval: TimeInterval = 5
    ) {
        self.loadForCreation = loadForCreation
        self.loadMenuEntries = loadMenuEntries
        self.refreshInterval = refreshInterval
        snapshot = .loading(previous: FinderMenuModelBuilder().entries(from: initialTemplates))
        notificationObserver = DarwinTemplateNotificationObserver(
            name: changeNotificationName
        ) { [weak self] in
            self?.scheduleRefresh()
        }
        scheduleRefresh()
    }

    /// Returns immediately from memory; menu construction never performs file-system I/O.
    func currentSnapshot() -> Snapshot {
        lock.lock()
        let currentSnapshot = snapshot
        var shouldRetry = false
        if !isRefreshInFlight {
            switch snapshot {
            case .refreshFailed:
                snapshot = .loading(previous: snapshot.entries)
                shouldRetry = true
            case .ready:
                shouldRetry = ProcessInfo.processInfo.systemUptime - lastRefreshTime >= refreshInterval
            case .loading:
                break
            }
            if shouldRetry { isRefreshInFlight = true }
        }
        lock.unlock()

        // Compensate for missed notifications on menu use, at most once per interval while ready.
        // Failed reads retry on the next request; the in-flight flag coalesces concurrent menus.
        if shouldRetry {
            enqueueRefresh()
        }
        return currentSnapshot
    }

    func currentEntries() -> [FinderTemplateMenuEntry] {
        currentSnapshot().entries
    }

    /// Shares the destination preparation's deadline instead of adding another wait.
    /// Loading never advertises defaults or a previous template snapshot.
    func menuSnapshot(waitingUntil deadline: DispatchTime) -> Snapshot {
        let current = currentSnapshot()
        guard case .loading = current else { return current }
        _ = refreshCompletion.wait(timeout: deadline)
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// Called on the creation queue; a menu snapshot is never authoritative for an action.
    func templateForCreation(id: UUID) throws -> FileTemplate? {
        let generation = beginRead()
        do {
            let loaded = try loadForCreation(id)
            publish(loaded.menuEntries, generation: generation)
            return loaded.template
        } catch {
            publish(nil, generation: generation)
            throw error
        }
    }

    private func scheduleRefresh() {
        lock.lock()
        // A notification invalidates every read that started before it, including
        // creation reads while the single background refresh is still occupied.
        refreshGeneration &+= 1
        let previousTemplates = snapshot.entries
        snapshot = .loading(previous: previousTemplates)
        guard !isRefreshInFlight else {
            refreshRequested = true
            lock.unlock()
            return
        }
        isRefreshInFlight = true
        lock.unlock()

        enqueueRefresh()
    }

    private func enqueueRefresh() {
        let load = loadMenuEntries
        let generation = beginRead()
        let completion = refreshCompletion
        completion.enter()
        refreshQueue.async { [weak self] in
            defer { completion.leave() }
            // Keep the last menu snapshot on failure; execution always performs a throwing reload.
            let entries = try? load()
            self?.completeRefresh(with: entries, generation: generation)
        }
    }

    private func beginRead() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        refreshGeneration &+= 1
        return refreshGeneration
    }

    private func publish(_ templates: [FinderTemplateMenuEntry]?, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        publishLocked(templates, generation: generation)
    }

    private func publishLocked(_ templates: [FinderTemplateMenuEntry]?, generation: UInt64) {
        guard generation == refreshGeneration else { return }
        snapshot = templates.map(Snapshot.ready) ?? .refreshFailed(previous: snapshot.entries)
        lastRefreshTime = ProcessInfo.processInfo.systemUptime
    }

    private func completeRefresh(with loadedTemplates: [FinderTemplateMenuEntry]?, generation: UInt64) {
        lock.lock()
        publishLocked(loadedTemplates, generation: generation)
        let shouldRefreshAgain = refreshRequested
        refreshRequested = false
        isRefreshInFlight = shouldRefreshAgain
        if shouldRefreshAgain {
            snapshot = .loading(previous: snapshot.entries)
        }
        lock.unlock()

        if shouldRefreshAgain {
            enqueueRefresh()
        }
    }
}

// The notification system owns the dispatch block, including its handler capture.
// An already-running callback remains valid even when cancellation races with teardown.
final class DarwinTemplateNotificationObserver: @unchecked Sendable {
    private let token: Int32?

    init(name: String, handler: @escaping @Sendable () -> Void) {
        var registration: Int32 = 0
        let status = notify_register_dispatch(name, &registration, .global(qos: .utility)) { _ in
            handler()
        }
        // Menu-time compensation still refreshes the cache if registration fails.
        token = status == NOTIFY_STATUS_OK ? registration : nil
    }

    deinit {
        if let token { notify_cancel(token) }
    }
}
