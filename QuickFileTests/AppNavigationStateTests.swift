import Foundation
import XCTest
@testable import QuickFile
@testable import QuickFileCore

final class AppNavigationStateTests: XCTestCase {
    func testColdRouteWaitsForStartupAuthorizationCheckAndDrain() {
        var pending = QuickFilePendingAppRoute()
        XCTAssertTrue(pending.receive(QuickFileAppRoute.templates.url))
        XCTAssertNil(pending.takeIfReady(startupAuthorizationChecked: false, isBusy: false))
        XCTAssertNil(pending.takeIfReady(startupAuthorizationChecked: true, isBusy: true))
        XCTAssertEqual(pending.route, .templates)
        XCTAssertEqual(pending.takeIfReady(startupAuthorizationChecked: true, isBusy: false), .templates)
        XCTAssertNil(pending.takeIfReady(startupAuthorizationChecked: true, isBusy: false))
    }

    func testLatestValidRouteWinsWhileBusyAndInvalidURLDoesNotEraseIt() {
        var pending = QuickFilePendingAppRoute()
        pending.receive(QuickFileAppRoute.templates.url)
        pending.receive(QuickFileAppRoute.diagnostics.url)
        XCTAssertFalse(pending.receive(URL(string: "quickfile://open/create?execute=true")!))
        for _ in 0..<100 {
            XCTAssertNil(pending.takeIfReady(startupAuthorizationChecked: true, isBusy: true))
        }
        XCTAssertEqual(pending.takeIfReady(startupAuthorizationChecked: true, isBusy: false), .diagnostics)
    }

    func testWindowPendingSlotsAreIndependent() {
        var receiving = QuickFilePendingAppRoute()
        var other = QuickFilePendingAppRoute()
        receiving.receive(QuickFileAppRoute.templates.url)
        XCTAssertNil(other.takeIfReady(startupAuthorizationChecked: true, isBusy: false))
        XCTAssertEqual(receiving.takeIfReady(startupAuthorizationChecked: true, isBusy: false), .templates)
    }

    func testNewerManualNavigationDiscardsPendingRoute() {
        var pending = QuickFilePendingAppRoute()
        pending.receive(QuickFileAppRoute.templates.url)
        pending.discard()
        XCTAssertNil(pending.takeIfReady(startupAuthorizationChecked: true, isBusy: false))
    }
    func testClosedWindowGenerationCannotPresentAfterReopening() throws {
        var window = QuickFileWindowPresentationState()
        XCTAssertNil(window.generation)
        window.appear()
        let original = try XCTUnwrap(window.generation)
        XCTAssertTrue(window.canPresent(original))
        window.appear()
        XCTAssertEqual(window.generation, original, "Repeated appearance must not invalidate a live callback")
        window.disappear()
        XCTAssertFalse(window.canPresent(original))
        window.appear()
        let reopened = try XCTUnwrap(window.generation)
        XCTAssertNotEqual(reopened, original)
        XCTAssertFalse(window.canPresent(original), "A stale claim cannot borrow a reopened window")
        XCTAssertTrue(window.canPresent(reopened))
    }

