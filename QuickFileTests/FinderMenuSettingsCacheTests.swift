import XCTest
@testable import QuickFileCore
@testable import QuickFileInfrastructure

final class FinderMenuSettingsCacheTests: XCTestCase {
    func testColdAndWarmMenuReadsDoNotWaitForBlockedStorage() throws {
        let updated = try FinderMenuDisplayLimit(maximumCount: 2)
        for initial in [FinderMenuDisplayLimit.all, try FinderMenuDisplayLimit(maximumCount: 8)] {
            let read = MenuSettingsRead(.success(updated), blocked: true)
            defer { read.release() }
            let loader = MenuSettingsLoader([read])
            let cache = FinderMenuSettingsCache(load: { try loader.load() }, initialLimit: initial,
                                                refreshInterval: .infinity)
            XCTAssertTrue(waitForSemaphore(read.started))
            let returned = expectation(description: "100 memory-only menu reads returned while storage is blocked")
            DispatchQueue.global().async {
                for _ in 0..<100 { XCTAssertEqual(cache.currentLimit(), initial) }
                returned.fulfill()
            }
            wait(for: [returned], timeout: 2)
            XCTAssertEqual(loader.callCount, 1, "Menu reads must not enqueue duplicate storage reads")
            XCTAssertFalse(loader.didReadOnMainThread)
            read.release()
            XCTAssertTrue(waitUntil { cache.currentLimit() == updated })
        }
    }

    func testSaveNotificationRefreshesIndependentCacheWithoutPeriodicRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickFileMenuCache-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("finder-menu-settings.v1.json")
        let name = "QuickFileTests.menu-settings-cache.\(UUID())"
        let writer = FinderMenuSettingsStore(storageURL: url, changeNotificationName: name)
        let reader = FinderMenuSettingsStore(storageURL: url, changeNotificationName: name)
        let original = try FinderMenuDisplayLimit(maximumCount: 8)
        let updated = try FinderMenuDisplayLimit(maximumCount: 3)
        try writer.save(original)
        let cache = FinderMenuSettingsCache(store: reader, refreshInterval: .infinity)
        XCTAssertTrue(waitUntil { cache.currentLimit() == original })

