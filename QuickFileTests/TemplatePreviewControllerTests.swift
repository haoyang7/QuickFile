import Combine
import Foundation
import XCTest
@testable import QuickFile
@testable import QuickFileCore

@MainActor
final class TemplatePreviewControllerTests: XCTestCase {
    func testOrdinaryEditsWithoutPreviewDoNotPublishUnchangedState() async throws {
        let controller = activeController(worker: TemplatePreviewWorker())
        var publications = 0
        let subscription = controller.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<1_000 { controller.invalidate() }
        XCTAssertEqual(publications, 0)

        let task = try XCTUnwrap(controller.request(content: "shown", fileExtension: "txt"))
        await task.value
        publications = 0
        controller.invalidate()
        XCTAssertNil(controller.result)
        XCTAssertEqual(publications, 1)
        for _ in 0..<1_000 { controller.invalidate() }
        XCTAssertEqual(publications, 1, "Already-empty preview state must not refresh the editor")
    }

    func testWorkRunsOffMainThreadAndRepeatedClicksDoNotPrepareOrQueueAnotherRequest() async throws {
        let barrier = PreviewRenderBarrier(entered: expectation(description: "preview render entered"))
        let worker = TemplatePreviewWorker(render: { barrier.render($0) })
        let controller = activeController(worker: worker)
        defer { barrier.release.signal() }

        let task = try XCTUnwrap(controller.request(content: "first", fileExtension: "txt"))
        await fulfillment(of: [barrier.entered], timeout: 2)
        XCTAssertTrue(controller.isWorking)
        XCTAssertNil(controller.result)
        XCTAssertNil(controller.request(content: String(repeating: "x", count: 65_537), fileExtension: "txt"))
        XCTAssertNil(controller.result, "A repeated click must not even preflight an oversized draft")
        XCTAssertFalse(controller.busyElsewhere)
        XCTAssertEqual(barrier.callCount, 1)

        barrier.release.signal()
        await task.value
        XCTAssertFalse(controller.isWorking)
        XCTAssertEqual(try controller.result?.get().text, "first")
        let retry = try XCTUnwrap(controller.request(content: "retry", fileExtension: "txt"))
        await retry.value
        XCTAssertEqual(try controller.result?.get().text, "retry")
        XCTAssertEqual(barrier.callCount, 2)
        XCTAssertTrue(barrier.allCallsWereBackground)
    }

    func testInvalidationAndTaskCancellationCannotReleaseTheRunningSlot() async throws {
        let barrier = PreviewRenderBarrier(entered: expectation(description: "preview render entered"))
        let worker = TemplatePreviewWorker(render: { barrier.render($0) })
        let owner = activeController(worker: worker)
        let other = activeController(worker: worker)
        defer { barrier.release.signal() }
        let task = try XCTUnwrap(owner.request(content: "obsolete", fileExtension: "txt"))
        await fulfillment(of: [barrier.entered], timeout: 2)

        task.cancel()
        owner.invalidate()
        XCTAssertTrue(owner.isWorking)
        XCTAssertNil(owner.request(content: "changed", fileExtension: "txt"))
        XCTAssertNil(other.request(content: "other", fileExtension: "txt"))
        XCTAssertTrue(other.busyElsewhere)
        XCTAssertFalse(other.isWorking)
        XCTAssertEqual(barrier.callCount, 1)

        barrier.release.signal()
        await task.value
        XCTAssertNil(owner.result)
        XCTAssertFalse(owner.isWorking)
        XCTAssertNil(other.result, "Rejected work is never queued")
        let retry = try XCTUnwrap(other.request(content: "other retry", fileExtension: "txt"))
        XCTAssertFalse(other.busyElsewhere)
        await retry.value
        XCTAssertEqual(try other.result?.get().text, "other retry")
        XCTAssertEqual(barrier.callCount, 2)
    }

    func testClosedControllerIsReleasedBeforeItsSynchronousRenderReturns() async throws {
        let barrier = PreviewRenderBarrier(entered: expectation(description: "preview render entered"))
        let worker = TemplatePreviewWorker(render: { barrier.render($0) })
        var controller: TemplatePreviewController? = activeController(worker: worker)
        weak var weakController = controller
        let other = activeController(worker: worker)
        defer { barrier.release.signal() }
        let task = try XCTUnwrap(controller?.request(content: "closed", fileExtension: "txt"))
        await fulfillment(of: [barrier.entered], timeout: 2)

        controller?.deactivate()
        controller = nil
        XCTAssertNil(weakController, "A blocked worker must not retain the editor controller")
        XCTAssertNil(other.request(content: "waiting", fileExtension: "txt"))
        XCTAssertTrue(other.busyElsewhere)
        XCTAssertEqual(barrier.callCount, 1)

        barrier.release.signal()
        await task.value
        let retry = try XCTUnwrap(other.request(content: "reopened", fileExtension: "txt"))
        await retry.value
        XCTAssertEqual(try other.result?.get().text, "reopened")
        XCTAssertEqual(barrier.callCount, 2)
    }

    func testReactivatedEditorRejectsOldSessionCompletionAndCanRequestAgain() async throws {
        let barrier = PreviewRenderBarrier(entered: expectation(description: "preview render entered"))
        let worker = TemplatePreviewWorker(render: { barrier.render($0) })
        let controller = activeController(worker: worker)
        defer { barrier.release.signal() }
        let task = try XCTUnwrap(controller.request(content: "old session", fileExtension: "txt"))
        await fulfillment(of: [barrier.entered], timeout: 2)

        controller.deactivate()
        controller.activate()
        XCTAssertTrue(controller.isWorking)
        XCTAssertNil(controller.request(content: "new session", fileExtension: "txt"))
        barrier.release.signal()
        await task.value
        XCTAssertNil(controller.result)
        XCTAssertFalse(controller.isWorking)

        let retry = try XCTUnwrap(controller.request(content: "new session", fileExtension: "txt"))
        await retry.value
        XCTAssertEqual(try controller.result?.get().text, "new session")
    }

