import XCTest
@testable import QuickFileCore

final class FinderMenuDestinationCacheTests: XCTestCase {
    func testColdDestinationCanBecomeReadyInTheFirstMenuRequest() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = LockedPreparationCount()
        let cache = FinderMenuDestinationCache { _ in
            XCTAssertFalse(Thread.isMainThread)
            _ = calls.increment()
            started.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return destination
        }
        DispatchQueue.global().async {
            XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
            release.signal()
        }
        XCTAssertEqual(cache.menuSnapshot(for: selection("Cold"), waitingUntil: .now() + 2), .ready(destination))
        XCTAssertEqual(calls.value, 1)
    }

    func testExpiredMenuDeadlineDoesNotReleaseOrDuplicateStalledPreparation() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = LockedPreparationCount()
        let cache = FinderMenuDestinationCache { _ in
            _ = calls.increment()
            started.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return nil
        }
        let selection = selection("Slow")
        XCTAssertEqual(cache.currentSnapshot(for: selection), .loading)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        for _ in 0..<10 {
            XCTAssertEqual(cache.menuSnapshot(for: selection, waitingUntil: .now()), .loading)
        }
        XCTAssertEqual(cache.activePreparationCount, 1)
        XCTAssertEqual(calls.value, 1)
        release.signal()
        try waitUntil { cache.activePreparationCount == 0 }
    }

    func testInvalidationDuringMenuWaitCannotPublishAnOldDestination() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let cache = FinderMenuDestinationCache { _ in
            started.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return destination
        }
        let selection = selection("Invalidated")
        DispatchQueue.global().async {
            XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
            cache.invalidate(selection)
            release.signal()
        }
        XCTAssertEqual(cache.menuSnapshot(for: selection, waitingUntil: .now() + 2), .unavailable)
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertNil(cache.cachedSnapshot(for: selection))
    }

    func testMenuSnapshotDoesNotWaitForBlockedBackgroundMetadata() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let returned = expectation(description: "menu returned while metadata is blocked")
        let cache = FinderMenuDestinationCache { _ in
            XCTAssertFalse(Thread.isMainThread)
            started.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return nil
        }
        let selection = selection("Slow")
        DispatchQueue.global().async {
            XCTAssertEqual(cache.currentSnapshot(for: selection), .loading)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 2)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        for _ in 0..<100 {
            XCTAssertEqual(cache.currentSnapshot(for: selection), .loading)
        }
        XCTAssertEqual(cache.activePreparationCount, 1)
        release.signal()
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedSnapshot(for: selection), .unavailable)
    }

    func testReadySnapshotRemainsReadableWhileAliasNormalizationIsBlocked() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let normalizationStarted = DispatchSemaphore(value: 0)
        let releaseNormalization = DispatchSemaphore(value: 0)
        let snapshotReturned = DispatchSemaphore(value: 0)
        defer { releaseNormalization.signal() }
        let calls = LockedPreparationCount()
        let cache = FinderMenuDestinationCache(maximumConcurrentPreparations: 1, standardizeURL: { url in
            XCTAssertFalse(Thread.isMainThread)
            normalizationStarted.signal()
            XCTAssertEqual(releaseNormalization.wait(timeout: .now() + 5), .success)
            return url.standardizedFileURL
        }, prepare: { _ in
            _ = calls.increment()
            return destination
        })
        let readySelection = selection("Already-ready")
        XCTAssertEqual(cache.currentSnapshot(for: readySelection), .loading)
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedSnapshot(for: readySelection), .ready(destination))
        let container = FinderMenuSelection(context: .container, targetedURL: destination.folder, selectedItemURLs: [])
        let toolbar = FinderMenuSelection(context: .toolbar, targetedURL: destination.folder, selectedItemURLs: [])
        XCTAssertEqual(cache.currentSnapshot(for: container), .loading)
        XCTAssertEqual(normalizationStarted.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            XCTAssertEqual(cache.cachedSnapshot(for: readySelection), .ready(destination))
            XCTAssertEqual(cache.currentSnapshot(for: readySelection), .ready(destination))
            XCTAssertEqual(cache.currentSnapshot(for: container), .loading)
            XCTAssertEqual(cache.currentSnapshot(for: toolbar), .loading)
            XCTAssertEqual(cache.activePreparationCount, 1, "Normalization must keep its preparation slot")
            XCTAssertEqual(calls.value, 2, "A blocked normalization must not admit another preparation")
            snapshotReturned.signal()
        }
        XCTAssertEqual(snapshotReturned.wait(timeout: .now() + 2), .success,
                       "Cached menu reads must return before the normalization dependency is released")
        releaseNormalization.signal()
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedSnapshot(for: container), .ready(destination))
        XCTAssertEqual(cache.cachedSnapshot(for: toolbar), .ready(destination))
    }

    func testInvalidationDuringAliasNormalizationCannotRepublishEitherContext() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let normalizationStarted = DispatchSemaphore(value: 0)
        let releaseNormalization = DispatchSemaphore(value: 0)
        let invalidationReturned = DispatchSemaphore(value: 0)
        defer { releaseNormalization.signal() }
        let cache = FinderMenuDestinationCache(standardizeURL: { url in
            normalizationStarted.signal()
            XCTAssertEqual(releaseNormalization.wait(timeout: .now() + 5), .success)
            return url.standardizedFileURL
        }, prepare: { _ in destination })
        let selections = [FinderMenuContext.container, .toolbar].map {
            FinderMenuSelection(context: $0, targetedURL: destination.folder, selectedItemURLs: [])
        }
        cache.prewarmObservedDirectory(at: destination.folder)
        XCTAssertEqual(normalizationStarted.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            for selection in selections {
                cache.invalidate(selection)
                XCTAssertEqual(cache.currentSnapshot(for: selection), .loading)
            }
            XCTAssertEqual(cache.activePreparationCount, 1)
            invalidationReturned.signal()
        }
        XCTAssertEqual(invalidationReturned.wait(timeout: .now() + 2), .success)
        releaseNormalization.signal()
        try waitUntil { cache.activePreparationCount == 0 }
        for selection in selections {
            XCTAssertEqual(cache.cachedSnapshot(for: selection), .loading,
                           "Revisited entries cannot inherit the old normalization's generation")
        }
    }

    func testUnmatchedAliasProofDoesNotPromoteToolbarSnapshot() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let differentFolder = destination.folder.appendingPathComponent("different")
        let cache = FinderMenuDestinationCache(standardizeURL: { _ in differentFolder }, prepare: { _ in destination })
        let container = FinderMenuSelection(context: .container, targetedURL: destination.folder, selectedItemURLs: [])
        let toolbar = FinderMenuSelection(context: .toolbar, targetedURL: destination.folder, selectedItemURLs: [])
        cache.prewarmObservedDirectory(at: destination.folder)
        try waitUntil { cache.activePreparationCount == 0 }

        XCTAssertEqual(cache.cachedSnapshot(for: container), .ready(destination))
        XCTAssertEqual(cache.cachedSnapshot(for: toolbar), .loading,
                       "Only an equal normalized directory proof may fan out to toolbar")
    }

    func testUnavailablePreparationRecoversOnLaterMenuRequest() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let calls = LockedPreparationCount()
        let cache = FinderMenuDestinationCache { _ in
            calls.increment() == 1 ? nil : destination
        }
        let selection = selection("Temporarily-unavailable")
        XCTAssertEqual(cache.currentSnapshot(for: selection), .loading)
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedSnapshot(for: selection), .unavailable)
        // A failed preparation is not a permanent negative cache entry.
        XCTAssertEqual(cache.currentSnapshot(for: selection), .unavailable)
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedSnapshot(for: selection), .ready(destination))
        XCTAssertEqual(calls.value, 2)
    }

    func testCapacityDeniedEntryCanPrepareAfterOtherWorkReturns() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = LockedPreparationCount()
        let cache = FinderMenuDestinationCache(maximumConcurrentPreparations: 1) { _ in
            if calls.increment() == 1 {
                started.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return destination
        }
        let blocked = selection("Slow")
        let denied = selection("Local")
        XCTAssertEqual(cache.currentSnapshot(for: blocked), .loading)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cache.currentSnapshot(for: denied), .busy)
        XCTAssertEqual(cache.activePreparationCount, 1)
        XCTAssertEqual(calls.value, 1)
        release.signal()
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedSnapshot(for: denied), .busy)
        XCTAssertEqual(calls.value, 1, "Capacity denial must not queue work")
        XCTAssertEqual(cache.currentSnapshot(for: denied), .loading)
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedSnapshot(for: denied), .ready(destination))
        XCTAssertEqual(calls.value, 2)
    }

    func testLateInvalidatedPreparationCannotOverwriteNewerGeneration() throws {
        let first = try destination()
        let second = try destination()
        defer { try? FileManager.default.removeItem(at: first.folder); try? FileManager.default.removeItem(at: second.folder) }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = LockedPreparationCount()
        let cache = FinderMenuDestinationCache { _ in
            if calls.increment() == 1 {
                started.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return first
            }
            return second
        }
        let selection = selection("Same-path")
        XCTAssertEqual(cache.currentSnapshot(for: selection), .loading)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        cache.invalidate(selection)
        XCTAssertEqual(cache.currentSnapshot(for: selection), .loading)
        XCTAssertEqual(calls.value, 1, "Invalidation must not duplicate a blocked read")
        release.signal()
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedSnapshot(for: selection), .loading,
                       "Invalidation must discard the old immutable identity")
        XCTAssertEqual(cache.currentSnapshot(for: selection), .loading)
        try waitUntil { cache.cachedSnapshot(for: selection) == .ready(second) }
        XCTAssertEqual(calls.value, 2)
    }

    func testCapacityDeniedToolbarAliasBecomesLoadingWhenContainerReadIsAdmitted() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let calls = LockedPreparationCount()
        let cache = FinderMenuDestinationCache(maximumConcurrentPreparations: 1) { _ in
            _ = calls.increment()
            started.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return destination
        }
        let blocked = selection("Unrelated")
        let container = FinderMenuSelection(context: .container, targetedURL: destination.folder, selectedItemURLs: [])
        let toolbar = FinderMenuSelection(context: .toolbar, targetedURL: destination.folder, selectedItemURLs: [])
        XCTAssertEqual(cache.currentSnapshot(for: blocked), .loading)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cache.currentSnapshot(for: toolbar), .busy)
        release.signal()
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.currentSnapshot(for: container), .loading)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cache.cachedSnapshot(for: toolbar), .loading)
        XCTAssertEqual(cache.currentSnapshot(for: toolbar), .loading)
        XCTAssertEqual(calls.value, 2, "An admitted container proof already covers its toolbar alias")
        XCTAssertEqual(cache.activePreparationCount, 1)
        release.signal()
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedSnapshot(for: container), .ready(destination))
        XCTAssertEqual(cache.cachedSnapshot(for: toolbar), .ready(destination))
    }

    func testRefreshAdoptsReplacementOnlyForNewMenusAndKeepsOldActionBound() throws {
        let original = try destination()
        let moved = original.folder.appendingPathExtension("old")
        defer { try? FileManager.default.removeItem(at: original.folder); try? FileManager.default.removeItem(at: moved) }
        let selection = FinderMenuSelection(context: .container, targetedURL: original.folder, selectedItemURLs: [])
        let cache = FinderMenuDestinationCache()
        XCTAssertEqual(cache.currentSnapshot(for: selection), .loading)
        try waitUntil { cache.cachedSnapshot(for: selection) == .ready(original) }
        let registry = FinderMenuActionRegistry()
        let tag = registry.register(templateID: UUID(), context: .container,
                                    destinationFolder: original.folder, destinationIdentity: original.identity)
        try FileManager.default.moveItem(at: original.folder, to: moved)
        try FileManager.default.createDirectory(at: original.folder, withIntermediateDirectories: false)
        let replacement = FinderMenuDestination(folder: original.folder, identity: try DirectoryIdentity.capture(at: original.folder))
        XCTAssertNotEqual(replacement.identity, original.identity)
        // Refresh is asynchronous; this menu is still bound to the original directory.
        XCTAssertEqual(cache.currentSnapshot(for: selection), .ready(original))
        try waitUntil { cache.cachedSnapshot(for: selection) == .ready(replacement) }
        XCTAssertEqual(registry.takeAction(for: tag)?.preparedDestination, original)
        XCTAssertEqual(cache.currentSnapshot(for: selection), .ready(replacement))
        try waitUntil { cache.activePreparationCount == 0 }
    }

    func testEvictionAndBlockedPreparationsStayBoundedWithoutPendingWork() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let calls = LockedPreparationCount()
        let cache = FinderMenuDestinationCache(maximumEntries: 3, maximumConcurrentPreparations: 2) { _ in
            _ = calls.increment()
            started.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return nil
        }
        for index in 0..<100 {
            XCTAssertEqual(cache.currentSnapshot(for: selection("Item-\(index)")), index < 2 ? .loading : .busy)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cache.cachedEntryCount, 3)
        XCTAssertEqual(cache.activePreparationCount, 2)
        XCTAssertEqual(cache.cachedSnapshot(for: selection("Item-99")), .busy)
        release.signal(); release.signal()
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(calls.value, 2, "Cache misses must not leave background work queued")
        XCTAssertNil(cache.cachedSnapshot(for: selection("Item-0")), "Old work cannot resurrect an evicted key")
    }

    func testEvictedPreparationCannotPublishOldProofWhenSelectionReturns() throws {
        let first = try destination()
        let second = try destination()
        defer { try? FileManager.default.removeItem(at: first.folder); try? FileManager.default.removeItem(at: second.folder) }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = LockedPreparationCount()
        let cache = FinderMenuDestinationCache(maximumEntries: 1, maximumConcurrentPreparations: 1) { _ in
            if calls.increment() == 1 {
                started.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return first
            }
            return second
        }
        let original = selection("Evicted")
        XCTAssertEqual(cache.currentSnapshot(for: original), .loading)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cache.currentSnapshot(for: selection("Different")), .busy)
        XCTAssertNil(cache.cachedSnapshot(for: original))
        // This exact read remains active, but its evicted entry cannot regain the generation.
        XCTAssertEqual(cache.currentSnapshot(for: original), .loading)
        XCTAssertEqual(calls.value, 1)
        release.signal()
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedSnapshot(for: original), .loading,
                       "Revisiting an evicted selection must not promote the old immutable identity")
        XCTAssertEqual(cache.currentSnapshot(for: original), .loading)
        try waitUntil { cache.cachedSnapshot(for: original) == .ready(second) }
        XCTAssertEqual(calls.value, 2)
    }

    func testExactSelectionKeyIncludesItemsBeyondPreflightLimit() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let cache = FinderMenuDestinationCache { _ in destination }
        let selected = (0..<300).map { destination.folder.appendingPathComponent("file-\($0)") }
        let first = FinderMenuSelection(context: .items, targetedURL: destination.folder, selectedItemURLs: selected)
        _ = cache.currentSnapshot(for: first)
        try waitUntil { cache.cachedSnapshot(for: first) == .ready(destination) }
        var changed = selected
        changed[299] = URL(fileURLWithPath: "/Volumes/Other/file")
        let second = FinderMenuSelection(context: .items, targetedURL: destination.folder, selectedItemURLs: changed)
        XCTAssertEqual(cache.currentSnapshot(for: second), .loading)
        try waitUntil { cache.activePreparationCount == 0 }
    }

    func testBackgroundPreparationValidatesEntireLargeSelection() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let item = destination.folder.appendingPathComponent("file")
        try Data().write(to: item)
        let items = Array(repeating: item, count: 300)
        XCTAssertEqual(FinderMenuDestination.prepare(for: FinderMenuSelection(
            context: .items, targetedURL: nil, selectedItemURLs: items
        )), destination)
        XCTAssertNil(FinderMenuDestination.prepare(for: FinderMenuSelection(
            context: .items, targetedURL: destination.folder,
            selectedItemURLs: items + [destination.folder.appendingPathComponent("missing")]
        )))
    }

    func testObservationPrewarmDoesNotGuessItemSidebarOrVirtualContext() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let observed = FinderMenuSelection(context: .container, targetedURL: destination.folder, selectedItemURLs: [])
        XCTAssertEqual(observed, FinderMenuSelection(context: .container, targetedURL: destination.folder,
                                                     selectedItemURLs: [destination.folder.appendingPathComponent("irrelevant")]))
        XCTAssertNotEqual(observed, FinderMenuSelection(context: .items, targetedURL: destination.folder, selectedItemURLs: []))
        XCTAssertNil(FinderMenuDestination.prepare(for: FinderMenuSelection(
            context: .sidebar, targetedURL: destination.folder, selectedItemURLs: []
        )))
        XCTAssertNil(FinderMenuDestination.prepare(for: FinderMenuSelection(
            context: .container, targetedURL: URL(string: "search:///"), selectedItemURLs: []
        )))
    }

    func testBlockedPreparationDoesNotRetainCache() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "preparation released")
        defer { release.signal() }
        var cache: FinderMenuDestinationCache? = FinderMenuDestinationCache { _ in
            started.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            finished.fulfill()
            return nil
        }
        weak var weakCache = cache
        _ = cache?.currentSnapshot(for: selection("Blocked"))
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        cache = nil
        XCTAssertNil(weakCache)
        release.signal()
        wait(for: [finished], timeout: 2)
    }

    func testBlockedObservationSharesContextsAndReservesDemandCapacityAfterInvalidation() throws {
        let local = try destination()
        defer { try? FileManager.default.removeItem(at: local.folder) }
        let slowURL = URL(fileURLWithPath: "/Volumes/Slow/Observed")
        let container = FinderMenuSelection(context: .container, targetedURL: slowURL, selectedItemURLs: [])
        let toolbar = FinderMenuSelection(context: .toolbar, targetedURL: slowURL, selectedItemURLs: [])
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = LockedPreparationCount()
        let cache = FinderMenuDestinationCache(maximumEntries: 3) { selection in
            _ = calls.increment()
            if selection.targetedURL == slowURL {
                started.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return nil
            }
            return FinderMenuDestination.prepare(for: selection)
        }
        cache.prewarmObservedDirectory(at: slowURL)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        for index in 0..<30 {
            cache.invalidate(container)
            cache.invalidate(toolbar)
            cache.prewarmObservedDirectory(at: slowURL)
            XCTAssertEqual(cache.currentSnapshot(for: container), .loading)
            XCTAssertEqual(cache.currentSnapshot(for: toolbar), .loading)
            cache.prewarmObservedDirectory(at: URL(fileURLWithPath: "/Volumes/Other-\(index)"))
        }
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(cache.activePreparationCount, 1)
        XCTAssertLessThanOrEqual(cache.cachedEntryCount, 3)
        let localSelection = FinderMenuSelection(context: .container, targetedURL: local.folder, selectedItemURLs: [])
        XCTAssertEqual(cache.currentSnapshot(for: localSelection), .loading)
        try waitUntil { cache.cachedSnapshot(for: localSelection) == .ready(local) }
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(cache.activePreparationCount, 1)
        release.signal()
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertNotEqual(cache.cachedSnapshot(for: container), .ready(local))
        XCTAssertNotEqual(cache.cachedSnapshot(for: toolbar), .ready(local))
    }

    func testSuccessfulObservedDirectoryWarmsToolbarWithSameIdentity() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let calls = LockedPreparationCount()
        let cache = FinderMenuDestinationCache { selection in
            _ = calls.increment()
            return FinderMenuDestination.prepare(for: selection)
        }
        cache.prewarmObservedDirectory(at: destination.folder)
        try waitUntil { cache.activePreparationCount == 0 }
        for context in [FinderMenuContext.container, .toolbar] {
            XCTAssertEqual(cache.cachedSnapshot(for: FinderMenuSelection(
                context: context, targetedURL: destination.folder, selectedItemURLs: []
            )), .ready(destination))
        }
        XCTAssertEqual(calls.value, 1)
    }

    func testFailedObservedDirectoryDoesNotSuppressToolbarFileParentFallback() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let file = destination.folder.appendingPathComponent("file")
        try Data().write(to: file)
        let cache = FinderMenuDestinationCache()
        cache.prewarmObservedDirectory(at: file)
        try waitUntil { cache.activePreparationCount == 0 }
        let container = FinderMenuSelection(context: .container, targetedURL: file, selectedItemURLs: [])
        let toolbar = FinderMenuSelection(context: .toolbar, targetedURL: file, selectedItemURLs: [])
        XCTAssertEqual(cache.cachedSnapshot(for: container), .unavailable)
        XCTAssertEqual(cache.currentSnapshot(for: toolbar), .loading)
        try waitUntil { cache.cachedSnapshot(for: toolbar) == .ready(destination) }
        XCTAssertEqual(cache.cachedSnapshot(for: container), .unavailable)
    }

    func testInvalidatedObservedProofCannotRepublishEitherContext() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let cache = FinderMenuDestinationCache { _ in
            started.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return destination
        }
        let selections = [FinderMenuContext.container, .toolbar].map {
            FinderMenuSelection(context: $0, targetedURL: destination.folder, selectedItemURLs: [])
        }
        cache.prewarmObservedDirectory(at: destination.folder)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        for selection in selections {
            cache.invalidate(selection)
            XCTAssertEqual(cache.currentSnapshot(for: selection), .loading)
        }
        XCTAssertEqual(cache.activePreparationCount, 1)
        release.signal()
        try waitUntil { cache.activePreparationCount == 0 }
        for selection in selections {
            XCTAssertEqual(cache.cachedSnapshot(for: selection), .loading)
        }
    }

    func testSingleSlotDisablesSpeculationAndKeepsDemandUsable() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let calls = LockedPreparationCount()
        let cache = FinderMenuDestinationCache(maximumConcurrentPreparations: 1) { _ in
            _ = calls.increment()
            return destination
        }
        cache.prewarmObservedDirectory(at: destination.folder)
        XCTAssertEqual(cache.activePreparationCount, 0)
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(cache.cachedSnapshot(for: FinderMenuSelection(
            context: .container, targetedURL: destination.folder, selectedItemURLs: []
        )), .busy)
        let demand = selection("Demand")
        XCTAssertEqual(cache.currentSnapshot(for: demand), .loading)
        try waitUntil { cache.cachedSnapshot(for: demand) == .ready(destination) }
        XCTAssertEqual(calls.value, 1)
    }

    func testSingleEntryCacheRetainsRequestedObservedAndDemandSnapshots() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.folder) }
        let cache = FinderMenuDestinationCache(maximumEntries: 1)
        let container = FinderMenuSelection(
            context: .container, targetedURL: destination.folder, selectedItemURLs: []
        )
        cache.prewarmObservedDirectory(at: destination.folder)
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedEntryCount, 1)
        XCTAssertEqual(cache.cachedSnapshot(for: container), .ready(destination))
        cache.invalidate(container)
        XCTAssertEqual(cache.currentSnapshot(for: container), .loading)
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedEntryCount, 1)
        XCTAssertEqual(cache.cachedSnapshot(for: container), .ready(destination))
    }

    func testBlockedToolbarFirstReadDoesNotDuplicateOrPublishFileParentAsContainer() throws {
        let destination = try destination()
        let local = try self.destination()
        defer {
            try? FileManager.default.removeItem(at: destination.folder)
            try? FileManager.default.removeItem(at: local.folder)
        }
        let file = destination.folder.appendingPathComponent("file")
        try Data().write(to: file)
        let toolbar = FinderMenuSelection(context: .toolbar, targetedURL: file, selectedItemURLs: [])
        let container = FinderMenuSelection(context: .container, targetedURL: file, selectedItemURLs: [])
        let localSelection = FinderMenuSelection(context: .container, targetedURL: local.folder, selectedItemURLs: [])
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = LockedPreparationCount()
        let cache = FinderMenuDestinationCache { selection in
            _ = calls.increment()
            if selection == toolbar {
                started.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return FinderMenuDestination.prepare(for: selection)
        }
        XCTAssertEqual(cache.currentSnapshot(for: toolbar), .loading)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        cache.invalidate(toolbar)
        for _ in 0..<10 {
            cache.prewarmObservedDirectory(at: file)
            XCTAssertEqual(cache.currentSnapshot(for: container), .busy)
            XCTAssertEqual(cache.currentSnapshot(for: toolbar), .loading)
        }
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(cache.activePreparationCount, 1)
        XCTAssertEqual(cache.currentSnapshot(for: localSelection), .loading)
        try waitUntil { cache.cachedSnapshot(for: localSelection) == .ready(local) }
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(cache.activePreparationCount, 1)
        release.signal()
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedSnapshot(for: container), .busy,
                       "A toolbar file-parent result cannot prove its target is a directory")
        XCTAssertEqual(cache.cachedSnapshot(for: toolbar), .loading,
                       "Invalidated toolbar identity must not be republished")
        XCTAssertEqual(cache.currentSnapshot(for: container), .loading)
        try waitUntil { cache.activePreparationCount == 0 }
        XCTAssertEqual(cache.cachedSnapshot(for: container), .unavailable)
        XCTAssertEqual(calls.value, 3)
    }

    private func selection(_ name: String) -> FinderMenuSelection {
        FinderMenuSelection(context: .items, targetedURL: nil,
                            selectedItemURLs: [URL(fileURLWithPath: "/Volumes/Test/\(name)")])
    }

    private func destination() throws -> FinderMenuDestination {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return FinderMenuDestination(folder: folder, identity: try DirectoryIdentity.capture(at: folder))
    }

    private func waitUntil(_ condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertTrue(condition(), "Background preparation did not reach the expected state")
    }
}

private final class LockedPreparationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
