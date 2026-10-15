import XCTest
import os
@testable import QuickFile

@MainActor
final class AutomaticFileOpenerTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/example/created.txt")

    func testCallbackOwnsScopeAndReleasesBeforeReturningFailure() async throws {
        let releases = OSAllocatedUnfairLock(initialState: 0)
        let started = expectation(description: "system handoff")
        var callback: (@Sendable (Error?) -> Void)?
        let id = UUID()
        let opener = AutomaticFileOpener(prepare: { _, receivedID, required in
            XCTAssertEqual(receivedID, id)
            XCTAssertTrue(required)
            return .init { releases.withLock { $0 += 1 } }
        }, open: { _, done in callback = done; started.fulfill() })
        let task = Task { await opener.openCreatedFile(url, authorizationID: id, requiresAuthorization: true) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(releases.withLock { $0 }, 0)
        XCTAssertTrue(opener.isOccupied)
        let busy = await opener.openCreatedFile(url, requiresAuthorization: true)
        XCTAssertTrue(busy is AutomaticFileOpener.Failure)
        callback?(CocoaError(.fileReadNoPermission))
        let error = await task.value as NSError?
        XCTAssertEqual(error?.code, NSFileReadNoPermissionError)
        XCTAssertEqual(releases.withLock { $0 }, 1)
        XCTAssertFalse(opener.isOccupied)
    }

    func testTimeoutDoesNotReleaseScopeOrAdmitMoreHandoffsAndLateCallbackRecovers() async {
        let releases = OSAllocatedUnfairLock(initialState: 0)
        let started = expectation(description: "system handoff")
        var callback: (@Sendable (Error?) -> Void)?
        var opens = 0
        let opener = AutomaticFileOpener(timeoutNanoseconds: 100_000_000, prepare: { _, _, _ in
            .init { releases.withLock { $0 += 1 } }
        }, open: { _, done in opens += 1; callback = done; started.fulfill() })
        let task = Task { await opener.openCreatedFile(url, requiresAuthorization: true) }
        await fulfillment(of: [started], timeout: 2)
        guard case AutomaticFileOpener.Failure.timedOut? = await task.value else { return XCTFail("Expected timeout") }
        XCTAssertTrue(opener.isOccupied)
        XCTAssertEqual(releases.withLock { $0 }, 0)
        for _ in 0..<3 {
            guard case AutomaticFileOpener.Failure.busy? = await opener.openCreatedFile(url, requiresAuthorization: true) else {
                return XCTFail("Timeout must not re-admit while the OS still owns the handoff")
            }
        }
        XCTAssertEqual(opens, 1)
        callback?(nil)
        for _ in 0..<100 where opener.isOccupied { await Task.yield() }
        XCTAssertFalse(opener.isOccupied)
        XCTAssertEqual(releases.withLock { $0 }, 1)
    }

    func testDeadlineDuringBookmarkResolutionNeverStartsLateSystemOpen() async {
        let entered = expectation(description: "prepare")
        let gate = DispatchSemaphore(value: 0)
        let releases = OSAllocatedUnfairLock(initialState: 0)
        let opener = AutomaticFileOpener(timeoutNanoseconds: 100_000_000, prepare: { _, _, _ in
            entered.fulfill()
            gate.wait()
            return .init { releases.withLock { $0 += 1 } }
        }, open: { _, _ in XCTFail("No late opening after a preparation timeout") })
        let task = Task { await opener.openCreatedFile(url, requiresAuthorization: true) }
        await fulfillment(of: [entered], timeout: 2)
        guard case AutomaticFileOpener.Failure.timedOut? = await task.value else {
            gate.signal(); return XCTFail("Expected timeout")
        }
        XCTAssertTrue(opener.isOccupied)
        gate.signal()
        for _ in 0..<1000 where opener.isOccupied { await Task.yield() }
        XCTAssertFalse(opener.isOccupied)
        XCTAssertEqual(releases.withLock { $0 }, 1)
    }

    func testDisabledAndRejectedAuthorizationDoNotOpenOrStrandAdmission() async {
        for enabled in [false, true] {
            let opener = AutomaticFileOpener(prepare: { _, _, _ in
                if enabled { throw CocoaError(.fileReadNoPermission) }
                return nil
            }, open: { _, _ in XCTFail("No admitted opening") })
            let error = await opener.openCreatedFile(url, requiresAuthorization: true)
            XCTAssertEqual(error != nil, enabled)
            XCTAssertFalse(opener.isOccupied)
        }
    }
}
