import Foundation
import XCTest
@testable import QuickFileCore
@testable import QuickFileInfrastructure

final class FinderExtensionActivityStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var temporaryDirectory: URL!
    private var failureHistoryFileURL: URL!

    override func setUpWithError() throws {
        suiteName = "QuickFileTests.FinderExtensionActivity.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        failureHistoryFileURL = temporaryDirectory
            .appendingPathComponent("failure-history.json", isDirectory: false)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        failureHistoryFileURL = nil
        temporaryDirectory = nil
        defaults = nil
        suiteName = nil
    }

    func testNoActivityIsReportedBeforeTheExtensionRecordsOne() {
        let store = makeStore()

        XCTAssertTrue(store.isAvailable)
        XCTAssertNil(store.latestActivity())
    }

    func testRecordsAndLoadsLatestActivity() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let store = makeStore()

        try store.record(.menuPrepared, at: timestamp)

        XCTAssertEqual(
            store.latestActivity(),
            FinderExtensionActivity(kind: .menuPrepared, timestamp: timestamp)
        )
    }

    func testNewActivityReplacesThePreviousRecord() throws {
        let store = makeStore()

        try store.record(.launched, at: Date(timeIntervalSince1970: 1))
        try store.record(.fileCreated, at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(
            store.latestActivity(),
            FinderExtensionActivity(kind: .fileCreated, timestamp: Date(timeIntervalSince1970: 2))
        )
    }

    func testDelayedOlderActivityCannotReplaceLatestActivity() throws {
        try makeStore().record(.fileCreated, at: Date(timeIntervalSince1970: 200))
        try makeStore().record(.launched, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(makeStore().latestActivity()?.timestamp, Date(timeIntervalSince1970: 200))
    }

    func testConcurrentStoresKeepNewestActivity() throws {
        let stores = (0..<64).map { _ in makeStore() }
        let errors = ErrorCollector()
        DispatchQueue.concurrentPerform(iterations: stores.count) { index in
            do {
                try stores[index].record(.menuPrepared, at: Date(timeIntervalSince1970: Double(index)))
            } catch { errors.append(error) }
        }
        XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")
        XCTAssertEqual(makeStore().latestActivity()?.timestamp, Date(timeIntervalSince1970: 63))
    }

    func testLatestActivityMigratesOnceAndIgnoresStaleDefaults() throws {
        let legacy = FinderExtensionActivity(kind: .fileCreated, timestamp: Date(timeIntervalSince1970: 200))
        defaults.set(try JSONEncoder().encode(legacy), forKey: "finderExtension.latestActivity.v1")
        XCTAssertEqual(makeStore().latestActivity(), legacy)
        let stale = FinderExtensionActivity(kind: .launched, timestamp: Date(timeIntervalSince1970: 300))
        defaults.set(try JSONEncoder().encode(stale), forKey: "finderExtension.latestActivity.v1")
        try makeStore().record(.menuPrepared, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(makeStore().latestActivity(), legacy)
    }

    func testCorruptLegacyLatestRecoversOnSuccessAndFailureEvents() throws {
        let failure = FinderExtensionActivityFailure(reason: .writeFailed, errorDomain: nil, errorCode: nil)
        for (index, eventFailure) in [nil, failure].enumerated() {
            let historyURL = temporaryDirectory.appendingPathComponent("legacy-recovery-\(index).json")
            let store = FinderExtensionActivityStore(defaults: defaults, failureHistoryFileURL: historyURL)
            defaults.set(Data("invalid".utf8), forKey: "finderExtension.latestActivity.v1")
            XCTAssertNil(store.latestActivity())
            let timestamp = Date(timeIntervalSince1970: 200)
            let kind: FinderExtensionActivityKind = eventFailure == nil ? .fileCreated : .fileCreationFailed

            try store.record(kind, failure: eventFailure, at: timestamp)

            XCTAssertEqual(store.latestActivity(), FinderExtensionActivity(kind: kind, timestamp: timestamp, failure: eventFailure))
            XCTAssertEqual(try store.recentFailures(referenceDate: timestamp).count, eventFailure == nil ? 0 : 1)
            XCTAssertNil(defaults.data(forKey: "finderExtension.latestActivity.v1"))
        }
    }

    func testCorruptLatestFileRecoversOnSuccessAndFailureEvents() throws {
        let failure = FinderExtensionActivityFailure(reason: .writeFailed, errorDomain: nil, errorCode: nil)
        let store = makeStore()
        for (index, eventFailure) in [nil, failure].enumerated() {
            // Exercise a malformed document and a syntactically valid, wrong-shaped state.
            let corruptData = index == 0 ? "invalid" : "{\"activity\":42}"
            try Data(corruptData.utf8).write(to: failureHistoryFileURL.appendingPathExtension("latest-v2.json"))
            XCTAssertNil(store.latestActivity())
            let timestamp = Date(timeIntervalSince1970: Double(200 + index))
            let kind: FinderExtensionActivityKind = eventFailure == nil ? .fileCreated : .fileCreationFailed

            try store.record(kind, failure: eventFailure, at: timestamp)

            XCTAssertEqual(store.latestActivity(), FinderExtensionActivity(kind: kind, timestamp: timestamp, failure: eventFailure))
            XCTAssertEqual(try store.recentFailures(referenceDate: timestamp).count, eventFailure == nil ? 0 : 1)
        }
    }

    func testLatestFileReadErrorIsNotTreatedAsCorruption() throws {
        let latestURL = failureHistoryFileURL.appendingPathExtension("latest-v2.json")
        try FileManager.default.createDirectory(at: latestURL, withIntermediateDirectories: false)
        let failure = FinderExtensionActivityFailure(reason: .writeFailed, errorDomain: nil, errorCode: nil)
        for eventFailure in [nil, failure] {
            XCTAssertThrowsError(try makeStore().record(.fileCreationFailed, failure: eventFailure)) { error in
                XCTAssertFalse(error is DecodingError)
            }
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failureHistoryFileURL.path))
    }

    func testCorruptFailureHistoryCanBeClearedWithoutLosingLatestActivity() throws {
        let timestamp = Date(timeIntervalSince1970: 200)
        try Data("invalid".utf8).write(to: failureHistoryFileURL)
        let failure = FinderExtensionActivityFailure(reason: .writeFailed, errorDomain: nil, errorCode: nil)
        XCTAssertThrowsError(try makeStore().record(.fileCreationFailed, failure: failure, at: timestamp))
        XCTAssertEqual(makeStore().latestActivity()?.timestamp, timestamp)
        XCTAssertThrowsError(try makeStore().recentFailures())
        try makeStore().clearFailureHistory()
        XCTAssertEqual(makeStore().latestActivity()?.timestamp, timestamp)
        XCTAssertTrue(try makeStore().recentFailures(referenceDate: timestamp).isEmpty)
    }

    func testPersistsSanitizedFailureMetadata() throws {
        let store = makeStore()
        let failure = FinderExtensionActivityFailure(
            reason: .permissionDenied,
            errorDomain: NSCocoaErrorDomain,
            errorCode: NSFileWriteNoPermissionError
        )

        try store.record(
            .fileCreationFailed,
            failure: failure,
            at: Date(timeIntervalSince1970: 3)
        )

        XCTAssertEqual(
            store.latestActivity(),
            FinderExtensionActivity(
                kind: .fileCreationFailed,
                timestamp: Date(timeIntervalSince1970: 3),
                failure: failure
            )
        )
    }

    func testOnlyFailuresAreAddedToRecentHistory() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let store = makeStore()
        let failure = FinderExtensionActivityFailure(
            reason: .directoryNotAuthorized,
            errorDomain: nil,
            errorCode: nil
        )

        try store.record(.menuPrepared, at: referenceDate.addingTimeInterval(-1))
        try store.record(.fileCreationFailed, failure: failure, at: referenceDate)
        try store.record(.fileCreated, at: referenceDate.addingTimeInterval(1))

        XCTAssertEqual(
            try store.recentFailures(referenceDate: referenceDate.addingTimeInterval(1)),
            [
                FinderExtensionActivity(
                    kind: .fileCreationFailed,
                    timestamp: referenceDate,
                    failure: failure
                )
            ]
        )
    }

    func testRecentFailureHistoryKeepsNewestConfiguredCount() throws {
        let store = makeStore(
            maximumFailureCount: 2
        )
        let failure = FinderExtensionActivityFailure(
            reason: .writeFailed,
            errorDomain: NSCocoaErrorDomain,
            errorCode: NSFileWriteUnknownError
        )

        for timestamp in 1...3 {
            try store.record(
                .fileCreationFailed,
                failure: failure,
                at: Date(timeIntervalSince1970: TimeInterval(timestamp))
            )
        }

        XCTAssertEqual(
            try store.recentFailures(referenceDate: Date(timeIntervalSince1970: 3)).map(\.timestamp),
            [Date(timeIntervalSince1970: 3), Date(timeIntervalSince1970: 2)]
        )
    }

    func testRecentFailureHistoryExpiresOldRecords() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let store = makeStore(
            failureRetentionDays: 1
        )
        let failure = FinderExtensionActivityFailure(
            reason: .permissionDenied,
            errorDomain: NSCocoaErrorDomain,
            errorCode: NSFileWriteNoPermissionError
        )

        try store.record(
            .fileCreationFailed,
            failure: failure,
            at: referenceDate.addingTimeInterval(-90_000)
        )
        try store.record(
            .fileCreationFailed,
            failure: failure,
            at: referenceDate
        )

        XCTAssertEqual(
            try store.recentFailures(referenceDate: referenceDate).map(\.timestamp),
            [referenceDate]
        )

        let persistedData = try Data(contentsOf: failureHistoryFileURL)
        let persistedFailures = try JSONDecoder().decode(
            [FinderExtensionActivity].self,
            from: persistedData
        )
        XCTAssertEqual(persistedFailures.map(\.timestamp), [referenceDate])
    }

    func testClearingFailureHistoryKeepsLatestActivity() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let store = makeStore()
        let failure = FinderExtensionActivityFailure(
            reason: .directoryNotAuthorized,
            errorDomain: nil,
            errorCode: nil
        )
        let activity = FinderExtensionActivity(
            kind: .fileCreationFailed,
            timestamp: timestamp,
            failure: failure
        )

        try store.record(.fileCreationFailed, failure: failure, at: timestamp)
        try store.clearFailureHistory()

        XCTAssertTrue(try store.recentFailures(referenceDate: timestamp).isEmpty)
        XCTAssertEqual(store.latestActivity(), activity)
        let persistedFailures = try JSONDecoder().decode(
            [FinderExtensionActivity].self,
            from: Data(contentsOf: failureHistoryFileURL)
        )
        XCTAssertTrue(persistedFailures.isEmpty)
    }

    func testEmptyHistoryFilePreventsStaleDefaultsFromRestoringClearedFailures() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let failure = FinderExtensionActivityFailure(
            reason: .writeFailed,
            errorDomain: NSCocoaErrorDomain,
            errorCode: NSFileWriteUnknownError
        )
        let legacyData = try JSONEncoder().encode([
            FinderExtensionActivity(
                kind: .fileCreationFailed,
                timestamp: timestamp,
                failure: failure
            )
        ])
        defaults.set(legacyData, forKey: "finderExtension.failureHistory.v1")
        let staleDefaultsView = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertNotNil(staleDefaultsView.data(forKey: "finderExtension.failureHistory.v1"))

        try makeStore().clearFailureHistory()
        staleDefaultsView.set(legacyData, forKey: "finderExtension.failureHistory.v1")
        let staleProcessStore = FinderExtensionActivityStore(
            defaults: staleDefaultsView,
            failureHistoryFileURL: failureHistoryFileURL
        )

        XCTAssertTrue(try staleProcessStore.recentFailures(referenceDate: timestamp).isEmpty)
        let persistedFailures = try JSONDecoder().decode(
            [FinderExtensionActivity].self,
            from: Data(contentsOf: failureHistoryFileURL)
        )
        XCTAssertTrue(persistedFailures.isEmpty)
    }

    func testMigratesLegacyDefaultsHistoryAndPrunesItInTheLockedFile() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let failure = FinderExtensionActivityFailure(
            reason: .writeFailed,
            errorDomain: NSCocoaErrorDomain,
            errorCode: NSFileWriteUnknownError
        )
        let legacyHistory = [
            FinderExtensionActivity(
                kind: .fileCreationFailed,
                timestamp: referenceDate.addingTimeInterval(-90_000),
                failure: failure
            ),
            FinderExtensionActivity(
                kind: .fileCreationFailed,
                timestamp: referenceDate.addingTimeInterval(-2),
                failure: failure
            ),
            FinderExtensionActivity(
                kind: .fileCreationFailed,
                timestamp: referenceDate.addingTimeInterval(-1),
                failure: failure
            ),
            FinderExtensionActivity(
                kind: .fileCreationFailed,
                timestamp: referenceDate,
                failure: failure
            )
        ]
        defaults.set(
            try JSONEncoder().encode(legacyHistory),
            forKey: "finderExtension.failureHistory.v1"
        )
        let store = makeStore(maximumFailureCount: 2, failureRetentionDays: 1)

        XCTAssertEqual(
            try store.recentFailures(referenceDate: referenceDate).map(\.timestamp),
            [referenceDate, referenceDate.addingTimeInterval(-1)]
        )
        XCTAssertNil(defaults.object(forKey: "finderExtension.failureHistory.v1"))

        let persistedFailures = try JSONDecoder().decode(
            [FinderExtensionActivity].self,
            from: Data(contentsOf: failureHistoryFileURL)
        )
        XCTAssertEqual(
            persistedFailures.map(\.timestamp),
            [referenceDate.addingTimeInterval(-1), referenceDate]
        )
    }

    func testConcurrentStoresDoNotOverwriteEachOthersFailureRecords() throws {
        let iterationCount = 64
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let failure = FinderExtensionActivityFailure(
            reason: .writeFailed,
            errorDomain: NSCocoaErrorDomain,
            errorCode: NSFileWriteUnknownError
        )
        let errors = ErrorCollector()
        let stores = (0..<iterationCount).map { _ in
            makeStore(maximumFailureCount: iterationCount)
        }

        DispatchQueue.concurrentPerform(iterations: iterationCount) { index in
            let store = stores[index]
            do {
                try store.record(
                    .fileCreationFailed,
                    failure: failure,
                    at: referenceDate.addingTimeInterval(TimeInterval(index))
                )
            } catch {
                errors.append(error)
            }
        }

        XCTAssertTrue(errors.values.isEmpty, "Unexpected recording errors: \(errors.values)")
        let failures = try makeStore(maximumFailureCount: iterationCount).recentFailures(
            referenceDate: referenceDate.addingTimeInterval(TimeInterval(iterationCount))
        )
        XCTAssertEqual(failures.count, iterationCount)
        XCTAssertEqual(Set(failures.map(\.timestamp)).count, iterationCount)
    }

    func testFailureHistoryFileErrorsAreThrownByMutatingOperations() throws {
        let invalidParentURL = temporaryDirectory
            .appendingPathComponent("not-a-directory", isDirectory: false)
        try Data().write(to: invalidParentURL)
        let store = FinderExtensionActivityStore(
            defaults: defaults,
            failureHistoryFileURL: invalidParentURL.appendingPathComponent("history.json")
        )
        let failure = FinderExtensionActivityFailure(
            reason: .writeFailed,
            errorDomain: NSCocoaErrorDomain,
            errorCode: NSFileWriteUnknownError
        )

        XCTAssertThrowsError(try store.record(.fileCreated))
        XCTAssertThrowsError(
            try store.record(.fileCreationFailed, failure: failure)
        )
        XCTAssertThrowsError(try store.recentFailures())
        XCTAssertThrowsError(try store.clearFailureHistory())
    }

    func testUnavailableSharedDefaultsProducesAnError() {
        let store = FinderExtensionActivityStore(
            defaults: nil,
            failureHistoryFileURL: nil
        )

        XCTAssertFalse(store.isAvailable)
        XCTAssertThrowsError(try store.record(.launched)) { error in
            XCTAssertEqual(
                error as? FinderExtensionActivityStore.StoreError,
                .sharedDefaultsUnavailable
            )
        }
    }

    private func makeStore(
        maximumFailureCount: Int = FinderExtensionActivityStore.defaultMaximumFailureCount,
        failureRetentionDays: Int = FinderExtensionActivityStore.defaultFailureRetentionDays
    ) -> FinderExtensionActivityStore {
        FinderExtensionActivityStore(
            defaults: defaults,
            failureHistoryFileURL: failureHistoryFileURL,
            maximumFailureCount: maximumFailureCount,
            failureRetentionDays: failureRetentionDays
        )
    }
}

private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    var values: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }

    func append(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        errors.append(error)
    }
}
