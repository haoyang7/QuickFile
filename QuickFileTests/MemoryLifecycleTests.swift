import Combine
import Foundation
import XCTest
@testable import QuickFile
@testable import QuickFileCore
@testable import QuickFileInfrastructure

/// Product-owned object lifetimes only. These tests do not instantiate SwiftUI/AppKit views,
/// inspect accessibility, sample allocations, or reproduce the installed application's leaks.
@MainActor
final class MemoryLifecycleTests: XCTestCase {
    private var suiteName: String!
    private var defaults: LifecyclePausedDefaults!
    private var directory: URL!

    override func setUpWithError() throws {
        suiteName = "QuickFileTests.MemoryLifecycle.\(UUID().uuidString)"
        defaults = try XCTUnwrap(LifecyclePausedDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickFileMemoryLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // This releases a paused read even if an assertion or unwrap failed.
        defaults?.releaseRead.signal()
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        if let directory { try FileManager.default.removeItem(at: directory) }
        defaults = nil
        directory = nil
        suiteName = nil
    }

    func testCreationWorkloadRestoresEightTemplatesAndReleasesModelAndStore() async throws {
        // Synthetic templates and outputs are confined to this test's own temporary directory.
        // Keep the 8 -> 300 -> three groups of 20 -> 8 lifecycle shape, not private user data.
        let small = makeTemplates(count: 8)
        let large = makeTemplates(count: 300)
        var store: TemplateStore? = makeTemplateStore()
        weak var weakStore = store
        XCTAssertNotNil(weakStore)
        try store!.saveTemplates(small)
        var model: QuickFileViewModel? = QuickFileViewModel(
            templateStore: store!, authorizedDirectoryStore: makeAuthorizationStore(),
            clipboardProvider: { XCTFail("Empty templates must not read the clipboard"); return nil }
        )
        weak var weakModel = model
        XCTAssertNotNil(weakModel)
        var changeCount = 0
        var observation: AnyCancellable? = model!.objectWillChange.sink { changeCount += 1 }
        await model!.loadTemplatesIfNeeded()
        model!.destinationFolder = directory
        XCTAssertEqual(model!.templates, small)

        try store!.saveTemplates(large)
        await model!.reloadTemplates()
        XCTAssertEqual(model!.templates, large)
        for group in 0..<3 {
            for iteration in 0..<20 {
                let template = large[(group * 20 + iteration) % large.count]
                model!.selectedTemplateID = template.id
                model!.requestedFilename = "group-\(group)-file-\(iteration)"
                await model!.createFile()
                let output = try XCTUnwrap(model!.createdFileURL)
                XCTAssertEqual(try Data(contentsOf: output), Data())
                XCTAssertFalse(model!.isBusy)
                XCTAssertFalse(model!.isLoadingTemplates)
                XCTAssertFalse(model!.isSavingTemplates)
            }
            XCTAssertEqual(model!.templates, large)
        }

        try store!.saveTemplates(small)
        await model!.reloadTemplates()
        XCTAssertEqual(model!.templates, small)
        XCTAssertEqual(try store!.loadTemplates(), small)
        XCTAssertEqual(model!.selectedTemplateID, small[0].id)
        XCTAssertGreaterThan(changeCount, 0)
        let outputs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("group-") }
        XCTAssertEqual(outputs.count, 60)

        observation?.cancel()
        observation = nil
        model = nil
        store = nil
        await waitForRelease { weakModel == nil && weakStore == nil }
        XCTAssertNil(weakModel, "A settled model must not retain itself through its dependencies")
        XCTAssertNil(weakStore, "The model's store must be released after settled work and owners end")
    }