    func testCompletedPreviewIsClearedOnDraftChangeAndWhenEditorDisappears() async throws {
        let calls = PreviewRenderCalls()
        let worker = TemplatePreviewWorker(render: { calls.render($0) })
        let controller = activeController(worker: worker)
        let first = try XCTUnwrap(controller.request(content: "visible", fileExtension: "txt"))
        await first.value
        XCTAssertEqual(try controller.result?.get().text, "visible")

        controller.invalidate()
        XCTAssertNil(controller.result)
        XCTAssertEqual(calls.count, 1, "Draft invalidation must never render automatically")
        let second = try XCTUnwrap(controller.request(content: "next", fileExtension: "txt"))
        await second.value
        controller.deactivate()
        XCTAssertNil(controller.result)
        XCTAssertFalse(controller.busyElsewhere)
        XCTAssertNil(controller.request(content: "hidden", fileExtension: "txt"))
        XCTAssertEqual(calls.count, 2)
    }

    func testRenderingFailureReleasesAdmissionAndAllowsRetry() async throws {
        let calls = PreviewRenderCalls(failFirst: true)
        let worker = TemplatePreviewWorker(render: { calls.render($0) })
        let controller = activeController(worker: worker)
        let failed = try XCTUnwrap(controller.request(content: "first", fileExtension: "txt"))
        await failed.value
        XCTAssertEqual(controller.result, .failure(.renderingFailed))
        XCTAssertFalse(controller.isWorking)

        let retry = try XCTUnwrap(controller.request(content: "retry", fileExtension: "txt"))
        await retry.value
        XCTAssertEqual(try controller.result?.get().text, "retry")
        XCTAssertEqual(calls.count, 2)
    }

    func testOversizedRequestsDoNotDispatchAndReleasePreflightAdmission() async throws {
        let calls = PreviewRenderCalls()
        let worker = TemplatePreviewWorker(render: { calls.render($0) })
        let controller = activeController(worker: worker)
        XCTAssertNil(controller.request(content: String(repeating: "x", count: 65_537), fileExtension: "txt"))
        XCTAssertEqual(controller.result, .failure(.inputTooLarge))
        XCTAssertFalse(controller.isWorking)
        XCTAssertNil(controller.request(content: "small", fileExtension: String(repeating: "x", count: 256)))
        XCTAssertEqual(controller.result, .failure(.fileExtensionTooLarge))
        XCTAssertEqual(calls.count, 0)

        let other = activeController(worker: worker)
        let retry = try XCTUnwrap(other.request(content: "valid", fileExtension: "txt"))
        await retry.value
        XCTAssertEqual(try other.result?.get().text, "valid")
        XCTAssertEqual(calls.count, 1)
        let ownRetry = try XCTUnwrap(controller.request(content: "own retry", fileExtension: "txt"))
        await ownRetry.value
        XCTAssertEqual(try controller.result?.get().text, "own retry")
    }

    func testDefaultControllersShareApplicationAdmissionAndRejectWithoutQueueing() async throws {
        let owner = TemplatePreviewController()
        let other = TemplatePreviewController()
        owner.activate()
        other.activate()
        let task = try XCTUnwrap(owner.request(content: "owner", fileExtension: "txt"))
        // No main-actor suspension yet: the admitted worker task cannot have started.
        XCTAssertNil(other.request(content: "rejected", fileExtension: "txt"))
        XCTAssertTrue(other.busyElsewhere)
        XCTAssertFalse(other.isWorking)
        await task.value
        XCTAssertEqual(try owner.result?.get().text, "owner")
        XCTAssertNil(other.result)

        let retry = try XCTUnwrap(other.request(content: "retry", fileExtension: "txt"))
        await retry.value
        XCTAssertFalse(other.busyElsewhere)
        XCTAssertEqual(try other.result?.get().text, "retry")
    }

    private func activeController(worker: TemplatePreviewWorker) -> TemplatePreviewController {
        let controller = TemplatePreviewController(worker: worker)
        controller.activate()
        return controller
    }
}

private final class PreviewRenderBarrier: @unchecked Sendable {
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    private var backgroundOnly = true

    init(entered: XCTestExpectation) {
        self.entered = entered
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var allCallsWereBackground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return backgroundOnly
    }

    func render(_ request: TemplatePreviewRequest) -> Result<TemplatePreviewOutput, TemplatePreviewError> {
        lock.lock()
        calls += 1
        let shouldBlock = calls == 1
        backgroundOnly = backgroundOnly && !Thread.isMainThread
        lock.unlock()
        if shouldBlock {
            entered.fulfill()
            guard release.wait(timeout: .now() + 10) == .success else { return .failure(.renderingFailed) }
        }
        return TemplatePreview.render(request)
    }
}

private final class PreviewRenderCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let failFirst: Bool

    init(failFirst: Bool = false) {
        self.failFirst = failFirst
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func render(_ request: TemplatePreviewRequest) -> Result<TemplatePreviewOutput, TemplatePreviewError> {
        lock.lock()
        calls += 1
        let shouldFail = failFirst && calls == 1
        lock.unlock()
        return shouldFail ? .failure(.renderingFailed) : TemplatePreview.render(request)
    }
}