        try writer.save(updated)
        XCTAssertTrue(waitUntil { cache.currentLimit() == updated }, "Notification must refresh an already-loaded cache")
        try writer.save(.all)
        XCTAssertTrue(waitUntil { cache.currentLimit() == .all })
    }

    func testMissedNotificationUsesZeroIntervalRefreshWithoutBlockingMenu() throws {
        let original = try FinderMenuDisplayLimit(maximumCount: 8)
        let updated = try FinderMenuDisplayLimit(maximumCount: 2)
        let first = MenuSettingsRead(.success(original), blocked: true)
        let second = MenuSettingsRead(.success(updated), blocked: true)
        defer { first.release(); second.release() }
        let loader = MenuSettingsLoader([first, second])
        // No notification observer: only a menu-time interval check can start the second read.
        let cache = FinderMenuSettingsCache(load: { try loader.load() }, refreshInterval: 0)
        XCTAssertTrue(waitForSemaphore(first.started))
        first.release()
        XCTAssertTrue(waitUntil { cache.currentLimit() == original })
        XCTAssertTrue(waitUntil {
            XCTAssertEqual(cache.currentLimit(), original)
            return second.started.wait(timeout: .now()) == .success
        })
        for _ in 0..<100 { XCTAssertEqual(cache.currentLimit(), original) }
        XCTAssertEqual(loader.callCount, 2)
        second.release()
        XCTAssertTrue(waitUntil { cache.currentLimit() == updated })
    }

    func testMalformedSettingsRetainLastGoodLimitUntilValidRecovery() throws {
        let original = try FinderMenuDisplayLimit(maximumCount: 9)
        let recovered = try FinderMenuDisplayLimit(maximumCount: 4)
        let first = MenuSettingsRead(.success(original))
        let failed = MenuSettingsRead(.failure(FinderMenuSettingsStore.StoreError.malformed))
        let repair = MenuSettingsRead(.success(recovered), blocked: true)
        defer { repair.release() }
        let loader = MenuSettingsLoader([first, failed, repair])
        let cache = FinderMenuSettingsCache(load: { try loader.load() }, refreshInterval: 0)
        var sawOriginal = false
        XCTAssertTrue(waitUntil {
            let limit = cache.currentLimit()
            if limit == original { sawOriginal = true }
            if sawOriginal { XCTAssertEqual(limit, original, "Malformed settings must not clear the last good limit") }
            return repair.started.wait(timeout: .now()) == .success
        })
        // The third read can start only after the failed read has completed. Blocking it
        // proves retention after failure, rather than racing with failure completion.
        XCTAssertTrue(sawOriginal)
        XCTAssertEqual(loader.callCount, 3)
        XCTAssertEqual(cache.currentLimit(), original)
        repair.release()
        XCTAssertTrue(waitUntil { cache.currentLimit() == recovered })
    }

    func testMalformedOrUnavailableInitialSettingsFallBackToAllAndRecover() throws {
        let failures: [Error] = [
            FinderMenuSettingsStore.StoreError.malformed,
            FinderMenuSettingsStore.StoreError.unavailable,
            FinderMenuSettingsStore.StoreError.readFailed(NSError(domain: NSCocoaErrorDomain,
                                                                   code: NSFileReadUnknownError))
        ]
        let recovered = try FinderMenuDisplayLimit(maximumCount: 5)
        for error in failures {
            let failed = MenuSettingsRead(.failure(error))
            let repair = MenuSettingsRead(.success(recovered), blocked: true)
            defer { repair.release() }
            let loader = MenuSettingsLoader([failed, repair])
            let cache = FinderMenuSettingsCache(load: { try loader.load() }, refreshInterval: 0)
            XCTAssertTrue(waitUntil {
                XCTAssertEqual(cache.currentLimit(), .all)
                return repair.started.wait(timeout: .now()) == .success
            })
            XCTAssertEqual(cache.currentLimit(), .all)
            repair.release()
            XCTAssertTrue(waitUntil { cache.currentLimit() == recovered })
        }
    }

    func testInvalidatedInFlightResultIsNeverPublishedAndRefreshesAreCoalesced() throws {
        let original = try FinderMenuDisplayLimit(maximumCount: 8)
        let obsolete = try FinderMenuDisplayLimit(maximumCount: 6)
        let newest = try FinderMenuDisplayLimit(maximumCount: 3)
        let staleRead = MenuSettingsRead(.success(obsolete), blocked: true)
        let newestRead = MenuSettingsRead(.success(newest), blocked: true)
        defer { staleRead.release(); newestRead.release() }
        let loader = MenuSettingsLoader([staleRead, newestRead])
        let cache = FinderMenuSettingsCache(load: { try loader.load() }, initialLimit: original,
                                            refreshInterval: .infinity)
        XCTAssertTrue(waitForSemaphore(staleRead.started))
        for _ in 0..<100 { cache.requestRefresh() }
        XCTAssertEqual(loader.callCount, 1)
        XCTAssertEqual(cache.currentLimit(), original)

        staleRead.release()
        XCTAssertTrue(waitForSemaphore(newestRead.started))
        // The older completion ran before this blocked replacement read began. It must
        // not be visible even briefly while the up-to-date result remains unavailable.
        for _ in 0..<100 { XCTAssertEqual(cache.currentLimit(), original) }
        XCTAssertEqual(loader.callCount, 2, "A notification burst should queue just one replacement read")
        XCTAssertEqual(loader.maximumConcurrentReads, 1)
        newestRead.release()
        XCTAssertTrue(waitUntil { cache.currentLimit() == newest })
        XCTAssertEqual(loader.callCount, 2)
    }

    func testInvalidationOfReplacementReadAlsoRejectsItsResult() throws {
        let original = try FinderMenuDisplayLimit(maximumCount: 10)
        let first = MenuSettingsRead(.success(try FinderMenuDisplayLimit(maximumCount: 8)), blocked: true)
        let second = MenuSettingsRead(.success(try FinderMenuDisplayLimit(maximumCount: 6)), blocked: true)
        let finalLimit = try FinderMenuDisplayLimit(maximumCount: 2)
        let third = MenuSettingsRead(.success(finalLimit), blocked: true)
        defer { first.release(); second.release(); third.release() }
        let loader = MenuSettingsLoader([first, second, third])
        let cache = FinderMenuSettingsCache(load: { try loader.load() }, initialLimit: original,
                                            refreshInterval: .infinity)
        XCTAssertTrue(waitForSemaphore(first.started))
        cache.requestRefresh()
        first.release()
        XCTAssertTrue(waitForSemaphore(second.started))
        XCTAssertEqual(cache.currentLimit(), original)
        cache.requestRefresh()
        second.release()
        XCTAssertTrue(waitForSemaphore(third.started))
        XCTAssertEqual(cache.currentLimit(), original)
        third.release()
        XCTAssertTrue(waitUntil { cache.currentLimit() == finalLimit })
        XCTAssertEqual(loader.callCount, 3)
    }

    func testBlockedReadDoesNotRetainCache() throws {
        let read = MenuSettingsRead(.success(try FinderMenuDisplayLimit(maximumCount: 2)), blocked: true)
        defer { read.release() }
        let loader = MenuSettingsLoader([read])
        var cache: FinderMenuSettingsCache? = FinderMenuSettingsCache(load: { try loader.load() })
        weak var weakCache = cache
        XCTAssertTrue(waitForSemaphore(read.started))
        cache = nil
        XCTAssertNil(weakCache)
        read.release()
        XCTAssertTrue(waitForSemaphore(read.finished))
    }

    private func waitForSemaphore(_ semaphore: DispatchSemaphore) -> Bool {
        waitUntil { semaphore.wait(timeout: .now()) == .success }
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        } while Date() < deadline
        return predicate()
    }
}