    func testCancelledReloadReleasesModelAfterUnderlyingReadReturns() async throws {
        let store = makeTemplateStore()
        try store.saveTemplates(makeTemplates(count: 8))
        var model: QuickFileViewModel? = QuickFileViewModel(
            templateStore: store, templates: [], authorizedDirectoryStore: makeAuthorizationStore()
        )
        weak var weakModel = model
        XCTAssertNotNil(weakModel)
        defaults.pauseNextRevisionRead()
        var task: Task<Void, Never>? = Task { [model] in
            _ = await model?.reloadTemplates()
        }
        let pausedDefaults = defaults!
        let entered = await BackgroundWork.run {
            pausedDefaults.readStarted.wait(timeout: .now() + 5) == .success
        }
        XCTAssertTrue(entered)
        if !entered {
            defaults.releaseRead.signal()
            await task?.value
            return
        }
        model = nil
        task?.cancel()
        // BackgroundWork is continuation-based and does not cancel a synchronous storage read.
        // This is pending-work retention, not proof of a leak or of cancellation support.
        XCTAssertNotNil(weakModel)
        defaults.releaseRead.signal()
        await task?.value
        task = nil
        await waitForRelease { weakModel == nil }
        XCTAssertNil(weakModel, "After the paused read returns, cancelled work must release its model")
    }

    func testDiagnosticsRevocationSubscriberDoesNotKeepSettledModelsAlive() async throws {
        let activityStore = FinderExtensionActivityStore(
            defaults: defaults, failureHistoryFileURL: directory.appendingPathComponent("failures.json")
        )
        let authorizationStore = makeAuthorizationStore()
        for _ in 0..<60 {
            var model: DiagnosticsViewModel? = DiagnosticsViewModel(
                extensionEnabledProvider: { false },
                runtimeProvider: { enabled in Self.snapshot(enabled: enabled) },
                extensionActivityStore: activityStore,
                authorizedDirectoryStore: authorizationStore,
                inventoryReadGate: DiagnosticsInventoryReadGate()
            )
            weak var weakModel = model
            XCTAssertNotNil(weakModel)
            await model!.refreshRuntimeStatus()
            XCTAssertFalse(model!.isRefreshingRuntimeStatus)
            XCTAssertFalse(model!.isManagingAuthorizations)
            model = nil
            await waitForRelease { weakModel == nil }
            XCTAssertNil(weakModel, "The static revocation subject must not own a closed model")
            guard weakModel == nil else { return }
        }
    }

    func testFinderIntegrationReleasesModelsAfterRepeatedCompletedRefreshes() async {
        for _ in 0..<60 {
            var model: FinderIntegrationViewModel? = FinderIntegrationViewModel(
                statusProvider: { false },
                runtimeProvider: { enabled in Self.snapshot(enabled: enabled) },
                managementOpener: { XCTFail("A refresh must not open system settings") }
            )
            weak var weakModel = model
            XCTAssertNotNil(weakModel)
            await model!.refresh()
            XCTAssertFalse(model!.isRefreshing)
            model = nil
            await waitForRelease { weakModel == nil }
            XCTAssertNil(weakModel)
            guard weakModel == nil else { return }
        }
    }

    func testTemplateCacheCanDeinitializeWhileItsReadIsBlocked() async throws {
        var store: TemplateStore? = makeTemplateStore()
        weak var weakStore = store
        XCTAssertNotNil(weakStore)
        try store!.saveTemplates(makeTemplates(count: 8))
        defaults.pauseNextRevisionRead()
        var cache: FinderTemplateCache? = FinderTemplateCache(
            loadForCreation: { [store = store!] in try store.reloadCreationSnapshot(templateID: $0) },
            loadMenuEntries: { [store = store!] in
                FinderMenuModelBuilder().entries(from: try store.reloadTemplates())
            },
            changeNotificationName: store!.changeNotificationName
        )
        weak var weakCache = cache
        XCTAssertNotNil(weakCache)
        let entered = defaults.readStarted.wait(timeout: .now() + 5) == .success
        XCTAssertTrue(entered)
        cache = nil
        XCTAssertNil(weakCache, "The refresh block and Darwin handler must not own the cache")
        defaults.releaseRead.signal()
        store = nil
        // Wait for the queue closure to release its store, not merely the overridden defaults read.
        // Teardown must not delete fixture files while the remaining JSON read is still running.
        await waitForRelease { weakStore == nil }
        XCTAssertNil(weakStore)
    }

