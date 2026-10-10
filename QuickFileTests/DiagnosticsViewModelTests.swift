import Combine
import Darwin
import XCTest
@testable import QuickFile
@testable import QuickFileCore
@testable import QuickFileInfrastructure

@MainActor
final class DiagnosticsViewModelTests: XCTestCase {
    private enum TestError: Error {
        case bookmarkResolutionFailed
        case probeCleanupFailed
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var temporaryDirectory: URL!
    private var inventoryReadGate: DiagnosticsInventoryReadGate!

    override func setUpWithError() throws {
        inventoryReadGate = DiagnosticsInventoryReadGate()
        suiteName = "QuickFileTests.DiagnosticsViewModel.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        inventoryReadGate = nil
        temporaryDirectory = nil
        defaults = nil
        suiteName = nil
    }

    func testSummaryUsesAllowlistAndInjectedRuntimeEvidence() async throws {
        let store = FinderExtensionActivityStore(
            defaults: defaults,
            failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
        )
        let timestamp = Date()
        try store.record(.fileCreationFailed, failure: FinderExtensionActivityFailure(
            reason: .writeFailed, errorDomain: "/Users/private-user/secret", errorCode: 42
        ), at: timestamp)
        let viewModel = DiagnosticsViewModel(
            extensionEnabledProvider: { true },
            runtimeProvider: { enabled in
                FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: ["com.test.extension", "/Users/private-user/secret"],
                    embeddingKnown: true, registration: .unknown,
                    registrationEvidence: "/Users/private-user/secret", enabled: enabled, responded: false
                )
            },
            extensionActivityStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(),
            inventoryReadGate: inventoryReadGate
        )
        await viewModel.authorizeDirectory(temporaryDirectory)
        await viewModel.refreshRuntimeStatus()
        XCTAssertEqual(viewModel.extensionSnapshot?.state, .noResponse)
        let summary = viewModel.diagnosticSummary
        XCTAssertTrue(summary.contains("com.test.extension"))
        XCTAssertTrue(summary.contains("appBundleIdentifier: \(Bundle.main.bundleIdentifier ?? "unknown")"))
        XCTAssertTrue(summary.contains("appGroupIdentifier: \(QuickFileConfiguration.appGroupIdentifier)"))
        XCTAssertTrue(summary.contains("latestActivityKind: fileCreationFailed"))
        XCTAssertTrue(summary.contains("latestActivityTimestamp: \(ISO8601DateFormatter().string(from: timestamp))"))
        XCTAssertTrue(summary.contains("registration: unknown"))
        XCTAssertTrue(summary.contains("writeFailed"))
        XCTAssertTrue(summary.contains("authorizedDirectoryCount: 1"))
        XCTAssertFalse(summary.contains("private-user"))
        XCTAssertFalse(summary.contains(temporaryDirectory.path))
        XCTAssertFalse(summary.contains("errorCode"))
    }

    func testRefreshLoadsExtensionAndAuthorizationState() async throws {
        let activityStore = FinderExtensionActivityStore(
            defaults: defaults,
            failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
        )
        let authorizationStore = makeAuthorizationStore()
        let failure = FinderExtensionActivityFailure(
            reason: .directoryNotAuthorized,
            errorDomain: nil,
            errorCode: nil
        )
        try activityStore.record(.fileCreationFailed, failure: failure)
        try authorizationStore.authorize(temporaryDirectory)
        let viewModel = DiagnosticsViewModel(
            extensionEnabledProvider: { true },
            runtimeProvider: { enabled in
                FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
                    registration: .registered, registrationEvidence: "test fixture",
                    enabled: enabled, responded: true
                )
            },
            extensionActivityStore: activityStore,
            authorizedDirectoryStore: authorizationStore,
            inventoryReadGate: inventoryReadGate
        )

        await viewModel.refreshRuntimeStatus()