private final class MenuSettingsRead: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let result: Result<FinderMenuDisplayLimit, Error>
    private let gate: DispatchSemaphore?

    init(_ result: Result<FinderMenuDisplayLimit, Error>, blocked: Bool = false) {
        self.result = result
        gate = blocked ? DispatchSemaphore(value: 0) : nil
    }

    func perform() throws -> FinderMenuDisplayLimit {
        started.signal()
        defer { finished.signal() }
        if let gate, gate.wait(timeout: .now() + 10) != .success {
            throw MenuSettingsTestError.readTimedOut
        }
        return try result.get()
    }

    func release() { gate?.signal() }
}

private enum MenuSettingsTestError: Error {
    case readTimedOut
}

private final class MenuSettingsLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let reads: [MenuSettingsRead]
    private var calls = 0
    private var activeReads = 0
    private var peakActiveReads = 0
    private var mainThreadRead = false

    init(_ reads: [MenuSettingsRead]) {
        precondition(!reads.isEmpty)
        self.reads = reads
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var maximumConcurrentReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakActiveReads
    }

    var didReadOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mainThreadRead
    }

    func load() throws -> FinderMenuDisplayLimit {
        lock.lock()
        let index = calls
        calls += 1
        activeReads += 1
        peakActiveReads = max(peakActiveReads, activeReads)
        mainThreadRead = mainThreadRead || Thread.isMainThread
        lock.unlock()
        defer {
            lock.lock()
            activeReads -= 1
            lock.unlock()
        }
        // Interval-zero polling may request another refresh after the final result.
        // Keep returning that result without reusing an already-consumed test gate.
        guard index < reads.count else { return try reads[reads.count - 1].result.get() }
        return try reads[index].perform()
    }
}
