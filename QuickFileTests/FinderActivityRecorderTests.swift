import XCTest
import QuickFileCore

final class FinderActivityRecorderTests: XCTestCase {
    func testBlockedPersistenceDoesNotBlockCallerAndKeepsRecordOrder() {
        let entered = expectation(description: "first persistence started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let finished = expectation(description: "second activity persisted after first")
        let recorder = FinderActivityRecorder(persist: { kind, _, _ in
            if kind == .fileCreationFailed {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            } else {
                XCTAssertEqual(kind, .fileCreated)
                finished.fulfill()
            }
        })

        recorder.record(.fileCreationFailed)
        wait(for: [entered], timeout: 5)
        // Reaching this line while the first write holds a lock is the responsiveness assertion.
        recorder.record(.fileCreated)
        release.signal()
        wait(for: [finished], timeout: 5)
    }

    func testMenuStormKeepsNewestFailuresAndCoalescesStateWithOneWriter() {
        let entered = expectation(description: "writer paused")
        let finished = expectation(description: "latest menu persisted")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let writes = RecordedActivities()
        let recorder = FinderActivityRecorder(persist: { kind, failure, timestamp in
            writes.append(FinderExtensionActivity(kind: kind, timestamp: timestamp, failure: failure))
            if kind == .launched {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            } else if kind == .menuPrepared {
                finished.fulfill()
            }
        })
        recorder.record(.launched)
        wait(for: [entered], timeout: 5)
        for _ in 0..<50_000 { recorder.record(.menuPrepared) }
        for index in 0..<30 {
            recorder.record(.fileCreationFailed, failure: .init(
                reason: .writeFailed, errorDomain: "test", errorCode: index
            ))
        }
        for _ in 0..<1_000 { recorder.record(.fileCreated) }
        recorder.record(.menuPrepared)
        XCTAssertEqual(writes.snapshot.count, 1)
        release.signal()
        wait(for: [finished], timeout: 5)
        let events = writes.snapshot
        XCTAssertEqual(events.count, 23)
        XCTAssertEqual(events.compactMap { $0.failure?.errorCode }, Array(10..<30))
        XCTAssertEqual(Array(events.suffix(2).map(\.kind)), [.fileCreated, .menuPrepared])
        XCTAssertEqual(events.map(\.timestamp), events.map(\.timestamp).sorted())
    }

    func testNewFailureSupersedesPendingSuccessAndMenuState() {
        let entered = expectation(description: "writer paused")
        let finished = expectation(description: "failure persisted")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let writes = RecordedActivities()
        let recorder = FinderActivityRecorder(persist: { kind, failure, timestamp in
            writes.append(.init(kind: kind, timestamp: timestamp, failure: failure))
            if kind == .launched {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            } else {
                XCTAssertEqual(kind, .fileCreationFailed)
                finished.fulfill()
            }
        })
        recorder.record(.launched)
        wait(for: [entered], timeout: 5)
        recorder.record(.menuPrepared)
        recorder.record(.fileCreated)
        recorder.record(.fileCreationFailed)
        release.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(writes.snapshot.map(\.kind), [.launched, .fileCreationFailed])
    }

    func testRecorderCanDeinitializeWhilePersistenceIsBlockedAndDropsPendingWork() {
        let entered = expectation(description: "writer paused")
        let release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let extraWrite = DispatchSemaphore(value: 0)
        var recorder: FinderActivityRecorder? = FinderActivityRecorder(persist: { kind, _, _ in
            if kind == .launched {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                returned.signal()
            } else {
                extraWrite.signal()
            }
        })
        weak var weakRecorder = recorder
        recorder?.record(.launched)
        wait(for: [entered], timeout: 5)
        for _ in 0..<50_000 { recorder?.record(.menuPrepared) }
        recorder = nil
        XCTAssertNil(weakRecorder)
        release.signal()
        XCTAssertEqual(returned.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(extraWrite.wait(timeout: .now() + 0.1), .timedOut)
    }

    func testPersistenceFailureDoesNotDiscardSubsequentActivity() {
        let finished = expectation(description: "record after failure")
        let recorder = FinderActivityRecorder(persist: { kind, _, _ in
            if kind == .fileCreationFailed { throw CocoaError(.fileWriteNoPermission) }
            finished.fulfill()
        })
        recorder.record(.fileCreationFailed)
        recorder.record(.fileCreated)
        wait(for: [finished], timeout: 5)
    }
}

private final class RecordedActivities: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FinderExtensionActivity] = []
    func append(_ event: FinderExtensionActivity) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
    var snapshot: [FinderExtensionActivity] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