        XCTAssertTrue(viewModel.isFinderExtensionEnabled)
        XCTAssertEqual(viewModel.extensionSnapshot?.state, .responding)
        XCTAssertTrue(viewModel.isAppGroupStoreAvailable)
        XCTAssertEqual(viewModel.extensionActivity?.failure, failure)
        XCTAssertEqual(viewModel.recentExtensionFailures.count, 1)
        XCTAssertEqual(viewModel.authorizedDirectories.map(\.url), [temporaryDirectory.standardizedFileURL])
    }

    func testRefreshRetriesWhenEnabledStateChangesAndNeverPublishesStaleSnapshot() async throws {
        var isEnabled = true
        var probeCount = 0
        var firstContinuation: CheckedContinuation<Bool, Never>?
        var secondContinuation: CheckedContinuation<Bool, Never>?
        let firstStarted = expectation(description: "first probe started")
        let secondStarted = expectation(description: "replacement probe started")
        let viewModel = DiagnosticsViewModel(
            extensionEnabledProvider: { isEnabled },
            runtimeProvider: { enabled in
                probeCount += 1
                let responded = await withCheckedContinuation { continuation in
                    if probeCount == 1 {
                        firstContinuation = continuation
                        firstStarted.fulfill()
                    } else {
                        secondContinuation = continuation
                        secondStarted.fulfill()
                    }
                }
                return FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
                    registration: .registered, registrationEvidence: "test",
                    enabled: enabled, responded: responded
                )
            },
            extensionActivityStore: FinderExtensionActivityStore(
                defaults: defaults,
                failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
            ),
            authorizedDirectoryStore: makeAuthorizationStore(),
            inventoryReadGate: inventoryReadGate
        )

        let refresh = Task { await viewModel.refreshRuntimeStatus() }
        await fulfillment(of: [firstStarted], timeout: 1)
        isEnabled = false
        firstContinuation?.resume(returning: true)
        await fulfillment(of: [secondStarted], timeout: 1)

        XCTAssertFalse(viewModel.isFinderExtensionEnabled)
        XCTAssertNil(viewModel.extensionSnapshot)
        XCTAssertTrue(viewModel.isRefreshingRuntimeStatus)

        secondContinuation?.resume(returning: false)
        await refresh.value
        XCTAssertEqual(probeCount, 2)
        XCTAssertFalse(viewModel.isFinderExtensionEnabled)
        XCTAssertEqual(viewModel.extensionSnapshot?.state, .disabled)
        XCTAssertFalse(viewModel.isRefreshingRuntimeStatus)
    }

    func testOverlappingRefreshRequestsMergeIntoOneFollowUpProbe() async {
        var probeCount = 0
        var firstContinuation: CheckedContinuation<Bool, Never>?
        let firstStarted = expectation(description: "first probe started")
        let viewModel = DiagnosticsViewModel(
            extensionEnabledProvider: { true },
            runtimeProvider: { enabled in
                probeCount += 1
                let responded: Bool
                if probeCount == 1 {
                    responded = await withCheckedContinuation { continuation in
                        firstContinuation = continuation
                        firstStarted.fulfill()
                    }
                } else {
                    responded = true
                }
                return FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
                    registration: .registered, registrationEvidence: "test",
                    enabled: enabled, responded: responded
                )
            },
            extensionActivityStore: FinderExtensionActivityStore(
                defaults: defaults,
                failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
            ),
            authorizedDirectoryStore: makeAuthorizationStore(),
            inventoryReadGate: inventoryReadGate
        )

        let firstRefresh = Task { await viewModel.refreshRuntimeStatus() }
        await fulfillment(of: [firstStarted], timeout: 1)
        await viewModel.refreshRuntimeStatus()
        await viewModel.refreshRuntimeStatus()
        XCTAssertEqual(probeCount, 1)

        firstContinuation?.resume(returning: true)
        await firstRefresh.value
        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(viewModel.extensionSnapshot?.state, .responding)
        XCTAssertFalse(viewModel.isRefreshingRuntimeStatus)
    }

    func testReopenedPageKeepsRefreshIntentWhileCancelledOldRuntimeReturns() async throws {
        try await assertReopenedRefreshDuringRuntime(cancelOld: true)
    }

    func testReopenedPageKeepsRefreshIntentWhileUncancelledOldRuntimeReturns() async throws {
        try await assertReopenedRefreshDuringRuntime(cancelOld: false)
    }

    private func assertReopenedRefreshDuringRuntime(cancelOld: Bool) async throws {
        let runtimeGate = DiagnosticsRuntimeReadGate()
        let store = makeAuthorizationStore()
        let authorization = try store.authorize(temporaryDirectory)
        var probeCount = 0
        var firstContinuation: CheckedContinuation<Void, Never>?
        let firstStarted = expectation(description: "old presentation runtime probe blocked")
        let model = DiagnosticsViewModel(
            extensionEnabledProvider: { true },
            runtimeProvider: { enabled in
                probeCount += 1
                let number = probeCount
                if number == 1 {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        firstContinuation = continuation
                        firstStarted.fulfill()
                    }
                }
                return FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
                    registration: .registered, registrationEvidence: "probe \(number)",
                    enabled: enabled, responded: true
                )
            },
            extensionActivityStore: FinderExtensionActivityStore(
                defaults: defaults, failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
            ),
            authorizedDirectoryStore: store, inventoryReadGate: inventoryReadGate,
            runtimeReadGate: runtimeGate
        )
        var publishedEvidence: [String] = []
        let runtimeObservation = model.$extensionSnapshot.sink { snapshot in
            if let snapshot { publishedEvidence.append(snapshot.registrationEvidence) }
        }
        let inventoryPublished = expectation(description: "reopened presentation finishes its own inventory")
        let inventoryObservation = model.$authorizedDirectories.dropFirst().sink { directories in
            if directories.map(\.id) == [authorization.id] { inventoryPublished.fulfill() }
        }
        let oldRefresh = Task { await model.refreshRuntimeStatus() }
        await fulfillment(of: [firstStarted], timeout: 2)
        if cancelOld { oldRefresh.cancel() }
        for _ in 0..<4 {
            model.directoryDiagnosticsDidDisappear()
            model.directoryDiagnosticsDidAppear()
            for _ in 0..<8 { await model.refreshRuntimeStatus() }
        }
        XCTAssertEqual(oldRefresh.isCancelled, cancelOld)
        XCTAssertEqual(probeCount, 1)
        XCTAssertTrue(runtimeGate.isReading, "The old probe must retain actual I/O admission")
        XCTAssertTrue(model.isRefreshingRuntimeStatus)

        firstContinuation?.resume()
        await oldRefresh.value
        await fulfillment(of: [inventoryPublished], timeout: 2)
        withExtendedLifetime((runtimeObservation, inventoryObservation)) {}
        XCTAssertEqual(probeCount, 2, "One new-generation request survives, regardless of old cancellation")
        XCTAssertEqual(publishedEvidence, ["probe 2"], "Closed-generation evidence must never publish")
        XCTAssertFalse(model.isRefreshingRuntimeStatus)
        XCTAssertFalse(model.isLoadingAuthorizationInventory)
        XCTAssertFalse(runtimeGate.isReading)
        XCTAssertFalse(inventoryReadGate.isReading)
    }

    func testCancelledRuntimeDiscardsSameGenerationCoalescedIntent() async {
        let started = expectation(description: "runtime probe blocked before caller cancellation")
        var continuation: CheckedContinuation<Void, Never>?
        var count = 0
        let model = DiagnosticsViewModel(
            extensionEnabledProvider: { true },
            runtimeProvider: { enabled in
                count += 1
                if count == 1 {
                    await withCheckedContinuation { (pending: CheckedContinuation<Void, Never>) in
                        continuation = pending
                        started.fulfill()
                    }
                }
                return FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
                    registration: .registered, registrationEvidence: "test",
                    enabled: enabled, responded: true
                )
            },
            extensionActivityStore: FinderExtensionActivityStore(
                defaults: defaults, failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
            ),
            authorizedDirectoryStore: makeAuthorizationStore(), inventoryReadGate: inventoryReadGate
        )
        let refresh = Task { await model.refreshRuntimeStatus() }
        await fulfillment(of: [started], timeout: 2)
        await model.refreshRuntimeStatus()
        refresh.cancel()
        continuation?.resume()
        await refresh.value
        XCTAssertEqual(count, 1)
        XCTAssertNil(model.extensionSnapshot)
        XCTAssertFalse(model.isRefreshingRuntimeStatus)
        await model.refreshRuntimeStatus()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(model.extensionSnapshot?.state, .responding)
    }

    func testClosedAgainDiscardsPendingReopenedRuntimeIntent() async {
        let started = expectation(description: "runtime blocked across closed presentations")
        var continuation: CheckedContinuation<Void, Never>?
        var count = 0
        let runtimeGate = DiagnosticsRuntimeReadGate()
        let model = DiagnosticsViewModel(
            extensionEnabledProvider: { true },
            runtimeProvider: { enabled in
                count += 1
                if count == 1 {
                    await withCheckedContinuation { (pending: CheckedContinuation<Void, Never>) in
                        continuation = pending
                        started.fulfill()
                    }
                }
                return FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
                    registration: .registered, registrationEvidence: "closed",
                    enabled: enabled, responded: true
                )
            },
            extensionActivityStore: FinderExtensionActivityStore(
                defaults: defaults, failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
            ),
            authorizedDirectoryStore: makeAuthorizationStore(), inventoryReadGate: inventoryReadGate,
            runtimeReadGate: runtimeGate
        )
        let refresh = Task { await model.refreshRuntimeStatus() }
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<4 {
            model.directoryDiagnosticsDidDisappear()
            model.directoryDiagnosticsDidAppear()
            await model.refreshRuntimeStatus()
        }
        model.directoryDiagnosticsDidDisappear()
        continuation?.resume()
        await refresh.value
        XCTAssertEqual(count, 1)
        XCTAssertNil(model.extensionSnapshot)
        XCTAssertFalse(model.isRefreshingRuntimeStatus)
        XCTAssertFalse(runtimeGate.isReading)
        XCTAssertFalse(inventoryReadGate.isReading)
    }

    func testAuthorizationAndRevocationUpdatePublishedState() async throws {
        let viewModel = DiagnosticsViewModel(
            extensionEnabledProvider: { false },
            extensionActivityStore: FinderExtensionActivityStore(
                defaults: defaults,
                failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
            ),
            authorizedDirectoryStore: makeAuthorizationStore(),
            inventoryReadGate: inventoryReadGate
        )

        await viewModel.authorizeDirectory(temporaryDirectory)

        let authorization = try XCTUnwrap(viewModel.authorizedDirectories.first)
        XCTAssertEqual(viewModel.authorizationMessage, "目录授权已保存。")
        XCTAssertFalse(viewModel.authorizationHasError)

        await viewModel.revokeAuthorization(authorization.id)

        XCTAssertTrue(viewModel.authorizedDirectories.isEmpty)
        XCTAssertEqual(viewModel.authorizationMessage, "目录授权已移除。")
        XCTAssertFalse(viewModel.authorizationHasError)
    }

    func testRevokingChildExplainsRemainingParentWithoutBookmarkIO() async throws {
        let resolver = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: resolver)
        let parent = try store.authorize(temporaryDirectory)
        let childURL = temporaryDirectory.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: false)
        let child = try store.authorize(childURL)
        let model = makeDiagnosticsModel(store: store)
        await model.refreshRuntimeStatus()
        let overlap = try XCTUnwrap(model.authorizationOverlapMessage(for: child))
        XCTAssertTrue(overlap.contains(parent.url.path))
        XCTAssertTrue(overlap.contains("最近读取"))
        XCTAssertTrue(overlap.contains("实际写入时会重新验证"))
        XCTAssertNil(model.authorizationOverlapMessage(for: parent), "A child grant does not cover its parent")

        let entered = expectation(description: "overlap feedback must not wait for inventory resolution")
        resolver.arm(entered)
        defer { resolver.release.signal() }
        let refresh = Task { await model.refreshRuntimeStatus() }
        await fulfillment(of: [entered], timeout: 2)
        let resolutionsBeforeRevoke = resolver.resolutionCount
        await model.revokeAuthorization(child.id)
        XCTAssertEqual(resolver.resolutionCount, resolutionsBeforeRevoke, "Feedback adds no bookmark resolution")
        XCTAssertEqual(model.authorizedDirectories.map(\.id), [parent.id])
        XCTAssertEqual(model.authorizationMessage, "目录授权已移除。" + overlap)
        XCTAssertFalse(model.authorizationHasError)
        XCTAssertTrue(inventoryReadGate.isReading)
        resolver.release.signal()
        await refresh.value
        XCTAssertEqual(model.authorizedDirectories.map(\.id), [parent.id])
        XCTAssertEqual(model.authorizationMessage, "目录授权已移除。" + overlap)
        XCTAssertEqual(try store.loadAuthorizedDirectories().map(\.id), [parent.id])
    }

    func testRevokingExactDuplicateRetainsOtherRecordAndExplainsCoverage() async throws {
        let store = makeAuthorizationStore()
        let original = try store.authorize(temporaryDirectory)
        let duplicateID = UUID()
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        try repository.update { records in
            records.append(StoredDirectoryAuthorization(
                id: duplicateID, persistentBookmarkData: Self.bookmarkData(for: temporaryDirectory),
                transferBookmarkData: Self.bookmarkData(for: temporaryDirectory)
            ))
        }
        let model = makeDiagnosticsModel(store: store)
        await model.refreshRuntimeStatus()
        XCTAssertEqual(model.authorizedDirectories.count, 2, "Inventory never merges historical duplicate records")
        await model.revokeAuthorization(duplicateID)
        XCTAssertEqual(model.authorizedDirectories.map(\.id), [original.id])
        let message = try XCTUnwrap(model.authorizationMessage)
        XCTAssertTrue(message.contains("此位置也由"))
        XCTAssertTrue(message.contains(original.url.path))
        XCTAssertEqual(try repository.load().map(\.id), [original.id])
    }

    func testStaleOverlapDoesNotClaimCurrentAuthorizationAndDoesNotResolveAgain() async throws {
        let store = makeAuthorizationStore()
        let parent = try store.authorize(temporaryDirectory)
        let childURL = temporaryDirectory.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: false)
        let child = try store.authorize(childURL)
        let resolver = InventoryResolutionGate()
        let parentPath = parent.url.path
        let staleStore = AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { Self.bookmarkData(for: $0) },
            transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { data in
                resolver.pauseIfArmed()
                let path = String(decoding: data, as: UTF8.self)
                return ResolvedSecurityScopedBookmark(url: URL(fileURLWithPath: path), isStale: path == parentPath)
            },
            transferBookmarkResolver: { try Self.resolveBookmark($0) },
            startAccessing: { _ in true }, stopAccessing: { _ in }
        )
        let model = makeDiagnosticsModel(store: staleStore)
        await model.refreshRuntimeStatus()
        let before = resolver.resolutionCount
        let overlap = try XCTUnwrap(model.authorizationOverlapMessage(for: child))
        XCTAssertTrue(overlap.contains("无法确认"))
        XCTAssertFalse(overlap.contains("此位置也由"))
        await model.revokeAuthorization(child.id)
        XCTAssertEqual(resolver.resolutionCount, before)
        XCTAssertEqual(model.authorizationMessage, "目录授权已移除。" + overlap)
        XCTAssertEqual(model.authorizedDirectories.map(\.id), [parent.id])
        XCTAssertTrue(model.authorizedDirectories[0].isBookmarkStale)
    }

    func testOverlapUsesResolvedPathsNotHintsOrTextPrefixes() async throws {
        let parentURL = temporaryDirectory.appendingPathComponent("Parent", isDirectory: true)
        let siblingURL = temporaryDirectory.appendingPathComponent("Parent-other", isDirectory: true)
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: siblingURL, withIntermediateDirectories: false)
        let store = makeAuthorizationStore()
        let parent = try store.authorize(parentURL)
        let sibling = try store.authorize(siblingURL)
        let unavailableID = UUID()
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        try repository.update { records in
            records.append(StoredDirectoryAuthorization(
                id: unavailableID, persistentBookmarkData: Data("unavailable".utf8),
                transferBookmarkData: Data(), canonicalPathHint: temporaryDirectory.path
            ))
        }
        let model = makeDiagnosticsModel(store: makeUnavailableAuthorizationStore(unavailablePaths: ["unavailable"]))
        await model.refreshRuntimeStatus()
        XCTAssertEqual(model.unavailableAuthorizedDirectories.map(\.id), [unavailableID])
        XCTAssertNil(model.authorizationOverlapMessage(for: parent))
        XCTAssertNil(model.authorizationOverlapMessage(for: sibling), "Text-prefix siblings are not parent grants")
        await model.revokeAuthorization(sibling.id)
        XCTAssertEqual(model.authorizationMessage, "目录授权已移除。")
        XCTAssertEqual(model.authorizedDirectories.map(\.id), [parent.id])
        XCTAssertEqual(model.unavailableAuthorizedDirectories.map(\.id), [unavailableID],
                       "An unavailable historical record and its hints must remain untouched")
    }

    func testUnresolvableAuthorizationRemainsVisibleAndCanBeRemoved() async throws {
        let authorization = try makeAuthorizationStore().authorize(temporaryDirectory)
        let failingStore = AuthorizedDirectoryStore(
            defaults: defaults,
            storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { Self.bookmarkData(for: $0) },
            transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { _ in throw TestError.bookmarkResolutionFailed },
            transferBookmarkResolver: { try Self.resolveBookmark($0) },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
        let viewModel = DiagnosticsViewModel(
            extensionEnabledProvider: { false },
            extensionActivityStore: FinderExtensionActivityStore(
                defaults: defaults,
                failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
            ),
            authorizedDirectoryStore: failingStore,
            inventoryReadGate: inventoryReadGate
        )

        await viewModel.refreshRuntimeStatus()

        XCTAssertTrue(viewModel.authorizedDirectories.isEmpty)
        XCTAssertEqual(
            viewModel.unavailableAuthorizedDirectories,
            [UnavailableAuthorizedDirectory(id: authorization.id)]
        )
        XCTAssertNotNil(viewModel.authorizationInventoryMessage)
        XCTAssertFalse(viewModel.authorizationHasError)

        await viewModel.revokeAuthorization(authorization.id)

        XCTAssertTrue(viewModel.unavailableAuthorizedDirectories.isEmpty)
        XCTAssertFalse(viewModel.authorizationHasError)
        XCTAssertEqual(viewModel.authorizationMessage, "目录授权已移除。")
    }

    func testRevocationCompletesWhileInventoryResolverIsPaused() async throws {
        try await assertRevocationDuringRefresh(fromAnotherWindow: false)
    }

    func testBulkRemovalWaitsForInventorySlotThenUpdatesAllWindows() async throws {
        let store = makeAuthorizationStore()
        let removed = try store.authorize(temporaryDirectory)
        let secondURL = temporaryDirectory.appendingPathComponent("Unavailable")
        let retainedURL = temporaryDirectory.appendingPathComponent("Retained")
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: retainedURL, withIntermediateDirectories: false)
        let alsoRemoved = try store.authorize(secondURL)
        let retained = try store.authorize(retainedURL)
        let gate = InventoryResolutionGate()
        let failingStore = makeUnavailableAuthorizationStore(
            unavailablePaths: [temporaryDirectory.path, secondURL.path], gate: gate
        )
        let model = makeDiagnosticsModel(store: failingStore)
        let otherWindow = makeDiagnosticsModel(store: failingStore)
        await model.refreshRuntimeStatus()
        await otherWindow.refreshRuntimeStatus()
        XCTAssertEqual(Set(model.unavailableAuthorizedDirectories.map(\.id)), [removed.id, alsoRemoved.id])
        let entered = expectation(description: "inventory before bulk removal paused")
        gate.arm(entered)
        let refresh = Task { await otherWindow.refreshRuntimeStatus() }
        await fulfillment(of: [entered], timeout: 2)
        defer { gate.release.signal() }

        await model.revokeUnavailableAuthorizations()

        XCTAssertEqual(Set(model.unavailableAuthorizedDirectories.map(\.id)), [removed.id, alsoRemoved.id])
        XCTAssertEqual(Set(otherWindow.unavailableAuthorizedDirectories.map(\.id)), [removed.id, alsoRemoved.id])
        XCTAssertNotNil(model.authorizationInventoryMessage)
        XCTAssertFalse(model.isManagingAuthorizations)
        XCTAssertFalse(otherWindow.isRefreshingRuntimeStatus)
        XCTAssertTrue(otherWindow.isLoadingAuthorizationInventory)

        gate.release.signal()
        await refresh.value
        // A rejected mutation is never queued behind the blocked resolver. The
        // user explicitly retries after the active operation releases its slot.
        await model.revokeUnavailableAuthorizations()
        XCTAssertTrue(model.unavailableAuthorizedDirectories.isEmpty)
        XCTAssertTrue(otherWindow.unavailableAuthorizedDirectories.isEmpty)
        XCTAssertEqual(model.authorizedDirectories.map(\.id), [retained.id])
        XCTAssertEqual(model.authorizationMessage, "已移除 2 个不可用授权。")
        XCTAssertFalse(model.authorizationHasError)
        XCTAssertEqual(otherWindow.authorizedDirectories.map(\.id), [retained.id])
        XCTAssertEqual(try store.loadAuthorizedDirectories().map(\.id), [retained.id])
        await model.revokeUnavailableAuthorizations()
        XCTAssertEqual(model.authorizationMessage, "已移除 2 个不可用授权。")
    }

    func testFailedBulkRemovalPreservesRowsAfterBlockedInventoryIsReleased() async throws {
        let authorization = try makeAuthorizationStore().authorize(temporaryDirectory)
        let gate = InventoryResolutionGate()
        let store = makeUnavailableAuthorizationStore(unavailablePaths: [temporaryDirectory.path], gate: gate)
        let model = makeDiagnosticsModel(store: store)
        await model.refreshRuntimeStatus()
        let entered = expectation(description: "inventory before failed bulk removal paused")
        gate.arm(entered)
        let refresh = Task { await model.refreshRuntimeStatus() }
        await fulfillment(of: [entered], timeout: 2)
        defer { gate.release.signal() }
        try Data("corrupt".utf8).write(to: temporaryDirectory.appendingPathComponent("authorizedDirectories.v2.json"))

        await model.revokeUnavailableAuthorizations()
        XCTAssertFalse(model.isManagingAuthorizations)
        XCTAssertEqual(model.authorizationInventoryMessage, "另一项目录授权检查仍在进行，请稍后刷新或重试。")
        gate.release.signal()
        await refresh.value

        await model.revokeUnavailableAuthorizations()
        XCTAssertEqual(model.unavailableAuthorizedDirectories.map(\.id), [authorization.id])
        XCTAssertTrue(model.authorizationHasError)
        XCTAssertFalse(model.isManagingAuthorizations)
        XCTAssertFalse(inventoryReadGate.isReading)
    }

    func testBulkRemovalReportsActualCountWhenAuthorizationRecovers() async throws {
        let store = makeAuthorizationStore()
        let authorization = try store.authorize(temporaryDirectory)
        let failingStore = makeUnavailableAuthorizationStore(unavailablePaths: [temporaryDirectory.path])
        let model = makeDiagnosticsModel(store: failingStore)
        await model.refreshRuntimeStatus()
        // The UI still holds the old unavailable ID, but another window has
        // replaced its bookmark with a resolvable one before cleanup begins.
        let recoveredURL = temporaryDirectory.appendingPathComponent("Recovered")
        try FileManager.default.createDirectory(at: recoveredURL, withIntermediateDirectories: false)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        try repository.update { records in
            records[0] = StoredDirectoryAuthorization(
                id: authorization.id,
                persistentBookmarkData: Data(recoveredURL.path.utf8),
                transferBookmarkData: Data(recoveredURL.path.utf8)
            )
        }

        await model.revokeUnavailableAuthorizations()

        XCTAssertFalse(model.authorizationHasError)
        XCTAssertEqual(model.authorizationMessage, "已移除 0 个不可用授权；其余记录可能已恢复或更新，请刷新状态查看。")
        XCTAssertEqual(try store.loadAuthorizedDirectories().map(\.id), [authorization.id])
        await model.refreshRuntimeStatus()
        XCTAssertTrue(model.unavailableAuthorizedDirectories.isEmpty)
        XCTAssertEqual(model.authorizedDirectories.map(\.url), [recoveredURL.standardizedFileURL])
    }

    private func makeUnavailableAuthorizationStore(
        unavailablePaths: Set<String>, gate: InventoryResolutionGate? = nil
    ) -> AuthorizedDirectoryStore {
        AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { Self.bookmarkData(for: $0) }, transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { data in
                gate?.pauseIfArmed()
                let path = String(decoding: data, as: UTF8.self)
                if unavailablePaths.contains(path) { throw TestError.bookmarkResolutionFailed }
                return ResolvedSecurityScopedBookmark(url: URL(fileURLWithPath: path), isStale: false)
            },
            transferBookmarkResolver: { try Self.resolveBookmark($0) },
            startAccessing: { _ in true }, stopAccessing: { _ in }
        )
    }

    func testOtherWindowRevocationInvalidatesPausedInventory() async throws {
        try await assertRevocationDuringRefresh(fromAnotherWindow: true)
    }

    func testFirstInventoryKeepsOtherRecordsWhenAnotherWindowRevokesDuringRead() async throws {
        let gate = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: gate)
        let first = temporaryDirectory.appendingPathComponent("First")
        let second = temporaryDirectory.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let removed = try store.authorize(first)
        let retained = try store.authorize(second)
        let firstWindow = makeDiagnosticsModel(store: store)
        await firstWindow.refreshRuntimeStatus()
        let newWindow = makeDiagnosticsModel(store: store)
        XCTAssertTrue(newWindow.authorizedDirectories.isEmpty)
        let entered = expectation(description: "first inventory read paused")
        gate.arm(entered)
        let refresh = Task { await newWindow.refreshRuntimeStatus() }
        await fulfillment(of: [entered], timeout: 2)
        defer { gate.release.signal() }

        await firstWindow.revokeAuthorization(removed.id)
        XCTAssertEqual(firstWindow.authorizedDirectories.map(\.id), [retained.id])
        gate.release.signal()
        await refresh.value
        XCTAssertEqual(newWindow.authorizedDirectories.map(\.id), [retained.id])
        XCTAssertEqual(firstWindow.authorizationMessage, "目录授权已移除。")

        // A later independent inventory read can still publish fresh authorization.
        let newlyAuthorized = try store.authorize(first)
        await newWindow.refreshRuntimeStatus()
        XCTAssertEqual(Set(newWindow.authorizedDirectories.map(\.id)), [retained.id, newlyAuthorized.id])
    }

    func testOtherWindowRevocationDoesNotHideAuthorizationFailure() async throws {
        let first = temporaryDirectory.appendingPathComponent("First")
        let second = temporaryDirectory.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let gate = InventoryResolutionGate()
        let store = AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { url in
                if url.standardizedFileURL.path == second.standardizedFileURL.path { gate.pauseIfArmed() }
                return Data(url.path.utf8)
            },
            transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { try Self.resolveBookmark($0) },
            transferBookmarkResolver: { try Self.resolveBookmark($0) },
            startAccessing: { _ in true }, stopAccessing: { _ in }
        )
        let authorization = try store.authorize(first)
        let model = makeDiagnosticsModel(store: store)
        let otherWindow = makeDiagnosticsModel(store: store)
        await model.refreshRuntimeStatus()
        await otherWindow.refreshRuntimeStatus()
        let entered = expectation(description: "new authorization paused before commit")
        gate.arm(entered)
        let adding = Task { await model.authorizeDirectory(second) }
        await fulfillment(of: [entered], timeout: 2)
        defer { gate.release.signal() }
        await otherWindow.revokeAuthorization(authorization.id)
        gate.release.signal()
        await adding.value
        XCTAssertTrue(model.authorizationHasError)
        XCTAssertEqual(model.authorizationMessage, AuthorizedDirectoryStore.StoreError.authorizationChanged.localizedDescription)
        XCTAssertTrue(model.authorizedDirectories.isEmpty)
        XCTAssertTrue(try store.loadAuthorizedDirectories().isEmpty)
    }

    private func assertRevocationDuringRefresh(fromAnotherWindow: Bool) async throws {
        let gate = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: gate)
        let authorization = try store.authorize(temporaryDirectory)
        let model = makeDiagnosticsModel(store: store)
        let otherWindow = makeDiagnosticsModel(store: store)
        await model.refreshRuntimeStatus()
        await otherWindow.refreshRuntimeStatus()
        XCTAssertEqual(model.authorizedDirectories.map(\.id), [authorization.id])
        let entered = expectation(description: "inventory resolver paused")
        gate.arm(entered)
        let refresh = Task { await model.refreshRuntimeStatus() }
        await fulfillment(of: [entered], timeout: 2)
        defer { gate.release.signal() }

        let revokingModel = fromAnotherWindow ? otherWindow : model
        let revoked = expectation(description: "revocation finishes before resolver resumes")
        let revoke = Task {
            await revokingModel.revokeAuthorization(authorization.id)
            revoked.fulfill()
        }
        await fulfillment(of: [revoked], timeout: 2)
        XCTAssertFalse(model.isRefreshingRuntimeStatus)
        XCTAssertTrue(model.isLoadingAuthorizationInventory)
        XCTAssertTrue(model.authorizedDirectories.isEmpty)
        XCTAssertTrue(otherWindow.authorizedDirectories.isEmpty)
        XCTAssertEqual(revokingModel.authorizationMessage, "目录授权已移除。")
        XCTAssertFalse(revokingModel.authorizationHasError)
        // No resolver calls are needed to remove a record or report success.
        XCTAssertTrue(try store.loadAuthorizedDirectoryInventory().availableDirectories.isEmpty)

        gate.release.signal()
        await revoke.value
        await refresh.value
        XCTAssertTrue(model.authorizedDirectories.isEmpty)
        XCTAssertTrue(otherWindow.authorizedDirectories.isEmpty)
        XCTAssertEqual(revokingModel.authorizationMessage, "目录授权已移除。")
    }

    func testFailedRevocationPreservesListAndFeedbackAfterPausedRefresh() async throws {
        let gate = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: gate)
        let authorization = try store.authorize(temporaryDirectory)
        let model = makeDiagnosticsModel(store: store)
        await model.refreshRuntimeStatus()
        let entered = expectation(description: "inventory resolver paused")
        gate.arm(entered)
        let refresh = Task { await model.refreshRuntimeStatus() }
        await fulfillment(of: [entered], timeout: 2)
        defer { gate.release.signal() }
        try Data("corrupt".utf8).write(to: temporaryDirectory.appendingPathComponent("authorizedDirectories.v2.json"))

        await model.revokeAuthorization(authorization.id)
        XCTAssertEqual(model.authorizedDirectories.map(\.id), [authorization.id])
        XCTAssertTrue(model.authorizationHasError)
        let failureMessage = try XCTUnwrap(model.authorizationMessage)
        gate.release.signal()
        await refresh.value
        XCTAssertEqual(model.authorizedDirectories.map(\.id), [authorization.id])
        XCTAssertTrue(model.authorizationHasError)
        XCTAssertEqual(model.authorizationMessage, failureMessage)
    }

    func testCancelledBlockedInventoryKeepsOneProcessSlotAndClosedWindowsDoNotQueue() async throws {
        let resolverGate = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: resolverGate)
        _ = try store.authorize(temporaryDirectory)
        var owner: DiagnosticsViewModel? = makeDiagnosticsModel(store: store)
        weak var weakOwner = owner
        let entered = expectation(description: "the single inventory reader is blocked")
        resolverGate.arm(entered)
        var refresh: Task<Void, Never>? = Task { [owner] in
            _ = await owner?.refreshRuntimeStatus()
        }
        await fulfillment(of: [entered], timeout: 2)
        defer { resolverGate.release.signal() }
        XCTAssertEqual(resolverGate.resolutionCount, 1)
        owner = nil
        refresh?.cancel()
        XCTAssertTrue(inventoryReadGate.isReading)
        XCTAssertNotNil(weakOwner, "Cancellation cannot release an operation still inside synchronous I/O")

        for _ in 0..<32 {
            var otherWindow: DiagnosticsViewModel? = makeDiagnosticsModel(store: store)
            weak var weakWindow = otherWindow
            var otherRefresh: Task<Void, Never>? = Task { [otherWindow] in
                _ = await otherWindow?.refreshRuntimeStatus()
            }
            await otherRefresh?.value
            XCTAssertFalse(otherWindow!.isRefreshingRuntimeStatus)
            XCTAssertNotNil(otherWindow!.authorizationInventoryMessage)
            otherRefresh?.cancel()
            otherRefresh = nil
            otherWindow = nil
            XCTAssertNil(weakWindow, "Rejected windows must not leave retained waiters")
        }
        XCTAssertEqual(resolverGate.resolutionCount, 1)
        XCTAssertTrue(inventoryReadGate.isReading)
        resolverGate.release.signal()
        await refresh?.value
        refresh = nil
        XCTAssertNil(weakOwner)
        XCTAssertFalse(inventoryReadGate.isReading)

        let newWindow = makeDiagnosticsModel(store: store)
        await newWindow.refreshRuntimeStatus()
        XCTAssertEqual(resolverGate.resolutionCount, 2)
        XCTAssertEqual(newWindow.authorizedDirectories.count, 1)
        XCTAssertFalse(newWindow.authorizationHasError)
    }

    func testCancelledInventoryDiscardsLateResultWithoutQueuingDuplicateInventory() async throws {
        let resolverGate = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: resolverGate)
        let authorization = try store.authorize(temporaryDirectory)
        let model = makeDiagnosticsModel(store: store)
        let entered = expectation(description: "inventory result will arrive after cancellation")
        resolverGate.arm(entered)
        let refresh = Task { await model.refreshRuntimeStatus() }
        await fulfillment(of: [entered], timeout: 2)
        defer { resolverGate.release.signal() }
        await model.refreshRuntimeStatus()
        refresh.cancel()
        resolverGate.release.signal()
        await refresh.value

        XCTAssertEqual(resolverGate.resolutionCount, 1, "Runtime refresh during blocked inventory must not queue another same-page inventory read")
        XCTAssertTrue(model.authorizedDirectories.isEmpty)
        XCTAssertNotNil(model.extensionSnapshot, "The handshake completed before inventory cancellation")
        XCTAssertFalse(model.isRefreshingRuntimeStatus)
        XCTAssertFalse(inventoryReadGate.isReading)
        await model.refreshRuntimeStatus()
        XCTAssertEqual(model.authorizedDirectories.map(\.id), [authorization.id])
        XCTAssertEqual(resolverGate.resolutionCount, 2)
    }

    func testAuthorizationAndRefreshShareAdmissionAcrossWindows() async throws {
        let resolverGate = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: resolverGate)
        _ = try store.authorize(temporaryDirectory)
        let owner = makeDiagnosticsModel(store: store)
        let otherWindow = makeDiagnosticsModel(store: store)
        let entered = expectation(description: "authorization is resolving existing records")
        resolverGate.arm(entered)
        let authorizing = Task { await owner.authorizeDirectory(temporaryDirectory) }
        await fulfillment(of: [entered], timeout: 2)
        defer { resolverGate.release.signal() }
        authorizing.cancel()
        await otherWindow.refreshRuntimeStatus()
        await otherWindow.authorizeDirectory(temporaryDirectory)
        XCTAssertEqual(resolverGate.resolutionCount, 1)
        XCTAssertFalse(otherWindow.isManagingAuthorizations)
        XCTAssertTrue(inventoryReadGate.isReading)
        resolverGate.release.signal()
        await authorizing.value
        XCTAssertTrue(owner.authorizedDirectories.isEmpty, "A cancelled generation cannot publish its inventory")
        XCTAssertFalse(inventoryReadGate.isReading)
        await otherWindow.refreshRuntimeStatus()
        XCTAssertEqual(otherWindow.authorizedDirectories.count, 1)
        XCTAssertFalse(otherWindow.authorizationHasError)
    }

    func testCancelledBulkCleanupKeepsAdmissionUntilResolverReturnsAndPublishesCommittedRemoval() async throws {
        let authorization = try makeAuthorizationStore().authorize(temporaryDirectory)
        let resolverGate = InventoryResolutionGate()
        let store = makeUnavailableAuthorizationStore(unavailablePaths: [temporaryDirectory.path], gate: resolverGate)
        let owner = makeDiagnosticsModel(store: store)
        let otherWindow = makeDiagnosticsModel(store: store)
        await owner.refreshRuntimeStatus()
        await otherWindow.refreshRuntimeStatus()
        let entered = expectation(description: "bulk cleanup is resolving selected bookmarks")
        resolverGate.arm(entered)
        let cleanup = Task { await owner.revokeUnavailableAuthorizations() }
        await fulfillment(of: [entered], timeout: 2)
        defer { resolverGate.release.signal() }
        cleanup.cancel()
        XCTAssertTrue(inventoryReadGate.isReading)
        await otherWindow.refreshRuntimeStatus()
        await otherWindow.revokeUnavailableAuthorizations()
        XCTAssertEqual(resolverGate.resolutionCount, 3)
        XCTAssertEqual(otherWindow.unavailableAuthorizedDirectories.map(\.id), [authorization.id])
        XCTAssertFalse(otherWindow.isManagingAuthorizations)

        resolverGate.release.signal()
        await cleanup.value
        XCTAssertFalse(inventoryReadGate.isReading)
        // Cancellation cannot roll back a committed removal. Other windows must
        // receive that revocation even if the initiating window has closed.
        XCTAssertTrue(owner.unavailableAuthorizedDirectories.isEmpty)
        XCTAssertTrue(otherWindow.unavailableAuthorizedDirectories.isEmpty)
        XCTAssertTrue(try makeAuthorizationStore().loadAuthorizedDirectories().isEmpty)
    }

    func testCancelledRuntimeProbeRetainsProcessSlotAndRejectsOtherWindowsWithoutQueueing() async throws {
        let runtimeGate = DiagnosticsRuntimeReadGate()
        let started = expectation(description: "runtime evidence is still in progress")
        var continuation: CheckedContinuation<Void, Never>?
        var probeCount = 0
        let provider: (Bool) async -> FinderExtensionDiagnosticSnapshot = { enabled in
            probeCount += 1
            if probeCount == 1 {
                await withCheckedContinuation { (pending: CheckedContinuation<Void, Never>) in
                    continuation = pending
                    started.fulfill()
                }
            }
            return FinderExtensionDiagnosticSnapshot(
                embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
                registration: .registered, registrationEvidence: "test",
                enabled: enabled, responded: true
            )
        }
        let owner = DiagnosticsViewModel(
            extensionEnabledProvider: { true }, runtimeProvider: provider,
            extensionActivityStore: FinderExtensionActivityStore(
                defaults: defaults, failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
            ),
            authorizedDirectoryStore: makeAuthorizationStore(), inventoryReadGate: inventoryReadGate,
            runtimeReadGate: runtimeGate
        )
        let refresh = Task { await owner.refreshRuntimeStatus() }
        await fulfillment(of: [started], timeout: 2)
        refresh.cancel()
        owner.directoryDiagnosticsDidDisappear()
        owner.directoryDiagnosticsDidAppear()
        XCTAssertTrue(runtimeGate.isReading)
        XCTAssertFalse(inventoryReadGate.isReading)
        for _ in 0..<8 {
            var otherWindow: DiagnosticsViewModel? = DiagnosticsViewModel(
                extensionEnabledProvider: { true }, runtimeProvider: provider,
                extensionActivityStore: FinderExtensionActivityStore(
                    defaults: defaults, failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
                ),
                authorizedDirectoryStore: makeAuthorizationStore(), inventoryReadGate: inventoryReadGate,
                runtimeReadGate: runtimeGate
            )
            weak var weakWindow = otherWindow
            await otherWindow?.refreshRuntimeStatus()
            XCTAssertNotNil(otherWindow?.runtimeStatusMessage)
            XCTAssertNil(otherWindow?.extensionSnapshot)
            otherWindow = nil
            XCTAssertNil(weakWindow)
        }
        XCTAssertEqual(probeCount, 1)
        XCTAssertTrue(runtimeGate.isReading)
        continuation?.resume()
        await refresh.value
        XCTAssertNil(owner.extensionSnapshot)
        XCTAssertFalse(runtimeGate.isReading)
        await owner.refreshRuntimeStatus()
        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(owner.extensionSnapshot?.state, .responding)
        XCTAssertFalse(runtimeGate.isReading)
    }

    func testRuntimeAndSharedStorePublishBeforeBlockedInventoryAndOtherWindowCanProbe() async throws {
        let resolver = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: resolver)
        _ = try store.authorize(temporaryDirectory)
        let owner = makeDiagnosticsModel(store: store, enabled: true)
        let otherWindow = makeDiagnosticsModel(store: store, enabled: true)
        let entered = expectation(description: "inventory paused after runtime evidence")
        resolver.arm(entered)
        defer { resolver.release.signal() }
        let refresh = Task { await owner.refreshRuntimeStatus() }
        await fulfillment(of: [entered], timeout: 2)

        XCTAssertEqual(owner.extensionSnapshot?.state, .responding)
        XCTAssertTrue(owner.hasLoadedActivityStoreStatus)
        XCTAssertTrue(owner.isAppGroupStoreAvailable)
        XCTAssertTrue(owner.isLoadingAuthorizationInventory)
        XCTAssertTrue(inventoryReadGate.isReading)
        await otherWindow.refreshRuntimeStatus()
        XCTAssertEqual(otherWindow.extensionSnapshot?.state, .responding, "An occupied inventory slot cannot suppress the handshake")
        XCTAssertTrue(otherWindow.hasLoadedActivityStoreStatus)
        XCTAssertTrue(otherWindow.isAppGroupStoreAvailable)
        XCTAssertNotNil(otherWindow.authorizationInventoryMessage)
        XCTAssertEqual(resolver.resolutionCount, 1, "Rejected inventory reads are never queued")
        XCTAssertTrue(inventoryReadGate.isReading)

        resolver.release.signal()
        await refresh.value
        XCTAssertFalse(owner.isLoadingAuthorizationInventory)
        XCTAssertEqual(owner.authorizedDirectories.count, 1)
        XCTAssertFalse(inventoryReadGate.isReading)
    }

    func testEnabledChangeDuringBlockedInventoryCanProbeAgainWithoutWaitingForInventory() async throws {
        let resolver = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: resolver)
        _ = try store.authorize(temporaryDirectory)
        var enabled = true
        var probeCount = 0
        let model = DiagnosticsViewModel(
            extensionEnabledProvider: { enabled },
            runtimeProvider: { currentEnabled in
                probeCount += 1
                return FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
                    registration: .registered, registrationEvidence: "test",
                    enabled: currentEnabled, responded: currentEnabled
                )
            },
            extensionActivityStore: FinderExtensionActivityStore(
                defaults: defaults, failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
            ),
            authorizedDirectoryStore: store, inventoryReadGate: inventoryReadGate
        )
        let entered = expectation(description: "inventory paused after responding probe")
        resolver.arm(entered)
        defer { resolver.release.signal() }
        let refresh = Task { await model.refreshRuntimeStatus() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(model.extensionSnapshot?.state, .responding)
        enabled = false
        await model.refreshRuntimeStatus()
        XCTAssertFalse(model.isFinderExtensionEnabled)
        XCTAssertEqual(model.extensionSnapshot?.state, .disabled,
                       "A new runtime probe must finish before the blocked inventory is released")
        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(resolver.resolutionCount, 1, "Runtime requests must not duplicate inventory work")
        XCTAssertFalse(model.isRefreshingRuntimeStatus)
        XCTAssertTrue(model.isLoadingAuthorizationInventory)
        XCTAssertTrue(inventoryReadGate.isReading)
        resolver.release.signal()
        await refresh.value
        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(model.extensionSnapshot?.state, .disabled)
        XCTAssertFalse(inventoryReadGate.isReading)
    }

    func testCommittedAuthorizationIsVisibleBeforeInventoryAndOtherWindowRevocationCannotResurrectIt() async throws {
        try await assertRevocationDuringPostCommitInventory(fromAnotherWindow: true)
    }

    func testCommittedAuthorizationIsVisibleBeforeInventoryAndSameWindowRevocationCannotResurrectIt() async throws {
        try await assertRevocationDuringPostCommitInventory(fromAnotherWindow: false)
    }

    private func assertRevocationDuringPostCommitInventory(fromAnotherWindow: Bool) async throws {
        let resolver = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: resolver)
        _ = try store.authorize(temporaryDirectory)
        let selected = temporaryDirectory.appendingPathComponent("NewGrant", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let model = makeDiagnosticsModel(store: store)
        let otherWindow = makeDiagnosticsModel(store: store)
        let entered = expectation(description: "unrelated inventory blocks after new grant commits")
        resolver.arm(entered)
        defer { resolver.release.signal() }
        let adding = Task { await model.authorizeDirectory(selected) }
        await fulfillment(of: [entered], timeout: 2)

        let committed = try XCTUnwrap(model.authorizedDirectories.first)
        XCTAssertEqual(committed.url, selected.standardizedFileURL)
        XCTAssertEqual(model.authorizationMessage, "目录授权已保存。")
        XCTAssertFalse(model.authorizationHasError)
        XCTAssertFalse(model.isManagingAuthorizations)
        XCTAssertTrue(model.isLoadingAuthorizationInventory)
        XCTAssertTrue(inventoryReadGate.isReading)
        let revokingWindow = fromAnotherWindow ? otherWindow : model
        await revokingWindow.revokeAuthorization(committed.id)
        XCTAssertTrue(model.authorizedDirectories.isEmpty)
        XCTAssertEqual(revokingWindow.authorizationMessage, "目录授权已移除。")
        resolver.release.signal()
        await adding.value
        XCTAssertFalse(model.authorizedDirectories.contains { $0.id == committed.id })
        XCTAssertEqual(model.authorizedDirectories.count, 1, "Unrelated existing grant remains visible")
        XCTAssertFalse(inventoryReadGate.isReading)
        XCTAssertEqual(revokingWindow.authorizationMessage, "目录授权已移除。")
        XCTAssertFalse(revokingWindow.authorizationHasError)
    }

    func testUnavailableBookmarkDoesNotMaskCommittedAuthorization() async throws {
        let existing = try makeAuthorizationStore().authorize(temporaryDirectory)
        let selected = temporaryDirectory.appendingPathComponent("NewGrant", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let model = makeDiagnosticsModel(store: makeUnavailableAuthorizationStore(
            unavailablePaths: [temporaryDirectory.path]
        ))
        await model.authorizeDirectory(selected)
        XCTAssertEqual(model.authorizationMessage, "目录授权已保存。")
        XCTAssertFalse(model.authorizationHasError)
        XCTAssertEqual(model.authorizedDirectories.map(\.url), [selected.standardizedFileURL])
        XCTAssertEqual(model.unavailableAuthorizedDirectories.map(\.id), [existing.id])
        XCTAssertEqual(model.authorizationInventoryMessage, "有 1 个目录授权暂不可用。")
    }

    func testRepositoryRefreshFailureDoesNotMaskCommittedAuthorization() async throws {
        let model = makeDiagnosticsModel(store: makeAuthorizationStore())
        let repositoryURL = temporaryDirectory.appendingPathComponent("authorizedDirectories.v2.json")
        var injectionError: Error?
        // Published feedback is synchronous on MainActor, before inventory is
        // scheduled. Corrupt only the subsequent repository read deterministically.
        let observation = model.$authorizationMessage.sink { message in
            guard message == "目录授权已保存。" else { return }
            do { try Data("corrupt after commit".utf8).write(to: repositoryURL) }
            catch { injectionError = error }
        }
        await model.authorizeDirectory(temporaryDirectory)
        withExtendedLifetime(observation) {}
        XCTAssertNil(injectionError)
        XCTAssertEqual(model.authorizationMessage, "目录授权已保存。")
        XCTAssertFalse(model.authorizationHasError)
        XCTAssertEqual(model.authorizedDirectories.map(\.url), [temporaryDirectory.standardizedFileURL])
        XCTAssertTrue(model.authorizationInventoryMessage?.hasPrefix("无法刷新目录授权列表：") == true)
        XCTAssertFalse(model.isLoadingAuthorizationInventory)
        XCTAssertFalse(inventoryReadGate.isReading)
    }

    func testCancelledPostCommitInventoryPreservesCommitAndRetainsPermitUntilReturn() async throws {
        let resolver = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: resolver)
        _ = try store.authorize(temporaryDirectory)
        let selected = temporaryDirectory.appendingPathComponent("NewGrant", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let model = makeDiagnosticsModel(store: store)
        let entered = expectation(description: "inventory paused after commit publication")
        resolver.arm(entered)
        defer { resolver.release.signal() }
        let adding = Task { await model.authorizeDirectory(selected) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(model.authorizationMessage, "目录授权已保存。")
        adding.cancel()
        model.directoryDiagnosticsDidDisappear()
        model.directoryDiagnosticsDidAppear()
        XCTAssertTrue(inventoryReadGate.isReading)
        XCTAssertTrue(model.isLoadingAuthorizationInventory)
        resolver.release.signal()
        await adding.value
        XCTAssertEqual(model.authorizedDirectories.map(\.url), [selected.standardizedFileURL],
                       "Do not publish the late full inventory into the new presentation")
        XCTAssertEqual(model.authorizationMessage, "目录授权已保存。")
        XCTAssertFalse(inventoryReadGate.isReading)
        await model.refreshRuntimeStatus()
        XCTAssertEqual(model.authorizedDirectories.count, 2)
    }

    func testClosedAndReopenedInventoryGenerationDropsLateRowsWithoutCancellation() async throws {
        let resolver = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: resolver)
        _ = try store.authorize(temporaryDirectory)
        let model = makeDiagnosticsModel(store: store)
        let entered = expectation(description: "old presentation inventory paused")
        resolver.arm(entered)
        defer { resolver.release.signal() }
        let refresh = Task { await model.refreshRuntimeStatus() }
        await fulfillment(of: [entered], timeout: 2)
        model.directoryDiagnosticsDidDisappear()
        model.directoryDiagnosticsDidAppear()
        XCTAssertFalse(refresh.isCancelled)
        XCTAssertTrue(inventoryReadGate.isReading)
        resolver.release.signal()
        await refresh.value
        XCTAssertTrue(model.authorizedDirectories.isEmpty)
        XCTAssertFalse(inventoryReadGate.isReading)
        await model.refreshRuntimeStatus()
        XCTAssertEqual(model.authorizedDirectories.count, 1)
    }

    func testReopenedPageKeepsInventoryIntentAfterCancelledOldRead() async throws {
        try await assertReopenedRefreshDuringInventory(cancelOld: true)
    }

    func testReopenedPageKeepsInventoryIntentAfterUncancelledOldRead() async throws {
        try await assertReopenedRefreshDuringInventory(cancelOld: false)
    }

    private func assertReopenedRefreshDuringInventory(cancelOld: Bool) async throws {
        let resolver = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: resolver)
        let authorization = try store.authorize(temporaryDirectory)
        let model = makeDiagnosticsModel(store: store, enabled: true)
        let oldEntered = expectation(description: "old presentation inventory blocked")
        resolver.arm(oldEntered)
        defer { resolver.release.signal() }
        let oldRefresh = Task { await model.refreshRuntimeStatus() }
        await fulfillment(of: [oldEntered], timeout: 2)
        if cancelOld { oldRefresh.cancel() }
        for _ in 0..<4 {
            model.directoryDiagnosticsDidDisappear()
            model.directoryDiagnosticsDidAppear()
            for _ in 0..<8 { await model.refreshRuntimeStatus() }
        }
        XCTAssertEqual(oldRefresh.isCancelled, cancelOld)
        XCTAssertTrue(model.isLoadingAuthorizationInventory)
        XCTAssertFalse(model.isRefreshingRuntimeStatus)
        XCTAssertEqual(resolver.resolutionCount, 1, "Reopening must not bypass the occupied inventory slot")

        let newEntered = expectation(description: "one new presentation inventory starts after actual return")
        resolver.arm(newEntered)
        resolver.release.signal()
        await oldRefresh.value
        await fulfillment(of: [newEntered], timeout: 2)
        XCTAssertTrue(model.authorizedDirectories.isEmpty, "Old-generation rows must not publish")
        XCTAssertEqual(resolver.resolutionCount, 2)
        XCTAssertTrue(inventoryReadGate.isReading)
        let published = expectation(description: "new presentation inventory published")
        let observation = model.$authorizedDirectories.dropFirst().sink { directories in
            if directories.map(\.id) == [authorization.id] { published.fulfill() }
        }
        resolver.release.signal()
        await fulfillment(of: [published], timeout: 2)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(resolver.resolutionCount, 2, "Repeated reopen requests coalesce to one inventory read")
        XCTAssertEqual(model.authorizedDirectories.map(\.id), [authorization.id])
        XCTAssertFalse(model.isLoadingAuthorizationInventory)
        XCTAssertFalse(inventoryReadGate.isReading)
    }

    func testReopenedInventoryIntentSurvivesConcurrentSingleRecordRevocation() async throws {
        let resolver = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: resolver)
        let authorization = try store.authorize(temporaryDirectory)
        let model = makeDiagnosticsModel(store: store)
        let entered = expectation(description: "old inventory paused outside repository lock")
        resolver.arm(entered)
        defer { resolver.release.signal() }
        let oldRefresh = Task { await model.refreshRuntimeStatus() }
        await fulfillment(of: [entered], timeout: 2)
        model.directoryDiagnosticsDidDisappear()
        model.directoryDiagnosticsDidAppear()
        await model.refreshRuntimeStatus()

        // Hold only this fixture's existing repository lock, so the allowed
        // single-record revocation stays in flight when the old read returns.
        let descriptor = open(temporaryDirectory.appendingPathComponent("authorizedDirectories.lock").path, O_RDWR)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let revocationStarted = expectation(description: "single-record revocation admitted")
        let mutationObservation = model.$isManagingAuthorizations.dropFirst().filter { $0 }.prefix(1).sink { _ in
            revocationStarted.fulfill()
        }
        let revocation = Task { await model.revokeAuthorization(authorization.id) }
        await fulfillment(of: [revocationStarted], timeout: 2)
        XCTAssertTrue(model.isManagingAuthorizations)
        resolver.release.signal()
        await oldRefresh.value
        XCTAssertTrue(model.isLoadingAuthorizationInventory, "New-generation intent must survive a concurrent revoke")
        XCTAssertTrue(inventoryReadGate.isReading)
        XCTAssertTrue(model.authorizedDirectories.isEmpty, "Closed-generation inventory still cannot publish")
        let replacementFinished = expectation(description: "replacement inventory releases actual admission")
        let inventoryObservation = model.$isLoadingAuthorizationInventory.dropFirst().filter { !$0 }.prefix(1).sink { _ in
            replacementFinished.fulfill()
        }
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        await revocation.value
        await fulfillment(of: [replacementFinished], timeout: 2)
        withExtendedLifetime((mutationObservation, inventoryObservation)) {}
        XCTAssertTrue(model.authorizedDirectories.isEmpty, "Committed revocation wins regardless of repository read order")
        XCTAssertFalse(model.isManagingAuthorizations)
        XCTAssertFalse(model.isLoadingAuthorizationInventory)
        XCTAssertFalse(inventoryReadGate.isReading)
    }

    func testClosedAgainDiscardsPendingReopenedInventoryIntent() async throws {
        let resolver = InventoryResolutionGate()
        let store = makeAuthorizationStore(gate: resolver)
        _ = try store.authorize(temporaryDirectory)
        let model = makeDiagnosticsModel(store: store)
        let entered = expectation(description: "inventory blocked across two closed presentations")
        resolver.arm(entered)
        defer { resolver.release.signal() }
        let refresh = Task { await model.refreshRuntimeStatus() }
        await fulfillment(of: [entered], timeout: 2)
        model.directoryDiagnosticsDidDisappear()
        model.directoryDiagnosticsDidAppear()
        await model.refreshRuntimeStatus()
        model.directoryDiagnosticsDidDisappear()
        resolver.release.signal()
        await refresh.value
        XCTAssertTrue(model.authorizedDirectories.isEmpty)
        XCTAssertEqual(resolver.resolutionCount, 1)
        XCTAssertFalse(inventoryReadGate.isReading)
    }

    private func makeDiagnosticsModel(store: AuthorizedDirectoryStore, enabled: Bool = false) -> DiagnosticsViewModel {
        DiagnosticsViewModel(
            extensionEnabledProvider: { enabled },
            runtimeProvider: { enabled in
                FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: ["test.extension"], embeddingKnown: true, registration: .unknown,
                    registrationEvidence: "test", enabled: enabled, responded: enabled ? true : nil
                )
            },
            extensionActivityStore: FinderExtensionActivityStore(
                defaults: defaults,
                failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
            ),
            authorizedDirectoryStore: store,
            inventoryReadGate: inventoryReadGate
        )
    }

    private func makeAuthorizationStore(gate: InventoryResolutionGate) -> AuthorizedDirectoryStore {
        AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { Self.bookmarkData(for: $0) }, transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { data in
                gate.pauseIfArmed()
                return ResolvedSecurityScopedBookmark(
                    url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true),
                    isStale: false
                )
            },
            transferBookmarkResolver: { try Self.resolveBookmark($0) },
            startAccessing: { _ in true }, stopAccessing: { _ in }
        )
    }

    func testDirectoryInspectionAndFailureHistoryActionsUpdateState() async throws {
        let activityStore = FinderExtensionActivityStore(
            defaults: defaults,
            failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
        )
        let failure = FinderExtensionActivityFailure(
            reason: .writeFailed,
            errorDomain: NSCocoaErrorDomain,
            errorCode: NSFileWriteUnknownError
        )
        try activityStore.record(.fileCreationFailed, failure: failure)
        let viewModel = DiagnosticsViewModel(
            extensionEnabledProvider: { false },
            extensionActivityStore: activityStore,
            authorizedDirectoryStore: makeAuthorizationStore(),
            inventoryReadGate: inventoryReadGate
        )
        await viewModel.refreshRuntimeStatus()

        await viewModel.inspectDirectory(temporaryDirectory)
        await viewModel.clearFailureHistory()

        XCTAssertEqual(viewModel.report?.folderURL, temporaryDirectory.standardizedFileURL)
        XCTAssertEqual(viewModel.report?.writeProbeSucceeded, true)
        XCTAssertTrue(viewModel.recentExtensionFailures.isEmpty)
        XCTAssertEqual(viewModel.activityStoreMessage, "失败历史已清空；最近扩展活动状态仍保留。")
        XCTAssertFalse(viewModel.activityStoreHasError)
    }

    func testHistoryClearRejectsOccupiedRuntimeSlotWithoutChangingTheFile() async throws {
        let history = temporaryDirectory.appendingPathComponent("failures.json")
        let original = Data("preserve until admitted".utf8)
        try original.write(to: history)
        let gate = DiagnosticsRuntimeReadGate()
        XCTAssertTrue(gate.tryBegin())
        defer { gate.finish() }
        let model = DiagnosticsViewModel(
            extensionEnabledProvider: { false },
            extensionActivityStore: FinderExtensionActivityStore(defaults: defaults, failureHistoryFileURL: history),
            authorizedDirectoryStore: makeAuthorizationStore(), inventoryReadGate: inventoryReadGate,
            runtimeReadGate: gate
        )
        await model.clearFailureHistory()
        XCTAssertEqual(try Data(contentsOf: history), original)
        XCTAssertFalse(model.isRefreshingRuntimeStatus)
        XCTAssertNotNil(model.activityStoreMessage)
        XCTAssertTrue(gate.isReading, "A rejected clear cannot release another operation's permit")
    }

    func testCancelledHistoryClearKeepsGlobalAdmissionUntilRealFileLockWorkReturns() async throws {
        let history = temporaryDirectory.appendingPathComponent("failures.json")
        try Data("[]".utf8).write(to: history)
        let lockFD = open(history.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        guard lockFD >= 0 else { return }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        XCTAssertEqual(flock(lockFD, LOCK_EX), 0)

        var owner: DiagnosticsViewModel? = makeDiagnosticsModel(store: makeAuthorizationStore())
        weak var weakOwner = owner
        let entered = expectation(description: "clear admitted before blocked file work")
        var observation: AnyCancellable? = owner!.$isRefreshingRuntimeStatus.first(where: { $0 }).sink { _ in
            entered.fulfill()
        }
        var clearing: Task<Void, Never>? = Task { [model = owner!] in await model.clearFailureHistory() }
        await fulfillment(of: [entered], timeout: 2)
        observation?.cancel()
        observation = nil
        XCTAssertTrue(DiagnosticsRuntimeReadGate.shared.isReading)
        owner?.directoryDiagnosticsDidDisappear()
        clearing?.cancel()
        owner = nil
        XCTAssertNotNil(weakOwner, "Cancellation does not end synchronous file-lock work")

        let others = (0..<2).map { _ in makeDiagnosticsModel(store: makeAuthorizationStore()) }
        let rejected = expectation(description: "other windows return without waiting for file lock")
        rejected.expectedFulfillmentCount = others.count
        let rejectedTasks = others.map { model in
            Task { await model.clearFailureHistory(); rejected.fulfill() }
        }
        await fulfillment(of: [rejected], timeout: 1)
        for model in others {
            XCTAssertFalse(model.isRefreshingRuntimeStatus)
            XCTAssertNotNil(model.activityStoreMessage)
        }
        XCTAssertTrue(DiagnosticsRuntimeReadGate.shared.isReading)
        XCTAssertEqual(flock(lockFD, LOCK_UN), 0)
        await clearing?.value
        clearing = nil
        for task in rejectedTasks { await task.value }
        XCTAssertFalse(DiagnosticsRuntimeReadGate.shared.isReading)
        XCTAssertNil(weakOwner)
        await others[0].clearFailureHistory()
        XCTAssertEqual(others[0].activityStoreMessage, "失败历史已清空；最近扩展活动状态仍保留。")
    }

    func testClosedProbeKeepsProcessAdmissionThroughWriteAndCleanupWithoutRetainingRejectedWindows() async throws {
        let writeBarrier = DirectoryProbeStageBarrier()
        let cleanupBarrier = DirectoryProbeStageBarrier()
        let service = DirectoryDiagnosticsService(
            beforeProbeWrite: { try writeBarrier.pauseIfArmed($0) },
            beforeProbeCleanup: { try cleanupBarrier.pauseIfArmed($0) }
        )
        let sentinel = temporaryDirectory.appendingPathComponent("user-data.txt")
        try Data("preserve user data".utf8).write(to: sentinel)
        let writeEntered = expectation(description: "the only actual probe is blocked before writing")
        let cleanupEntered = expectation(description: "cancelled probe is blocked before cleanup")
        writeBarrier.arm(writeEntered)
        cleanupBarrier.arm(cleanupEntered)
        defer {
            writeBarrier.release.signal()
            cleanupBarrier.release.signal()
        }

        // Omit injection here: independently created windows must use the same
        // production default, not just happen to share a test-only gate.
        var owner: DiagnosticsViewModel? = makeProbeModel(service: service)
        weak var weakOwner = owner
        var inspection: Task<Void, Never>? = try XCTUnwrap(owner?.startDirectoryInspection(temporaryDirectory))
        await fulfillment(of: [writeEntered], timeout: 2)
        XCTAssertTrue(DiagnosticsWriteProbeGate.shared.isRunning)
        XCTAssertNil(owner?.startDirectoryInspection(temporaryDirectory), "Repeated actions do not enqueue a second task")
        owner?.directoryDiagnosticsDidDisappear()
        owner = nil
        XCTAssertTrue(inspection!.isCancelled)
        XCTAssertNotNil(weakOwner, "Actual I/O still owns its task and permit after the window closes")

        for _ in 0..<32 {
            var otherWindow: DiagnosticsViewModel? = makeProbeModel(service: service)
            weak var weakWindow = otherWindow
            XCTAssertNil(otherWindow?.startDirectoryInspection(temporaryDirectory))
            XCTAssertFalse(otherWindow!.isInspectingDirectory)
            XCTAssertNotNil(otherWindow!.directoryInspectionMessage)
            otherWindow?.directoryDiagnosticsDidDisappear()
            otherWindow = nil
            XCTAssertNil(weakWindow, "Immediate rejection must not retain a waiting window or task")
        }
        XCTAssertEqual(writeBarrier.callCount, 1)
        XCTAssertEqual(cleanupBarrier.callCount, 0)
        XCTAssertTrue(DiagnosticsWriteProbeGate.shared.isRunning)

        writeBarrier.release.signal()
        await fulfillment(of: [cleanupEntered], timeout: 2)
        let probeURL = try XCTUnwrap(cleanupBarrier.lastProbeURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: probeURL.appendingPathComponent("payload").path))
        XCTAssertTrue(DiagnosticsWriteProbeGate.shared.isRunning, "Cancellation must not release before cleanup returns")
        XCTAssertNil(weakOwner?.report)
        let retryWindow = makeProbeModel(service: service)
        XCTAssertNil(retryWindow.startDirectoryInspection(temporaryDirectory))
        XCTAssertEqual(writeBarrier.callCount, 1)

        cleanupBarrier.release.signal()
        await inspection?.value
        inspection = nil
        XCTAssertNil(weakOwner)
        XCTAssertFalse(DiagnosticsWriteProbeGate.shared.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeURL.path))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "preserve user data")

        let retry = try XCTUnwrap(retryWindow.startDirectoryInspection(temporaryDirectory))
        await retry.value
        XCTAssertEqual(writeBarrier.callCount, 2)
        XCTAssertEqual(cleanupBarrier.callCount, 2)
        XCTAssertEqual(retryWindow.report?.writeProbeSucceeded, true)
        XCTAssertNil(retryWindow.directoryInspectionMessage)
        XCTAssertFalse(DiagnosticsWriteProbeGate.shared.isRunning)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), ["user-data.txt"])
    }

    func testClosedAndReopenedProbeGenerationDiscardsLateResultWithoutTaskCancellation() async throws {
        let barrier = DirectoryProbeStageBarrier()
        let gate = DiagnosticsWriteProbeGate()
        let service = DirectoryDiagnosticsService(beforeProbeWrite: { try barrier.pauseIfArmed($0) })
        let model = makeProbeModel(service: service, gate: gate)
        await model.inspectDirectory(temporaryDirectory)
        let previousReport = try XCTUnwrap(model.report)
        let secondDirectory = temporaryDirectory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: false)
        let entered = expectation(description: "result belongs to the closed presentation generation")
        barrier.arm(entered)
        defer { barrier.release.signal() }
        let inspection = Task { await model.inspectDirectory(secondDirectory) }
        await fulfillment(of: [entered], timeout: 2)

        model.directoryDiagnosticsDidDisappear()
        XCTAssertNil(model.startDirectoryInspection(temporaryDirectory), "A closed page cannot schedule a new probe")
        model.directoryDiagnosticsDidAppear()
        XCTAssertNil(model.startDirectoryInspection(temporaryDirectory), "Reopening does not free the actual I/O slot")
        XCTAssertFalse(inspection.isCancelled, "This test isolates generation rejection from cancellation")
        barrier.release.signal()
        await inspection.value

        XCTAssertEqual(model.report, previousReport)
        XCTAssertFalse(model.isInspectingDirectory)
        XCTAssertFalse(gate.isRunning)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: secondDirectory.path), [])
        await model.inspectDirectory(secondDirectory)
        XCTAssertEqual(model.report?.folderURL, secondDirectory.standardizedFileURL)
        XCTAssertEqual(model.report?.writeProbeSucceeded, true)
        XCTAssertEqual(barrier.callCount, 3)
    }

    func testCancelledProbeDropsLateReportButFinishesCleanupAndAllowsRetry() async throws {
        let barrier = DirectoryProbeStageBarrier()
        let gate = DiagnosticsWriteProbeGate()
        let service = DirectoryDiagnosticsService(beforeProbeCleanup: { try barrier.pauseIfArmed($0) })
        let model = makeProbeModel(service: service, gate: gate)
        let entered = expectation(description: "cancelled caller still waits for actual cleanup")
        barrier.arm(entered)
        defer { barrier.release.signal() }
        let inspection = Task { await model.inspectDirectory(temporaryDirectory) }
        await fulfillment(of: [entered], timeout: 2)
        inspection.cancel()
        XCTAssertTrue(gate.isRunning)
        XCTAssertTrue(model.isInspectingDirectory)
        let probeURL = try XCTUnwrap(barrier.lastProbeURL)
        barrier.release.signal()
        await inspection.value

        XCTAssertNil(model.report)
        XCTAssertFalse(model.isInspectingDirectory)
        XCTAssertFalse(gate.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeURL.path))
        await model.inspectDirectory(temporaryDirectory)
        XCTAssertEqual(model.report?.writeProbeSucceeded, true)
        XCTAssertEqual(barrier.callCount, 2)
    }

    func testManagedProbeClosedBeforeTaskStartsDoesNotPerformIOAndReleasesAdmission() async throws {
        let barrier = DirectoryProbeStageBarrier()
        let gate = DiagnosticsWriteProbeGate()
        let model = makeProbeModel(
            service: DirectoryDiagnosticsService(beforeProbeWrite: { try barrier.pauseIfArmed($0) }),
            gate: gate
        )
        let inspection = try XCTUnwrap(model.startDirectoryInspection(temporaryDirectory))
        // No suspension: the admitted child task has not entered its main-actor body.
        model.directoryDiagnosticsDidDisappear()
        model.directoryDiagnosticsDidAppear()
        XCTAssertTrue(gate.isRunning)
        await inspection.value
        XCTAssertEqual(barrier.callCount, 0)
        XCTAssertNil(model.report)
        XCTAssertFalse(model.isInspectingDirectory)
        XCTAssertFalse(gate.isRunning)
        await model.inspectDirectory(temporaryDirectory)
        XCTAssertEqual(barrier.callCount, 1)
        XCTAssertEqual(model.report?.writeProbeSucceeded, true)
    }

    func testAlreadyCancelledProbeRequestDoesNotTakeAdmissionOrStartIO() async {
        let barrier = DirectoryProbeStageBarrier()
        let gate = DiagnosticsWriteProbeGate()
        let model = makeProbeModel(
            service: DirectoryDiagnosticsService(beforeProbeWrite: { try barrier.pauseIfArmed($0) }),
            gate: gate
        )
        let request = Task {
            await model.inspectDirectory(temporaryDirectory)
            XCTAssertNil(model.startDirectoryInspection(temporaryDirectory))
        }
        // Both tasks are MainActor-isolated, so cancel before allowing the body to run.
        request.cancel()
        await request.value
        XCTAssertEqual(barrier.callCount, 0)
        XCTAssertNil(model.report)
        XCTAssertFalse(model.isInspectingDirectory)
        XCTAssertFalse(gate.isRunning)
    }

    func testProbeFailureCompletesCleanupAndReleasesAdmission() async throws {
        let gate = DiagnosticsWriteProbeGate()
        let service = DirectoryDiagnosticsService(beforeProbeCleanup: { _ in
            throw TestError.probeCleanupFailed
        })
        let model = makeProbeModel(service: service, gate: gate)
        await model.inspectDirectory(temporaryDirectory)

        XCTAssertEqual(model.report?.writeProbeSucceeded, false)
        XCTAssertFalse(gate.isRunning)
        XCTAssertFalse(model.isInspectingDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), [])
        let nextWindow = makeProbeModel(service: DirectoryDiagnosticsService(), gate: gate)
        await nextWindow.inspectDirectory(temporaryDirectory)
        XCTAssertEqual(nextWindow.report?.writeProbeSucceeded, true)
        XCTAssertFalse(gate.isRunning)
    }

    func testBlockedProbeDoesNotBlockInventoryReadsOrCommittedRevocations() async throws {
        let barrier = DirectoryProbeStageBarrier()
        let gate = DiagnosticsWriteProbeGate()
        let owner = makeProbeModel(
            service: DirectoryDiagnosticsService(beforeProbeWrite: { try barrier.pauseIfArmed($0) }),
            gate: gate
        )
        let store = makeAuthorizationStore()
        let authorization = try store.authorize(temporaryDirectory)
        let otherWindow = makeDiagnosticsModel(store: store)
        let entered = expectation(description: "write probe blocks independently of authorization work")
        barrier.arm(entered)
        defer { barrier.release.signal() }
        let inspection = try XCTUnwrap(owner.startDirectoryInspection(temporaryDirectory))
        await fulfillment(of: [entered], timeout: 2)

        await otherWindow.refreshRuntimeStatus()
        XCTAssertEqual(otherWindow.authorizedDirectories.map(\.id), [authorization.id])
        await otherWindow.revokeAuthorization(authorization.id)
        XCTAssertTrue(otherWindow.authorizedDirectories.isEmpty)
        XCTAssertTrue(gate.isRunning)
        XCTAssertFalse(inventoryReadGate.isReading)
        barrier.release.signal()
        await inspection.value
        XCTAssertEqual(owner.report?.writeProbeSucceeded, true)
        XCTAssertFalse(gate.isRunning)
    }

    private func makeProbeModel(
        service: DirectoryDiagnosticsService,
        gate: DiagnosticsWriteProbeGate? = nil
    ) -> DiagnosticsViewModel {
        DiagnosticsViewModel(
            extensionEnabledProvider: { false },
            diagnosticsService: service,
            extensionActivityStore: FinderExtensionActivityStore(
                defaults: defaults,
                failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
            ),
            authorizedDirectoryStore: makeAuthorizationStore(),
            inventoryReadGate: inventoryReadGate,
            writeProbeGate: gate
        )
    }

    func testHistoryReadFailurePreservesVisibleRecordsAndCanRecover() async throws {
        let historyURL = temporaryDirectory.appendingPathComponent("failures.json")
        let store = FinderExtensionActivityStore(defaults: defaults, failureHistoryFileURL: historyURL)
        let failure = FinderExtensionActivityFailure(reason: .writeFailed, errorDomain: nil, errorCode: nil)
        try store.record(.fileCreationFailed, failure: failure)
        let model = DiagnosticsViewModel(
            extensionEnabledProvider: { true },
            runtimeProvider: { enabled in
                FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
                    registration: .registered, registrationEvidence: "test fixture",
                    enabled: enabled, responded: true
                )
            },
            extensionActivityStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(),
            inventoryReadGate: inventoryReadGate
        )
        await model.refreshRuntimeStatus()
        let previousFailures = model.recentExtensionFailures
        XCTAssertEqual(previousFailures.count, 1)
        try Data("corrupt-history".utf8).write(to: historyURL)

        await model.refreshRuntimeStatus()
        XCTAssertEqual(model.recentExtensionFailures, previousFailures)
        XCTAssertTrue(model.activityStoreHasError)

        await model.clearFailureHistory()
        await model.refreshRuntimeStatus()
        XCTAssertFalse(model.activityStoreHasError)
        XCTAssertTrue(model.recentExtensionFailures.isEmpty)
        XCTAssertFalse(model.isRefreshingRuntimeStatus)
    }

    func testInitiallyCorruptHistoryCanBeClearedAndRecordsNewFailures() async throws {
        let historyURL = temporaryDirectory.appendingPathComponent("failures.json")
        try Data("corrupt-at-startup".utf8).write(to: historyURL)
        let store = FinderExtensionActivityStore(defaults: defaults, failureHistoryFileURL: historyURL)
        try store.record(.menuPrepared)
        let model = DiagnosticsViewModel(
            extensionEnabledProvider: { true },
            runtimeProvider: { enabled in
                FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
                    registration: .registered, registrationEvidence: "test fixture",
                    enabled: enabled, responded: true
                )
            },
            extensionActivityStore: store,
            authorizedDirectoryStore: makeAuthorizationStore(),
            inventoryReadGate: inventoryReadGate
        )

        await model.refreshRuntimeStatus()
        XCTAssertTrue(model.activityStoreHasError)
        XCTAssertTrue(model.recentExtensionFailures.isEmpty)
        XCTAssertEqual(model.extensionActivity?.kind, .menuPrepared)
        try store.record(.fileCreated)
        await model.refreshRuntimeStatus()
        XCTAssertEqual(model.extensionActivity?.kind, .fileCreated)
        await model.clearFailureHistory()
        XCTAssertFalse(model.activityStoreHasError)
        let failure = FinderExtensionActivityFailure(reason: .writeFailed, errorDomain: nil, errorCode: nil)
        try store.record(.fileCreationFailed, failure: failure)
        await model.refreshRuntimeStatus()
        XCTAssertEqual(model.recentExtensionFailures.count, 1)
        XCTAssertEqual(model.recentExtensionFailures.first?.failure, failure)
    }

    func testConsoleOpenResultIsPresentedAsState() {
        let viewModel = DiagnosticsViewModel(
            extensionEnabledProvider: { false },
            extensionActivityStore: FinderExtensionActivityStore(
                defaults: defaults,
                failureHistoryFileURL: temporaryDirectory.appendingPathComponent("failures.json")
            ),
            authorizedDirectoryStore: makeAuthorizationStore(),
            inventoryReadGate: inventoryReadGate
        )

        viewModel.openConsole(using: { false })
        XCTAssertTrue(viewModel.activityStoreHasError)

        viewModel.openConsole(using: { true })
        XCTAssertFalse(viewModel.activityStoreHasError)
        XCTAssertEqual(
            viewModel.activityStoreMessage,
            "Console 已打开，请筛选子系统 com.haoyoung.QuickFile。"
        )
    }

    private func makeAuthorizationStore() -> AuthorizedDirectoryStore {
        AuthorizedDirectoryStore(
            defaults: defaults,
            storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { Self.bookmarkData(for: $0) },
            transferBookmarkCreator: { Self.bookmarkData(for: $0) },
            persistentBookmarkResolver: { try Self.resolveBookmark($0) },
            transferBookmarkResolver: { try Self.resolveBookmark($0) },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
    }

    nonisolated private static func bookmarkData(for url: URL) -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    nonisolated private static func resolveBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
        let path = try XCTUnwrap(String(data: data, encoding: .utf8))
        return ResolvedSecurityScopedBookmark(
            url: URL(fileURLWithPath: path, isDirectory: true),
            isStale: false
        )
    }
}