    func testSchedulerCanDeinitializeWhileAcceptedOperationsAreBlocked() {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let started = expectation(description: "both independent workers started")
        started.expectedFulfillmentCount = 2
        let finished = expectation(description: "both workers returned")
        finished.expectedFulfillmentCount = 2
        var scheduler: FinderOperationScheduler? = FinderOperationScheduler()
        weak var weakScheduler = scheduler
        XCTAssertNotNil(weakScheduler)
        let operation: @Sendable () -> Void = {
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            finished.fulfill()
        }
        let action = FinderMenuAction(
            templateID: UUID(), context: .container, destinationFolder: directory
        )
        XCTAssertEqual(scheduler!.submitCreation(action, operation: operation), .accepted)
        XCTAssertTrue(scheduler!.submitAuthorization(operation: operation))
        wait(for: [started], timeout: 5)
        scheduler = nil
        XCTAssertNil(weakScheduler, "Accepted workers must not retain their scheduler")
        release.signal(); release.signal()
        wait(for: [finished], timeout: 5)
    }

    private func waitForRelease(_ released: () -> Bool) async {
        // Allow already-resumed continuations and dispatch blocks to finish disposing captures.
        // A deadline failure is an ownership regression signal, never a leaks/RSS measurement.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !released(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeTemplateStore() -> TemplateStore {
        TemplateStore(
            defaults: defaults, storageURL: directory.appendingPathComponent("templates.json"),
            changeNotificationName: "QuickFileTests.MemoryLifecycle.templates.\(suiteName!)"
        )
    }

    private func makeTemplates(count: Int) -> [FileTemplate] {
        (0..<count).map { FileTemplate(name: "Synthetic \($0)", fileExtension: "txt", content: "") }
    }

    private func makeAuthorizationStore() -> AuthorizedDirectoryStore {
        AuthorizedDirectoryStore(
            defaults: defaults,
            storageDirectory: directory.appendingPathComponent("authorizations", isDirectory: true),
            persistentBookmarkCreator: { Data($0.standardizedFileURL.path.utf8) },
            transferBookmarkCreator: { Data($0.standardizedFileURL.path.utf8) },
            persistentBookmarkResolver: { try Self.resolveSyntheticBookmark($0) },
            transferBookmarkResolver: { try Self.resolveSyntheticBookmark($0) },
            startAccessing: { _ in true }, stopAccessing: { _ in }
        )
    }

    nonisolated private static func resolveSyntheticBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
        let path = try XCTUnwrap(String(data: data, encoding: .utf8))
        return ResolvedSecurityScopedBookmark(url: URL(fileURLWithPath: path, isDirectory: true), isStale: false)
    }

    nonisolated private static func snapshot(enabled: Bool) -> FinderExtensionDiagnosticSnapshot {
        FinderExtensionDiagnosticSnapshot(
            embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
            registration: .registered, registrationEvidence: "synthetic lifecycle fixture",
            enabled: enabled, responded: nil
        )
    }
}

private final class LifecyclePausedDefaults: UserDefaults, @unchecked Sendable {
    let readStarted = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pauseNextRead = false

    func pauseNextRevisionRead() {
        lock.lock()
        pauseNextRead = true
        lock.unlock()
    }

    override func string(forKey key: String) -> String? {
        lock.lock()
        let shouldPause = key == "templates.revision.v2" && pauseNextRead
        if shouldPause { pauseNextRead = false }
        lock.unlock()
        if shouldPause {
            readStarted.signal()
            _ = releaseRead.wait(timeout: .now() + 10)
        }
        let value = super.string(forKey: key)
        return value
    }
}
