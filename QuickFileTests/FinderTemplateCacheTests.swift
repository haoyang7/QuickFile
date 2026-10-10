import XCTest
import CoreFoundation
@testable import QuickFileCore
@testable import QuickFileApplication
@testable import QuickFileInfrastructure

final class FinderTemplateCacheTests: XCTestCase {
    private var suiteName: String!
    private var defaults: PausedTemplateDefaults!
    private var directoryURL: URL!
    private var storageURL: URL { directoryURL.appendingPathComponent("templates.json") }
    private var notificationName: String { "QuickFileTests.templates.\(suiteName!)" }

    override func setUpWithError() throws {
        suiteName = "QuickFileTests.MenuCache.\(UUID())"
        defaults = try XCTUnwrap(PausedTemplateDefaults(suiteName: suiteName))
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickFileCache-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.releaseRead.signal()
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.removeItem(at: directoryURL)
        defaults = nil
    }

    func testColdMenuDoesNotAdvertiseBuiltInsWhileConfigurationIsLoading() throws {
        let store = makeStore()
        try store.saveTemplates([])
        defaults.pauseNextRevisionRead()
        let cache = makeCache(store)
        XCTAssertTrue(waitForSemaphore(defaults.readStarted))

        XCTAssertEqual(cache.currentSnapshot(), .loading(previous: []))
        XCTAssertTrue(cache.currentEntries().isEmpty)
    }

    func testColdTemplatesCanBecomeReadyWithoutASecondMenuRequest() throws {
        let template = FileTemplate(name: "Own template", fileExtension: "txt", content: "own content")
        let store = makeStore()
        try store.saveTemplates([template])
        defaults.pauseNextRevisionRead()
        let cache = makeCache(store)
        XCTAssertTrue(waitForSemaphore(defaults.readStarted))
        XCTAssertEqual(cache.currentSnapshot(), .loading(previous: []))
        let release = defaults.releaseRead
        DispatchQueue.global().async { release.signal() }
        XCTAssertEqual(cache.menuSnapshot(waitingUntil: .now() + 2), .ready(entries([template])))
    }

    func testExpiredDeadlineKeepsLoadingInsteadOfAdvertisingPreviousTemplates() throws {
        let previous = FileTemplate(name: "Previous", fileExtension: "txt", content: "old")
        let store = makeStore()
        try store.saveTemplates([])
        defaults.pauseNextRevisionRead()
        let cache = makeCache(store, initialTemplates: [previous])
        XCTAssertTrue(waitForSemaphore(defaults.readStarted))
        for _ in 0..<10 {
            XCTAssertEqual(cache.menuSnapshot(waitingUntil: .now()), .loading(previous: entries([previous])))
        }
        defaults.releaseRead.signal()
        XCTAssertEqual(waitForReadyEntries(cache, expected: entries([])), entries([]))
    }

    func testMenuReadinessWaitPreservesTemplateReadFailure() throws {
        let store = makeStore()
        try store.saveTemplates([])
        try Data("invalid".utf8).write(to: storageURL)
        let cache = makeCache(store)
        XCTAssertEqual(cache.menuSnapshot(waitingUntil: .now() + 2), .refreshFailed(previous: []))
    }

    func testUnreadableConfigurationBlocksFinderCreationAndAuthorizationUntilRecovery() throws {
        let original = FileTemplate(name: "Text", fileExtension: "txt", content: "original")
        let store = makeStore()
        try store.saveTemplates([original])
        let cache = makeCache(store, initialTemplates: [original])
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { try cache.templateForCreation(id: $0) },
            performWithAccess: { _, operation in try operation() },
            createFile: { try FileCreationService().createFile(for: $0) },
            requiresAuthorization: { _ in
                XCTFail("Template loading failures must not trigger directory authorization")
                return true
            }
        )
        let authorization = FinderAuthorizationCoordinator(
            loadTemplates: { try store.reloadTemplates() },
            authorizeDirectory: { _ in XCTFail("Must not persist authorization after a template read failure"); return UUID() },
            performWithAccess: { _, _, operation in try operation() },
            createFile: { try FileCreationService().createFile(for: $0) }
        )
        try Data("invalid".utf8).write(to: storageURL, options: .atomic)
        let action = FinderMenuAction(templateID: original.id, context: .container, destinationFolder: directoryURL,
                                    destinationIdentity: try DirectoryIdentity.capture(at: directoryURL))

