import Darwin
import XCTest
@testable import QuickFileCore
@testable import QuickFileInfrastructure

final class FinderAuthorizationRequestStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directoryURL: URL!

    override func setUpWithError() throws {
        suiteName = "QuickFileTests.AuthorizationRequest.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickFileRequests-\(UUID())", isDirectory: true)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.removeItem(at: directoryURL)
        }
        defaults = nil
        suiteName = nil
        directoryURL = nil
    }

    func testBoundedRequestReaderAcceptsExactBudgetAndPreservesOversizedFile() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let file = directoryURL.appendingPathComponent("fixture.json")
        try Data("abcd".utf8).write(to: file)
        XCTAssertEqual(try FinderAuthorizationRequestStore.readBoundedRequest(at: file, maximumBytes: 4), Data("abcd".utf8))
        XCTAssertThrowsError(try FinderAuthorizationRequestStore.readBoundedRequest(at: file, maximumBytes: 3))
        XCTAssertEqual(try Data(contentsOf: file), Data("abcd".utf8))
        try Data().write(to: file)
        XCTAssertEqual(try FinderAuthorizationRequestStore.readBoundedRequest(at: file, maximumBytes: 0), Data())
    }

    func testOversizedQueuedPayloadDoesNotBlockHealthyClaimOrGetDeleted() throws {
        let healthy = makeRequest(at: 100)
        let store = makeStore()
        try store.save(healthy)
        let oversized = directoryURL.appendingPathComponent("\(UUID().uuidString).json")
        let bytes = Data(repeating: 0x20, count: FinderAuthorizationRequestStore.maximumRequestBytes + 1)
        try bytes.write(to: oversized)
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), healthy)
        XCTAssertEqual(try Data(contentsOf: oversized), bytes)
        XCTAssertThrowsError(try store.takePendingRequest(referenceDate: date(101)))
        XCTAssertEqual(try Data(contentsOf: oversized), bytes)
    }

    func testBoundedRequestReaderRejectsSymbolicLinksWithoutReadingTarget() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let target = directoryURL.appendingPathComponent("target")
        let alias = directoryURL.appendingPathComponent("alias.json")
        let bytes = Data("sentinel".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        XCTAssertThrowsError(try FinderAuthorizationRequestStore.readBoundedRequest(at: alias))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), target.path)
    }

    func testOversizedReplacementRequestPreservesExistingRequest() throws {
        let original = makeRequest(at: 100)
        let store = makeStore()
        try store.save(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["destinationFolderPath"] = "/" + String(repeating: "x", count: FinderAuthorizationRequestStore.maximumRequestBytes)
        let oversized = try JSONDecoder().decode(FinderAuthorizationRequest.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try store.save(oversized)) { error in
            guard case FinderAuthorizationRequestStore.StoreError.requestTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), original)
    }

    func testOversizedLegacyPayloadIsPreservedWithoutBlockingHealthyQueue() throws {
        let original = makeRequest(at: 99)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["destinationFolderPath"] = "/" + String(repeating: "x", count: FinderAuthorizationRequestStore.maximumRequestBytes)
        let legacy = try JSONDecoder().decode(FinderAuthorizationRequest.self,
            from: JSONSerialization.data(withJSONObject: object))
        defaults.set(try JSONEncoder().encode(legacy), forKey: "finderAuthorizationRequest.v1")
        let healthy = makeRequest(at: 100)
        let store = makeStore()
        try store.save(healthy)
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), healthy)
        let retained = directoryURL.appendingPathComponent("\(legacy.id.uuidString).json")
        XCTAssertEqual(try JSONDecoder().decode(FinderAuthorizationRequest.self, from: Data(contentsOf: retained)), legacy)
        XCTAssertNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
        XCTAssertThrowsError(try store.takePendingRequest(referenceDate: date(101)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    }

    func testRawOversizedLegacySkipsDecoderAndPreservesOriginalAcrossQueueSizesAndRestarts() throws {
        let cap = FinderAuthorizationRequestStore.maximumLegacyInputBytes
        XCTAssertEqual(cap, 256 * 1024)
        XCTAssertGreaterThan(cap, FinderAuthorizationRequestStore.maximumRequestBytes)
        for kind in RawLegacyFixture.allCases {
            for count in [0, 2, FinderAuthorizationRequestStore.maximumPendingRequests] {
                try resetLegacyFixture()
                let (bytes, _) = try rawLegacyFixture(kind, byteCount: cap + 1)
                let calls = LegacyDecodeCounter()
                let store = makeStore(decodeLegacyRequest: calls.decode)
                let healthy = (0..<count).map { makeRequest(at: 100 + Double($0)) }
                for request in healthy { try store.save(request, referenceDate: date(200)) }
                defaults.set(bytes, forKey: "finderAuthorizationRequest.v1")
                for (index, request) in healthy.enumerated() {
                    // Alternate the same instance and new instances, with the same raw value.
                    let consumer = index.isMultiple(of: 2) ? store : makeStore(decodeLegacyRequest: calls.decode)
                    XCTAssertEqual(try consumer.takePendingRequest(referenceDate: date(200)), request)
                    XCTAssertEqual(try queueFileCount(), count - index - 1)
                    assertRawLegacyRetained(bytes)
                }
                for timestamp in [200.0, 1_000.0, 0.0] {
                    let consumer = makeStore(decodeLegacyRequest: calls.decode)
                    assertRetainedOversizedError { try consumer.takePendingRequest(referenceDate: date(timestamp)) }
                    assertRawLegacyRetained(bytes)
                    XCTAssertEqual(try queueFileCount(), 0)
                }
                // Decoder entry is also a prerequisite for all migration encoder paths.
                XCTAssertEqual(calls.count, 0, "Oversized raw fixture: \(kind), queue: \(count)")
                // Recovery needs no process-local reset: replacing only the raw value works.
                let recovered = makeRequest(at: 99)
                defaults.set(try JSONEncoder().encode(recovered), forKey: "finderAuthorizationRequest.v1")
                XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), recovered)
                XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(200)))
                XCTAssertEqual(calls.count, 1)
            }
        }
    }

    func testExactRawBudgetAcceptsWhitespaceAndUnknownFieldsAndMigratesOnlyOnce() throws {
        for kind in [RawLegacyFixture.paddedValid, .unknownField] {
            for count in [0, 2, FinderAuthorizationRequestStore.maximumPendingRequests] {
                try resetLegacyFixture()
                let (bytes, legacy) = try rawLegacyFixture(kind,
                    byteCount: FinderAuthorizationRequestStore.maximumLegacyInputBytes)
                let calls = LegacyDecodeCounter()
                let store = makeStore(decodeLegacyRequest: calls.decode)
                let healthy = (0..<count).map { makeRequest(at: 100 + Double($0)) }
                for request in healthy { try store.save(request, referenceDate: date(200)) }
                defaults.set(bytes, forKey: "finderAuthorizationRequest.v1")
                XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), legacy)
                XCTAssertEqual(calls.count, 1)
                XCTAssertEqual(try queueFileCount(), count)
                XCTAssertNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
                XCTAssertTrue(FileManager.default.fileExists(atPath: legacyMarkerURL.path))
                // Simulate stale cached defaults after restarting the store.
                defaults.set(bytes, forKey: "finderAuthorizationRequest.v1")
                XCTAssertEqual(try drain(makeStore(decodeLegacyRequest: calls.decode), referenceDate: date(200)), healthy)
                XCTAssertEqual(calls.count, 1)
            }
        }
    }

    func testExactRawBudgetMalformedAndWhitespaceOnlyInputsKeepExistingOneTimeFailurePolicy() throws {
        for kind in [RawLegacyFixture.malformed, .whitespaceOnly] {
            for count in [0, 2, FinderAuthorizationRequestStore.maximumPendingRequests] {
                try resetLegacyFixture()
                let (bytes, _) = try rawLegacyFixture(kind,
                    byteCount: FinderAuthorizationRequestStore.maximumLegacyInputBytes)
                let calls = LegacyDecodeCounter()
                let store = makeStore(decodeLegacyRequest: calls.decode)
                let healthy = (0..<count).map { makeRequest(at: 100 + Double($0)) }
                for request in healthy { try store.save(request, referenceDate: date(200)) }
                defaults.set(bytes, forKey: "finderAuthorizationRequest.v1")
                XCTAssertThrowsError(try store.takePendingRequest(referenceDate: date(200)))
                XCTAssertEqual(calls.count, 1)
                XCTAssertNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
                XCTAssertTrue(FileManager.default.fileExists(atPath: legacyMarkerURL.path))
                XCTAssertEqual(try drain(makeStore(), referenceDate: date(200)), healthy)
            }
        }
    }

    func testExactRawBudgetLargeCanonicalRequestRetainsExistingMigrationFilePolicy() throws {
        for count in [0, 2, FinderAuthorizationRequestStore.maximumPendingRequests] {
            try resetLegacyFixture()
            let (bytes, legacy) = try rawLegacyFixture(.largePath,
                byteCount: FinderAuthorizationRequestStore.maximumLegacyInputBytes)
            let request = try XCTUnwrap(legacy)
            let store = makeStore()
            let healthy = (0..<count).map { makeRequest(at: 100 + Double($0)) }
            for item in healthy { try store.save(item, referenceDate: date(200)) }
            defaults.set(bytes, forKey: "finderAuthorizationRequest.v1")
            for (index, item) in healthy.enumerated() {
                XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), item)
                if count == FinderAuthorizationRequestStore.maximumPendingRequests && index == 0 {
                    assertRawLegacyRetained(bytes)
                }
            }
            assertRetainedOversizedError { try makeStore().takePendingRequest(referenceDate: date(200)) }
            XCTAssertNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacyMarkerURL.path))
            let retainedBytes = try Data(contentsOf: requestURL(request))
            XCTAssertGreaterThan(retainedBytes.count, FinderAuthorizationRequestStore.maximumRequestBytes)
            XCTAssertEqual(try JSONDecoder().decode(FinderAuthorizationRequest.self, from: retainedBytes), request)
            assertRetainedOversizedError { try makeStore().takePendingRequest(referenceDate: date(1_000)) }
            XCTAssertEqual(try Data(contentsOf: requestURL(request)), retainedBytes)
        }
    }

    private enum RawLegacyFixture: CaseIterable, Equatable {
        case largePath, paddedValid, unknownField, malformed, whitespaceOnly
    }

    private var legacyMarkerURL: URL { directoryURL.appendingPathComponent(".legacy-v1-migrated") }

    private func resetLegacyFixture() throws {
        defaults.removeObject(forKey: "finderAuthorizationRequest.v1")
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.removeItem(at: directoryURL)
        }
    }

    private func rawLegacyFixture(_ kind: RawLegacyFixture, byteCount: Int) throws -> (Data, FinderAuthorizationRequest?) {
        let original = makeRequest(at: 99)
        var bytes: Data
        var request: FinderAuthorizationRequest? = original
        switch kind {
        case .paddedValid:
            bytes = try JSONEncoder().encode(original)
        case .largePath, .unknownField:
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            let key = kind == .largePath ? "destinationFolderPath" : "ignoredLegacyField"
            let prefix = kind == .largePath ? "/" : ""
            object[key] = prefix
            let baseline = try JSONSerialization.data(withJSONObject: object)
            object[key] = prefix + String(repeating: "x", count: byteCount - baseline.count)
            bytes = try JSONSerialization.data(withJSONObject: object)
            request = try JSONDecoder().decode(FinderAuthorizationRequest.self, from: bytes)
        case .malformed:
            bytes = Data("invalid".utf8)
            request = nil
        case .whitespaceOnly:
            bytes = Data()
            request = nil
        }
        bytes.append(Data(repeating: 0x20, count: byteCount - bytes.count))
        XCTAssertEqual(bytes.count, byteCount)
        return (bytes, request)
    }

    private func assertRawLegacyRetained(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(defaults.data(forKey: "finderAuthorizationRequest.v1"), bytes, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyMarkerURL.path), file: file, line: line)
    }

    private func assertRetainedOversizedError(
        _ operation: () throws -> FinderAuthorizationRequest?, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case let FinderAuthorizationRequestStore.StoreError.persistenceFailed(underlying) = error,
                  case FinderAuthorizationRequestStore.StoreError.requestTooLarge = underlying else {
                return XCTFail("Expected retained oversized input error, got \(error)", file: file, line: line)
            }
        }
    }

    func testSavesAndConsumesRequestOnce() throws {
        let request = makeRequest(at: 100)
        try makeStore().save(request)

        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(101)), request)
        XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(101)))
    }

    func testQueuesRequestsInCreationOrderWithoutOverwriting() throws {
        let first = makeRequest(at: 100)
        let second = makeRequest(at: 101)
        try makeStore().save(second)
        try makeStore().save(first)

        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(102)), first)
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(102)), second)
        XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(102)))
    }

    func testConcurrentProducersPreserveEveryRequest() throws {
        let requests = (0..<16).map { makeRequest(at: 100 + Double($0)) }
        let store = makeStore()
        DispatchQueue.concurrentPerform(iterations: requests.count) { index in
            do {
                try store.save(requests[index])
            } catch {
                XCTFail("Producer failed: \(error)")
            }
        }

        var received: [UUID] = []
        while let request = try makeStore().takePendingRequest(referenceDate: date(200)) {
            received.append(request.id)
        }
        XCTAssertEqual(received, requests.map(\.id))
    }

    func testLaterSaveDoesNotReplaceRequestsAlreadyWaiting() throws {
        let first = makeRequest(at: 100)
        let second = makeRequest(at: 101)
        let third = makeRequest(at: 102)
        let store = makeStore()
        try store.save(first)
        try store.save(second)
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(103)), first)
        try makeStore().save(third)

        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(103)), second)
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(103)), third)
    }

    func testDiscardsExpiredRequestWithoutDiscardingNewerRequest() throws {
        let store = makeStore(retentionInterval: 60)
        let fresh = makeRequest(at: 150)
        try store.save(makeRequest(at: 100))
        try store.save(fresh)

        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(161)), fresh)
        XCTAssertNil(try store.takePendingRequest(referenceDate: date(161)))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            .filter { $0.hasSuffix(".json") }.isEmpty)
    }

    func testKeepsRequestDatedInTheFutureUntilItBecomesEligible() throws {
        let store = makeStore()
        let request = makeRequest(at: 101)
        try store.save(request)

        XCTAssertNil(try store.takePendingRequest(referenceDate: date(100)))
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(102)), request)
        XCTAssertNil(try store.takePendingRequest(referenceDate: date(102)))
    }

    func testRequestPublishedDuringDirectoryEnumerationIsNotLost() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileManager = PublishingRequestFileManager(
            directoryURL: directoryURL,
            destinationFolder: URL(fileURLWithPath: "/tmp/QuickFile Target", isDirectory: true)
        )
        let store = makeStore(fileManager: fileManager)

        let received = try store.takePendingRequest()

        XCTAssertEqual(received, try XCTUnwrap(fileManager.publishedRequest))
        XCTAssertNil(try store.takePendingRequest())
    }

    func testMigratesLegacyRequestAlongsideQueuedRequests() throws {
        let legacy = makeRequest(at: 100)
        let queued = makeRequest(at: 101)
        defaults.set(try JSONEncoder().encode(legacy), forKey: "finderAuthorizationRequest.v1")
        try makeStore().save(queued)

        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(102)), legacy)
        XCTAssertNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(102)), queued)
        XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(102)))
    }

    func testSustainedReadFailureAllowsHealthyRequestsAndRecoveryConsumesEachOnce() throws {
        let blocked = makeRequest(at: 99)
        let first = makeRequest(at: 100)
        let second = makeRequest(at: 101)
        let blockedURL = requestURL(blocked)
        for request in [second, blocked, first] { try makeStore().save(request) }
        let originalData = try Data(contentsOf: blockedURL)
        let readFailure = NSError(domain: "QuickFileTests.RequestRead", code: 1)
        var injectedFaultCount = 0
        let failingStore = makeStore(readRequestData: { url in
            if url.lastPathComponent == blockedURL.lastPathComponent {
                injectedFaultCount += 1
                throw readFailure
            }
            return try Data(contentsOf: url)
        })

        XCTAssertEqual(try failingStore.takePendingRequest(referenceDate: date(102)), first)
        XCTAssertEqual(try failingStore.takePendingRequest(referenceDate: date(102)), second)
        for _ in 0..<2 {
            XCTAssertThrowsError(try failingStore.takePendingRequest(referenceDate: date(102))) { error in
                guard case let FinderAuthorizationRequestStore.StoreError.persistenceFailed(underlying) = error else {
                    return XCTFail("Expected request read failure, got \(error)")
                }
                XCTAssertEqual(underlying as NSError, readFailure)
            }
        }
        XCTAssertEqual(injectedFaultCount, 4, "Each take attempts a faulty file only once")
        XCTAssertEqual(try Data(contentsOf: blockedURL), originalData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL(first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL(second).path))

        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(102)), blocked)
        XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(102)))
    }

    func testFailedClaimRemovalNeverReturnsRequestOrBlocksHealthyRequests() throws {
        let blocked = makeRequest(at: 99)
        let first = makeRequest(at: 100)
        let second = makeRequest(at: 101)
        for request in [second, blocked, first] { try makeStore().save(request) }
        let originalData = try Data(contentsOf: requestURL(blocked))
        let fileManager = FailingRequestRemovalFileManager(filename: requestURL(blocked).lastPathComponent)
        let store = makeStore(fileManager: fileManager)

        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(102)), first)
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(102)), second)
        for _ in 0..<2 {
            XCTAssertThrowsError(try store.takePendingRequest(referenceDate: date(102))) { error in
                guard case let FinderAuthorizationRequestStore.StoreError.persistenceFailed(underlying) = error else {
                    return XCTFail("Expected removal failure, got \(error)")
                }
                XCTAssertEqual(underlying as NSError, fileManager.failure)
            }
        }
        XCTAssertEqual(fileManager.failedRemovalCount, 4)
        XCTAssertEqual(try Data(contentsOf: requestURL(blocked)), originalData)
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(102)), blocked)
        XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(102)))
    }

    func testMalformedCleanupFailureDoesNotBlockHealthyRequests() throws {
        try assertCleanupFailureDoesNotBlockHealthyRequests(malformed: true)
    }

    func testExpiredCleanupFailureDoesNotBlockHealthyRequests() throws {
        try assertCleanupFailureDoesNotBlockHealthyRequests(malformed: false)
    }

    private func assertCleanupFailureDoesNotBlockHealthyRequests(malformed: Bool) throws {
        let discarded = makeRequest(at: 1)
        let healthy = makeRequest(at: 100)
        try makeStore().save(discarded)
        try makeStore().save(healthy)
        let discardedURL = requestURL(discarded)
        if malformed { try Data("not-json".utf8).write(to: discardedURL) }
        let originalData = try Data(contentsOf: discardedURL)
        let fileManager = FailingRequestRemovalFileManager(filename: discardedURL.lastPathComponent)
        let store = makeStore(fileManager: fileManager, retentionInterval: 60)

        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), healthy)
        for _ in 0..<2 {
            XCTAssertThrowsError(try store.takePendingRequest(referenceDate: date(101))) { error in
                guard case let FinderAuthorizationRequestStore.StoreError.persistenceFailed(underlying) = error else {
                    return XCTFail("Expected cleanup failure, got \(error)")
                }
                XCTAssertEqual(underlying as NSError, fileManager.failure)
            }
        }
        XCTAssertEqual(fileManager.failedRemovalCount, 3)
        XCTAssertEqual(try Data(contentsOf: discardedURL), originalData)
        let recovered = makeStore(retentionInterval: 60)
        if malformed {
            XCTAssertThrowsError(try recovered.takePendingRequest(referenceDate: date(101)))
        } else {
            XCTAssertNil(try recovered.takePendingRequest(referenceDate: date(101)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: discardedURL.path))
        XCTAssertNil(try recovered.takePendingRequest(referenceDate: date(101)))
    }

    func testHealthyRequestsWithSameCreationTimeUseUUIDOrderDespiteReadFailure() throws {
        let blocked = makeRequest(at: 99)
        let requests = (0..<4).map { _ in makeRequest(at: 100) }
        for request in requests + [blocked] { try makeStore().save(request) }
        let store = makeStore(readRequestData: { url in
            if url.lastPathComponent == "\(blocked.id.uuidString).json" {
                throw NSError(domain: "QuickFileTests.RequestRead", code: 1)
            }
            return try Data(contentsOf: url)
        })
        for request in requests.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), request)
        }
        XCTAssertThrowsError(try store.takePendingRequest(referenceDate: date(101)))
    }

    func testUnreadableMigratedRequestAllowsQueuedRequestAndRecoversWithoutReplay() throws {
        let legacy = makeRequest(at: 100)
        let queued = makeRequest(at: 101)
        let legacyData = try JSONEncoder().encode(legacy)
        defaults.set(legacyData, forKey: "finderAuthorizationRequest.v1")
        try makeStore().save(queued)
        let store = makeStore(readRequestData: { url in
            if url.lastPathComponent == "\(legacy.id.uuidString).json" {
                throw NSError(domain: "QuickFileTests.RequestRead", code: 1)
            }
            return try Data(contentsOf: url)
        })

        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(102)), queued)
        XCTAssertThrowsError(try store.takePendingRequest(referenceDate: date(102)))
        XCTAssertNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
        XCTAssertEqual(
            try JSONDecoder().decode(FinderAuthorizationRequest.self, from: Data(contentsOf: requestURL(legacy))),
            legacy
        )
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(102)), legacy)
        defaults.set(legacyData, forKey: "finderAuthorizationRequest.v1")
        XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(102)))
    }

    func testReadFailurePreservesMigratedRequestWithoutReplayingIt() throws {
        let request = makeRequest(at: 100)
        let data = try JSONEncoder().encode(request)
        defaults.set(data, forKey: "finderAuthorizationRequest.v1")
        let failingStore = makeStore(readRequestData: { _ in
            throw NSError(domain: "QuickFileTests.RequestRead", code: 1)
        })

        XCTAssertThrowsError(try failingStore.takePendingRequest(referenceDate: date(101)))
        XCTAssertNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(101)), request)
        // A stale defaults writer cannot resurrect the already-consumed migrated request.
        defaults.set(data, forKey: "finderAuthorizationRequest.v1")
        XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(101)))
    }

    func testCorruptRequestDoesNotBlockHealthyRequestInSameTake() throws {
        let valid = makeRequest(at: 100)
        let store = makeStore()
        try store.save(valid)
        let corruptURL = directoryURL.appendingPathComponent("\(UUID()).json")
        try Data("not-json".utf8).write(to: corruptURL)

        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), valid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertNil(try store.takePendingRequest(referenceDate: date(101)))
    }

    func testTwoConsumersClaimEachQueuedRequestExactlyOnce() throws {
        let requests = (0..<32).map { makeRequest(at: 100 + Double($0)) }
        for request in requests { try makeStore().save(request) }
        let stores = [makeStore(), makeStore()]
        let results = RequestResults()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                while let request = try stores[index].takePendingRequest(referenceDate: self.date(200)) {
                    results.append(request.id)
                }
            } catch { results.append(error) }
        }
        XCTAssertTrue(results.errors.isEmpty, "\(results.errors)")
        XCTAssertEqual(results.ids.count, requests.count)
        XCTAssertEqual(Set(results.ids), Set(requests.map(\.id)))
    }

    func testTwoConsumersDrainHealthyRequestsExactlyOnceDespiteSustainedReadFailure() throws {
        let blocked = makeRequest(at: 99)
        let requests = (0..<16).map { makeRequest(at: 100 + Double($0)) }
        for request in requests + [blocked] { try makeStore().save(request) }
        let stores = (0..<2).map { _ in
            makeStore(readRequestData: { url in
                if url.lastPathComponent == "\(blocked.id.uuidString).json" {
                    throw NSError(domain: "QuickFileTests.RequestRead", code: 1)
                }
                return try Data(contentsOf: url)
            })
        }
        let results = RequestResults()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                while let request = try stores[index].takePendingRequest(referenceDate: self.date(200)) {
                    results.append(request.id)
                }
            } catch { results.append(error) }
        }
        XCTAssertEqual(results.errors.count, 2, "Both drains terminate on the retained fault")
        XCTAssertEqual(results.ids.count, requests.count)
        XCTAssertEqual(Set(results.ids), Set(requests.map(\.id)))
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(200)), blocked)
        XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(200)))
    }

    func testConcurrentLegacyMigrationConsumesOnceAndIgnoresStaleDefaults() throws {
        let request = makeRequest(at: 100)
        let data = try JSONEncoder().encode(request)
        defaults.set(data, forKey: "finderAuthorizationRequest.v1")
        let stores = [makeStore(), makeStore()]
        let results = RequestResults()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                if let request = try stores[index].takePendingRequest(referenceDate: self.date(101)) {
                    results.append(request.id)
                }
            } catch { results.append(error) }
        }
        XCTAssertTrue(results.errors.isEmpty, "\(results.errors)")
        XCTAssertEqual(results.ids, [request.id])
        defaults.set(data, forKey: "finderAuthorizationRequest.v1")
        XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(101)))
    }

    func testCorruptLegacyRequestIsReportedOnceAndQueueRecovers() throws {
        defaults.set(Data("invalid".utf8), forKey: "finderAuthorizationRequest.v1")
        let request = makeRequest(at: 100)
        try makeStore().save(request)
        XCTAssertThrowsError(try makeStore().takePendingRequest(referenceDate: date(101)))
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(101)), request)
    }

    func testReportsUnavailableSharedStore() {
        let store = FinderAuthorizationRequestStore(defaults: nil, directoryURL: nil)
        XCTAssertThrowsError(try store.save(makeRequest(at: 100))) { error in
            guard case FinderAuthorizationRequestStore.StoreError.sharedStoreUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testQueueAdmits64RequestsAndRejects65thWithoutChangingHealthyFiles() throws {
        XCTAssertEqual(FinderAuthorizationRequestStore.maximumPendingRequests, 64)
        let store = makeStore()
        let requests = (0..<64).map { makeRequest(at: 100 + Double($0)) }
        for request in requests { try store.save(request, referenceDate: date(200)) }
        let before = try requests.map { try Data(contentsOf: requestURL($0)) }
        let rejected = makeRequest(at: 164)
        assertQueueFull { try store.save(rejected, referenceDate: date(200)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL(rejected).path))
        XCTAssertEqual(try queueFileCount(), 64)
        XCTAssertEqual(try requests.map { try Data(contentsOf: requestURL($0)) }, before)
        for request in requests {
            XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), request)
        }
        XCTAssertNil(try store.takePendingRequest(referenceDate: date(200)))
    }

    func testExistingIDCanBeSavedAgainAtCapacityWithoutTakingAnotherSlot() throws {
        let store = makeStore()
        let requests = (0..<64).map { makeRequest(at: 100 + Double($0)) }
        for request in requests { try store.save(request, referenceDate: date(200)) }
        let replacement = FinderAuthorizationRequest(
            id: requests[0].id, templateID: UUID(), destinationFolder: requests[0].destinationFolder,
            createdAt: date(99)
        )
        try store.save(replacement, referenceDate: date(200))
        try store.save(replacement, referenceDate: date(200))
        XCTAssertEqual(try queueFileCount(), 64)
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), replacement)
        for request in requests.dropFirst() {
            XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), request)
        }
        XCTAssertNil(try store.takePendingRequest(referenceDate: date(200)))
    }

    func testExistingIDAtCapacityAcceptsBaseRelativeEnumerationURLs() throws {
        let requests = (0..<64).map { makeRequest(at: 100 + Double($0)) }
        let store = makeStore()
        for request in requests { try store.save(request, referenceDate: date(200)) }
        let fileManager = BaseRelativeRequestFileManager()
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        let existing = try XCTUnwrap(entries.first {
            $0.lastPathComponent == requestURL(requests[0]).lastPathComponent
        })
        XCTAssertNotNil(existing.baseURL, "Exercise enumeration URLs with a retained directory base")
        XCTAssertEqual(existing.standardizedFileURL.path, requestURL(requests[0]).standardizedFileURL.path)
        let replacement = FinderAuthorizationRequest(
            id: requests[0].id, templateID: UUID(), destinationFolder: requests[0].destinationFolder,
            createdAt: date(99)
        )

        try makeStore(fileManager: fileManager).save(replacement, referenceDate: date(200))

        XCTAssertEqual(try queueFileCount(), 64)
        XCTAssertEqual(
            try JSONDecoder().decode(FinderAuthorizationRequest.self, from: Data(contentsOf: requestURL(requests[0]))),
            replacement
        )
        XCTAssertEqual(try drain(store, referenceDate: date(200)), [replacement] + Array(requests.dropFirst()))
    }

    func testCapacityPrunesOnlyExpiredEntriesAndPreservesExactRetentionBoundary() throws {
        let store = makeStore(retentionInterval: 60)
        let expired = makeRequest(at: 39)
        let boundary = makeRequest(at: 40)
        let healthy = (0..<62).map { _ in makeRequest(at: 99) }
        for request in [expired, boundary] + healthy {
            try store.save(request, referenceDate: date(100))
        }
        let newRequest = makeRequest(at: 100)
        try store.save(newRequest, referenceDate: date(100))
        XCTAssertEqual(try queueFileCount(), 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL(expired).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL(boundary).path))
        assertQueueFull { try store.save(makeRequest(at: 100), referenceDate: date(100)) }
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(100)), boundary)
        let received = try drain(store, referenceDate: date(100))
        XCTAssertEqual(Set(received.map(\.id)), Set((healthy + [newRequest]).map(\.id)))
    }

    func testAdmissionRetainsUnreadableMalformedFutureAndUnremovableEntries() throws {
        let unreadable = makeRequest(at: 1)
        let malformed = makeRequest(at: 2)
        let future = makeRequest(at: 101)
        let unremovable = makeRequest(at: 3)
        let healthy = (0..<60).map { _ in makeRequest(at: 99) }
        let requests = [unreadable, malformed, future, unremovable] + healthy
        for request in requests { try makeStore().save(request, referenceDate: date(100)) }
        try Data("not-json".utf8).write(to: requestURL(malformed))
        let before = try requests.map { try Data(contentsOf: requestURL($0)) }
        let fileManager = FailingRequestRemovalFileManager(filename: requestURL(unremovable).lastPathComponent)
        let store = makeStore(fileManager: fileManager, retentionInterval: 60, readRequestData: { url in
            if url.lastPathComponent == "\(unreadable.id.uuidString).json" {
                throw NSError(domain: "QuickFileTests.RequestRead", code: 1)
            }
            return try Data(contentsOf: url)
        })
        assertQueueFull { try store.save(makeRequest(at: 100), referenceDate: date(100)) }
        XCTAssertEqual(try queueFileCount(), 64)
        XCTAssertEqual(fileManager.failedRemovalCount, 1)
        XCTAssertEqual(try requests.map { try Data(contentsOf: requestURL($0)) }, before)
        // Consumer cleanup/error ordering is unchanged; healthy entries still drain.
        for request in healthy.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            XCTAssertEqual(try store.takePendingRequest(referenceDate: date(100)), request)
        }
        XCTAssertThrowsError(try store.takePendingRequest(referenceDate: date(100)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL(future).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL(unreadable).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL(unremovable).path))
    }

    func testFailedExpiredRemovalDoesNotPreventReclaimingAnotherExpiredSlot() throws {
        let blocked = makeRequest(at: 1)
        let expired = makeRequest(at: 2)
        let healthy = (0..<62).map { _ in makeRequest(at: 99) }
        for request in [blocked, expired] + healthy {
            try makeStore().save(request, referenceDate: date(100))
        }
        let fileManager = FailingRequestRemovalFileManager(filename: requestURL(blocked).lastPathComponent)
        let store = makeStore(fileManager: fileManager, retentionInterval: 60)
        let admitted = makeRequest(at: 100)
        try store.save(admitted, referenceDate: date(100))
        XCTAssertEqual(try queueFileCount(), 64)
        XCTAssertEqual(fileManager.failedRemovalCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL(blocked).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL(expired).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL(admitted).path))
    }

    func testConcurrentAdmissionCannotExceed64AndEveryAcceptedRequestCanBeClaimed() throws {
        let requests = (0..<96).map { makeRequest(at: 100 + Double($0)) }
        let stores = (0..<4).map { _ in makeStore() }
        let results = RequestResults()
        let referenceDate = date(200)
        DispatchQueue.concurrentPerform(iterations: requests.count) { index in
            do {
                try stores[index % stores.count].save(requests[index], referenceDate: referenceDate)
                results.append(requests[index].id)
            } catch { results.append(error) }
        }
        XCTAssertEqual(results.ids.count, 64)
        XCTAssertEqual(results.errors.count, 32)
        for error in results.errors {
            guard case FinderAuthorizationRequestStore.StoreError.queueFull = error else {
                return XCTFail("Expected queueFull, got \(error)")
            }
        }
        XCTAssertEqual(try queueFileCount(), 64)
        let received = try drain(makeStore(), referenceDate: referenceDate)
        XCTAssertEqual(received.count, 64)
        XCTAssertEqual(Set(received.map(\.id)), Set(results.ids))
        XCTAssertEqual(received.map(\.createdAt), received.map(\.createdAt).sorted())
    }

    func testFullQueueClaimsOlderLegacyRequestWithoutCreating65thFileOrReplayingIt() throws {
        let requests = (0..<64).map { makeRequest(at: 100 + Double($0)) }
        let store = makeStore()
        for request in requests { try store.save(request, referenceDate: date(200)) }
        let legacy = makeRequest(at: 99)
        let legacyData = try JSONEncoder().encode(legacy)
        defaults.set(legacyData, forKey: "finderAuthorizationRequest.v1")
        // The upgrade fixture contains 64 disk entries plus one historical
        // defaults entry; new admission must not make a 65th disk file.
        assertQueueFull { try store.save(makeRequest(at: 164), referenceDate: date(200)) }
        XCTAssertEqual(try queueFileCount(), 64)
        XCTAssertNotNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), legacy)
        XCTAssertEqual(try queueFileCount(), 64)
        XCTAssertNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
        defaults.set(legacyData, forKey: "finderAuthorizationRequest.v1")
        XCTAssertEqual(try drain(store, referenceDate: date(200)), requests)
        XCTAssertNil(try store.takePendingRequest(referenceDate: date(200)))
    }

    func testFullQueueClaimsOldestLegacyAtExactSerializedByteBudget() throws {
        let requests = (0..<64).map { makeRequest(at: 100 + Double($0)) }
        let store = makeStore()
        for request in requests { try store.save(request, referenceDate: date(200)) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(makeRequest(at: 99))) as? [String: Any])
        object["destinationFolderPath"] = "/"
        let baseline = try JSONDecoder().decode(FinderAuthorizationRequest.self,
            from: JSONSerialization.data(withJSONObject: object))
        let baselineBytes = try JSONEncoder().encode(baseline)
        object["destinationFolderPath"] = "/" + String(repeating: "x",
            count: FinderAuthorizationRequestStore.maximumRequestBytes - baselineBytes.count)
        let legacy = try JSONDecoder().decode(FinderAuthorizationRequest.self,
            from: JSONSerialization.data(withJSONObject: object))
        let legacyBytes = try JSONEncoder().encode(legacy)
        XCTAssertEqual(legacyBytes.count, FinderAuthorizationRequestStore.maximumRequestBytes)
        defaults.set(legacyBytes, forKey: "finderAuthorizationRequest.v1")

        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), legacy)
        XCTAssertEqual(try queueFileCount(), 64)
        XCTAssertNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
        XCTAssertEqual(try drain(store, referenceDate: date(200)), requests)
    }

    func testFullQueuePreservesOversizedOldestLegacyWhileHealthyRequestsDrain() throws {
        try assertFullQueuePreservesOversizedLegacy(
            at: 99, path: "/" + String(repeating: "x", count: FinderAuthorizationRequestStore.maximumRequestBytes)
        )
    }

    func testFullQueuePreservesLegacyWhoseJSONEscapingExceedsByteBudget() throws {
        let path = "/" + String(repeating: "\"", count: FinderAuthorizationRequestStore.maximumRequestBytes / 2)
        XCTAssertLessThan(path.utf8.count, FinderAuthorizationRequestStore.maximumRequestBytes)
        try assertFullQueuePreservesOversizedLegacy(at: 99, path: path)
    }

    func testFullQueuePreservesOversizedFutureLegacyWhileHealthyRequestsDrain() throws {
        try assertFullQueuePreservesOversizedLegacy(
            at: 201, path: "/" + String(repeating: "x", count: FinderAuthorizationRequestStore.maximumRequestBytes)
        )
    }

    func testFullQueuePreservesOversizedExpiredLegacyWhileHealthyRequestsDrain() throws {
        try assertFullQueuePreservesOversizedLegacy(
            at: -401, path: "/" + String(repeating: "x", count: FinderAuthorizationRequestStore.maximumRequestBytes)
        )
    }

    private func assertFullQueuePreservesOversizedLegacy(at timestamp: TimeInterval, path: String) throws {
        let store = makeStore()
        let healthy = (0..<64).map { makeRequest(at: 100 + Double($0)) }
        for request in healthy { try store.save(request, referenceDate: date(200)) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(makeRequest(at: timestamp))) as? [String: Any])
        object["destinationFolderPath"] = path
        let legacy = try JSONDecoder().decode(FinderAuthorizationRequest.self,
            from: JSONSerialization.data(withJSONObject: object))
        let legacyBytes = try JSONEncoder().encode(legacy)
        XCTAssertGreaterThan(legacyBytes.count, FinderAuthorizationRequestStore.maximumRequestBytes)
        defaults.set(legacyBytes, forKey: "finderAuthorizationRequest.v1")
        let marker = directoryURL.appendingPathComponent(".legacy-v1-migrated")

        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), healthy[0])
        XCTAssertEqual(defaults.data(forKey: "finderAuthorizationRequest.v1"), legacyBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL(legacy).path))
        XCTAssertEqual(try queueFileCount(), 63)

        // A freed slot permits the existing migration path, but its oversized file
        // remains unreadable. It must never be claimed or deleted for its age.
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), healthy[1])
        XCTAssertNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try queueFileCount(), 63)
        let retainedBytes = try Data(contentsOf: requestURL(legacy))
        XCTAssertGreaterThan(retainedBytes.count, FinderAuthorizationRequestStore.maximumRequestBytes)
        XCTAssertEqual(try JSONDecoder().decode(FinderAuthorizationRequest.self, from: retainedBytes), legacy)
        for request in healthy.dropFirst(2) {
            XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), request)
        }
        XCTAssertEqual(try queueFileCount(), 1)
        for referenceDate in [date(200), date(1_000)] {
            XCTAssertThrowsError(try store.takePendingRequest(referenceDate: referenceDate)) { error in
                guard case let FinderAuthorizationRequestStore.StoreError.persistenceFailed(underlying) = error,
                      case FinderAuthorizationRequestStore.StoreError.requestTooLarge = underlying else {
                    return XCTFail("Expected retained oversized request error, got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: requestURL(legacy)), retainedBytes)
        }
    }

    func testFullQueueDiscardsExpiredLegacyWithinBudgetAndClaimsOldestHealthyRequest() throws {
        let requests = (0..<64).map { makeRequest(at: 100 + Double($0)) }
        let store = makeStore()
        for request in requests { try store.save(request, referenceDate: date(200)) }
        let legacy = makeRequest(at: -401)
        let legacyBytes = try JSONEncoder().encode(legacy)
        defaults.set(legacyBytes, forKey: "finderAuthorizationRequest.v1")

        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), requests[0])
        XCTAssertEqual(try queueFileCount(), 63)
        XCTAssertNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL(legacy).path))
        defaults.set(legacyBytes, forKey: "finderAuthorizationRequest.v1")
        XCTAssertEqual(try drain(store, referenceDate: date(200)), Array(requests.dropFirst()))
    }

    func testFullQueueDefersFutureLegacyUntilASlotIsFreed() throws {
        let requests = (0..<64).map { makeRequest(at: 100 + Double($0)) }
        let store = makeStore()
        for request in requests { try store.save(request, referenceDate: date(200)) }
        let legacy = makeRequest(at: 201)
        defaults.set(try JSONEncoder().encode(legacy), forKey: "finderAuthorizationRequest.v1")
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), requests[0])
        XCTAssertEqual(try queueFileCount(), 63)
        XCTAssertNotNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), requests[1])
        XCTAssertEqual(try queueFileCount(), 63)
        XCTAssertNil(defaults.data(forKey: "finderAuthorizationRequest.v1"))
        XCTAssertEqual(try drain(store, referenceDate: date(200)), Array(requests.dropFirst(2)))
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(202)), legacy)
        XCTAssertNil(try store.takePendingRequest(referenceDate: date(202)))
    }

    func testOversizedPreUpgradeQueueRejectsNewAdmissionWithoutDroppingHealthyRequests() throws {
        let requests = (0..<65).map { makeRequest(at: 100 + Double($0)) }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        // Simulate a queue written by the older unbounded producer.
        for request in requests {
            try JSONEncoder().encode(request).write(to: requestURL(request), options: .atomic)
        }
        let store = makeStore()
        let newRequest = makeRequest(at: 165)
        assertQueueFull { try store.save(newRequest, referenceDate: date(200)) }
        XCTAssertEqual(try queueFileCount(), 65)
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), requests[0])
        assertQueueFull { try store.save(newRequest, referenceDate: date(200)) }
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), requests[1])
        try store.save(newRequest, referenceDate: date(200))
        XCTAssertEqual(try queueFileCount(), 64)
        XCTAssertEqual(try drain(store, referenceDate: date(200)), Array(requests.dropFirst(2)) + [newRequest])
    }

    func testBlockedPinnedReadDoesNotBlockProducerAndRevalidatesInsertion() throws {
        try finishMigrationForSnapshotTests()
        let original = makeRequest(at: 100)
        let older = makeRequest(at: 99)
        let writer = makeStore()
        try writer.save(original)
        let probe = PinnedReadProbe()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let producerFinished = DispatchSemaphore(value: 0)
        let results = RequestResults()
        let consumer = makeStore(readPinnedRequestData: { descriptor, url in
            if probe.record(descriptor, url: url) == 1 {
                entered.signal()
                release.wait()
            }
            return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
        })
        defer { release.signal(); _ = finished.wait(timeout: .now() + 5) }
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do { if let request = try consumer.takePendingRequest(referenceDate: Date(timeIntervalSince1970: 101)) {
                results.append(request.id)
            } } catch { results.append(error) }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            defer { producerFinished.signal() }
            do { try writer.save(older) } catch { results.append(error) }
        }
        // The producer must finish BEFORE the blocked descriptor read is released.
        let producerProgress = producerFinished.wait(timeout: .now() + 5)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        if producerProgress != .success { _ = producerFinished.wait(timeout: .now() + 5) }
        XCTAssertEqual(producerProgress, .success)
        XCTAssertTrue(results.errors.isEmpty, "\(results.errors)")
        XCTAssertEqual(results.ids, [older.id])
        XCTAssertGreaterThan(probe.count, 1)
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(101)), original)
        assertDescriptorsClosed(probe.descriptors)
    }

    func testPinnedDescriptorReadsOriginalObjectAfterBuild43AtomicReplacement() throws {
        try finishMigrationForSnapshotTests()
        let original = makeRequest(at: 100)
        let replacement = makeRequest(id: original.id, at: 99)
        try makeStore().save(original)
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: { descriptor, url in
            let first = probe.record(descriptor, url: url) == 1
            if first { try self.writeUsingBuild43Protocol(replacement) }
            let bytes = try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
            if first {
                XCTAssertEqual(try JSONDecoder().decode(FinderAuthorizationRequest.self, from: bytes), original,
                    "The fast reader must consume the pinned FD, never reopen the replacement pathname")
            }
            return bytes
        })
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), replacement)
        XCTAssertEqual(probe.count, 2)
        assertDescriptorsClosed(probe.descriptors)
        XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(101)))
    }

    func testNonwinningReplacementRevalidatesWholeSnapshotBeforeClaim() throws {
        try finishMigrationForSnapshotTests()
        let winner = makeRequest(at: 100)
        let nonwinner = makeRequest(at: 101)
        let replacement = makeRequest(id: nonwinner.id, at: 99)
        for request in [winner, nonwinner] { try makeStore().save(request) }
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: { descriptor, url in
            if probe.record(descriptor, url: url) == 1 { try self.writeUsingBuild43Protocol(replacement) }
            return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
        })
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(102)), replacement)
        XCTAssertEqual(probe.count, 4)
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(102)), winner)
        assertDescriptorsClosed(probe.descriptors)
    }

    func testMalformedReplacementCannotBeDeletedByStaleCleanup() throws {
        try assertReplacementSurvivesStaleCleanup(malformed: true)
    }

    func testExpiredReplacementCannotBeDeletedByStaleCleanup() throws {
        try assertReplacementSurvivesStaleCleanup(malformed: false)
    }

    private func assertReplacementSurvivesStaleCleanup(malformed: Bool) throws {
        try finishMigrationForSnapshotTests()
        let old = makeRequest(at: 1)
        let replacement = makeRequest(id: old.id, at: 99)
        let healthy = makeRequest(at: 100)
        for request in [old, healthy] { try makeStore().save(request) }
        if malformed { try Data("malformed".utf8).write(to: requestURL(old), options: .atomic) }
        let probe = PinnedReadProbe()
        let store = makeStore(retentionInterval: 60, readPinnedRequestData: { descriptor, url in
            if probe.record(descriptor, url: url) == 1 { try self.writeUsingBuild43Protocol(replacement) }
            return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
        })
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), replacement)
        XCTAssertEqual(probe.count, 4)
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(101)), healthy)
        assertDescriptorsClosed(probe.descriptors)
    }

    func testTwoOverlappingPinnedSnapshotsClaimEachRequestOnlyOnce() throws {
        try finishMigrationForSnapshotTests()
        let requests = [makeRequest(at: 100), makeRequest(at: 101)]
        for request in requests { try makeStore().save(request) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let results = RequestResults()
        let probes = [PinnedReadProbe(), PinnedReadProbe()]
        let stores = probes.map { probe in
            makeStore(readPinnedRequestData: { descriptor, url in
                if probe.record(descriptor, url: url) == 1 {
                    entered.signal()
                    release.wait()
                }
                return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
            })
        }
        defer { for _ in stores { release.signal() }; _ = finished.wait(timeout: .now() + 5) }
        for store in stores {
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                do { if let request = try store.takePendingRequest(referenceDate: Date(timeIntervalSince1970: 102)) {
                    results.append(request.id)
                } } catch { results.append(error) }
            }
        }
        let firstEntered = entered.wait(timeout: .now() + 5)
        let secondEntered = entered.wait(timeout: .now() + 5)
        release.signal()
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(firstEntered, .success)
        XCTAssertEqual(secondEntered, .success)
        XCTAssertTrue(results.errors.isEmpty, "\(results.errors)")
        XCTAssertEqual(results.ids.count, 2)
        XCTAssertEqual(Set(results.ids), Set(requests.map(\.id)))
        XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(102)))
        for probe in probes { assertDescriptorsClosed(probe.descriptors) }
    }

    func testBuild43ConsumerMayClaimWhileNewConsumerReadsWithoutDuplicateReturn() throws {
        try finishMigrationForSnapshotTests()
        let requests = [makeRequest(at: 100), makeRequest(at: 101)]
        for request in requests { try writeUsingBuild43Protocol(request) }
        let probe = PinnedReadProbe()
        var oldClaim: FinderAuthorizationRequest?
        let store = makeStore(readPinnedRequestData: { descriptor, url in
            if probe.record(descriptor, url: url) == 1 { oldClaim = try self.takeUsingBuild43Protocol() }
            return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
        })
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(102)), requests[1])
        XCTAssertEqual(oldClaim, requests[0])
        XCTAssertNil(try takeUsingBuild43Protocol())
        assertDescriptorsClosed(probe.descriptors)
    }

    func testSnapshotRetryLimitFallsBackAndReleasesEveryDescriptor() throws {
        try finishMigrationForSnapshotTests()
        let original = makeRequest(at: 100)
        try makeStore().save(original)
        let probe = PinnedReadProbe()
        var latest = original
        let store = makeStore(readPinnedRequestData: { descriptor, url in
            let attempt = probe.record(descriptor, url: url)
            latest = self.makeRequest(id: original.id, at: 100 + Double(attempt))
            try self.writeUsingBuild43Protocol(latest)
            return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
        })
        let received = try store.takePendingRequest(referenceDate: date(110))
        XCTAssertEqual(received, latest)
        XCTAssertEqual(probe.count, FinderAuthorizationRequestStore.maximumSnapshotAttempts)
        assertDescriptorsClosed(probe.descriptors)
        // A subsequent store can use the process-wide admission after retry exhaustion.
        try makeStore().save(original)
        let nextProbe = PinnedReadProbe()
        let nextStore = makeStore(readPinnedRequestData: nextProbe.read)
        XCTAssertEqual(try nextStore.takePendingRequest(referenceDate: date(110)), original)
        XCTAssertEqual(nextProbe.count, 1)
    }

    func testPinnedReadErrorPreservesFileTerminatesAndReleasesAdmission() throws {
        try finishMigrationForSnapshotTests()
        let request = makeRequest(at: 100)
        try makeStore().save(request)
        let probe = PinnedReadProbe()
        let failure = NSError(domain: "QuickFileTests.PinnedRead", code: 1)
        let failing = makeStore(readPinnedRequestData: { descriptor, url in
            _ = probe.record(descriptor, url: url)
            throw failure
        })
        // More calls than the process admission limit expose leaked permits.
        for _ in 0..<(FinderAuthorizationRequestStore.maximumConcurrentSnapshots + 2) {
            XCTAssertThrowsError(try failing.takePendingRequest(referenceDate: date(101))) { error in
                guard case let FinderAuthorizationRequestStore.StoreError.persistenceFailed(underlying) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(underlying as NSError, failure)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL(request).path))
            assertDescriptorsClosed(probe.descriptors)
        }
        XCTAssertEqual(probe.count, FinderAuthorizationRequestStore.maximumConcurrentSnapshots + 2)
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(101)), request)
    }

    func testPinnedReadErrorDoesNotBlockHealthySameTimestampUUIDOrder() throws {
        try finishMigrationForSnapshotTests()
        let unreadable = makeRequest(at: 99)
        let requests = (0..<3).map { _ in makeRequest(at: 100) }.sorted { $0.id.uuidString < $1.id.uuidString }
        for request in requests + [unreadable] { try makeStore().save(request) }
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: { descriptor, url in
            _ = probe.record(descriptor, url: url)
            if url.lastPathComponent == "\(unreadable.id.uuidString).json" {
                throw NSError(domain: "QuickFileTests.PinnedRead", code: 1)
            }
            return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
        })
        for request in requests { XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), request) }
        XCTAssertThrowsError(try store.takePendingRequest(referenceDate: date(101)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL(unreadable).path))
        assertDescriptorsClosed(probe.descriptors)
    }

    func testSnapshotAdmissionIsProcessWideAndHeldUntilActualReadCompletion() throws {
        try finishMigrationForSnapshotTests()
        let original = makeRequest(at: 100)
        try makeStore().save(original)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let results = RequestResults()
        let probes = (0..<FinderAuthorizationRequestStore.maximumConcurrentSnapshots).map { _ in PinnedReadProbe() }
        defer { for _ in probes { release.signal() }; _ = finished.wait(timeout: .now() + 5) }
        for probe in probes {
            let store = makeStore(readPinnedRequestData: { descriptor, url in
                if probe.record(descriptor, url: url) == 1 {
                    entered.signal()
                    release.wait()
                }
                return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
            })
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                do { if let request = try store.takePendingRequest(referenceDate: Date(timeIntervalSince1970: 101)) {
                    results.append(request.id)
                } } catch { results.append(error) }
            }
        }
        for _ in probes { XCTAssertEqual(entered.wait(timeout: .now() + 5), .success) }
        // A different directory and store share the same process admission. With
        // both real reads still blocked, the third caller must use locked fallback.
        let otherDirectory = directoryURL.appendingPathComponent("other-queue", isDirectory: true)
        let otherProbe = PinnedReadProbe()
        let other = FinderAuthorizationRequestStore(defaults: nil, directoryURL: otherDirectory,
            readPinnedRequestData: otherProbe.read)
        XCTAssertNil(try other.takePendingRequest(referenceDate: date(101)))
        let otherRequest = makeRequest(at: 100)
        try other.save(otherRequest)
        XCTAssertEqual(try other.takePendingRequest(referenceDate: date(101)), otherRequest)
        XCTAssertEqual(otherProbe.count, 0)
        // Bound the wait before releasing readers, so a regression that holds
        // flock during a read fails this assertion instead of hanging the test.
        let fallback = makeStore()
        let fallbackResults = RequestResults()
        let fallbackFinished = DispatchSemaphore(value: 0)
        finished.enter()
        DispatchQueue.global().async {
            defer { fallbackFinished.signal(); finished.leave() }
            do { if let request = try fallback.takePendingRequest(referenceDate: Date(timeIntervalSince1970: 101)) {
                fallbackResults.append(request.id)
            } } catch { fallbackResults.append(error) }
        }
        let fallbackProgress = fallbackFinished.wait(timeout: .now() + 5)
        for _ in probes { release.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(fallbackProgress, .success)
        XCTAssertEqual(fallbackResults.ids, [original.id])
        XCTAssertTrue(fallbackResults.errors.isEmpty, "\(fallbackResults.errors)")
        XCTAssertTrue(results.errors.isEmpty, "\(results.errors)")
        XCTAssertTrue(results.ids.isEmpty, "The blocked snapshots must revalidate the fallback consumer's claim")
        for probe in probes { assertDescriptorsClosed(probe.descriptors) }
        try other.save(otherRequest)
        XCTAssertEqual(try other.takePendingRequest(referenceDate: date(101)), otherRequest)
        XCTAssertEqual(otherProbe.count, 1, "Actual completion releases admission")
    }

    func testUnfinishedMigrationAndHistoricalOversizedQueueUseLockedFallback() throws {
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: probe.read)
        let legacy = makeRequest(at: 99)
        defaults.set(try JSONEncoder().encode(legacy), forKey: "finderAuthorizationRequest.v1")
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), legacy)
        XCTAssertEqual(probe.count, 0)
        let requests = (0..<65).map { makeRequest(at: 100 + Double($0)) }
        for request in requests { try writeUsingBuild43Protocol(request) }
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), requests[0])
        XCTAssertEqual(probe.count, 0)
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(200)), requests[1])
        XCTAssertEqual(probe.count, 64, "Exactly 64 entries can enter the normal pinned path")
        assertDescriptorsClosed(probe.descriptors)
    }

    func testSymbolicLinkIdentityAmbiguityFallsBackWithoutDeletingTarget() throws {
        try finishMigrationForSnapshotTests()
        let request = makeRequest(at: 100)
        try makeStore().save(request)
        let target = directoryURL.appendingPathComponent("sentinel")
        let alias = directoryURL.appendingPathComponent("\(UUID().uuidString).json")
        let bytes = Data("do not delete".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: probe.read)
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), request)
        XCTAssertEqual(probe.count, 0, "No payload reads begin until every descriptor is safely pinned")
        XCTAssertThrowsError(try store.takePendingRequest(referenceDate: date(101)))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), target.path)
    }

    func testLateExpiryBeforeClaimIsRecheckedOnPinnedAndLockedPaths() throws {
        for usePinned in [true, false] {
            try resetLegacyFixture()
            try finishMigrationForSnapshotTests()
            let request = makeRequest(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, at: 100)
            let later = makeRequest(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, at: 150)
            for item in [request, later] { try makeStore().save(item) }
            let clock = RequestTestClock(date(101))
            let probe = PinnedReadProbe()
            let store = makeStore(fileManager: SnapshotTestFileManager(), retentionInterval: 60,
                readRequestData: usePinned ? nil : { url in
                    let data = try FinderAuthorizationRequestStore.readBoundedRequest(at: url)
                    // Change the clock only after the first entry's age was checked.
                    if probe.record(-1, url: url) == 2 { clock.set(self.date(161)) }
                    return data
                },
                readPinnedRequestData: { descriptor, url in
                    let data = try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
                    if probe.record(descriptor, url: url) == 2 { clock.set(self.date(161)) }
                    return data
                }, currentDate: clock.now)
            XCTAssertEqual(try store.takePendingRequest(), later)
            XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL(request).path))
            XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(161)))
            assertDescriptorsClosed(probe.descriptors.filter { $0 >= 0 })
        }
    }

    func testClockMovingBackwardBeforeClaimPreservesFutureRequestOnBothPaths() throws {
        for usePinned in [true, false] {
            try resetLegacyFixture()
            try finishMigrationForSnapshotTests()
            let request = makeRequest(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, at: 100)
            let later = makeRequest(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, at: 101)
            for item in [request, later] { try makeStore().save(item) }
            let clock = RequestTestClock(date(102))
            let probe = PinnedReadProbe()
            let store = makeStore(fileManager: SnapshotTestFileManager(),
                readRequestData: usePinned ? nil : { url in
                    let bytes = try FinderAuthorizationRequestStore.readBoundedRequest(at: url)
                    if probe.record(-1, url: url) == 2 { clock.set(self.date(99)) }
                    return bytes
                }, readPinnedRequestData: { descriptor, url in
                    let bytes = try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
                    if probe.record(descriptor, url: url) == 2 { clock.set(self.date(99)) }
                    return bytes
                }, currentDate: clock.now)
            XCTAssertNil(try store.takePendingRequest())
            XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL(request).path))
            XCTAssertEqual(try drain(makeStore(), referenceDate: date(102)), [request, later])
            assertDescriptorsClosed(probe.descriptors.filter { $0 >= 0 })
        }
    }

    func testPinnedMalformedAndExpiredCleanupFailuresPreserveHealthyProgress() throws {
        for malformed in [true, false] {
            for removalFails in [true, false] {
                try resetLegacyFixture()
                try finishMigrationForSnapshotTests()
                let discarded = makeRequest(at: 1)
                let healthy = makeRequest(at: 100)
                for request in [discarded, healthy] { try makeStore().save(request) }
                if malformed { try Data("malformed".utf8).write(to: requestURL(discarded), options: .atomic) }
                let original = try Data(contentsOf: requestURL(discarded))
                let probe = PinnedReadProbe()
                let fileManager: FileManager = removalFails
                    ? FailingRequestRemovalFileManager(filename: requestURL(discarded).lastPathComponent) : .default
                let store = makeStore(fileManager: fileManager, retentionInterval: 60, readPinnedRequestData: probe.read)
                XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), healthy)
                XCTAssertEqual(probe.count, 2)
                if removalFails {
                    XCTAssertEqual(try Data(contentsOf: requestURL(discarded)), original)
                    XCTAssertThrowsError(try store.takePendingRequest(referenceDate: date(101)))
                } else {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL(discarded).path))
                    XCTAssertNil(try store.takePendingRequest(referenceDate: date(101)))
                }
                assertDescriptorsClosed(probe.descriptors)
            }
        }
    }

    func testPinnedOversizedReadRetainsBytesAndAllowsHealthyClaim() throws {
        try finishMigrationForSnapshotTests()
        let oversized = makeRequest(at: 99)
        let healthy = makeRequest(at: 100)
        try makeStore().save(healthy)
        let bytes = Data(repeating: 0x20, count: FinderAuthorizationRequestStore.maximumRequestBytes + 1)
        try bytes.write(to: requestURL(oversized), options: .atomic)
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: probe.read)
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), healthy)
        XCTAssertEqual(probe.count, 2)
        assertRetainedOversizedError { try store.takePendingRequest(referenceDate: date(101)) }
        XCTAssertEqual(try Data(contentsOf: requestURL(oversized)), bytes)
        assertDescriptorsClosed(probe.descriptors)
    }

    func testPartialPinFailureClosesEarlierDescriptorsBeforeLockedFallback() throws {
        try finishMigrationForSnapshotTests()
        let healthy = makeRequest(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, at: 100)
        try makeStore().save(healthy)
        let healthyURL = requestURL(healthy)
        let nonregular = directoryURL.appendingPathComponent("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF.json")
        try FileManager.default.createDirectory(at: nonregular, withIntermediateDirectories: false)
        var metadata = stat()
        XCTAssertEqual(stat(healthyURL.path, &metadata), 0)
        let device = metadata.st_dev
        let inode = metadata.st_ino
        let probe = PinnedReadProbe()
        // Sorted enumeration ensures the healthy descriptor is pinned before the
        // directory's nonregular descriptor forces fallback.
        let store = makeStore(fileManager: SnapshotTestFileManager(), readPinnedRequestData: probe.read)
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), healthy)
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonregular.path))
        let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap(Int32.init)
        for descriptor in descriptors {
            var openMetadata = stat()
            if fstat(descriptor, &openMetadata) == 0 {
                XCTAssertFalse(openMetadata.st_dev == device && openMetadata.st_ino == inode,
                    "A partially pinned descriptor must not remain open after fallback")
            }
        }
    }

    func testFinalEnumerationFailureClosesDescriptorsAndReleasesAdmission() throws {
        try finishMigrationForSnapshotTests()
        let request = makeRequest(at: 100)
        try makeStore().save(request)
        let failure = NSError(domain: "QuickFileTests.FinalEnumeration", code: 1)
        let fileManager = SnapshotTestFileManager(afterListing: { count, urls in
            if count.isMultiple(of: 2) { throw failure }
            return urls
        })
        let probe = PinnedReadProbe()
        let store = makeStore(fileManager: fileManager, readPinnedRequestData: probe.read)
        for _ in 0..<(FinderAuthorizationRequestStore.maximumConcurrentSnapshots + 2) {
            XCTAssertThrowsError(try store.takePendingRequest(referenceDate: date(101))) { error in
                guard case let FinderAuthorizationRequestStore.StoreError.persistenceFailed(underlying) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(underlying as NSError, failure)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL(request).path))
            assertDescriptorsClosed(probe.descriptors)
        }
        XCTAssertEqual(probe.count, FinderAuthorizationRequestStore.maximumConcurrentSnapshots + 2)
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(101)), request)
    }

    func testFinalStatAmbiguityFallsBackWithoutReturningStaleRequest() throws {
        try finishMigrationForSnapshotTests()
        let request = makeRequest(at: 100)
        try makeStore().save(request)
        let fileManager = SnapshotTestFileManager(afterListing: { count, urls in
            if count == 2 {
                // Return the just-enumerated set, but force final lstat to fail.
                // This fault fixture deliberately goes beyond cooperative writers.
                try FileManager.default.removeItem(at: self.requestURL(request))
            }
            return urls
        })
        let probe = PinnedReadProbe()
        let store = makeStore(fileManager: fileManager, readPinnedRequestData: probe.read)
        XCTAssertNil(try store.takePendingRequest(referenceDate: date(101)))
        XCTAssertEqual(probe.count, 1)
        assertDescriptorsClosed(probe.descriptors)
    }

    func testClockJumpDuringSuccessfulRemovalStillReturnsCommittedClaim() throws {
        for usePinned in [true, false] {
            try resetLegacyFixture()
            try finishMigrationForSnapshotTests()
            let request = makeRequest(at: 100)
            try makeStore().save(request)
            let clock = RequestTestClock(date(101))
            let fileManager = SnapshotTestFileManager(beforeRemoval: { _ in clock.set(self.date(99)) })
            let lockedReader: ((URL) throws -> Data)? = usePinned ? nil : {
                try FinderAuthorizationRequestStore.readBoundedRequest(at: $0)
            }
            let store = makeStore(fileManager: fileManager, readRequestData: lockedReader, currentDate: clock.now)
            XCTAssertEqual(try store.takePendingRequest(), request)
            XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL(request).path))
        }
    }

    func testRecoveryInspectionIsBoundedReadOnlyAndExposesOnlySafeClasses() throws {
        let malformed = try recoveryFixture(Data("not json /private/path".utf8))
        let oversized = try recoveryFixture(Data(repeating: 32, count: FinderAuthorizationRequestStore.maximumRequestBytes + 1))
        let healthy = makeRequest(at: 100)
        let future = makeRequest(at: 300)
        let expired = makeRequest(at: -1000)
        for request in [healthy, future, expired] { try JSONEncoder().encode(request).write(to: requestURL(request)) }
        let legacy = Data(repeating: 32, count: FinderAuthorizationRequestStore.maximumLegacyInputBytes + 1)
        defaults.set(legacy, forKey: "finderAuthorizationRequest.v1")
        let before = try recoveryQueueBytes()
        let inspection = try makeStore().inspectRecoveryCandidates(referenceDate: date(101))
        let reasons = Dictionary(uniqueKeysWithValues: inspection.candidates.map { ($0.id, $0.reason) })
        XCTAssertEqual(reasons[malformed], .malformed)
        XCTAssertEqual(reasons[oversized], .oversized)
        XCTAssertEqual(reasons[future.id.uuidString], .futureDated)
        XCTAssertEqual(reasons[expired.id.uuidString], .expired)
        XCTAssertNil(reasons[healthy.id.uuidString])
        XCTAssertFalse(inspection.isTruncated)
        XCTAssertTrue(inspection.legacyRecoveryUnsupported)
        XCTAssertEqual(try recoveryQueueBytes(), before)
        XCTAssertEqual(defaults.data(forKey: "finderAuthorizationRequest.v1"), legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyMarkerURL.path))
    }

    func testRecoveryInspectionCapsHistoricalQueueAndActualPayloadReads() throws {
        for _ in 0..<70 { _ = try recoveryFixture(Data("malformed".utf8)) }
        let probe = PinnedReadProbe()
        let inspection = try makeStore(readPinnedRequestData: probe.read)
            .inspectRecoveryCandidates(referenceDate: date(101))
        XCTAssertTrue(inspection.isTruncated)
        XCTAssertEqual(inspection.candidates.count, FinderAuthorizationRequestStore.maximumPendingRequests)
        XCTAssertEqual(probe.count, FinderAuthorizationRequestStore.maximumPendingRequests)
        XCTAssertEqual(try queueFileCount(), 70)
        assertDescriptorsClosed(probe.descriptors)
    }

    func testRecoveryInspectionCapsUnrelatedDirectoryEntriesWithoutReadingPayloads() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        for index in 0..<300 {
            try Data().write(to: directoryURL.appendingPathComponent("unrelated-\(index)"))
        }
        let probe = PinnedReadProbe()
        let inspection = try makeStore(readPinnedRequestData: probe.read).inspectRecoveryCandidates()
        XCTAssertTrue(inspection.isTruncated)
        XCTAssertTrue(inspection.candidates.isEmpty)
        XCTAssertEqual(probe.count, 0)
    }

    func testRecoveryArchivesExactlyOneOriginalWithPrivateDirectoryAndSameInode() throws {
        let bytes = Data("malformed original including /private/path".utf8)
        let selected = try recoveryFixture(bytes)
        let retained = try recoveryFixture(Data("other".utf8))
        let source = directoryURL.appendingPathComponent(selected + ".json")
        var before = stat()
        XCTAssertEqual(lstat(source.path, &before), 0)
        let store = makeStore()
        let ticket = try store.prepareRecovery(candidateID: selected, referenceDate: date(101))
        let result = try store.commitRecovery(ticket, referenceDate: date(101))
        XCTAssertEqual(result.requestID, selected)
        XCTAssertFalse(result.durabilityWarning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.archiveURL)), bytes)
        XCTAssertEqual(try Data(contentsOf: directoryURL.appendingPathComponent(retained + ".json")), Data("other".utf8))
        var archived = stat(), archiveDirectory = stat()
        XCTAssertEqual(lstat(try XCTUnwrap(result.archiveURL).path, &archived), 0)
        XCTAssertEqual(archived.st_ino, before.st_ino)
        XCTAssertEqual(archived.st_dev, before.st_dev)
        XCTAssertEqual(lstat(try XCTUnwrap(result.archiveURL).deletingLastPathComponent().path, &archiveDirectory), 0)
        XCTAssertEqual(archiveDirectory.st_mode & 0o7777, 0o700)
        XCTAssertEqual(archiveDirectory.st_uid, geteuid())
        XCTAssertEqual(try queueFileCount(), 1)
        assertRecoveryError(.invalidTicket) { _ = try store.commitRecovery(ticket) }
    }

    func testRecoveryCancelPinsOriginalUntilCanceledAndDoesNotCreateArchive() throws {
        let selected = try recoveryFixture(Data("malformed".utf8))
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: probe.read)
        let before = try recoveryQueueBytes()
        let ticket = try store.prepareRecovery(candidateID: selected)
        let descriptor = try XCTUnwrap(probe.descriptors.first)
        XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
        assertRecoveryError(.busy) { _ = try makeStore().inspectRecoveryCandidates() }
        store.cancelRecovery(ticket)
        assertDescriptorsClosed([descriptor])
        store.cancelRecovery(ticket) // Must not over-signal the process-wide permit.
        XCTAssertEqual(try recoveryQueueBytes(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryArchiveURL.path))
        let next = try store.prepareRecovery(candidateID: selected)
        defer { store.cancelRecovery(next) }
        assertRecoveryError(.busy) { _ = try store.prepareRecovery(candidateID: selected) }
    }

    func testRecoveryPrepareRejectsHealthyRequestAndReleasesAdmission() throws {
        let healthy = makeRequest(at: 100)
        let store = makeStore()
        try store.save(healthy)
        assertRecoveryError(.healthyRequest) {
            _ = try store.prepareRecovery(candidateID: healthy.id.uuidString, referenceDate: date(101))
        }
        XCTAssertEqual(try JSONDecoder().decode(FinderAuthorizationRequest.self,
            from: Data(contentsOf: requestURL(healthy))), healthy)
        XCTAssertTrue(try store.inspectRecoveryCandidates(referenceDate: date(101)).candidates.isEmpty)
    }

    func testRecoveryFreshPrepareReclassifiesSelectedEntry() throws {
        let selected = try recoveryFixture(Data("malformed".utf8))
        let store = makeStore()
        XCTAssertEqual(try store.inspectRecoveryCandidates().candidates.first?.reason, .malformed)
        let bytes = Data(repeating: 32, count: FinderAuthorizationRequestStore.maximumRequestBytes + 1)
        try bytes.write(to: directoryURL.appendingPathComponent(selected + ".json"), options: .atomic)
        let ticket = try store.prepareRecovery(candidateID: selected)
        XCTAssertEqual(ticket.candidate.reason, .oversized)
        let result = try store.commitRecovery(ticket)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.archiveURL)), bytes)
    }

    func testRecoveryHealthyReplacementBetweenInspectionAndPrepareIsPreserved() throws {
        let request = makeRequest(at: 100)
        _ = try recoveryFixture(Data("malformed".utf8), id: request.id.uuidString)
        let store = makeStore()
        XCTAssertEqual(try store.inspectRecoveryCandidates(referenceDate: date(101)).candidates.count, 1)
        try writeUsingBuild43Protocol(request)
        assertRecoveryError(.healthyRequest) {
            _ = try store.prepareRecovery(candidateID: request.id.uuidString, referenceDate: date(101))
        }
        XCTAssertEqual(try JSONDecoder().decode(FinderAuthorizationRequest.self, from: Data(contentsOf: requestURL(request))), request)
    }

    func testRecoveryReplacementDuringPrepareReadsPinnedOriginalAndFailsClosed() throws {
        let original = Data("malformed pinned original".utf8)
        let request = makeRequest(at: 100)
        _ = try recoveryFixture(original, id: request.id.uuidString)
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: { descriptor, url in
            _ = probe.record(descriptor, url: url)
            try self.writeUsingBuild43Protocol(request)
            let data = try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
            XCTAssertEqual(data, original)
            return data
        })
        assertRecoveryError(.changed) {
            _ = try store.prepareRecovery(candidateID: request.id.uuidString, referenceDate: date(101))
        }
        assertDescriptorsClosed(probe.descriptors)
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(101)), request)
    }

    func testRecoveryAtomicReplacementAfterConfirmationNeverMovesNewSameID() throws {
        let request = makeRequest(at: 100)
        let original = Data("malformed original".utf8)
        _ = try recoveryFixture(original, id: request.id.uuidString)
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: probe.read)
        let ticket = try store.prepareRecovery(candidateID: request.id.uuidString, referenceDate: date(101))
        let descriptor = try XCTUnwrap(probe.descriptors.first)
        try writeUsingBuild43Protocol(request)
        XCTAssertEqual(lseek(descriptor, 0, SEEK_SET), 0)
        XCTAssertEqual(try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor), original)
        assertRecoveryError(.changed) { _ = try store.commitRecovery(ticket, referenceDate: date(101)) }
        assertDescriptorsClosed([descriptor])
        XCTAssertEqual(try JSONDecoder().decode(FinderAuthorizationRequest.self, from: Data(contentsOf: requestURL(request))), request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryArchiveURL.path))
    }

    func testRecoveryFutureEntryBecomingClaimableDuringConfirmationIsPreserved() throws {
        let request = makeRequest(at: 200)
        let store = makeStore()
        try store.save(request)
        let ticket = try store.prepareRecovery(candidateID: request.id.uuidString, referenceDate: date(100))
        XCTAssertEqual(ticket.candidate.reason, .futureDated)
        assertRecoveryError(.healthyRequest) { _ = try store.commitRecovery(ticket, referenceDate: date(201)) }
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(201)), request)
    }

    func testRecoveryExpiredEntryBecomingClaimableAfterClockChangeIsPreserved() throws {
        let request = makeRequest(at: 100)
        let store = makeStore()
        try store.save(request)
        let ticket = try store.prepareRecovery(candidateID: request.id.uuidString, referenceDate: date(1000))
        XCTAssertEqual(ticket.candidate.reason, .expired)
        assertRecoveryError(.healthyRequest) { _ = try store.commitRecovery(ticket, referenceDate: date(101)) }
        XCTAssertEqual(try store.takePendingRequest(referenceDate: date(101)), request)
    }

    func testRecoverySymlinkAndNonregularEntriesAreVisibleButCannotBePrepared() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let target = directoryURL.appendingPathComponent("target")
        try Data("sentinel".utf8).write(to: target)
        let symlink = UUID().uuidString, folder = UUID().uuidString, fifo = UUID().uuidString
        try FileManager.default.createSymbolicLink(at: directoryURL.appendingPathComponent(symlink + ".json"),
            withDestinationURL: target)
        try FileManager.default.createDirectory(at: directoryURL.appendingPathComponent(folder + ".json"),
            withIntermediateDirectories: false)
        XCTAssertEqual(mkfifo(directoryURL.appendingPathComponent(fifo + ".json").path, 0o600), 0)
        let store = makeStore()
        let candidates = try store.inspectRecoveryCandidates().candidates
        XCTAssertEqual(Set(candidates.map(\.id)), Set([symlink, folder, fifo]))
        XCTAssertTrue(candidates.allSatisfy { $0.reason == .unsafeEntry && !$0.canPrepare })
        for id in [symlink, folder, fifo] {
            assertRecoveryError(.unsafeEntry) { _ = try store.prepareRecovery(candidateID: id) }
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("sentinel".utf8))
    }

    func testRecoverySymlinkReplacementAfterPreparePreservesTarget() throws {
        let selected = try recoveryFixture(Data("malformed".utf8))
        let source = directoryURL.appendingPathComponent(selected + ".json")
        let target = directoryURL.appendingPathComponent("target")
        try Data("sentinel".utf8).write(to: target)
        let store = makeStore()
        let ticket = try store.prepareRecovery(candidateID: selected)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        assertRecoveryError(.changed) { _ = try store.commitRecovery(ticket) }
        XCTAssertEqual(try Data(contentsOf: target), Data("sentinel".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), target.path)
    }

    func testRecoveryRejectsHardlinksAndChangedMetadata() throws {
        let selected = try recoveryFixture(Data("malformed".utf8))
        let source = directoryURL.appendingPathComponent(selected + ".json")
        let alias = directoryURL.appendingPathComponent("hardlink")
        XCTAssertEqual(link(source.path, alias.path), 0)
        let store = makeStore()
        assertRecoveryError(.unsafeEntry) { _ = try store.prepareRecovery(candidateID: selected) }
        try FileManager.default.removeItem(at: alias)
        let ticket = try store.prepareRecovery(candidateID: selected)
        XCTAssertEqual(chmod(source.path, 0o400), 0)
        assertRecoveryError(.changed) { _ = try store.commitRecovery(ticket) }
        XCTAssertEqual(try Data(contentsOf: source), Data("malformed".utf8))
    }

    func testRecoveryUnreadableClassificationCannotProducePreparedLease() throws {
        let selected = try recoveryFixture(Data("malformed".utf8))
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: { descriptor, url in
            _ = probe.record(descriptor, url: url)
            throw NSError(domain: "private path must not surface", code: Int(EIO))
        })
        let candidate = try XCTUnwrap(store.inspectRecoveryCandidates().candidates.first)
        XCTAssertEqual(candidate.reason, .unreadable)
        XCTAssertFalse(candidate.canPrepare)
        assertRecoveryError(.unreadable) { _ = try store.prepareRecovery(candidateID: selected) }
        assertDescriptorsClosed(probe.descriptors)
        XCTAssertEqual(try queueFileCount(), 1)
        XCTAssertEqual(try makeStore().inspectRecoveryCandidates().candidates.count, 1)
    }

    func testRecoveryArchiveCollisionNeverOverwritesEitherOriginal() throws {
        let bytes = Data("selected original".utf8)
        let selected = try recoveryFixture(bytes)
        let name = UUID().uuidString
        try FileManager.default.createDirectory(at: recoveryArchiveURL, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let collision = recoveryArchiveURL.appendingPathComponent(name + ".original.json")
        try Data("prior archive".utf8).write(to: collision)
        let store = makeStore(recoveryArchiveName: { name })
        let ticket = try store.prepareRecovery(candidateID: selected)
        assertRecoveryError(.archiveFailed) { _ = try store.commitRecovery(ticket) }
        XCTAssertEqual(try Data(contentsOf: collision), Data("prior archive".utf8))
        XCTAssertEqual(try Data(contentsOf: directoryURL.appendingPathComponent(selected + ".json")), bytes)
        assertRecoveryError(.invalidTicket) { _ = try store.commitRecovery(ticket) }
    }

    func testRecoveryArchiveSymlinkAndNonprivateDirectoryFailWithoutMovingSource() throws {
        let selected = try recoveryFixture(Data("malformed".utf8))
        let target = directoryURL.appendingPathComponent("outside-archive")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: recoveryArchiveURL, withDestinationURL: target)
        let store = makeStore()
        var ticket = try store.prepareRecovery(candidateID: selected)
        assertRecoveryError(.archiveFailed) { _ = try store.commitRecovery(ticket) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        try FileManager.default.removeItem(at: recoveryArchiveURL)
        try FileManager.default.createDirectory(at: recoveryArchiveURL, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755])
        ticket = try store.prepareRecovery(candidateID: selected)
        assertRecoveryError(.archiveFailed) { _ = try store.commitRecovery(ticket) }
        XCTAssertEqual(try queueFileCount(), 1)
    }

    func testRecoveryPrecommitFailureLeavesLiveQueueBytesUnchangedAndReleasesLease() throws {
        let selected = try recoveryFixture(Data("malformed".utf8))
        _ = try recoveryFixture(Data("other".utf8))
        let before = try recoveryQueueBytes()
        let store = makeStore(recoveryCheckpoint: { point in
            if point == .beforeArchive { throw NSError(domain: "test archive unavailable", code: Int(EIO)) }
        })
        let ticket = try store.prepareRecovery(candidateID: selected)
        assertRecoveryError(.archiveFailed) { _ = try store.commitRecovery(ticket) }
        XCTAssertEqual(try recoveryQueueBytes(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryArchiveURL.path))
        XCTAssertEqual(try makeStore().inspectRecoveryCandidates().candidates.count, 2)
    }

    func testRecoveryPostcommitFailureReturnsCommittedWarningAndNeverConsumesReplacement() throws {
        let bytes = Data("malformed original".utf8)
        let selected = try recoveryFixture(bytes)
        let replacement = makeRequest(id: try XCTUnwrap(UUID(uuidString: selected)), at: 100)
        let store = makeStore(recoveryCheckpoint: { point in
            if point == .afterArchiveCommit {
                // Publication is direct in this seam because production holds flock.
                try JSONEncoder().encode(replacement).write(to: self.requestURL(replacement), options: .atomic)
                throw NSError(domain: "test postcommit fsync", code: Int(EIO))
            }
        })
        let ticket = try store.prepareRecovery(candidateID: selected, referenceDate: date(101))
        let result = try store.commitRecovery(ticket, referenceDate: date(101))
        XCTAssertTrue(result.durabilityWarning)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.archiveURL)), bytes)
        assertRecoveryError(.invalidTicket) { _ = try store.commitRecovery(ticket) }
        XCTAssertEqual(try makeStore().takePendingRequest(referenceDate: date(101)), replacement)
    }

    func testRecoveryLockReplacementAndDirectoryReplacementInvalidateTicket() throws {
        let selected = try recoveryFixture(Data("malformed".utf8))
        let store = makeStore()
        var ticket = try store.prepareRecovery(candidateID: selected)
        try Data().write(to: directoryURL.appendingPathComponent(".queue.lock"), options: .atomic)
        assertRecoveryError(.changed) { _ = try store.commitRecovery(ticket) }
        ticket = try store.prepareRecovery(candidateID: selected)
        let previous = directoryURL.appendingPathExtension("previous")
        defer { try? FileManager.default.removeItem(at: previous) }
        try FileManager.default.moveItem(at: directoryURL, to: previous)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        _ = try recoveryFixture(Data("replacement".utf8), id: selected)
        assertRecoveryError(.changed) { _ = try store.commitRecovery(ticket) }
        XCTAssertEqual(try Data(contentsOf: previous.appendingPathComponent(selected + ".json")), Data("malformed".utf8))
        XCTAssertEqual(try Data(contentsOf: directoryURL.appendingPathComponent(selected + ".json")), Data("replacement".utf8))
    }

    func testRecoveryPreservesExactLowercaseFilenameAndOtherCaseVariant() throws {
        let upper = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let lower = upper.lowercased()
        _ = try recoveryFixture(Data("upper original".utf8), id: upper)
        var upperStatus = stat()
        XCTAssertEqual(lstat(directoryURL.appendingPathComponent(upper + ".json").path, &upperStatus), 0)
        let lowerURL = directoryURL.appendingPathComponent(lower + ".json")
        var existingLower = stat()
        let caseSensitive = lstat(lowerURL.path, &existingLower) != 0
        if caseSensitive {
            _ = try recoveryFixture(Data("lower original".utf8), id: lower)
        } else {
            try FileManager.default.removeItem(at: directoryURL.appendingPathComponent(upper + ".json"))
            _ = try recoveryFixture(Data("lower original".utf8), id: lower)
        }
        let store = makeStore()
        let ids = try store.inspectRecoveryCandidates().candidates.map(\.id)
        XCTAssertTrue(ids.contains(lower))
        let ticket = try store.prepareRecovery(candidateID: lower)
        let result = try store.commitRecovery(ticket)
        XCTAssertEqual(result.requestID, lower)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.archiveURL)), Data("lower original".utf8))
        if caseSensitive {
            XCTAssertEqual(try Data(contentsOf: directoryURL.appendingPathComponent(upper + ".json")), Data("upper original".utf8))
        }
    }

    func testRecoveryKeepsAnyLegacyAcceptedUUIDSpellingExact() throws {
        let canonical = "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C"
        let spellings = [canonical, canonical.lowercased(), "abcdefAB-CDEF-abcd-EFAB-cdef0000000C",
            canonical.replacingOccurrences(of: "-", with: ""), "{" + canonical + "}", "urn:uuid:" + canonical]
        for spelling in spellings where UUID(uuidString: spelling) != nil {
            let bytes = Data(("malformed " + spelling).utf8)
            _ = try recoveryFixture(bytes, id: spelling)
            let store = makeStore()
            XCTAssertEqual(try store.inspectRecoveryCandidates().candidates.map(\.id), [spelling])
            let ticket = try store.prepareRecovery(candidateID: spelling)
            XCTAssertEqual(ticket.candidate.id, spelling)
            let receipt = try store.commitRecovery(ticket)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(receipt.archiveURL)), bytes)
        }
    }

    func testRecoveryActualBlockedIOKeepsGlobalAdmissionUntilItEnds() throws {
        _ = try recoveryFixture(Data("malformed".utf8))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let results = RequestResults()
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: { descriptor, url in
            _ = probe.record(descriptor, url: url)
            entered.signal()
            release.wait()
            return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
        })
        defer { release.signal(); _ = finished.wait(timeout: .now() + 5) }
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do { _ = try store.inspectRecoveryCandidates() } catch { results.append(error) }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let invalid = FinderAuthorizationRequestStore.PreparedRecovery(id: UUID(), candidate:
            .init(id: UUID().uuidString, reason: .malformed))
        store.cancelRecovery(invalid)
        for _ in 0..<3 { assertRecoveryError(.busy) { _ = try self.makeStore().inspectRecoveryCandidates() } }
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(results.errors.isEmpty)
        assertDescriptorsClosed(probe.descriptors)
        XCTAssertEqual(try makeStore().inspectRecoveryCandidates().candidates.count, 1)
    }

    func testRecoveryStaleCancelOrCommitCannotReleaseNewLeaseOrReusedDescriptor() throws {
        let selected = try recoveryFixture(Data("malformed".utf8))
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: probe.read)
        let old = try store.prepareRecovery(candidateID: selected)
        store.cancelRecovery(old)
        let current = try store.prepareRecovery(candidateID: selected)
        defer { store.cancelRecovery(current) }
        let descriptor = try XCTUnwrap(probe.descriptors.last)
        store.cancelRecovery(old)
        assertRecoveryError(.invalidTicket) { _ = try store.commitRecovery(old) }
        XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
        assertRecoveryError(.busy) { _ = try store.inspectRecoveryCandidates() }
        XCTAssertEqual(try queueFileCount(), 1)
    }

    func testRecoverySameBytesAtomicABANeverMatchesPinnedOriginalIdentity() throws {
        let original = Data("malformed A".utf8)
        let selected = try recoveryFixture(original)
        let source = directoryURL.appendingPathComponent(selected + ".json")
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: probe.read)
        let ticket = try store.prepareRecovery(candidateID: selected)
        let descriptor = try XCTUnwrap(probe.descriptors.last)
        var pinned = stat(), replacement = stat()
        XCTAssertEqual(fstat(descriptor, &pinned), 0)
        try Data("malformed B".utf8).write(to: source, options: .atomic)
        try original.write(to: source, options: .atomic)
        XCTAssertEqual(lstat(source.path, &replacement), 0)
        XCTAssertNotEqual(replacement.st_ino, pinned.st_ino, "The original open FD prevents inode reuse")
        assertRecoveryError(.changed) { _ = try store.commitRecovery(ticket) }
        XCTAssertEqual(try Data(contentsOf: source), original)
        assertDescriptorsClosed([descriptor])
    }

    func testRecoveryCancelDuringBlockedCommitCannotReleaseItsFDOrAdmission() throws {
        let selected = try recoveryFixture(Data("malformed".utf8))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let results = RequestResults()
        let probe = PinnedReadProbe()
        let store = makeStore(readPinnedRequestData: probe.read, recoveryCheckpoint: { point in
            if point == .beforeArchive { entered.signal(); release.wait() }
        })
        let ticket = try store.prepareRecovery(candidateID: selected)
        let descriptor = try XCTUnwrap(probe.descriptors.last)
        defer { release.signal(); _ = finished.wait(timeout: .now() + 5); store.cancelRecovery(ticket) }
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do { _ = try store.commitRecovery(ticket) } catch { results.append(error) }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        store.cancelRecovery(ticket)
        XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
        assertRecoveryError(.busy) { _ = try store.inspectRecoveryCandidates() }
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(results.errors.isEmpty)
        assertDescriptorsClosed([descriptor])
        XCTAssertTrue(try makeStore().inspectRecoveryCandidates().candidates.isEmpty)
    }

    func testRecoveryPostcommitQueueRelocationReturnsWarningWithoutInventingArchiveLocation() throws {
        let bytes = Data("malformed original".utf8)
        let selected = try recoveryFixture(bytes)
        let previous = directoryURL.appendingPathExtension("previous")
        defer { try? FileManager.default.removeItem(at: previous) }
        let store = makeStore(recoveryCheckpoint: { point in
            if point == .afterArchiveCommit {
                try FileManager.default.moveItem(at: self.directoryURL, to: previous)
                try FileManager.default.createDirectory(at: self.directoryURL, withIntermediateDirectories: false)
            }
        })
        let ticket = try store.prepareRecovery(candidateID: selected)
        let result = try store.commitRecovery(ticket)
        XCTAssertTrue(result.durabilityWarning)
        XCTAssertNil(result.archiveURL)
        let archive = previous.appendingPathComponent(".recovery-archive")
        let files = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), bytes)
        assertRecoveryError(.invalidTicket) { _ = try store.commitRecovery(ticket) }
    }

    func testRecoveryRejectsOtherUserWritableQueueOrSource() throws {
        let selected = try recoveryFixture(Data("malformed".utf8))
        let source = directoryURL.appendingPathComponent(selected + ".json")
        let store = makeStore()
        XCTAssertEqual(chmod(directoryURL.path, 0o777), 0)
        defer { chmod(directoryURL.path, 0o700); chmod(source.path, 0o600) }
        assertRecoveryError(.unsafeEntry) { _ = try store.prepareRecovery(candidateID: selected) }
        XCTAssertEqual(chmod(directoryURL.path, 0o700), 0)
        XCTAssertEqual(chmod(source.path, 0o666), 0)
        assertRecoveryError(.unsafeEntry) { _ = try store.prepareRecovery(candidateID: selected) }
        XCTAssertEqual(try Data(contentsOf: source), Data("malformed".utf8))
    }

    func testRecoveryRejectsACLGrantsOnQueueSourceAndPrivateArchive() throws {
        let selected = try recoveryFixture(Data("malformed".utf8))
        let source = directoryURL.appendingPathComponent(selected + ".json")
        try FileManager.default.createDirectory(at: recoveryArchiveURL, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let grant = try XCTUnwrap(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:read\n"))
        defer { acl_free(UnsafeMutableRawPointer(grant)) }
        let empty = try XCTUnwrap(acl_init(0))
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        let store = makeStore()
        for target in [directoryURL!, source] {
            XCTAssertEqual(acl_set_file(target.path, ACL_TYPE_EXTENDED, grant), 0)
            assertRecoveryError(.unsafeEntry) { _ = try store.prepareRecovery(candidateID: selected) }
            XCTAssertEqual(acl_set_file(target.path, ACL_TYPE_EXTENDED, empty), 0)
        }
        XCTAssertEqual(acl_set_file(recoveryArchiveURL.path, ACL_TYPE_EXTENDED, grant), 0)
        let ticket = try store.prepareRecovery(candidateID: selected)
        assertRecoveryError(.archiveFailed) { _ = try store.commitRecovery(ticket) }
        XCTAssertEqual(try Data(contentsOf: source), Data("malformed".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recoveryArchiveURL.path).isEmpty)
    }

    private var recoveryArchiveURL: URL { directoryURL.appendingPathComponent(".recovery-archive", isDirectory: true) }

    private func recoveryFixture(_ bytes: Data, id: String = UUID().uuidString) throws -> String {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try bytes.write(to: directoryURL.appendingPathComponent(id + ".json"), options: .atomic)
        return id
    }

    private func recoveryQueueBytes() throws -> [String: Data] {
        var values: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            values[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return values
    }

    private func assertRecoveryError(
        _ expected: FinderAuthorizationRequestStore.RecoveryError,
        file: StaticString = #filePath, line: UInt = #line, _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? FinderAuthorizationRequestStore.RecoveryError, expected, file: file, line: line)
        }
    }

    private func finishMigrationForSnapshotTests() throws {
        XCTAssertNil(try makeStore().takePendingRequest(referenceDate: date(101)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyMarkerURL.path))
    }

    private func assertDescriptorsClosed(_ descriptors: [Int32], file: StaticString = #filePath, line: UInt = #line) {
        for descriptor in Set(descriptors) {
            let result = fcntl(descriptor, F_GETFD)
            let error = errno
            XCTAssertEqual(result, -1, file: file, line: line)
            XCTAssertEqual(error, EBADF, file: file, line: line)
        }
    }

    // Protocol fixture copied from build 43's stable flock + atomic file publication.
    // This is not an installed old binary or a real mixed-version Finder exercise.
    private func writeUsingBuild43Protocol(_ request: FinderAuthorizationRequest) throws {
        try withBuild43QueueLock {
            try JSONEncoder().encode(request).write(to: requestURL(request), options: .atomic)
        }
    }

    // Healthy-entry subset of build 43's consumer; all payload reads stay under flock.
    private func takeUsingBuild43Protocol() throws -> FinderAuthorizationRequest? {
        return try withBuild43QueueLock { () throws -> FinderAuthorizationRequest? in
            let files: [URL] = try FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil
            )
            var pending: [(request: FinderAuthorizationRequest, url: URL)] = []
            for url in files {
                guard url.pathExtension == "json",
                      UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
                let data: Data = try FinderAuthorizationRequestStore.readBoundedRequest(at: url)
                let request: FinderAuthorizationRequest = try JSONDecoder().decode(
                    FinderAuthorizationRequest.self, from: data
                )
                pending.append((request: request, url: url))
            }
            pending.sort { left, right in
                if left.request.createdAt == right.request.createdAt {
                    return left.request.id.uuidString < right.request.id.uuidString
                }
                return left.request.createdAt < right.request.createdAt
            }
            guard let next = pending.first else { return nil }
            try FileManager.default.removeItem(at: next.url)
            return next.request
        }
    }

    private func withBuild43QueueLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let descriptor = open(directoryURL.appendingPathComponent(".queue.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        // Test-only bounded acquisition avoids self-deadlocking if production
        // accidentally moves the injected payload reader back inside flock.
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            guard error == EINTR || error == EWOULDBLOCK || error == EAGAIN else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
            }
            usleep(1_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func assertQueueFull(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case FinderAuthorizationRequestStore.StoreError.queueFull = error else {
                return XCTFail("Expected queueFull, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(error.localizedDescription.contains("64"), file: file, line: line)
        }
    }

    private func queueFileCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.count
    }

    private func drain(_ store: FinderAuthorizationRequestStore, referenceDate: Date) throws -> [FinderAuthorizationRequest] {
        var requests: [FinderAuthorizationRequest] = []
        while let request = try store.takePendingRequest(referenceDate: referenceDate) { requests.append(request) }
        return requests
    }

    private func requestURL(_ request: FinderAuthorizationRequest) -> URL {
        directoryURL.appendingPathComponent("\(request.id.uuidString).json")
    }

    private func makeStore(
        fileManager: FileManager = .default,
        retentionInterval: TimeInterval = 600,
        readRequestData: ((URL) throws -> Data)? = nil,
        decodeLegacyRequest: @escaping (Data) throws -> FinderAuthorizationRequest = {
            try JSONDecoder().decode(FinderAuthorizationRequest.self, from: $0)
        },
        readPinnedRequestData: @escaping (Int32, URL) throws -> Data = { descriptor, _ in
            try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
        },
        currentDate: @escaping () -> Date = Date.init,
        recoveryArchiveName: @escaping () -> String = { UUID().uuidString },
        recoveryCheckpoint: ((FinderAuthorizationRequestStore.RecoveryCheckpoint) throws -> Void)? = nil
    ) -> FinderAuthorizationRequestStore {
        FinderAuthorizationRequestStore(
            defaults: defaults,
            directoryURL: directoryURL,
            fileManager: fileManager,
            retentionInterval: retentionInterval,
            readRequestData: readRequestData,
            decodeLegacyRequest: decodeLegacyRequest,
            readPinnedRequestData: readPinnedRequestData,
            currentDate: currentDate,
            recoveryArchiveName: recoveryArchiveName,
            recoveryCheckpoint: recoveryCheckpoint
        )
    }

    private func makeRequest(id: UUID = UUID(), at timestamp: TimeInterval) -> FinderAuthorizationRequest {
        FinderAuthorizationRequest(
            id: id,
            templateID: UUID(),
            destinationFolder: URL(fileURLWithPath: "/tmp/QuickFile Target", isDirectory: true),
            createdAt: date(timestamp)
        )
    }

    private func date(_ timestamp: TimeInterval) -> Date {
        Date(timeIntervalSince1970: timestamp)
    }
}

private final class PublishingRequestFileManager: FileManager, @unchecked Sendable {
    private let directoryURL: URL
    private let destinationFolder: URL
    private(set) var publishedRequest: FinderAuthorizationRequest?

    init(directoryURL: URL, destinationFolder: URL) {
        self.directoryURL = directoryURL
        self.destinationFolder = destinationFolder
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if publishedRequest == nil {
            let request = FinderAuthorizationRequest(
                templateID: UUID(),
                destinationFolder: destinationFolder,
                createdAt: Date()
            )
            let fileURL = directoryURL.appendingPathComponent("\(request.id.uuidString).json")
            try JSONEncoder().encode(request).write(to: fileURL, options: .atomic)
            publishedRequest = request
        }
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
}

private final class RequestResults: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedIDs: [UUID] = []
    private var recordedErrors: [Error] = []

    var ids: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return recordedIDs
    }

    var errors: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return recordedErrors
    }

    func append(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        recordedIDs.append(id)
    }

    func append(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        recordedErrors.append(error)
    }
}