private final class InventoryResolutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered: XCTestExpectation?
    private var resolutions = 0

    var resolutionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resolutions
    }
    let release = DispatchSemaphore(value: 0)

    func arm(_ expectation: XCTestExpectation) {
        lock.lock()
        entered = expectation
        lock.unlock()
    }

    func pauseIfArmed() {
        lock.lock()
        resolutions += 1
        let expectation = entered
        entered = nil
        lock.unlock()
        guard let expectation else { return }
        expectation.fulfill()
        _ = release.wait(timeout: .now() + 10)
    }
}

// All mutable fixture state is lock-protected; the semaphore is thread-safe.
// The finite wait fails the probe instead of leaving a failed test stuck in I/O.
private final class DirectoryProbeStageBarrier: @unchecked Sendable {
    private enum Failure: Error { case timedOut }
    private let lock = NSLock()
    private var entered: XCTestExpectation?
    private var calls = 0
    private var probeURL: URL?
    let release = DispatchSemaphore(value: 0)

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var lastProbeURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return probeURL
    }

    func arm(_ expectation: XCTestExpectation) {
        lock.lock()
        entered = expectation
        lock.unlock()
    }

    func pauseIfArmed(_ url: URL) throws {
        lock.lock()
        calls += 1
        probeURL = url
        let expectation = entered
        entered = nil
        lock.unlock()
        guard let expectation else { return }
        expectation.fulfill()
        guard release.wait(timeout: .now() + 10) == .success else { throw Failure.timedOut }
    }
}