    func testReopenedWindowWaitsForOldDrainThenChecksOnlyOnce() throws {
        var window = QuickFileWindowPresentationState()
        window.appear()
        let closedGeneration = try XCTUnwrap(window.requestAuthorizationCheck())
        window.disappear()
        window.appear()
        let reopened = try XCTUnwrap(window.requestAuthorizationCheck())
        XCTAssertTrue(window.finishAuthorizationCheck(for: reopened, isBusy: true))
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: true))
        XCTAssertTrue(window.shouldResumeAuthorizationCheck(isBusy: false))
        XCTAssertFalse(window.finishAuthorizationCheck(for: closedGeneration, isBusy: false),
                       "An old completion must not clear the reopened window's intent")
        let retry = try XCTUnwrap(window.requestAuthorizationCheck())
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: false))
        XCTAssertTrue(window.isAwaitingAuthorizationCheck, "Navigation waits for the queued retry too")
        XCTAssertTrue(window.finishAuthorizationCheck(for: retry, isBusy: false))
        for _ in 0..<100 {
            XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: false),
                           "An empty queue completion must not start another drain")
        }
        XCTAssertFalse(window.isAwaitingAuthorizationCheck)
    }

    func testRepeatedRequestsCoalesceToOneTaskAndOneExtraCheck() throws {
        var window = QuickFileWindowPresentationState()
        window.appear()
        let generation = try XCTUnwrap(window.requestAuthorizationCheck())
        for _ in 0..<100 { XCTAssertNil(window.requestAuthorizationCheck()) }
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: false))
        XCTAssertTrue(window.finishAuthorizationCheck(for: generation, isBusy: false))
        XCTAssertTrue(window.shouldResumeAuthorizationCheck(isBusy: false))
        let retry = try XCTUnwrap(window.requestAuthorizationCheck())
        XCTAssertTrue(window.finishAuthorizationCheck(for: retry, isBusy: false))
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: false))
        XCTAssertFalse(window.isAwaitingAuthorizationCheck)
    }

    func testQueuedCheckMergesOneResumeReceiptWithoutAutomaticReplay() throws {
        var window = QuickFileWindowPresentationState()
        window.appear()
        let generation = try XCTUnwrap(window.requestAuthorizationCheck())
        let pauseID = UUID()
        for _ in 0..<100 {
            XCTAssertNil(window.requestAuthorizationCheck(resumingPauseID: pauseID))
            XCTAssertNil(window.requestAuthorizationCheck())
        }
        XCTAssertEqual(window.takeAuthorizationResumePauseID(for: generation, currentPauseID: pauseID), pauseID)
        XCTAssertTrue(window.finishAuthorizationCheck(
            for: generation, isBusy: false, resumingPauseID: pauseID, currentPauseID: UUID()
        ))
        XCTAssertTrue(window.shouldResumeAuthorizationCheck(isBusy: false))
        let followUp = try XCTUnwrap(window.requestAuthorizationCheck())
        XCTAssertNil(window.takeAuthorizationResumePauseID(for: followUp, currentPauseID: pauseID))
        XCTAssertTrue(window.finishAuthorizationCheck(for: followUp, isBusy: false))
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: false))
    }

    func testRunningCheckPreservesNewerResumeAndDiscardsStaleReceipt() throws {
        var window = QuickFileWindowPresentationState()
        window.appear()
        let generation = try XCTUnwrap(window.requestAuthorizationCheck())
        XCTAssertNil(window.takeAuthorizationResumePauseID(for: generation, currentPauseID: UUID()))
        let oldPauseID = UUID()
        let currentPauseID = UUID()
        XCTAssertNil(window.requestAuthorizationCheck(resumingPauseID: oldPauseID))
        XCTAssertNil(window.requestAuthorizationCheck(resumingPauseID: currentPauseID))
        XCTAssertTrue(window.finishAuthorizationCheck(for: generation, isBusy: false))
        let followUp = try XCTUnwrap(window.requestAuthorizationCheck())
        XCTAssertEqual(window.takeAuthorizationResumePauseID(for: followUp, currentPauseID: currentPauseID), currentPauseID)
        XCTAssertTrue(window.finishAuthorizationCheck(for: followUp, isBusy: false))
        let staleCheck = try XCTUnwrap(window.requestAuthorizationCheck(resumingPauseID: oldPauseID))
        XCTAssertNil(window.takeAuthorizationResumePauseID(for: staleCheck, currentPauseID: currentPauseID))
        XCTAssertTrue(window.finishAuthorizationCheck(for: staleCheck, isBusy: false))
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: false))
    }

    func testBusyCheckReturnsOnlyStillCurrentResumeReceipt() throws {
        var window = QuickFileWindowPresentationState()
        window.appear()
        let pauseID = UUID()
        let generation = try XCTUnwrap(window.requestAuthorizationCheck(resumingPauseID: pauseID))
        XCTAssertEqual(window.takeAuthorizationResumePauseID(for: generation, currentPauseID: pauseID), pauseID)
        XCTAssertTrue(window.finishAuthorizationCheck(
            for: generation, isBusy: true, resumingPauseID: pauseID, currentPauseID: pauseID
        ))
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: true))
        XCTAssertTrue(window.shouldResumeAuthorizationCheck(isBusy: false))
        let retry = try XCTUnwrap(window.requestAuthorizationCheck())
        XCTAssertEqual(window.takeAuthorizationResumePauseID(for: retry, currentPauseID: pauseID), pauseID)
        let newerPauseID = UUID()
        XCTAssertTrue(window.finishAuthorizationCheck(
            for: retry, isBusy: true, resumingPauseID: pauseID, currentPauseID: newerPauseID
        ))
        let staleRetry = try XCTUnwrap(window.requestAuthorizationCheck())
        XCTAssertNil(window.takeAuthorizationResumePauseID(for: staleRetry, currentPauseID: newerPauseID))
        XCTAssertTrue(window.finishAuthorizationCheck(for: staleRetry, isBusy: false))
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: false))
    }

    func testCloseDiscardsResumeReceiptAndOldGenerationCannotConsumeNewReceipt() throws {
        var window = QuickFileWindowPresentationState()
        window.appear()
        let pauseID = UUID()
        let old = try XCTUnwrap(window.requestAuthorizationCheck(resumingPauseID: pauseID))
        window.disappear()
        window.appear()
        let reopened = try XCTUnwrap(window.requestAuthorizationCheck())
        XCTAssertNil(window.takeAuthorizationResumePauseID(for: reopened, currentPauseID: pauseID))
        XCTAssertNil(window.requestAuthorizationCheck(resumingPauseID: pauseID))
        XCTAssertNil(window.takeAuthorizationResumePauseID(for: old, currentPauseID: pauseID))
        XCTAssertFalse(window.finishAuthorizationCheck(
            for: old, isBusy: true, resumingPauseID: pauseID, currentPauseID: pauseID
        ))
        XCTAssertEqual(window.takeAuthorizationResumePauseID(for: reopened, currentPauseID: pauseID), pauseID)
        XCTAssertTrue(window.finishAuthorizationCheck(for: reopened, isBusy: false))
        let followUp = try XCTUnwrap(window.requestAuthorizationCheck())
        XCTAssertNil(window.takeAuthorizationResumePauseID(for: followUp, currentPauseID: pauseID))
        XCTAssertTrue(window.finishAuthorizationCheck(for: followUp, isBusy: false))
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: false))
    }

    func testClosedWindowClearsItsQueuedAndDeferredAuthorizationCheck() throws {
        var window = QuickFileWindowPresentationState()
        window.appear()
        let generation = try XCTUnwrap(window.requestAuthorizationCheck())
        XCTAssertNil(window.requestAuthorizationCheck())
        window.disappear()
        XCTAssertFalse(window.finishAuthorizationCheck(for: generation, isBusy: false))
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: false))
        XCTAssertFalse(window.isAwaitingAuthorizationCheck)
        window.appear()
        XCTAssertFalse(window.shouldResumeAuthorizationCheck(isBusy: false))
        XCTAssertFalse(window.isAwaitingAuthorizationCheck)
    }
}
