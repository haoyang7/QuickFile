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
    private let loadChangeToken: (@Sendable () throws -> TemplateStore.ChangeToken)?
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
    // Protected with the snapshot by lock; only a matching authoritative read establishes it.
    private var menuChangeToken: TemplateStore.ChangeToken?
    private var notificationObserver: DarwinTemplateNotificationObserver?

    convenience init() {
        // The reusable menu reader retains only a digest and display metadata.
        // Execution validates every record with a separate operation-scoped reader,
        // retaining only the requested body and fresh menu metadata.
        let menuStore = TemplateStore(cachesReads: false, cachesMenuReads: true)
        self.init(
            loadForCreation: { try TemplateStore(cachesReads: false).reloadCreationSnapshot(templateID: $0) },
            loadMenuEntries: { try menuStore.reloadMenuEntries() },
            loadChangeToken: { try menuStore.changeToken() }
        )
    }

    init(
        loadForCreation: @escaping @Sendable (UUID) throws -> TemplateStore.CreationSnapshot,
        loadMenuEntries: @escaping @Sendable () throws -> [FinderTemplateMenuEntry],
        loadChangeToken: (@Sendable () throws -> TemplateStore.ChangeToken)? = nil,
        changeNotificationName: String = QuickFileConfiguration.templatesDidChangeDarwinNotification,
        initialTemplates: [FileTemplate] = [],
        refreshInterval: TimeInterval = 5
    ) {
        self.loadForCreation = loadForCreation
        self.loadMenuEntries = loadMenuEntries
        self.loadChangeToken = loadChangeToken
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
        var needsAuthority = true
        if !isRefreshInFlight {
            switch snapshot {
            case .refreshFailed:
                snapshot = .loading(previous: snapshot.entries)
                shouldRetry = true
            case .ready:
                shouldRetry = ProcessInfo.processInfo.systemUptime - lastRefreshTime >= refreshInterval
                needsAuthority = false
            case .loading:
                break
            }
            if shouldRetry { isRefreshInFlight = true }
        }
        lock.unlock()

        // Compensate for missed notifications on menu use, at most once per interval while ready.
        // Failed reads retry on the next request; the in-flight flag coalesces concurrent menus.
        if shouldRetry {
            enqueueRefresh(needsAuthority: needsAuthority)
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
        menuChangeToken = nil
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

    private enum RefreshResult {
        case unchanged(TemplateStore.ChangeToken)
        case loaded([FinderTemplateMenuEntry]?, token: TemplateStore.ChangeToken?)
    }

    private func enqueueRefresh(needsAuthority: Bool = true) {
        let load = loadMenuEntries
        let loadToken = loadChangeToken
        lock.lock()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let cachedToken = menuChangeToken
        lock.unlock()
        let completion = refreshCompletion
        completion.enter()
        refreshQueue.async { [weak self] in
            defer { completion.leave() }
            // Token I/O stays on this single background slot. A failed check must still
            // read authority; a token spanning a changed file cannot describe the loaded menu.
            let before = loadToken.flatMap { try? $0() }
            let result: RefreshResult
            if !needsAuthority, let before, before == cachedToken {
                result = .unchanged(before)
            } else {
                // Keep the last menu snapshot on failure; execution always performs a throwing reload.
                let entries = try? load()
                let after = entries == nil ? nil : loadToken.flatMap { try? $0() }
                result = .loaded(entries, token: before == after ? after : nil)
            }
            self?.completeRefresh(with: result, generation: generation)
        }
    }

    private func beginRead() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        refreshGeneration &+= 1
        // Creation publishes fresh metadata without a paired token check. Never keep a
        // token belonging to the earlier menu, even while its background check is running.
        menuChangeToken = nil
        return refreshGeneration
    }

    private func publish(_ templates: [FinderTemplateMenuEntry]?, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        publishLocked(templates, generation: generation)
    }

    private func publishLocked(
        _ templates: [FinderTemplateMenuEntry]?, generation: UInt64,
        token: TemplateStore.ChangeToken? = nil
    ) {
        guard generation == refreshGeneration else { return }
        snapshot = templates.map(Snapshot.ready) ?? .refreshFailed(previous: snapshot.entries)
        menuChangeToken = templates == nil ? nil : token
        lastRefreshTime = ProcessInfo.processInfo.systemUptime
    }

    private func completeRefresh(with result: RefreshResult, generation: UInt64) {
        lock.lock()
        switch result {
        case let .loaded(entries, token):
            publishLocked(entries, generation: generation, token: token)
        case let .unchanged(token):
            if generation == refreshGeneration {
                menuChangeToken = token
                lastRefreshTime = ProcessInfo.processInfo.systemUptime
            }
        }
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