private final class FailingRequestRemovalFileManager: FileManager, @unchecked Sendable {
    private let filename: String
    let failure = NSError(domain: "QuickFileTests.RequestRemoval", code: 1)
    private(set) var failedRemovalCount = 0

    init(filename: String) {
        self.filename = filename
        super.init()
    }

    override func removeItem(at url: URL) throws {
        if url.lastPathComponent == filename {
            failedRemovalCount += 1
            throw failure
        }
        try super.removeItem(at: url)
    }
}

// This stateless FileManager test subclass only changes URL representation;
// filesystem operations retain FileManager's existing thread-safety contract.
private final class BaseRelativeRequestFileManager: FileManager, @unchecked Sendable {
    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask).map {
            URL(fileURLWithPath: $0.lastPathComponent, isDirectory: false, relativeTo: url)
        }
    }
}

// The injected decoder may be called from different store instances. Synchronize
// instrumentation rather than relying on the tests currently running serially.
private final class LegacyDecodeCounter {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func decode(_ data: Data) throws -> FinderAuthorizationRequest {
        lock.lock()
        value += 1
        lock.unlock()
        return try JSONDecoder().decode(FinderAuthorizationRequest.self, from: data)
    }
}

// All probe state can be accessed while a descriptor reader is blocked on another
// thread. Synchronize both readers and writers; the probe never owns the FD.
private final class PinnedReadProbe {
    private let lock = NSLock()
    private var recordedDescriptors: [Int32] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedDescriptors.count
    }

    var descriptors: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDescriptors
    }

    func record(_ descriptor: Int32, url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        recordedDescriptors.append(descriptor)
        return recordedDescriptors.count
    }

    func read(_ descriptor: Int32, _ url: URL) throws -> Data {
        _ = record(descriptor, url: url)
        return try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
    }
}

private final class RequestTestClock {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.date = date
    }
}

// Each instance is confined to one synchronous test operation. The only mutable
// counter is locked; hooks use synchronized clocks or are invoked synchronously.
private final class SnapshotTestFileManager: FileManager, @unchecked Sendable {
    private let counterLock = NSLock()
    private var listingCount = 0
    private let afterListing: (Int, [URL]) throws -> [URL]
    private let beforeRemoval: (URL) throws -> Void

    init(
        afterListing: @escaping (Int, [URL]) throws -> [URL] = { _, urls in urls },
        beforeRemoval: @escaping (URL) throws -> Void = { _ in }
    ) {
        self.afterListing = afterListing
        self.beforeRemoval = beforeRemoval
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        let urls = try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        counterLock.lock()
        listingCount += 1
        let count = listingCount
        counterLock.unlock()
        return try afterListing(count, urls)
    }

    override func removeItem(at url: URL) throws {
        try beforeRemoval(url)
        try super.removeItem(at: url)
    }
}
