import XCTest
@testable import QuickFileCore
@testable import QuickFileInfrastructure

final class AuthorizedDirectoryStoreTests: XCTestCase {
    private enum TestError: Error {
        case operationFailed
    }

    private enum AccessPause: CaseIterable, Sendable {
        case bookmarkResolution
        case scopeStart
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        suiteName = "QuickFileTests.AuthorizedDirectories.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickFileAuthorizedDirectories-\(UUID().uuidString)", isDirectory: true)
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
        temporaryDirectory = nil
        defaults = nil
        suiteName = nil
    }

    func testRepositoryReusesDecodeOnlyForExactAuthoritativeBytes() throws {
        let decodes = LockedTestValue(0)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory,
            didDecodeSnapshot: { decodes.update { $0 += 1 } })
        let record = StoredDirectoryAuthorization(id: UUID(),
            persistentBookmarkData: Data("persistent".utf8), transferBookmarkData: Data("transfer".utf8))
        try repository.update { $0 = [record] }
        let first = try repository.loadSnapshot()
        XCTAssertTrue(try repository.contains(record))
        XCTAssertTrue(try repository.contains(record))
        XCTAssertEqual(decodes.value, 1)

        let file = temporaryDirectory.appendingPathComponent("authorizedDirectories.v2.json")
        let replacement = StoredDirectoryAuthorization(id: record.id,
            persistentBookmarkData: record.persistentBookmarkData,
            transferBookmarkData: record.transferBookmarkData)
        // Same envelope generation is deliberately insufficient cache authority.
        let changed = AuthorizedDirectoryRepository.Snapshot(generation: first.generation, authorizations: [replacement])
        try JSONEncoder().encode(changed).write(to: file, options: .atomic)
        XCTAssertFalse(try repository.contains(record))
        XCTAssertTrue(try repository.contains(replacement))
        XCTAssertEqual(decodes.value, 2)

        let marker = temporaryDirectory.appendingPathComponent("authorizedDirectories.migrated")
        try FileManager.default.removeItem(at: marker)
        XCTAssertTrue(try repository.contains(replacement))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(decodes.value, 2, "A cache hit must still repair the migration marker")
        try Data("broken".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try repository.contains(replacement), "Never admit from cache after a corrupt read")
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try repository.load(), "A missing saved table cannot fall back to cached grants")
    }

    func testRepositoryDoesNotRetainLargeRawDecodeCache() throws {
        let decodes = LockedTestValue(0)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory,
            didDecodeSnapshot: { decodes.update { $0 += 1 } })
        let record = StoredDirectoryAuthorization(id: UUID(),
            persistentBookmarkData: Data(repeating: 0x61, count: 300 * 1024), transferBookmarkData: Data())
        try repository.update { $0 = [record] }
        XCTAssertEqual(try repository.load(), [record])
        XCTAssertEqual(try repository.load(), [record])
        XCTAssertEqual(decodes.value, 2)
    }

    func testRepositoryLegacyArrayRestorationGetsFreshGeneration() throws {
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let record = StoredDirectoryAuthorization(id: UUID(), persistentBookmarkData: Data(), transferBookmarkData: Data())
        let file = temporaryDirectory.appendingPathComponent("authorizedDirectories.v2.json")
        let bytes = try JSONEncoder().encode([record])
        try bytes.write(to: file, options: .atomic)
        let first = try repository.loadSnapshot()
        try bytes.write(to: file, options: .atomic)
        let second = try repository.loadSnapshot()
        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertEqual(second.authorizations, [record])
    }

    func testUnavailableSharedDefaultsProducesAnError() {
        let store = AuthorizedDirectoryStore(
            defaults: nil,
            persistentBookmarkCreator: { Data($0.path.utf8) },
            transferBookmarkCreator: { Data($0.path.utf8) },
            persistentBookmarkResolver: { data in
                let path = try XCTUnwrap(String(data: data, encoding: .utf8))
                return ResolvedSecurityScopedBookmark(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    isStale: false
                )
            },
            transferBookmarkResolver: { try Self.resolveTestBookmark($0) }
        )

        XCTAssertFalse(store.isAvailable)
        XCTAssertThrowsError(try store.authorize(temporaryDirectory)) { error in
            guard case AuthorizedDirectoryStore.StoreError.sharedDefaultsUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAuthorizesAndReloadsDirectory() throws {
        let store = makeStore()

        let authorization = try store.authorize(temporaryDirectory)
        let reloaded = try makeStore().loadAuthorizedDirectories()

        XCTAssertEqual(reloaded, [authorization])
    }

    func testReauthorizingSameDirectoryDoesNotDuplicateIt() throws {
        let store = makeStore()

        let first = try store.authorize(temporaryDirectory)
        let second = try store.authorize(temporaryDirectory)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try store.loadAuthorizedDirectories().count, 1)
    }

    func testReauthorizingSymlinkPreservesCanonicalDirectoryIdentity() throws {
        let child = temporaryDirectory.appendingPathComponent("Child", isDirectory: true)
        let alias = temporaryDirectory.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        let store = makeStore()
        let first = try store.authorize(child)

        let second = try store.authorize(alias)

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.url, first.url)
        XCTAssertEqual(try store.loadAuthorizedDirectories().count, 1)
    }

    func testNewGrantAndReauthorizationSkipBlockedUnrelatedHintedAndLegacyRecords() throws {
        let unrelated = temporaryDirectory.appendingPathComponent("Offline", isDirectory: true)
        let selected = temporaryDirectory.appendingPathComponent("Selected", isDirectory: true)
        for url in [unrelated, selected] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let original = try makeStore().authorize(unrelated)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let legacy = StoredDirectoryAuthorization(id: UUID(), persistentBookmarkData: Data(unrelated.path.utf8),
            transferBookmarkData: Data(unrelated.path.utf8))
        try repository.update { $0.append(legacy) }
        let originals = try repository.load()
        let release = DispatchSemaphore(value: 0)
        let shouldBlock = LockedTestValue(true)
        let unrelatedCalls = LockedTestValue(0)
        let selectedCalls = LockedTestValue(0)
        let store = makeStore(persistentBookmarkResolver: { data in
            let resolved = try Self.resolveTestBookmark(data)
            if resolved.url.path == unrelated.path {
                unrelatedCalls.update { $0 += 1 }
                if shouldBlock.value { _ = release.wait(timeout: .now() + 10) }
                throw TestError.operationFailed
            }
            selectedCalls.update { $0 += 1 }
            return resolved
        })
        let finished = expectation(description: "Both explicit grants finish while unrelated resolver is blocked")
        let workers = DispatchGroup()
        let selectedID = LockedTestValue<UUID?>(nil)
        workers.enter()
        DispatchQueue.global().async {
            defer { finished.fulfill(); workers.leave() }
            do {
                let first = try store.authorize(selected)
                let second = try store.authorize(selected)
                XCTAssertEqual(first.id, second.id)
                selectedID.value = second.id
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        // Always release and join even when the regression causes this wait to fail.
        wait(for: [finished], timeout: 2)
        shouldBlock.value = false
        release.signal()
        XCTAssertEqual(workers.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(unrelatedCalls.value, 0)
        XCTAssertEqual(selectedCalls.value, 1)
        let records = try repository.load()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(Array(records.prefix(2)), originals)
        XCTAssertEqual(records.first?.id, original.id)
        XCTAssertEqual(records.last?.id, selectedID.value)
    }

    func testRecreatedPathSkipsMovedGrantsBlockedResolverAndPreservesOldRecord() throws {
        let selected = temporaryDirectory.appendingPathComponent("Selected", isDirectory: true)
        let moved = temporaryDirectory.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let original = try makeStore().authorize(selected)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let originalRecord = try XCTUnwrap(repository.load().first)
        try FileManager.default.moveItem(at: selected, to: moved)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        XCTAssertNotEqual(originalRecord.directoryIdentityHint, try DirectoryIdentity.capture(at: selected))
        let release = DispatchSemaphore(value: 0)
        let shouldBlock = LockedTestValue(true)
        let resolverCalls = LockedTestValue(0)
        let store = makeStore(persistentBookmarkResolver: { _ in
            resolverCalls.update { $0 += 1 }
            if shouldBlock.value { _ = release.wait(timeout: .now() + 10) }
            return ResolvedSecurityScopedBookmark(url: moved, isStale: false)
        })
        let finished = expectation(description: "Recreated target authorizes without resolving moved/offline grant")
        let workers = DispatchGroup()
        let selectedID = LockedTestValue<UUID?>(nil)
        workers.enter()
        DispatchQueue.global().async {
            defer { finished.fulfill(); workers.leave() }
            do { selectedID.value = try store.authorize(selected).id }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        wait(for: [finished], timeout: 2)
        shouldBlock.value = false
        release.signal()
        XCTAssertEqual(workers.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(resolverCalls.value, 0)
        XCTAssertNotNil(selectedID.value)
        XCTAssertNotEqual(selectedID.value, original.id)
        let records = try repository.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first, originalRecord)
        XCTAssertEqual(records.last?.directoryIdentityHint, try DirectoryIdentity.capture(at: selected))
    }

    func testPathOnlyLegacyHintDoesNotResolveOrReplaceExistingRecord() throws {
        let pathOnly = StoredDirectoryAuthorization(id: UUID(),
            persistentBookmarkData: Data(temporaryDirectory.path.utf8),
            transferBookmarkData: Data(temporaryDirectory.path.utf8),
            canonicalPathHint: temporaryDirectory.resolvingSymlinksInPath().path)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        try repository.update { $0.append(pathOnly) }
        let store = makeStore(persistentBookmarkResolver: { _ in
            XCTFail("A matching path without an identity hint is not a dedup candidate")
            throw TestError.operationFailed
        })

        let selected = try store.authorize(temporaryDirectory)

        XCTAssertNotEqual(selected.id, pathOnly.id)
        XCTAssertEqual(try repository.load().first, pathOnly)
        XCTAssertEqual(try repository.load().count, 2)
    }

    func testLiveIdentityChangeDuringCandidateResolutionRejectsAuthorizationWithoutChangingRecords() throws {
        let selected = temporaryDirectory.appendingPathComponent("Selected", isDirectory: true)
        let moved = temporaryDirectory.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        try makeStore().authorize(selected)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let original = try repository.loadSnapshot()

        assertAuthorizationConflictsDuringResolution(selected) {
            try FileManager.default.moveItem(at: selected, to: moved)
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        }

        XCTAssertEqual(try repository.loadSnapshot(), original)
    }

    func testSelectedSymlinkRetargetingDuringBookmarkCreationRejectsAuthorization() throws {
        let original = temporaryDirectory.appendingPathComponent("Original", isDirectory: true)
        let replacement = temporaryDirectory.appendingPathComponent("Replacement", isDirectory: true)
        let selected = temporaryDirectory.appendingPathComponent("Selected", isDirectory: true)
        for url in [original, replacement] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: original)
        let store = makeStore(persistentBookmarkCreator: { url in
            try FileManager.default.removeItem(at: selected)
            try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: replacement)
            return Data(url.path.utf8)
        })

        XCTAssertThrowsError(try store.authorize(selected)) { error in
            guard case AuthorizedDirectoryStoreError.authorizationChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(try store.loadAuthorizedDirectories().isEmpty)
    }

    func testExactPathHintRequiresLiveResolutionBeforeReusingRecordIdentity() throws {
        let actual = temporaryDirectory.appendingPathComponent("Actual", isDirectory: true)
        let hinted = temporaryDirectory.appendingPathComponent("Hinted", isDirectory: true)
        for url in [actual, hinted] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let wrongHint = StoredDirectoryAuthorization(id: UUID(), persistentBookmarkData: Data(actual.path.utf8),
            transferBookmarkData: Data(actual.path.utf8),
            canonicalPathHint: hinted.resolvingSymlinksInPath().path,
            directoryIdentityHint: try DirectoryIdentity.capture(at: hinted))
        try repository.update { $0.append(wrongHint) }
        let resolverCalls = LockedTestValue(0)
        let store = makeStore(persistentBookmarkResolver: { data in
            resolverCalls.update { $0 += 1 }
            return try Self.resolveTestBookmark(data)
        })

        let selected = try store.authorize(hinted)

        XCTAssertEqual(resolverCalls.value, 1)
        XCTAssertNotEqual(selected.id, wrongHint.id)
        XCTAssertEqual(try repository.load().first, wrongHint)
        XCTAssertThrowsError(try store.withAccess(to: hinted, authorizationID: wrongHint.id) {
            XCTFail("A matching hint cannot authorize another directory")
        }) { error in
            guard case AuthorizedDirectoryStoreError.directoryNotAuthorized = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNoThrow(try store.withAccess(to: hinted, authorizationID: selected.id) {})
    }

    func testUnhintedLegacySameDirectoryIsPreservedDuringExplicitAuthorization() throws {
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "bookmarkData": Data(temporaryDirectory.path.utf8).base64EncodedString()
        ])
        let legacy = try JSONDecoder().decode(StoredDirectoryAuthorization.self, from: legacyData)
        XCTAssertNil(legacy.canonicalPathHint)
        XCTAssertNil(legacy.revision)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        try repository.update { $0.append(legacy) }
        let store = makeStore(persistentBookmarkResolver: { _ in
            XCTFail("Unhinted legacy grants must not be scanned during explicit authorization")
            throw TestError.operationFailed
        })

        let fresh = try store.authorize(temporaryDirectory)

        XCTAssertNotEqual(fresh.id, legacy.id)
        XCTAssertEqual(try repository.load().first, legacy)
        XCTAssertEqual(try repository.load().count, 2)
        // Removing one record does not silently remove any retained overlapping grant.
        XCTAssertTrue(try store.revoke(fresh.id))
        XCTAssertEqual(try repository.load(), [legacy])
        XCTAssertThrowsError(try store.withAccess(to: temporaryDirectory, authorizationID: fresh.id) {})
    }

    func testMalformedOptionalHintsDecodeAsAbsentWithoutChangingGrantIdentity() throws {
        let id = UUID()
        let revision = UUID()
        let malformedHints: [Any] = [17, ["unexpected": "object"], ["array"], NSNull()]
        for hint in malformedHints {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": id.uuidString, "revision": revision.uuidString,
                "persistentBookmarkData": Data("persistent".utf8).base64EncodedString(),
                "transferBookmarkData": Data("transfer".utf8).base64EncodedString(),
                "canonicalPathHint": hint,
                "directoryIdentityHint": hint
            ])
            let record = try JSONDecoder().decode(StoredDirectoryAuthorization.self, from: data)
            XCTAssertEqual(record.id, id)
            XCTAssertEqual(record.revision, revision)
            XCTAssertEqual(record.persistentBookmarkData, Data("persistent".utf8))
            XCTAssertEqual(record.transferBookmarkData, Data("transfer".utf8))
            XCTAssertNil(record.canonicalPathHint)
            XCTAssertNil(record.directoryIdentityHint)
        }
    }

    func testUnavailableHintedGrantStillFailsClosedDuringAccess() throws {
        let authorization = try makeStore().authorize(temporaryDirectory)
        let unavailable = makeStore(transferBookmarkResolver: { _ in throw TestError.operationFailed })

        XCTAssertThrowsError(try unavailable.withAccess(to: temporaryDirectory, authorizationID: authorization.id) {
            XCTFail("The path hint must never bypass a failed live bookmark")
        }) { error in
            guard case AuthorizedDirectoryStoreError.bookmarkResolutionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPausedAuthorizationAllowsLoadAndRevocationWithoutRestoringRevokedRecord() throws {
        let otherStore = makeStore()
        let original = try otherStore.authorize(temporaryDirectory)

        assertAuthorizationConflictsDuringResolution(temporaryDirectory) {
            XCTAssertEqual(try otherStore.loadAuthorizedDirectories(), [original])
            XCTAssertTrue(try otherStore.revoke(original.id))
            XCTAssertTrue(try otherStore.loadAuthorizedDirectories().isEmpty)
        }

        XCTAssertTrue(try otherStore.loadAuthorizedDirectories().isEmpty)
        let explicitlyReauthorized = try otherStore.authorize(temporaryDirectory)
        XCTAssertNotEqual(explicitlyReauthorized.id, original.id)
        XCTAssertEqual(try otherStore.loadAuthorizedDirectories(), [explicitlyReauthorized])
    }

    func testAuthorizationAnalysisDoesNotOverwriteNewerRevisionOrNewDirectory() throws {
        let otherStore = makeStore()
        let original = try otherStore.authorize(temporaryDirectory)
        let child = temporaryDirectory.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let originalRecord = try XCTUnwrap(repository.load().first)
        let newerRecords = LockedTestValue<[StoredDirectoryAuthorization]>([])

        let directoryURL = try XCTUnwrap(temporaryDirectory)
        assertAuthorizationConflictsDuringResolution(directoryURL) {
            XCTAssertEqual(try otherStore.authorize(directoryURL).id, original.id)
            let replacement = try XCTUnwrap(repository.load().first)
            XCTAssertEqual(replacement.persistentBookmarkData, originalRecord.persistentBookmarkData)
            XCTAssertEqual(replacement.transferBookmarkData, originalRecord.transferBookmarkData)
            XCTAssertNotEqual(replacement.revision, originalRecord.revision)
            try otherStore.authorize(child)
            newerRecords.value = try repository.load()
        }

        XCTAssertEqual(try repository.load(), newerRecords.value)
        XCTAssertEqual(newerRecords.value.count, 2)
    }

    func testAuthorizationAnalysisDoesNotReplaceConcurrentRevokeAndReauthorization() throws {
        let otherStore = makeStore()
        let original = try otherStore.authorize(temporaryDirectory)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let replacement = LockedTestValue<StoredDirectoryAuthorization?>(nil)

        let directoryURL = try XCTUnwrap(temporaryDirectory)
        assertAuthorizationConflictsDuringResolution(directoryURL) {
            XCTAssertTrue(try otherStore.revoke(original.id))
            let reauthorized = try otherStore.authorize(directoryURL)
            XCTAssertNotEqual(reauthorized.id, original.id)
            replacement.value = try XCTUnwrap(repository.load().first)
        }

        XCTAssertEqual(try repository.load(), [try XCTUnwrap(replacement.value)])
    }

    func testConcurrentFirstAuthorizationsOfSameDirectoryCommitOnlyOnce() throws {
        let creationStarted = expectation(description: "Both authorizations have a snapshot")
        creationStarted.expectedFulfillmentCount = 2
        let firstFinished = expectation(description: "First authorization committed")
        let secondFinished = expectation(description: "Second authorization reported conflict")
        let resumeFirst = DispatchSemaphore(value: 0)
        let resumeSecond = DispatchSemaphore(value: 0)
        let firstStore = makeStore(persistentBookmarkCreator: { url in
            creationStarted.fulfill()
            guard resumeFirst.wait(timeout: .now() + 10) == .success else {
                throw TestError.operationFailed
            }
            return Data(url.path.utf8)
        })
        let secondStore = makeStore(persistentBookmarkCreator: { url in
            creationStarted.fulfill()
            guard resumeSecond.wait(timeout: .now() + 10) == .success else {
                throw TestError.operationFailed
            }
            return Data(url.path.utf8)
        })
        let directoryURL = try XCTUnwrap(temporaryDirectory)
        let workers = DispatchGroup()
        defer {
            resumeFirst.signal()
            resumeSecond.signal()
            XCTAssertEqual(workers.wait(timeout: .now() + 5), .success)
        }
        workers.enter()
        DispatchQueue.global().async {
            defer {
                firstFinished.fulfill()
                workers.leave()
            }
            do {
                try firstStore.authorize(directoryURL)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        workers.enter()
        DispatchQueue.global().async {
            defer {
                secondFinished.fulfill()
                workers.leave()
            }
            do {
                try secondStore.authorize(directoryURL)
                XCTFail("Concurrent authorization should report a conflict")
            } catch {
                guard case AuthorizedDirectoryStoreError.authorizationChanged = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        wait(for: [creationStarted], timeout: 2)
        resumeFirst.signal()
        wait(for: [firstFinished], timeout: 2)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let committedRecords = try repository.load()
        resumeSecond.signal()
        wait(for: [secondFinished], timeout: 2)

        XCTAssertEqual(committedRecords.count, 1)
        XCTAssertEqual(try repository.load(), committedRecords)
        let explicitlyReauthorized = try makeStore().authorize(directoryURL)
        XCTAssertEqual(explicitlyReauthorized.id, committedRecords.first?.id)
        XCTAssertEqual(try repository.load().count, 1)
    }

    func testAuthorizationConflictDoesNotTriggerAutomaticAuthorizationRequest() {
        let error = AuthorizedDirectoryStoreError.authorizationChanged

        XCTAssertFalse(AuthorizedDirectoryFailureClassifier.requiresAuthorization(error))
        XCTAssertEqual(AuthorizedDirectoryFailureClassifier.activityFailure(error)?.reason,
                       .authorizationUnavailable)
        XCTAssertNil(error.underlyingError)
    }

    func testPausedFirstAuthorizationRejectsInsertThenRevokeABA() throws {
        let creationStarted = expectation(description: "Authorization with an empty snapshot is paused")
        let authorizationFinished = expectation(description: "Old authorization reported conflict")
        let resumeCreation = DispatchSemaphore(value: 0)
        let workers = DispatchGroup()
        let store = makeStore(persistentBookmarkCreator: { url in
            creationStarted.fulfill()
            guard resumeCreation.wait(timeout: .now() + 10) == .success else {
                throw TestError.operationFailed
            }
            return Data(url.path.utf8)
        })
        let directoryURL = try XCTUnwrap(temporaryDirectory)
        defer {
            resumeCreation.signal()
            XCTAssertEqual(workers.wait(timeout: .now() + 5), .success)
        }
        workers.enter()
        DispatchQueue.global().async {
            defer {
                authorizationFinished.fulfill()
                workers.leave()
            }
            do {
                try store.authorize(directoryURL)
                XCTFail("Insert-then-revoke must invalidate the old empty snapshot")
            } catch {
                guard case AuthorizedDirectoryStoreError.authorizationChanged = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        wait(for: [creationStarted], timeout: 2)
        let otherStore = makeStore()
        let inserted = try otherStore.authorize(directoryURL)
        XCTAssertTrue(try otherStore.revoke(inserted.id))
        XCTAssertTrue(try otherStore.loadAuthorizedDirectories().isEmpty)
        resumeCreation.signal()
        wait(for: [authorizationFinished], timeout: 2)

        XCTAssertTrue(try otherStore.loadAuthorizedDirectories().isEmpty)
        let explicitlyReauthorized = try otherStore.authorize(directoryURL)
        XCTAssertNotEqual(explicitlyReauthorized.id, inserted.id)
        XCTAssertEqual(try otherStore.loadAuthorizedDirectories(), [explicitlyReauthorized])
    }

    func testRevokesAuthorization() throws {
        let store = makeStore()
        let authorization = try store.authorize(temporaryDirectory)

        XCTAssertTrue(try store.revoke(authorization.id))
        XCTAssertTrue(try store.loadAuthorizedDirectories().isEmpty)
        XCTAssertFalse(try store.revoke(authorization.id))
    }

    func testAllowsAccessToAuthorizedDescendant() throws {
        let nestedDirectory = temporaryDirectory.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let startedURLs = LockedTestValue<[URL]>([])
        let stoppedURLs = LockedTestValue<[URL]>([])
        let store = makeStore(
            startAccessing: { url in
                startedURLs.update { $0.append(url) }
                return true
            },
            stopAccessing: { url in
                stoppedURLs.update { $0.append(url) }
            }
        )
        let authorization = try store.authorize(temporaryDirectory)

        let result = try store.withAccess(to: nestedDirectory) {
            "created"
        }

        XCTAssertEqual(result, "created")
        XCTAssertEqual(startedURLs.value, [authorization.url])
        XCTAssertEqual(stoppedURLs.value, [authorization.url])
    }

    func testPausedAccessRejectsRevocationBeforeAdmission() throws {
        for pause in AccessPause.allCases {
            let directory = try accessDirectory(for: pause)
            let otherStore = makeStore()
            let original = try otherStore.authorize(directory)

            try assertAccessDuringPause(
                pause, to: directory,
                expectedStartedURLs: pause == .scopeStart ? [original.url] : [],
                expectAccess: false
            ) {
                XCTAssertTrue(try otherStore.revoke(original.id))
                XCTAssertTrue(try otherStore.loadAuthorizedDirectories().isEmpty)
            }
        }
    }

    func testPausedAccessDoesNotUseNewAuthorizationAfterRevoke() throws {
        for pause in AccessPause.allCases {
            let directory = try accessDirectory(for: pause)
            let otherStore = makeStore()
            let original = try otherStore.authorize(directory)

            try assertAccessDuringPause(
                pause, to: directory,
                expectedStartedURLs: pause == .scopeStart ? [original.url] : [],
                expectAccess: false
            ) {
                XCTAssertTrue(try otherStore.revoke(original.id))
                XCTAssertNotEqual(try otherStore.authorize(directory).id, original.id)
            }
            // A subsequent explicit access can use the new authorization.
            XCTAssertNoThrow(try otherStore.withAccess(to: directory) {})
        }
    }

    func testPausedAccessRejectsNewRevisionWithIdenticalBookmarkData() throws {
        for pause in AccessPause.allCases {
            let directory = try accessDirectory(for: pause)
            let otherStore = makeStore()
            let original = try otherStore.authorize(directory)
            let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
            let originalRecord = try XCTUnwrap(repository.load().first { $0.id == original.id })

            try assertAccessDuringPause(
                pause, to: directory,
                expectedStartedURLs: pause == .scopeStart ? [original.url] : [],
                expectAccess: false
            ) {
                XCTAssertEqual(try otherStore.authorize(directory).id, original.id)
                let replacement = try XCTUnwrap(repository.load().first { $0.id == original.id })
                XCTAssertEqual(replacement.persistentBookmarkData, originalRecord.persistentBookmarkData)
                XCTAssertEqual(replacement.transferBookmarkData, originalRecord.transferBookmarkData)
                XCTAssertNotEqual(replacement.revision, originalRecord.revision)
            }
        }
    }

    func testPausedAccessSurvivesUnrelatedAuthorizationChanges() throws {
        for pause in AccessPause.allCases {
            let directory = try accessDirectory(for: pause)
            let unrelatedDirectory = temporaryDirectory.appendingPathComponent("Unrelated", isDirectory: true)
            try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)
            let otherStore = makeStore()
            let original = try otherStore.authorize(directory)

            try assertAccessDuringPause(
                pause, to: directory, expectedStartedURLs: [original.url], expectAccess: true
            ) {
                let unrelated = try otherStore.authorize(unrelatedDirectory)
                XCTAssertTrue(try otherStore.revoke(unrelated.id))
            }
        }
    }

    func testPausedAccessFallsBackToUnchangedParentAfterChildIsReauthorized() throws {
        for pause in AccessPause.allCases {
            let parentDirectory = try accessDirectory(for: pause)
            let childDirectory = parentDirectory.appendingPathComponent("Child", isDirectory: true)
            try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
            let otherStore = makeStore()
            let parent = try otherStore.authorize(parentDirectory)
            let child = try otherStore.authorize(childDirectory)

            try assertAccessDuringPause(
                pause, to: childDirectory,
                expectedStartedURLs: pause == .scopeStart ? [child.url, parent.url] : [parent.url],
                expectAccess: true
            ) {
                XCTAssertTrue(try otherStore.revoke(child.id))
                XCTAssertNotEqual(try otherStore.authorize(childDirectory).id, child.id)
            }
        }
    }

    func testPausedAccessDoesNotFallBackToReauthorizedParent() throws {
        for pause in AccessPause.allCases {
            let parentDirectory = try accessDirectory(for: pause)
            let childDirectory = parentDirectory.appendingPathComponent("Child", isDirectory: true)
            try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
            let otherStore = makeStore()
            let parent = try otherStore.authorize(parentDirectory)
            let child = try otherStore.authorize(childDirectory)

            try assertAccessDuringPause(
                pause, to: childDirectory,
                expectedStartedURLs: pause == .scopeStart ? [child.url] : [],
                expectAccess: false
            ) {
                XCTAssertTrue(try otherStore.revoke(child.id))
                XCTAssertEqual(try otherStore.authorize(parentDirectory).id, parent.id)
            }
        }
    }

    func testAdmittedOperationCanFinishAfterRevocationWithoutHoldingRepositoryLock() throws {
        let operationStarted = expectation(description: "Operation has been admitted")
        let revocationFinished = expectation(description: "Revocation completed while operation is paused")
        let accessFinished = expectation(description: "Admitted operation completed")
        let resumeOperation = DispatchSemaphore(value: 0)
        let workers = DispatchGroup()
        let directory = try XCTUnwrap(temporaryDirectory)
        let fileURL = directory.appendingPathComponent("admitted.txt")
        let otherStore = makeStore()
        let authorization = try otherStore.authorize(directory)
        let operationCount = LockedTestValue(0)
        let stoppedURLs = LockedTestValue<[URL]>([])
        let store = makeStore(stopAccessing: { url in stoppedURLs.update { $0.append(url) } })
        defer {
            resumeOperation.signal()
            XCTAssertEqual(workers.wait(timeout: .now() + 5), .success)
        }
        workers.enter()
        DispatchQueue.global().async {
            defer {
                accessFinished.fulfill()
                workers.leave()
            }
            do {
                try store.withAccess(to: directory) {
                    operationCount.update { $0 += 1 }
                    operationStarted.fulfill()
                    guard resumeOperation.wait(timeout: .now() + 10) == .success else {
                        throw TestError.operationFailed
                    }
                    try Data("admitted".utf8).write(to: fileURL)
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        wait(for: [operationStarted], timeout: 2)
        workers.enter()
        DispatchQueue.global().async {
            defer {
                revocationFinished.fulfill()
                workers.leave()
            }
            do {
                let revoked = try otherStore.revoke(authorization.id)
                let remaining = try otherStore.loadAuthorizedDirectories()
                XCTAssertTrue(revoked)
                XCTAssertTrue(remaining.isEmpty)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        wait(for: [revocationFinished], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        resumeOperation.signal()
        wait(for: [accessFinished], timeout: 2)
        XCTAssertEqual(workers.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(operationCount.value, 1)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("admitted".utf8))
        XCTAssertEqual(stoppedURLs.value, [authorization.url])
    }

    func testRejectsDirectoryOutsideAuthorization() throws {
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickFileOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let store = makeStore()
        try store.authorize(temporaryDirectory)

        XCTAssertThrowsError(try store.withAccess(to: outsideDirectory) {}) { error in
            guard case AuthorizedDirectoryStore.StoreError.directoryNotAuthorized = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHintedExactGrantsSkipEarlierBlockedUnrelatedBookmark() throws {
        let offline = temporaryDirectory.appendingPathComponent("Offline", isDirectory: true)
        let targets = ["LocalA", "LocalB"].map {
            temporaryDirectory.appendingPathComponent($0, isDirectory: true)
        }
        let setupStore = makeStore()
        for url in [offline] + targets {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try setupStore.authorize(url)
        }
        let offlinePath = AuthorizedDirectoryPolicy.canonicalURL(offline).path
        let unrelatedCalls = LockedTestValue(0)
        let operations = LockedTestValue(0)
        let stops = LockedTestValue(0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let store = makeStore(transferBookmarkResolver: { data in
            let resolved = try Self.resolveTestBookmark(data)
            if resolved.url.path == offlinePath {
                unrelatedCalls.update { $0 += 1 }
                _ = release.wait(timeout: .now() + 5)
            }
            return resolved
        }, stopAccessing: { _ in stops.update { $0 += 1 } })
        for target in targets {
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                do { try store.withAccess(to: target) { operations.update { $0 += 1 } } }
                catch { XCTFail("Unexpected access error: \(error)") }
            }
        }
        let completedWithoutUnrelatedRead = finished.wait(timeout: .now() + 2) == .success
        // Release every possible old-implementation waiter before fixture teardown.
        release.signal(); release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(completedWithoutUnrelatedRead)
        XCTAssertEqual(unrelatedCalls.value, 0)
        XCTAssertEqual(operations.value, 2)
        XCTAssertEqual(stops.value, 2)
    }

    func testMisleadingExactHintCannotMakeParentBeatMoreSpecificGrant() throws {
        let child = temporaryDirectory.appendingPathComponent("Child", isDirectory: true)
        let target = child.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let setupStore = makeStore()
        let parentGrant = try setupStore.authorize(temporaryDirectory)
        let childGrant = try setupStore.authorize(child)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        try repository.update { records in
            let index = records.firstIndex { $0.id == parentGrant.id }!
            let old = records[index]
            records[index] = StoredDirectoryAuthorization(id: old.id,
                persistentBookmarkData: old.persistentBookmarkData,
                transferBookmarkData: old.transferBookmarkData,
                canonicalPathHint: AuthorizedDirectoryPolicy.canonicalURL(target).path)
        }
        let starts = LockedTestValue<[URL]>([])
        let accessStore = makeStore(startAccessing: { url in starts.update { $0.append(url) }; return true })
        try accessStore.withAccess(to: target) {}
        XCTAssertEqual(starts.value, [childGrant.url])
    }

    func testMisleadingHintPreservesEqualDepthParentFallbackOrder() throws {
        let target = temporaryDirectory.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let parent = AuthorizedDirectoryPolicy.canonicalURL(temporaryDirectory)
        let earlier = StoredDirectoryAuthorization(id: UUID(),
            persistentBookmarkData: Data(parent.path.utf8), transferBookmarkData: Data(parent.path.utf8))
        let later = StoredDirectoryAuthorization(id: UUID(),
            persistentBookmarkData: Data(parent.path.utf8), transferBookmarkData: Data(parent.path.utf8),
            canonicalPathHint: AuthorizedDirectoryPolicy.canonicalURL(target).path)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        try repository.update { $0 = [earlier, later] }
        let starts = LockedTestValue(0)
        let stops = LockedTestValue(0)
        let store = makeStore(startAccessing: { _ in
            starts.update { $0 += 1 }
            // If the later record were admitted first, its final revision check
            // would fail and access would need a second scope-start for the earlier one.
            do { try repository.update { $0.removeAll { $0.id == later.id } } }
            catch { XCTFail("Unexpected revocation error: \(error)") }
            return true
        }, stopAccessing: { _ in stops.update { $0 += 1 } })
        XCTAssertEqual(try store.withAccess(to: target) { "created" }, "created")
        XCTAssertEqual(starts.value, 1)
        XCTAssertEqual(stops.value, 1)
    }

    func testHintlessExactGrantRemainsEligibleAfterUnrelatedHintedCandidate() throws {
        let target = temporaryDirectory.appendingPathComponent("Target", isDirectory: true)
        let unrelated = temporaryDirectory.appendingPathComponent("Unrelated", isDirectory: true)
        for url in [target, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let setupStore = makeStore()
        let exact = try setupStore.authorize(target)
        let other = try setupStore.authorize(unrelated)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        try repository.update { records in
            records = records.map { record in
                StoredDirectoryAuthorization(id: record.id,
                    persistentBookmarkData: record.persistentBookmarkData,
                    transferBookmarkData: record.transferBookmarkData,
                    canonicalPathHint: record.id == other.id ? exact.url.path : nil)
            }
        }
        let starts = LockedTestValue<[URL]>([])
        let store = makeStore(startAccessing: { url in starts.update { $0.append(url) }; return true })
        XCTAssertEqual(try store.withAccess(to: target) { 41 }, 41)
        XCTAssertEqual(starts.value, [exact.url])
    }

    func testExactAdmissionSkipsLaterUnrelatedBookmarkAndPreservesOptionalNil() throws {
        let target = temporaryDirectory.appendingPathComponent("Target", isDirectory: true)
        let unrelated = temporaryDirectory.appendingPathComponent("Unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let resolutions = LockedTestValue<[String]>([])
        let stops = LockedTestValue(0)
        let operations = LockedTestValue(0)
        let store = makeStore(
            transferBookmarkResolver: { data in
                let resolved = try Self.resolveTestBookmark(data)
                resolutions.update { $0.append(resolved.url.path) }
                if resolved.url.path == unrelated.path { throw TestError.operationFailed }
                return resolved
            },
            stopAccessing: { _ in stops.update { $0 += 1 } }
        )
        try store.authorize(target)
        try store.authorize(unrelated)

        let result: String? = try store.withAccess(to: target) {
            operations.update { $0 += 1 }
            return nil
        }

        XCTAssertNil(result)
        XCTAssertEqual(resolutions.value, [AuthorizedDirectoryPolicy.canonicalURL(target).path])
        XCTAssertEqual(operations.value, 1)
        XCTAssertEqual(stops.value, 1)
    }

    func testRejectedExactGrantDiscoversParentStoredLater() throws {
        let target = temporaryDirectory.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let parent = AuthorizedDirectoryPolicy.canonicalURL(temporaryDirectory)
        let child = AuthorizedDirectoryPolicy.canonicalURL(target)
        let resolutions = LockedTestValue<[URL]>([])
        let starts = LockedTestValue<[URL]>([])
        let stops = LockedTestValue<[URL]>([])
        let store = makeStore(
            transferBookmarkResolver: { data in
                let resolved = try Self.resolveTestBookmark(data)
                resolutions.update { $0.append(resolved.url) }
                return resolved
            },
            startAccessing: { url in
                starts.update { $0.append(url) }
                return url == parent
            },
            stopAccessing: { url in stops.update { $0.append(url) } }
        )
        try store.authorize(target)
        try store.authorize(temporaryDirectory)

        XCTAssertEqual(try store.withAccess(to: target) { 42 }, 42)

        XCTAssertEqual(resolutions.value, [child, parent])
        XCTAssertEqual(starts.value, [child, parent])
        XCTAssertEqual(stops.value, [parent])
    }

    func testExactGrantBeatsEarlierParentAndSkipsLaterBookmark() throws {
        let target = temporaryDirectory.appendingPathComponent("Target", isDirectory: true)
        let unrelated = temporaryDirectory.appendingPathComponent("Unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let resolutions = LockedTestValue<[String]>([])
        let starts = LockedTestValue<[URL]>([])
        let store = makeStore(
            transferBookmarkResolver: { data in
                let resolved = try Self.resolveTestBookmark(data)
                resolutions.update { $0.append(resolved.url.path) }
                return resolved
            },
            startAccessing: { url in starts.update { $0.append(url) }; return true }
        )
        try store.authorize(temporaryDirectory)
        let exact = try store.authorize(target)
        try store.authorize(unrelated)

        try store.withAccess(to: target) {}

        XCTAssertEqual(resolutions.value, [exact.url.path])
        XCTAssertEqual(starts.value, [exact.url])
    }

    func testExactOperationFailureDoesNotResolveOrRetryLaterParent() throws {
        let target = temporaryDirectory.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let resolutions = LockedTestValue(0)
        let operations = LockedTestValue(0)
        let stops = LockedTestValue(0)
        let store = makeStore(
            transferBookmarkResolver: { data in
                resolutions.update { $0 += 1 }
                return try Self.resolveTestBookmark(data)
            },
            stopAccessing: { _ in stops.update { $0 += 1 } }
        )
        try store.authorize(target)
        try store.authorize(temporaryDirectory)

        XCTAssertThrowsError(try store.withAccess(to: target) {
            operations.update { $0 += 1 }
            throw TestError.operationFailed
        }) { XCTAssertTrue($0 is TestError) }

        XCTAssertEqual(resolutions.value, 1)
        XCTAssertEqual(operations.value, 1)
        XCTAssertEqual(stops.value, 1)
    }

    func testUsesMostSpecificMatchingAuthorization() throws {
        let nestedDirectory = temporaryDirectory.appendingPathComponent("Nested", isDirectory: true)
        let targetDirectory = nestedDirectory.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let startedURL = LockedTestValue<URL?>(nil)
        let store = makeStore(startAccessing: {
            startedURL.value = $0
            return true
        })
        try store.authorize(temporaryDirectory)
        let nestedAuthorization = try store.authorize(nestedDirectory)

        try store.withAccess(to: targetDirectory) {}

        XCTAssertEqual(startedURL.value, nestedAuthorization.url)
    }

    func testFallsBackToParentAuthorizationWhenMostSpecificScopeCannotStart() throws {
        let nestedDirectory = temporaryDirectory.appendingPathComponent("Nested", isDirectory: true)
        let targetDirectory = nestedDirectory.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let parentURL = AuthorizedDirectoryPolicy.canonicalURL(temporaryDirectory)
        let nestedURL = AuthorizedDirectoryPolicy.canonicalURL(nestedDirectory)
        let startedURLs = LockedTestValue<[URL]>([])
        let stoppedURLs = LockedTestValue<[URL]>([])
        let operationCount = LockedTestValue(0)
        let store = makeStore(
            startAccessing: { url in
                startedURLs.update { $0.append(url) }
                return url == parentURL
            },
            stopAccessing: { url in stoppedURLs.update { $0.append(url) } }
        )
        try store.authorize(temporaryDirectory)
        try store.authorize(nestedDirectory)

        try store.withAccess(to: targetDirectory) {
            operationCount.update { $0 += 1 }
        }

        XCTAssertEqual(startedURLs.value, [nestedURL, parentURL])
        XCTAssertEqual(stoppedURLs.value, [parentURL])
        XCTAssertEqual(operationCount.value, 1)
    }

    func testReportsUnavailableScopeAfterAllMatchingAuthorizationsFailToStart() throws {
        let nestedDirectory = temporaryDirectory.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let startedURLs = LockedTestValue<[URL]>([])
        let stoppedURLs = LockedTestValue<[URL]>([])
        let operationCount = LockedTestValue(0)
        let store = makeStore(
            startAccessing: { url in
                startedURLs.update { $0.append(url) }
                return false
            },
            stopAccessing: { url in stoppedURLs.update { $0.append(url) } }
        )
        try store.authorize(temporaryDirectory)
        try store.authorize(nestedDirectory)

        XCTAssertThrowsError(try store.withAccess(to: nestedDirectory) {
            operationCount.update { $0 += 1 }
        }) { error in
            guard case AuthorizedDirectoryStore.StoreError.securityScopeUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(startedURLs.value.count, 2)
        XCTAssertTrue(stoppedURLs.value.isEmpty)
        XCTAssertEqual(operationCount.value, 0)
    }

    func testOperationFailureDoesNotTryParentAuthorizationAgain() throws {
        let nestedDirectory = temporaryDirectory.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let startedURLs = LockedTestValue<[URL]>([])
        let stoppedURLs = LockedTestValue<[URL]>([])
        let operationCount = LockedTestValue(0)
        let store = makeStore(
            startAccessing: { url in
                startedURLs.update { $0.append(url) }
                return true
            },
            stopAccessing: { url in stoppedURLs.update { $0.append(url) } }
        )
        try store.authorize(temporaryDirectory)
        let nestedAuthorization = try store.authorize(nestedDirectory)

        XCTAssertThrowsError(try store.withAccess(to: nestedDirectory) {
            operationCount.update { $0 += 1 }
            throw TestError.operationFailed
        })
        XCTAssertEqual(startedURLs.value, [nestedAuthorization.url])
        XCTAssertEqual(stoppedURLs.value, [nestedAuthorization.url])
        XCTAssertEqual(operationCount.value, 1)
    }

    func testStopsSecurityScopeWhenOperationThrows() throws {
        let didStopAccess = LockedTestValue(false)
        let store = makeStore(stopAccessing: { _ in
            didStopAccess.value = true
        })
        try store.authorize(temporaryDirectory)

        XCTAssertThrowsError(
            try store.withAccess(to: temporaryDirectory) {
                throw TestError.operationFailed
            }
        )
        XCTAssertTrue(didStopAccess.value)
    }

    func testDirectoryContainmentUsesPathComponents() {
        let authorized = URL(fileURLWithPath: "/tmp/QuickFile/Root", isDirectory: true)
        let descendant = URL(fileURLWithPath: "/tmp/QuickFile/Root/Child", isDirectory: true)
        let similarPrefix = URL(fileURLWithPath: "/tmp/QuickFile/RootOther", isDirectory: true)

        XCTAssertTrue(AuthorizedDirectoryStore.directory(authorized, contains: descendant))
        XCTAssertFalse(AuthorizedDirectoryStore.directory(authorized, contains: similarPrefix))
    }

    func testRefreshesTransferBookmarkFromPersistentAuthorization() throws {
        let transferCreationCount = LockedTestValue(0)
        let store = AuthorizedDirectoryStore(
            defaults: defaults,
            storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { Data("persistent:\($0.path)".utf8) },
            transferBookmarkCreator: {
                transferCreationCount.update { $0 += 1 }
                return Data("transfer:\($0.path)".utf8)
            },
            persistentBookmarkResolver: { data in
                let value = try XCTUnwrap(String(data: data, encoding: .utf8))
                let path = value.replacingOccurrences(of: "persistent:", with: "")
                return ResolvedSecurityScopedBookmark(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    isStale: false
                )
            },
            transferBookmarkResolver: { data in
                let value = try XCTUnwrap(String(data: data, encoding: .utf8))
                let path = value.replacingOccurrences(of: "transfer:", with: "")
                return ResolvedSecurityScopedBookmark(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    isStale: false
                )
            },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
        try store.authorize(temporaryDirectory)

        try store.refreshTransferBookmarks()
        try store.withAccess(to: temporaryDirectory) {}

        XCTAssertEqual(transferCreationCount.value, 2)
    }

    func testRefreshesStalePersistentBookmark() throws {
        let persistentCreationCount = LockedTestValue(0)
        let store = AuthorizedDirectoryStore(
            defaults: defaults,
            storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { url in
                let creationCount = persistentCreationCount.update { count in
                    count += 1
                    return count
                }
                return Data("persistent-\(creationCount):\(url.path)".utf8)
            },
            transferBookmarkCreator: { Data("transfer:\($0.path)".utf8) },
            persistentBookmarkResolver: { data in
                let value = try XCTUnwrap(String(data: data, encoding: .utf8))
                let separator = try XCTUnwrap(value.firstIndex(of: ":"))
                return ResolvedSecurityScopedBookmark(
                    url: URL(fileURLWithPath: String(value[value.index(after: separator)...]), isDirectory: true),
                    isStale: value.hasPrefix("persistent-1:")
                )
            },
            transferBookmarkResolver: { try Self.resolveTestBookmark($0) },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
        try store.authorize(temporaryDirectory)

        try store.refreshTransferBookmarks()
        let inventory = try store.loadAuthorizedDirectoryInventory()

        XCTAssertEqual(persistentCreationCount.value, 2)
        XCTAssertEqual(inventory.availableDirectories.count, 1)
        XCTAssertFalse(try XCTUnwrap(inventory.availableDirectories.first).isBookmarkStale)
    }

    func testReportsPartialRefreshFailureAfterSavingSuccessfulRefreshes() throws {
        let secondDirectory = temporaryDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("QuickFileAuthorizedDirectories-Second-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondDirectory) }

        let initialStore = makeStore()
        try initialStore.authorize(temporaryDirectory)
        let failedAuthorization = try initialStore.authorize(secondDirectory)
        let refreshingStore = AuthorizedDirectoryStore(
            defaults: defaults,
            storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { Data($0.path.utf8) },
            transferBookmarkCreator: { Data("refreshed:\($0.path)".utf8) },
            persistentBookmarkResolver: { data in
                let path = try XCTUnwrap(String(data: data, encoding: .utf8))
                if path == secondDirectory.path {
                    throw TestError.operationFailed
                }
                return ResolvedSecurityScopedBookmark(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    isStale: false
                )
            },
            transferBookmarkResolver: { data in
                let value = try XCTUnwrap(String(data: data, encoding: .utf8))
                guard value.hasPrefix("refreshed:") else {
                    throw TestError.operationFailed
                }
                return ResolvedSecurityScopedBookmark(
                    url: URL(
                        fileURLWithPath: String(value.dropFirst("refreshed:".count)),
                        isDirectory: true
                    ),
                    isStale: false
                )
            },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )

        XCTAssertThrowsError(try refreshingStore.refreshTransferBookmarks()) { error in
            guard case let AuthorizedDirectoryStore.StoreError.bookmarkRefreshFailed(ids, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(ids, [failedAuthorization.id])
        }
        XCTAssertNoThrow(try refreshingStore.withAccess(to: temporaryDirectory) {})
    }

    func testInventoryKeepsUnresolvableAuthorizationAvailableForRevocation() throws {
        let authorization = try makeStore().authorize(temporaryDirectory)
        let failingStore = AuthorizedDirectoryStore(
            defaults: defaults,
            storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { Data($0.path.utf8) },
            transferBookmarkCreator: { Data($0.path.utf8) },
            persistentBookmarkResolver: { _ in throw TestError.operationFailed },
            transferBookmarkResolver: { try Self.resolveTestBookmark($0) }
        )

        let inventory = try failingStore.loadAuthorizedDirectoryInventory()

        XCTAssertTrue(inventory.availableDirectories.isEmpty)
        XCTAssertEqual(
            inventory.unavailableDirectories,
            [UnavailableAuthorizedDirectory(id: authorization.id)]
        )
        XCTAssertThrowsError(try failingStore.loadAuthorizedDirectories()) { error in
            guard case let AuthorizedDirectoryStore.StoreError.authorizationResolutionFailed(count) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(count, 1)
        }
        XCTAssertTrue(try failingStore.revoke(authorization.id))
        XCTAssertTrue(try failingStore.loadAuthorizedDirectoryInventory().unavailableDirectories.isEmpty)
    }

    func testCleanupRemovesOnlySelectedUnavailableAuthorizationsAndCanBeRepeated() throws {
        let initialStore = makeStore()
        let valid = try initialStore.authorize(temporaryDirectory)
        var children: [AuthorizedDirectory] = []
        for name in ["Stale", "UnavailableOne", "UnavailableTwo", "Unselected"] {
            let directory = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            children.append(try initialStore.authorize(directory))
        }
        let stale = children[0]
        let unavailableIDs: Set<UUID> = [children[1].id, children[2].id]
        let unselected = children[3]
        let failedNames: Set<String> = ["UnavailableOne", "UnavailableTwo", "Unselected"]
        let resolvedNames = LockedTestValue<Set<String>>([])
        let store = makeStore(persistentBookmarkResolver: { data in
            let resolved = try Self.resolveTestBookmark(data)
            let name = resolved.url.lastPathComponent
            resolvedNames.update { $0.insert(name) }
            if failedNames.contains(name) { throw TestError.operationFailed }
            return ResolvedSecurityScopedBookmark(url: resolved.url, isStale: name == "Stale")
        })
        let inventory = try store.loadAuthorizedDirectoryInventory()
        XCTAssertEqual(Set(inventory.unavailableDirectories.map(\.id)), unavailableIDs.union([unselected.id]))
        XCTAssertEqual(inventory.availableDirectories.first { $0.id == stale.id }?.isBookmarkStale, true)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let originals = try repository.load()
        let selectedIDs = unavailableIDs.union([valid.id, stale.id, UUID()])
        resolvedNames.value = []

        XCTAssertEqual(try store.revokeUnavailableAuthorizations(selectedIDs), unavailableIDs)

        XCTAssertEqual(resolvedNames.value, [temporaryDirectory.lastPathComponent, "Stale", "UnavailableOne", "UnavailableTwo"])
        let remaining = try repository.loadSnapshot()
        XCTAssertEqual(remaining.authorizations, originals.filter { !unavailableIDs.contains($0.id) })
        XCTAssertTrue(try store.revokeUnavailableAuthorizations(selectedIDs).isEmpty)
        XCTAssertTrue(try store.revokeUnavailableAuthorizations([]).isEmpty)
        XCTAssertEqual(try repository.loadSnapshot(), remaining)
    }

    func testCleanupPreservesAuthorizationThatRecoveredAfterInventoryLoad() throws {
        let authorization = try makeStore().authorize(temporaryDirectory)
        let isUnavailable = LockedTestValue(true)
        let store = makeStore(persistentBookmarkResolver: { data in
            if isUnavailable.value { throw TestError.operationFailed }
            return try Self.resolveTestBookmark(data)
        })
        let inventory = try store.loadAuthorizedDirectoryInventory()
        XCTAssertEqual(inventory.unavailableDirectories.map(\.id), [authorization.id])
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let original = try repository.loadSnapshot()
        isUnavailable.value = false

        XCTAssertTrue(try store.revokeUnavailableAuthorizations(Set(inventory.unavailableDirectories.map(\.id))).isEmpty)

        XCTAssertEqual(try repository.loadSnapshot(), original)
        XCTAssertEqual(try store.loadAuthorizedDirectories(), [authorization])
    }

    func testPausedCleanupAllowsConcurrentChangesAndPreservesNewRevisionAndNewAuthorization() throws {
        let otherStore = makeStore()
        let directoryURL = try XCTUnwrap(temporaryDirectory)
        let reauthorized = try otherStore.authorize(directoryURL)
        let revokedURL = directoryURL.appendingPathComponent("Revoked", isDirectory: true)
        let removedURL = directoryURL.appendingPathComponent("Removed", isDirectory: true)
        let newURL = directoryURL.appendingPathComponent("New", isDirectory: true)
        for url in [revokedURL, removedURL, newURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let revoked = try otherStore.authorize(revokedURL)
        let removed = try otherStore.authorize(removedURL)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let originalRecord = try XCTUnwrap(repository.load().first { $0.id == reauthorized.id })
        let selectedIDs: Set<UUID> = [reauthorized.id, revoked.id, removed.id]
        let resolutionStarted = expectation(description: "Cleanup resolver is paused")
        let concurrentOperationFinished = expectation(description: "Other store completed while cleanup is paused")
        let cleanupFinished = expectation(description: "Cleanup completed")
        let resumeResolution = DispatchSemaphore(value: 0)
        let workers = DispatchGroup()
        let concurrentRecords = LockedTestValue<[StoredDirectoryAuthorization]>([])
        let store = makeStore(persistentBookmarkResolver: { data in
            if data == originalRecord.persistentBookmarkData {
                resolutionStarted.fulfill()
                guard resumeResolution.wait(timeout: .now() + 10) == .success else {
                    throw TestError.operationFailed
                }
            }
            throw TestError.operationFailed
        })
        defer {
            resumeResolution.signal()
            XCTAssertEqual(workers.wait(timeout: .now() + 5), .success)
        }
        workers.enter()
        DispatchQueue.global().async {
            defer {
                cleanupFinished.fulfill()
                workers.leave()
            }
            do {
                let removedIDs = try store.revokeUnavailableAuthorizations(selectedIDs)
                XCTAssertEqual(removedIDs, [removed.id])
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        wait(for: [resolutionStarted], timeout: 2)
        workers.enter()
        DispatchQueue.global().async {
            defer {
                concurrentOperationFinished.fulfill()
                workers.leave()
            }
            do {
                XCTAssertEqual(try otherStore.loadAuthorizedDirectories().count, 3)
                XCTAssertEqual(try otherStore.authorize(directoryURL).id, reauthorized.id)
                let replacement = try XCTUnwrap(repository.load().first { $0.id == reauthorized.id })
                XCTAssertEqual(replacement.persistentBookmarkData, originalRecord.persistentBookmarkData)
                XCTAssertEqual(replacement.transferBookmarkData, originalRecord.transferBookmarkData)
                XCTAssertNotEqual(replacement.revision, originalRecord.revision)
                try otherStore.authorize(newURL)
                XCTAssertTrue(try otherStore.revoke(revoked.id))
                concurrentRecords.value = try repository.load()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        wait(for: [concurrentOperationFinished], timeout: 2)
        resumeResolution.signal()
        wait(for: [cleanupFinished], timeout: 2)
        XCTAssertEqual(workers.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(concurrentRecords.value.count, 3)
        XCTAssertEqual(try repository.load(), concurrentRecords.value.filter { $0.id != removed.id })
    }

    func testCleanupPropagatesSnapshotReadFailureButEmptySelectionDoesNotReadStorage() throws {
        let authorization = try makeStore().authorize(temporaryDirectory)
        let snapshotURL = temporaryDirectory.appendingPathComponent("authorizedDirectories.v2.json")
        let corruptData = Data("invalid json".utf8)
        try corruptData.write(to: snapshotURL)
        let store = makeStore(persistentBookmarkResolver: { _ in
            XCTFail("A failed snapshot read must not resolve bookmarks")
            throw TestError.operationFailed
        })

        XCTAssertTrue(try store.revokeUnavailableAuthorizations([]).isEmpty)
        XCTAssertThrowsError(try store.revokeUnavailableAuthorizations([authorization.id])) { error in
            guard case AuthorizedDirectoryStoreError.persistenceFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: snapshotURL), corruptData)
    }

    func testCleanupPropagatesSaveFailureWithoutRemovingAuthorizations() throws {
        let authorization = try makeStore().authorize(temporaryDirectory)
        let storageDirectory = try XCTUnwrap(temporaryDirectory)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: storageDirectory)
        let original = try repository.loadSnapshot()
        let store = makeStore(persistentBookmarkResolver: { _ in
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: storageDirectory.path)
            throw TestError.operationFailed
        })
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageDirectory.path)
        }

        XCTAssertThrowsError(try store.revokeUnavailableAuthorizations([authorization.id])) { error in
            guard case AuthorizedDirectoryStoreError.persistenceFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try repository.loadSnapshot(), original)
    }

    func testRefreshDoesNotRestoreConcurrentRevocationFromAnotherStore() throws {
        let otherStore = makeStore()
        let authorization = try otherStore.authorize(temporaryDirectory)
        let refreshingStore = makeRefreshingStore { _ in
            XCTAssertTrue(try otherStore.revoke(authorization.id))
        }

        try refreshingStore.refreshTransferBookmarks()

        XCTAssertTrue(try otherStore.loadAuthorizedDirectories().isEmpty)
        XCTAssertThrowsError(try refreshingStore.withAccess(to: temporaryDirectory) {})
    }

    func testRefreshPreservesConcurrentReauthorizationAndNewAuthorization() throws {
        let otherStore = makeStore()
        let first = try otherStore.authorize(temporaryDirectory)
        let child = temporaryDirectory.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let replacement = LockedTestValue<StoredDirectoryAuthorization?>(nil)
        let directoryURL = try XCTUnwrap(temporaryDirectory)
        let refreshingStore = makeRefreshingStore { _ in
            XCTAssertEqual(try otherStore.authorize(directoryURL).id, first.id)
            replacement.value = try repository.load().first
            try otherStore.authorize(child)
        }

        try refreshingStore.refreshTransferBookmarks()

        let stored = try repository.load()
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.first { $0.id == first.id }, replacement.value)
    }

    func testMigratesLegacyBookmarksOnceAndNeverRestoresRevokedLegacyEntry() throws {
        let id = UUID()
        let legacy = [["id": id.uuidString,
                       "bookmarkData": Data(temporaryDirectory.path.utf8).base64EncodedString()]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "authorizedDirectories.v1")
        let store = makeStore()

        XCTAssertEqual(try store.loadAuthorizedDirectories().first?.id, id)
        try store.refreshTransferBookmarks()
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let refreshed = try XCTUnwrap(repository.load().first)
        XCTAssertEqual(refreshed.id, id)
        XCTAssertEqual(refreshed.canonicalPathHint, temporaryDirectory.resolvingSymlinksInPath().path)
        XCTAssertEqual(refreshed.directoryIdentityHint, try DirectoryIdentity.capture(at: temporaryDirectory))
        XCTAssertNotNil(refreshed.revision)
        XCTAssertEqual(try store.authorize(temporaryDirectory).id, id)
        XCTAssertEqual(try repository.load().count, 1)
        XCTAssertNoThrow(try store.withAccess(to: temporaryDirectory) {})
        XCTAssertTrue(try store.revoke(id))
        XCTAssertTrue(try makeStore().loadAuthorizedDirectories().isEmpty)
    }

    func testProductionRepositoryMigratesPersistedAppGroupPreferences() throws {
        let preferencesDirectory = temporaryDirectory.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
        let legacy = StoredDirectoryAuthorization(
            id: UUID(), persistentBookmarkData: Data("persistent".utf8),
            transferBookmarkData: Data("transfer".utf8)
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["authorizedDirectories.v1": try JSONEncoder().encode([legacy])],
            format: .binary, options: 0
        )
        let preferencesURL = preferencesDirectory
            .appendingPathComponent(QuickFileConfiguration.appGroupIdentifier + ".plist")
        try plist.write(to: preferencesURL)
        let repository = AuthorizedDirectoryRepository(containerURL: temporaryDirectory)

        XCTAssertEqual(try repository.load(), [legacy])
        try repository.update { $0.removeAll() }
        XCTAssertTrue(try AuthorizedDirectoryRepository(containerURL: temporaryDirectory).load().isEmpty)
    }

    func testInterruptedMigrationRepairsMarkerBeforeRevocation() throws {
        let id = UUID()
        let authorization = StoredDirectoryAuthorization(
            id: id, persistentBookmarkData: Data(temporaryDirectory.path.utf8),
            transferBookmarkData: Data(temporaryDirectory.path.utf8)
        )
        let data = try JSONEncoder().encode([authorization])
        defaults.set(data, forKey: "authorizedDirectories.v1")
        let snapshot = temporaryDirectory.appendingPathComponent("authorizedDirectories.v2.json")
        let marker = temporaryDirectory.appendingPathComponent("authorizedDirectories.migrated")
        // Simulate termination between writing the initial snapshot and its marker.
        try data.write(to: snapshot, options: .atomic)
        let store = makeStore()

        XCTAssertEqual(try store.loadAuthorizedDirectories().first?.id, id)
        XCTAssertNoThrow(try Data(contentsOf: marker))
        XCTAssertTrue(try store.revoke(id))
        try FileManager.default.removeItem(at: snapshot)

        XCTAssertThrowsError(try makeStore().loadAuthorizedDirectories()) { error in
            guard case AuthorizedDirectoryStoreError.persistenceFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try store.withAccess(to: temporaryDirectory) {})
    }

    func testMigratesV2ArrayWithoutChangingExistingRecords() throws {
        let versioned = StoredDirectoryAuthorization(
            id: UUID(), persistentBookmarkData: Data("persistent".utf8),
            transferBookmarkData: Data("transfer".utf8)
        )
        let unversionedData = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "persistentBookmarkData": Data("old-persistent".utf8).base64EncodedString(),
            "transferBookmarkData": Data("old-transfer".utf8).base64EncodedString()
        ])
        let unversioned = try JSONDecoder().decode(StoredDirectoryAuthorization.self, from: unversionedData)
        let originalRecords = [versioned, unversioned]
        let url = temporaryDirectory.appendingPathComponent("authorizedDirectories.v2.json")
        try JSONEncoder().encode(originalRecords).write(to: url, options: .atomic)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)

        let migrated = try repository.loadSnapshot()

        XCTAssertEqual(migrated.authorizations, originalRecords)
        XCTAssertEqual(try repository.loadSnapshot(), migrated)
        XCTAssertEqual(
            try JSONDecoder().decode(AuthorizedDirectoryRepository.Snapshot.self, from: Data(contentsOf: url)),
            migrated
        )
        XCTAssertNil(migrated.authorizations.last?.revision)
        XCTAssertTrue(migrated.authorizations.allSatisfy { $0.canonicalPathHint == nil && $0.directoryIdentityHint == nil })
        XCTAssertNoThrow(try Data(contentsOf: temporaryDirectory.appendingPathComponent("authorizedDirectories.migrated")))
    }

    func testMigratedEmptyTableRetainsGenerationAcrossInsertAndRevocation() throws {
        let url = temporaryDirectory.appendingPathComponent("authorizedDirectories.v2.json")
        try Data("[]".utf8).write(to: url, options: .atomic)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let otherRepository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let original = try repository.loadSnapshot()
        XCTAssertTrue(original.authorizations.isEmpty)
        XCTAssertEqual(try otherRepository.loadSnapshot(), original)
        let store = makeStore()

        let inserted = try store.authorize(temporaryDirectory)
        let afterInsert = try otherRepository.loadSnapshot()
        XCTAssertNotEqual(afterInsert.generation, original.generation)
        XCTAssertTrue(try store.revoke(inserted.id))
        let afterRevoke = try otherRepository.loadSnapshot()

        XCTAssertEqual(afterRevoke.authorizations, original.authorizations)
        XCTAssertNotEqual(afterRevoke.generation, original.generation)
        XCTAssertNotEqual(afterRevoke.generation, afterInsert.generation)
        XCTAssertEqual(try repository.loadSnapshot(), afterRevoke)
        XCTAssertEqual(
            try JSONDecoder().decode(AuthorizedDirectoryRepository.Snapshot.self, from: Data(contentsOf: url)),
            afterRevoke
        )
    }

    func testUnchangedAndFailedUpdatesPreservePersistentGeneration() throws {
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        let original = try repository.loadSnapshot()

        try repository.update { _ in }
        XCTAssertEqual(try repository.loadSnapshot(), original)
        XCTAssertThrowsError(try repository.update { authorizations in
            authorizations.append(StoredDirectoryAuthorization(
                id: UUID(), persistentBookmarkData: Data("persistent".utf8),
                transferBookmarkData: Data("transfer".utf8)
            ))
            throw TestError.operationFailed
        })

        XCTAssertEqual(try repository.loadSnapshot(), original)
    }

    func testEnvelopeWithoutGenerationFailsWithoutLegacyFallback() throws {
        let original = StoredDirectoryAuthorization(
            id: UUID(), persistentBookmarkData: Data(temporaryDirectory.path.utf8),
            transferBookmarkData: Data(temporaryDirectory.path.utf8)
        )
        let legacyData = try JSONEncoder().encode([original])
        defaults.set(legacyData, forKey: "authorizedDirectories.v1")
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: temporaryDirectory)
        _ = try repository.loadSnapshot()
        let corruptData = try JSONSerialization.data(withJSONObject: [
            "authorizations": try JSONSerialization.jsonObject(with: legacyData)
        ])
        let url = temporaryDirectory.appendingPathComponent("authorizedDirectories.v2.json")
        try corruptData.write(to: url, options: .atomic)

        XCTAssertThrowsError(try repository.loadSnapshot()) { error in
            guard case AuthorizedDirectoryStoreError.persistenceFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), corruptData)
    }

    func testCorruptOrMissingMigratedSnapshotFailsWithoutLegacyFallback() throws {
        let store = makeStore()
        try store.authorize(temporaryDirectory)
        let snapshot = temporaryDirectory.appendingPathComponent("authorizedDirectories.v2.json")
        defaults.set(try Data(contentsOf: snapshot), forKey: "authorizedDirectories.v1")
        try Data("invalid json".utf8).write(to: snapshot)
        XCTAssertThrowsError(try store.withAccess(to: temporaryDirectory) {})
        try FileManager.default.removeItem(at: snapshot)
        XCTAssertThrowsError(try store.loadAuthorizedDirectories())
        XCTAssertThrowsError(try store.withAccess(to: temporaryDirectory) {})
    }

    private func accessDirectory(for pause: AccessPause) throws -> URL {
        let directory = temporaryDirectory.appendingPathComponent("\(pause)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func assertAccessDuringPause(
        _ pause: AccessPause,
        to directoryURL: URL,
        expectedStartedURLs: [URL],
        expectAccess: Bool,
        concurrentOperation: @escaping @Sendable () throws -> Void
    ) throws {
        let accessPaused = expectation(description: "Access is paused at \(pause)")
        let concurrentOperationFinished = expectation(description: "Other store completed while access is paused")
        let accessFinished = expectation(description: "Access completed")
        let resumeAccess = DispatchSemaphore(value: 0)
        let workers = DispatchGroup()
        let pausedURL = AuthorizedDirectoryPolicy.canonicalURL(directoryURL)
        let fileURL = directoryURL.appendingPathComponent("access-\(UUID().uuidString).txt")
        let startedURLs = LockedTestValue<[URL]>([])
        let stoppedURLs = LockedTestValue<[URL]>([])
        let operationCount = LockedTestValue(0)
        let awaitResume: @Sendable () throws -> Void = {
            accessPaused.fulfill()
            guard resumeAccess.wait(timeout: .now() + 10) == .success else {
                throw TestError.operationFailed
            }
        }
        let store = makeStore(
            transferBookmarkResolver: { data in
                let resolved = try Self.resolveTestBookmark(data)
                if pause == .bookmarkResolution,
                   AuthorizedDirectoryPolicy.canonicalURL(resolved.url) == pausedURL {
                    try awaitResume()
                }
                return resolved
            },
            startAccessing: { url in
                startedURLs.update { $0.append(url) }
                if pause == .scopeStart, url == pausedURL {
                    do {
                        try awaitResume()
                    } catch {
                        XCTFail("Access pause timed out: \(error)")
                        return false
                    }
                }
                return true
            },
            stopAccessing: { url in stoppedURLs.update { $0.append(url) } }
        )
        defer {
            resumeAccess.signal()
            XCTAssertEqual(workers.wait(timeout: .now() + 5), .success)
        }
        workers.enter()
        DispatchQueue.global().async {
            defer {
                accessFinished.fulfill()
                workers.leave()
            }
            do {
                try store.withAccess(to: directoryURL) {
                    operationCount.update { $0 += 1 }
                    try Data("created".utf8).write(to: fileURL)
                }
                if !expectAccess { XCTFail("An invalidated snapshot must not enter the operation") }
            } catch {
                if expectAccess { return XCTFail("Unexpected error: \(error)") }
                guard case AuthorizedDirectoryStoreError.authorizationChanged = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        wait(for: [accessPaused], timeout: 2)
        workers.enter()
        DispatchQueue.global().async {
            defer {
                concurrentOperationFinished.fulfill()
                workers.leave()
            }
            do {
                try concurrentOperation()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        wait(for: [concurrentOperationFinished], timeout: 2)
        resumeAccess.signal()
        wait(for: [accessFinished], timeout: 2)
        XCTAssertEqual(workers.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(operationCount.value, expectAccess ? 1 : 0)
        XCTAssertEqual(FileManager.default.fileExists(atPath: fileURL.path), expectAccess)
        if expectAccess { XCTAssertEqual(try Data(contentsOf: fileURL), Data("created".utf8)) }
        XCTAssertEqual(startedURLs.value, expectedStartedURLs)
        XCTAssertEqual(stoppedURLs.value, expectedStartedURLs)
    }

    private func makeRefreshingStore(
        beforeRefresh: @escaping @Sendable (Data) throws -> Void
    ) -> AuthorizedDirectoryStore {
        AuthorizedDirectoryStore(
            defaults: defaults,
            storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: { Data($0.path.utf8) },
            transferBookmarkCreator: { Data("refreshed:\($0.path)".utf8) },
            persistentBookmarkResolver: { data in
                try beforeRefresh(data)
                return try Self.resolveTestBookmark(data)
            },
            transferBookmarkResolver: { try Self.resolveTestBookmark($0) },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
    }

    private func assertAuthorizationConflictsDuringResolution(
        _ directoryURL: URL,
        concurrentOperation: @escaping @Sendable () throws -> Void
    ) {
        let resolutionStarted = expectation(description: "Authorization resolver is paused")
        let concurrentOperationFinished = expectation(description: "Other store completed while resolver is paused")
        let authorizationFinished = expectation(description: "Authorization reported conflict")
        let resumeResolution = DispatchSemaphore(value: 0)
        let workers = DispatchGroup()
        let store = makeStore(persistentBookmarkResolver: { data in
            resolutionStarted.fulfill()
            guard resumeResolution.wait(timeout: .now() + 10) == .success else {
                throw TestError.operationFailed
            }
            return try Self.resolveTestBookmark(data)
        })
        defer {
            resumeResolution.signal()
            XCTAssertEqual(workers.wait(timeout: .now() + 5), .success)
        }
        workers.enter()
        DispatchQueue.global().async {
            defer {
                authorizationFinished.fulfill()
                workers.leave()
            }
            do {
                try store.authorize(directoryURL)
                XCTFail("Concurrent authorization should report a conflict")
            } catch {
                guard case AuthorizedDirectoryStoreError.authorizationChanged = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        wait(for: [resolutionStarted], timeout: 2)
        workers.enter()
        DispatchQueue.global().async {
            defer {
                concurrentOperationFinished.fulfill()
                workers.leave()
            }
            do {
                try concurrentOperation()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        wait(for: [concurrentOperationFinished], timeout: 2)
        resumeResolution.signal()
        wait(for: [authorizationFinished], timeout: 2)
    }

    private func makeStore(
        persistentBookmarkCreator: @escaping AuthorizedDirectoryStore.BookmarkCreator = { Data($0.path.utf8) },
        persistentBookmarkResolver: @escaping AuthorizedDirectoryStore.BookmarkResolver = { try AuthorizedDirectoryStoreTests.resolveTestBookmark($0) },
        transferBookmarkResolver: @escaping AuthorizedDirectoryStore.BookmarkResolver = { try AuthorizedDirectoryStoreTests.resolveTestBookmark($0) },
        startAccessing: @escaping AuthorizedDirectoryStore.SecurityScopeStarter = { _ in true },
        stopAccessing: @escaping AuthorizedDirectoryStore.SecurityScopeStopper = { _ in }
    ) -> AuthorizedDirectoryStore {
        return AuthorizedDirectoryStore(
            defaults: defaults,
            storageDirectory: temporaryDirectory,
            persistentBookmarkCreator: persistentBookmarkCreator,
            transferBookmarkCreator: { url in
                Data(url.path.utf8)
            },
            persistentBookmarkResolver: persistentBookmarkResolver,
            transferBookmarkResolver: transferBookmarkResolver,
            startAccessing: startAccessing,
            stopAccessing: stopAccessing
        )
    }

    private static func resolveTestBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
        let path = try XCTUnwrap(String(data: data, encoding: .utf8))
        return ResolvedSecurityScopedBookmark(
            url: URL(fileURLWithPath: path, isDirectory: true),
            isStale: false
        )
    }
}