        XCTAssertThrowsError(try coordinator.createFile(for: action))
        XCTAssertThrowsError(try authorization.complete(
            FinderAuthorizationRequest(templateID: original.id, destinationFolder: directoryURL),
            authorizedDirectory: directoryURL
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).sorted(),
            ["templates.json", "templates.json.lock"]
        )
        var recovered = original
        recovered.content = "recovered"
        try JSONEncoder().encode([recovered]).write(to: storageURL, options: .atomic)
        let result = try coordinator.createFile(for: action)
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "recovered")
    }

    func testCreationRejectsDisabledTemplateAndReadsEditedContentDespiteStaleMenu() throws {
        let original = FileTemplate(name: "Text", fileExtension: "txt", content: "old")
        let store = makeStore()
        try store.saveTemplates([original])
        defaults.pauseNextRevisionRead()
        let cache = makeCache(store, initialTemplates: [original])
        XCTAssertTrue(waitForSemaphore(defaults.readStarted))
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { try cache.templateForCreation(id: $0) },
            performWithAccess: { _, operation in try operation() },
            createFile: { try FileCreationService().createFile(for: $0) },
            requiresAuthorization: { _ in false }
        )
        let action = FinderMenuAction(templateID: original.id, context: .container, destinationFolder: directoryURL,
                                    destinationIdentity: try DirectoryIdentity.capture(at: directoryURL))
        var edited = original
        edited.isEnabled = false
        // Simulate the JSON arriving before UserDefaults propagates its new revision.
        try JSONEncoder().encode([edited]).write(to: storageURL, options: .atomic)
        XCTAssertEqual(cache.currentEntries(), entries([original]))
        XCTAssertThrowsError(try coordinator.createFile(for: action)) { error in
            XCTAssertEqual(error as? FinderFileCreationError, .templateUnavailable)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).sorted(),
            ["templates.json", "templates.json.lock"]
        )

        edited.isEnabled = true
        edited.content = "updated"
        try JSONEncoder().encode([edited]).write(to: storageURL, options: .atomic)
        let result = try coordinator.createFile(for: action)
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "updated")
    }

    func testSaveNotificationRefreshesSnapshotWithoutMenuRead() throws {
        let store = makeStore()
        try store.saveTemplates([])
        let cache = makeCache(store)
        XCTAssertEqual(waitForSnapshot(cache) { snapshot in
            if case .ready([]) = snapshot { return true }
            return false
        }, .ready([]))

        let first = FileTemplate(name: "B", fileExtension: "b", content: "first")
        let second = FileTemplate(name: "A", fileExtension: "a", content: "second")
        try store.saveTemplates([first, second])
        XCTAssertEqual(waitForReadyEntries(cache, expected: entries([first, second])), entries([first, second]))

        var disabled = second
        disabled.isEnabled = false
        try store.saveTemplates([disabled])
        XCTAssertEqual(waitForReadyEntries(cache, expected: entries([disabled])), entries([disabled]))
    }

    func testNotificationDuringRefreshCannotLoseNewestSnapshot() throws {
        let store = makeStore()
        let initial = FileTemplate(name: "Initial", fileExtension: "txt", content: "initial")
        try store.saveTemplates([initial])
        let cache = makeCache(store)
        XCTAssertEqual(waitForReadyEntries(cache, expected: entries([initial])), entries([initial]))

        defaults.pauseNextRevisionRead()
        let intermediate = FileTemplate(name: "Intermediate", fileExtension: "txt", content: "one")
        try store.saveTemplates([intermediate])
        XCTAssertTrue(waitForSemaphore(defaults.readStarted))
        let newest = FileTemplate(name: "Newest", fileExtension: "md", content: "two")
        try store.saveTemplates([newest])
        defaults.releaseRead.signal()

        XCTAssertEqual(waitForReadyEntries(cache, expected: entries([newest])), entries([newest]))
    }

    func testNotificationInvalidatesOlderCreationReadBeforeBackgroundRefreshFinishes() {
        let old = FileTemplate(name: "Old", fileExtension: "txt", content: "old")
        var updated = old
        updated.name = "New"
        let new = updated
        let reads = LockedTestValue(0)
        let backgroundStarted = DispatchSemaphore(value: 0)
        let creationStarted = DispatchSemaphore(value: 0)
        let releaseBackground = DispatchSemaphore(value: 0)
        let releaseCreation = DispatchSemaphore(value: 0)
        defer { releaseBackground.signal(); releaseCreation.signal() }
        let load: @Sendable () -> [FileTemplate] = {
            let read = reads.update { value in defer { value += 1 }; return value }
            switch read {
            case 0: return [old]
            case 1:
                backgroundStarted.signal()
                XCTAssertEqual(releaseBackground.wait(timeout: .now() + 5), .success)
                return [old]
            case 2:
                creationStarted.signal()
                XCTAssertEqual(releaseCreation.wait(timeout: .now() + 5), .success)
                return [old]
            default: return [new]
            }
        }
        let cache = FinderTemplateCache(
            loadForCreation: { id in Self.creationSnapshot(load(), id: id) },
            loadMenuEntries: { FinderMenuModelBuilder().entries(from: load()) },
            changeNotificationName: notificationName, refreshInterval: 0
        )
        XCTAssertEqual(cache.menuSnapshot(waitingUntil: .now() + 2), .ready(entries([old])))
        _ = cache.currentSnapshot()
        XCTAssertTrue(waitForSemaphore(backgroundStarted))
        let creationFinished = expectation(description: "old creation read returned")
        DispatchQueue.global().async {
            defer { creationFinished.fulfill() }
            do {
                let template = try cache.templateForCreation(id: old.id)
                XCTAssertEqual(template, old)
            } catch { XCTFail("Unexpected creation read failure: \(error)") }
        }
        XCTAssertTrue(waitForSemaphore(creationStarted))
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString), nil, nil, true)
        let loading = FinderTemplateCache.Snapshot.loading(previous: entries([old]))
        XCTAssertEqual(waitForSnapshot(cache) { $0 == loading }, loading)
        releaseCreation.signal()
        wait(for: [creationFinished], timeout: 2)
        XCTAssertEqual(cache.currentSnapshot(), loading,
                       "A pre-notification creation read must not make the old menu ready again")
        releaseBackground.signal()
        XCTAssertEqual(waitForReadyEntries(cache, expected: entries([new])), entries([new]))
    }

    func testFailedSnapshotRetriesAfterConfigurationIsRepairedWithoutSaveNotification() throws {
        let store = makeStore()
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        try store.saveTemplates([original])
        try Data("invalid".utf8).write(to: storageURL, options: .atomic)
        let cache = makeCache(store, initialTemplates: [original])

        let failedSnapshot = waitForSnapshot(cache) { snapshot in
            snapshot == .refreshFailed(previous: entries([original]))
        }
        XCTAssertEqual(failedSnapshot, .refreshFailed(previous: entries([original])))

        var repaired = original
        repaired.content = "repaired"
        repaired.name = "Repaired"
        try JSONEncoder().encode([repaired]).write(to: storageURL, options: .atomic)
        switch cache.currentSnapshot() {
        case let .refreshFailed(previous), let .loading(previous):
            XCTAssertEqual(previous, entries([original]))
        case let .ready(templates):
            XCTAssertEqual(templates, entries([repaired]))
        }
        XCTAssertEqual(waitForReadyEntries(cache, expected: entries([repaired])), entries([repaired]))
    }

    func testReadySnapshotRecoversFromMissedNotificationWithoutBlockingMenu() throws {
        let store = makeStore()
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        try store.saveTemplates([original])
        let cache = makeCache(store, refreshInterval: 0.05)
        XCTAssertEqual(waitForReadyEntries(cache, expected: entries([original])), entries([original]))
        var updated = original
        updated.content = "new without notification"
        updated.name = "Updated without notification"
        try JSONEncoder().encode([updated]).write(to: storageURL, options: .atomic)
        defaults.pauseNextRevisionRead()
        XCTAssertTrue(waitForSemaphoreAfterPolling(cache, semaphore: defaults.readStarted))
        // The compensation read is paused; menu reads still return the previous ready snapshot.
        for _ in 0..<100 {
            XCTAssertEqual(cache.currentSnapshot(), .ready(entries([original])))
        }
        defaults.releaseRead.signal()
        XCTAssertEqual(waitForReadyEntries(cache, expected: entries([updated])), entries([updated]))
    }

    func testCreationReloadPublishesSnapshotWhileOlderBackgroundRefreshIsPaused() throws {
        let store = makeStore()
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        try store.saveTemplates([original])
        defaults.pauseNextRevisionRead()
        let cache = makeCache(store, initialTemplates: [original])
        XCTAssertTrue(waitForSemaphore(defaults.readStarted))
        var updated = original
        updated.content = "new"
        updated.name = "Updated"
        try JSONEncoder().encode([updated]).write(to: storageURL, options: .atomic)
        XCTAssertEqual(try cache.templateForCreation(id: original.id), updated)
        XCTAssertEqual(cache.currentSnapshot(), .ready(entries([updated])))
        // Make the older read fail after the authoritative execution read succeeded.
        try Data("invalid".utf8).write(to: storageURL, options: .atomic)
        defaults.releaseRead.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(cache.currentSnapshot(), .ready(entries([updated])))
    }

    func testOperationScopedReadsKeepMenuMetadataWhileCreationUsesCurrentBodyAndEnabledState() throws {
        let original = FileTemplate(name: "Text", fileExtension: "txt", content: "old")
        try makeStore().saveTemplates([original])
        let readDefaults = defaults!
        let readURL = storageURL
        let name = notificationName
        let reader = TemplateStore(defaults: readDefaults, storageURL: readURL, cachesReads: false,
                                   cachesMenuReads: true, changeNotificationName: name)
        let cache = FinderTemplateCache(
            loadForCreation: { try reader.reloadCreationSnapshot(templateID: $0) },
            loadMenuEntries: { try reader.reloadMenuEntries() }, changeNotificationName: name
        )
        let metadata = entries([original])
        XCTAssertEqual(waitForReadyEntries(cache, expected: metadata), metadata)

        var changed = original
        changed.content = String(repeating: "new body ", count: 2048)
        try JSONEncoder().encode([changed]).write(to: storageURL, options: .atomic)
        XCTAssertEqual(try cache.templateForCreation(id: original.id), changed)
        XCTAssertEqual(cache.currentEntries(), metadata)

        changed.isEnabled = false
        try JSONEncoder().encode([changed]).write(to: storageURL, options: .atomic)
        XCTAssertNil(try cache.templateForCreation(id: original.id))
        XCTAssertEqual(cache.currentSnapshot(), .ready([]))

        try JSONEncoder().encode([FileTemplate]()).write(to: storageURL, options: .atomic)
        XCTAssertNil(try cache.templateForCreation(id: original.id))
        XCTAssertEqual(cache.currentSnapshot(), .ready([]))

        try Data("invalid".utf8).write(to: storageURL, options: .atomic)
        XCTAssertThrowsError(try cache.templateForCreation(id: original.id))
        XCTAssertEqual(cache.currentSnapshot(), .refreshFailed(previous: []))
    }

    func testMetadataRefreshUsesItsLoaderAndCreationStillLoadsCurrentBodies() throws {
        let old = FileTemplate(name: "Old", fileExtension: "txt", content: "old")
        var latest = old
        latest.name = "Current"
        latest.content = "new body"
        let current = latest
        let other = FileTemplate(name: "Other", fileExtension: "md", content: "other body")
        let cache = FinderTemplateCache(
            loadForCreation: { id in Self.creationSnapshot([current, other], id: id) },
            loadMenuEntries: { [FinderTemplateMenuEntry(template: old)] },
            changeNotificationName: notificationName
        )
        XCTAssertEqual(waitForReadyEntries(cache, expected: entries([old])), entries([old]))
        XCTAssertEqual(try cache.templateForCreation(id: current.id), current)
        XCTAssertEqual(cache.currentSnapshot(), .ready(entries([current, other])))
    }

    func testProjectedMenuRefreshReportsCorruptionAndRecovers() throws {
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "body")
        let store = makeStore()
        let menuStore = TemplateStore(defaults: defaults, storageURL: storageURL,
                                      cachesReads: false, cachesMenuReads: true,
                                      changeNotificationName: notificationName)
        try store.saveTemplates([template])
        let cache = FinderTemplateCache(
            loadForCreation: { try menuStore.reloadCreationSnapshot(templateID: $0) },
            loadMenuEntries: { try menuStore.reloadMenuEntries() },
            changeNotificationName: notificationName
        )
        XCTAssertEqual(waitForReadyEntries(cache, expected: entries([template])), entries([template]))
        try Data("invalid".utf8).write(to: storageURL, options: .atomic)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString), nil, nil, true
        )
        XCTAssertEqual(waitForSnapshot(cache) {
            if case .refreshFailed = $0 { return true }
            return false
        }, .refreshFailed(previous: entries([template])))
        XCTAssertThrowsError(try cache.templateForCreation(id: template.id))
        try JSONEncoder().encode([FileTemplate]()).write(to: storageURL, options: .atomic)
        XCTAssertEqual(waitForReadyEntries(cache, expected: []), [])
        XCTAssertNil(try cache.templateForCreation(id: template.id))
    }

    func testDarwinCallbackOwnsHandlerDuringConcurrentObserverDestruction() {
        let entered = expectation(description: "Darwin callback entered")
        let finished = expectation(description: "handler survived observer destruction")
        let release = DispatchSemaphore(value: 0)
        let name = "QuickFileTests.observer.\(UUID())"
        let holder = ObserverHolder(DarwinTemplateNotificationObserver(name: name) {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            finished.fulfill()
        })
        weak var observer = holder.observer
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true
        )
        wait(for: [entered], timeout: 5)
        let destroyed = expectation(description: "observer destroyed on another thread")
        DispatchQueue.global().async {
            holder.observer = nil
            destroyed.fulfill()
        }
        wait(for: [destroyed], timeout: 5)
        XCTAssertNil(observer)
        release.signal()
        wait(for: [finished], timeout: 5)
    }

    private func waitForSemaphoreAfterPolling(
        _ cache: FinderTemplateCache,
        semaphore: DispatchSemaphore
    ) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            _ = cache.currentSnapshot()
            if semaphore.wait(timeout: .now()) == .success { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return false
    }

    private func entries(_ templates: [FileTemplate]) -> [FinderTemplateMenuEntry] {
        FinderMenuModelBuilder().entries(from: templates)
    }

    private static func creationSnapshot(_ templates: [FileTemplate], id: UUID) -> TemplateStore.CreationSnapshot {
        TemplateStore.CreationSnapshot(template: templates.first { $0.id == id && $0.isEnabled },
                                       menuEntries: FinderMenuModelBuilder().entries(from: templates))
    }

    private func makeCache(
        _ store: TemplateStore,
        initialTemplates: [FileTemplate] = [],
        refreshInterval: TimeInterval = 5
    ) -> FinderTemplateCache {
        FinderTemplateCache(
            loadForCreation: { try store.reloadCreationSnapshot(templateID: $0) },
            // These tests pause the revision read to control refresh ordering.
            loadMenuEntries: { FinderMenuModelBuilder().entries(from: try store.reloadTemplates()) },
            changeNotificationName: store.changeNotificationName,
            initialTemplates: initialTemplates,
            refreshInterval: refreshInterval
        )
    }

    private func makeStore() -> TemplateStore {
        TemplateStore(
            defaults: defaults,
            storageURL: storageURL,
            changeNotificationName: notificationName
        )
    }

    private func waitForReadyEntries(
        _ cache: FinderTemplateCache,
        expected: [FinderTemplateMenuEntry],
        timeout: TimeInterval = 5
    ) -> [FinderTemplateMenuEntry] {
        waitForSnapshot(cache, timeout: timeout) { snapshot in
            snapshot == .ready(expected)
        }.entries
    }

    private func waitForSnapshot(
        _ cache: FinderTemplateCache,
        timeout: TimeInterval = 5,
        predicate: (FinderTemplateCache.Snapshot) -> Bool
    ) -> FinderTemplateCache.Snapshot {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let snapshot = cache.currentSnapshot()
            if predicate(snapshot) { return snapshot }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return cache.currentSnapshot()
    }

    private func waitForSemaphore(
        _ semaphore: DispatchSemaphore,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if semaphore.wait(timeout: .now()) == .success { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return semaphore.wait(timeout: .now()) == .success
    }
}

private final class PausedTemplateDefaults: UserDefaults, @unchecked Sendable {
    let readStarted = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldPauseNextRead = false

    func pauseNextRevisionRead() {
        lock.lock()
        shouldPauseNextRead = true
        lock.unlock()
    }

    override func string(forKey defaultName: String) -> String? {
        lock.lock()
        let shouldPause = defaultName == "templates.revision.v2" && shouldPauseNextRead
        if shouldPause { shouldPauseNextRead = false }
        lock.unlock()
        if shouldPause {
            readStarted.signal()
            _ = releaseRead.wait(timeout: .now() + 10)
        }
        return super.string(forKey: defaultName)
    }
}

// Access is ordered by the test's expectations; only the background releaser mutates it.
private final class ObserverHolder: @unchecked Sendable {
    var observer: DarwinTemplateNotificationObserver?
    init(_ observer: DarwinTemplateNotificationObserver) { self.observer = observer }
}
