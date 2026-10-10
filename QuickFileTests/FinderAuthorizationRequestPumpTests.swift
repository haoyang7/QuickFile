import Foundation
import XCTest
@testable import QuickFile
@testable import QuickFileCore

@MainActor
final class FinderAuthorizationRequestPumpTests: XCTestCase {
    func testDrainKeepsClaimsOffMainActorAndCallbacksSerialOnMainActor() async {
        let requests = [makeRequest("first"), makeRequest("second")]
        let reader = PumpRequestReader([.request(requests[0]), .request(requests[1]), .empty])
        let pump = FinderAuthorizationRequestPump()
        let grantedDirectory = FileManager.default.temporaryDirectory
        var events: [String] = []
        var completed: [FinderAuthorizationRequest] = []
        var presented: [FinderAuthorizationRequest] = []

        await pump.drain(
            takePendingRequest: { try reader.take() },
            willPresent: {
                XCTAssertTrue(Thread.isMainThread)
                events.append("present")
            },
            confirmAuthorization: { request in
                XCTAssertTrue(Thread.isMainThread)
                presented.append(request)
                events.append("confirm \(request.destinationFolder.lastPathComponent)")
                return grantedDirectory
            },
            complete: { request, directory in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(directory, grantedDirectory)
                completed.append(request)
                events.append("start \(request.destinationFolder.lastPathComponent)")
                await Task.yield()
                XCTAssertTrue(Thread.isMainThread)
                events.append("finish \(request.destinationFolder.lastPathComponent)")
                return true
            },
            didCancel: { XCTFail("No request was cancelled") },
            didFail: { XCTFail("Unexpected read failure: \($0)") }
        )

        XCTAssertEqual(presented, requests, "The confirmation must receive complete request, template and target identities")
        XCTAssertEqual(completed, requests, "The pump must pass each original request unchanged")
        XCTAssertEqual(events, [
            "present", "confirm first", "start first", "finish first",
            "present", "confirm second", "start second", "finish second"
        ])
        XCTAssertEqual(reader.readCount, 3)
    }

    func testCancelledRequestStopsBeforeClaimingNextEvenWithPendingRecheck() async {
        let requests = [makeRequest("cancelled"), makeRequest("accepted")]
        let reader = PumpRequestReader([.request(requests[0]), .request(requests[1]), .empty])
        let pump = FinderAuthorizationRequestPump()
        var presentations = 0
        var cancellations = 0
        var completed: [FinderAuthorizationRequest] = []

        await pump.drain(
            takePendingRequest: { try reader.take() },
            willPresent: { presentations += 1 },
            confirmAuthorization: { request in
                request == requests[0] ? nil : request.destinationFolder
            },
            complete: { request, _ in completed.append(request); return true },
            didCancel: {
                XCTAssertTrue(Thread.isMainThread)
                cancellations += 1
                pump.requestRecheck()
            },
            didFail: { XCTFail("Unexpected read failure: \($0)") }
        )

        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(completed.isEmpty)
        XCTAssertEqual(reader.readCount, 1, "Cancel must not claim the next request, even after a notification")
    }

    func testFailedCompletionStopsBeforeClaimingNextRequestAndCanResume() async {
        let requests = [makeRequest("failed"), makeRequest("later")]
        let reader = PumpRequestReader([.request(requests[0]), .request(requests[1]), .empty])
        let pump = FinderAuthorizationRequestPump()
        var completed: [FinderAuthorizationRequest] = []

        await pump.drain(
            takePendingRequest: { try reader.take() },
            willPresent: {},
            confirmAuthorization: { $0.destinationFolder },
            complete: { request, _ in
                completed.append(request)
                pump.requestRecheck()
                return false
            },
            didCancel: { XCTFail("No request was cancelled") },
            didFail: { XCTFail("Completion failures belong to the owner: \($0)") }
        )

        XCTAssertEqual(completed, [requests[0]])
        XCTAssertEqual(reader.readCount, 1, "A recheck must not override a failed completion")

        await pump.drain(
            takePendingRequest: { try reader.take() },
            willPresent: {},
            confirmAuthorization: { $0.destinationFolder },
            complete: { request, _ in completed.append(request); return true },
            didCancel: { XCTFail("No request was cancelled") },
            didFail: { XCTFail("Unexpected read failure: \($0)") }
        )

        XCTAssertEqual(completed, requests)
        XCTAssertEqual(reader.readCount, 3)
    }

    func testReadFailureReportsWithoutNavigationThenAllowsLaterDrain() async {
        let request = makeRequest("later")
        let reader = PumpRequestReader([.failure, .request(request), .empty])
        let pump = FinderAuthorizationRequestPump()
        var events: [String] = []

        await pump.drain(
            takePendingRequest: { try reader.take() },
            willPresent: {
                XCTAssertTrue(Thread.isMainThread)
                XCTFail("Background read failure must not navigate")
            },
            confirmAuthorization: { _ in XCTFail("An unread request must not be presented"); return nil },
            complete: { _, _ in XCTFail("An unread request must not be completed"); return false },
            didCancel: { XCTFail("A read failure is not cancellation") },
            didFail: { error in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(error as? PumpRequestReader.ReadError, .unavailable)
                events.append("failure")
            }
        )

        XCTAssertEqual(events, ["failure"])
        XCTAssertEqual(reader.readCount, 1)

        await pump.drain(
            takePendingRequest: { try reader.take() },
            willPresent: {},
            confirmAuthorization: { $0.destinationFolder },
            complete: { received, _ in XCTAssertEqual(received, request); return true },
            didCancel: { XCTFail("No request was cancelled") },
            didFail: { XCTFail("Unexpected read failure: \($0)") }
        )

        XCTAssertEqual(reader.readCount, 3)
    }

    func testNotificationDuringEmptyReadRechecksBeforeReturning() async {
        let request = makeRequest("arrived")
        let reader = PumpRequestReader([.empty, .request(request), .empty], pauseFirstEmptyRead: true)
        defer { reader.resumeEmptyRead.signal() }
        let pump = FinderAuthorizationRequestPump()
        var completed: [FinderAuthorizationRequest] = []

        let drain = Task {
            await pump.drain(
                takePendingRequest: { try reader.take() },
                willPresent: {},
                confirmAuthorization: { $0.destinationFolder },
                complete: { received, _ in completed.append(received); return true },
                didCancel: { XCTFail("No request was cancelled") },
                didFail: { XCTFail("Unexpected read failure: \($0)") }
            )
        }
        let started = await BackgroundWork.run {
            reader.emptyReadStarted.wait(timeout: .now() + 5) == .success
        }
        XCTAssertTrue(started, "The empty queue read must be suspended before requesting a recheck")
        pump.requestRecheck()
        pump.requestRecheck()
        reader.resumeEmptyRead.signal()
        await drain.value

        XCTAssertEqual(completed, [request])
        XCTAssertEqual(reader.readCount, 3)
    }

    func testSameFolderRequestsKeepDistinctTemplateAndCancellationContext() async {
        let folder = FileManager.default.temporaryDirectory
        let requests = [FinderAuthorizationRequest(templateID: UUID(), destinationFolder: folder),
                        FinderAuthorizationRequest(templateID: UUID(), destinationFolder: folder)]
        let reader = PumpRequestReader([.request(requests[0]), .request(requests[1]), .empty])
        let pump = FinderAuthorizationRequestPump()
        var presented: [FinderAuthorizationRequest] = []
        var completed: [FinderAuthorizationRequest] = []
        var cancelled = 0
        await pump.drain(
            takePendingRequest: { try reader.take() }, willPresent: {},
            confirmAuthorization: { request in
                presented.append(request)
                return request.id == requests[0].id ? nil : request.destinationFolder
            },
            complete: { request, _ in completed.append(request); return true },
            didCancel: { cancelled += 1 }, didFail: { XCTFail("Unexpected read failure: \($0)") }
        )
        XCTAssertEqual(presented, [requests[0]])
        XCTAssertTrue(completed.isEmpty)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(reader.readCount, 1)
        // Only the owner can admit a second drain after explicit continuation.
        await pump.drain(
            takePendingRequest: { try reader.take() }, willPresent: {},
            confirmAuthorization: { request in presented.append(request); return request.destinationFolder },
            complete: { request, _ in completed.append(request); return true },
            didCancel: { XCTFail("The retained request should be accepted") },
            didFail: { XCTFail("Unexpected read failure: \($0)") }
        )
        XCTAssertEqual(presented, requests)
        XCTAssertEqual(completed, [requests[1]])
        XCTAssertEqual(reader.readCount, 3)
    }

    func testUnavailableWindowStopsBeforeClaimingAnyRequest() async {
        let reader = PumpRequestReader([.request(makeRequest("untouched")), .empty])
        let pump = FinderAuthorizationRequestPump()
        await pump.drain(
            takePendingRequest: { try reader.take() },
            willPresent: { XCTFail("A closed window must not present") },
            confirmAuthorization: { _ in XCTFail("A closed window must not open a panel"); return nil },
            complete: { _, _ in XCTFail("Unclaimed work must not complete"); return false },
            didCancel: { XCTFail("No panel was cancelled") },
            didFail: { XCTFail("No read should occur: \($0)") },
            isPresentationAvailable: { false },
            didCancelForUnavailableWindow: { _ in XCTFail("No request was claimed") }
        )
        XCTAssertEqual(reader.readCount, 0)
    }

    func testWindowClosingDuringClaimCancelsOnlyClaimedRequestWithoutPanelThenResumesRemainder() async {
        let requests = [makeRequest("claimed"), makeRequest("still-queued")]
        let reader = PumpRequestReader([.request(requests[0]), .request(requests[1]), .empty], pauseFirstRead: true)
        defer { reader.resumeRead.signal() }
        let pump = FinderAuthorizationRequestPump()
        var windowAvailable = true
        var cancelled: [FinderAuthorizationRequest] = []
        let drain = Task {
            await pump.drain(
                takePendingRequest: { try reader.take() },
                willPresent: { XCTFail("The originating window closed during its claim") },
                confirmAuthorization: { _ in XCTFail("No stale authorization panel may open"); return nil },
                complete: { _, _ in XCTFail("A request without a confirmed panel must not create"); return false },
                didCancel: { XCTFail("Window loss is not a user's Cancel click") },
                didFail: { XCTFail("Unexpected read error: \($0)") },
                isPresentationAvailable: { windowAvailable },
                didCancelForUnavailableWindow: { cancelled.append($0) }
            )
        }
        let started = await BackgroundWork.run { reader.readStarted.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        windowAvailable = false
        pump.requestRecheck()
        reader.resumeRead.signal()
        await drain.value
        XCTAssertEqual(cancelled, [requests[0]])
        XCTAssertEqual(reader.readCount, 1, "A recheck notification cannot consume requests after window loss")

        windowAvailable = true
        var completed: [FinderAuthorizationRequest] = []
        await pump.drain(
            takePendingRequest: { try reader.take() }, willPresent: {},
            confirmAuthorization: { $0.destinationFolder },
            complete: { request, _ in completed.append(request); return true },
            didCancel: { XCTFail("The remaining request should proceed") },
            didFail: { XCTFail("Unexpected read error: \($0)") },
            isPresentationAvailable: { windowAvailable },
            didCancelForUnavailableWindow: { _ in XCTFail("The replacement presentation is available") }
        )
        XCTAssertEqual(completed, [requests[1]])
        XCTAssertEqual(reader.readCount, 3)
    }

    func testWindowLossDuringPresentationPreparationNeverOpensPanelOrClaimsNextRequest() async {
        let requests = [makeRequest("claimed"), makeRequest("still-queued")]
        let reader = PumpRequestReader([.request(requests[0]), .request(requests[1])])
        let pump = FinderAuthorizationRequestPump()
        var windowAvailable = true
        var cancelled: [FinderAuthorizationRequest] = []
        await pump.drain(
            takePendingRequest: { try reader.take() },
            willPresent: { windowAvailable = false },
            confirmAuthorization: { _ in XCTFail("Preparation invalidated the window"); return nil },
            complete: { _, _ in XCTFail("An unconfirmed request must not create"); return false },
            didCancel: { XCTFail("No panel was shown") }, didFail: { XCTFail("Unexpected error: \($0)") },
            isPresentationAvailable: { windowAvailable },
            didCancelForUnavailableWindow: { cancelled.append($0) }
        )
        XCTAssertEqual(cancelled, [requests[0]])
        XCTAssertEqual(reader.readCount, 1)
    }

    func testWindowClosingDuringModalConfirmationDoesNotBeginCreationOrClaimNextRequest() async {
        for returnsDirectory in [true, false] {
            let requests = [makeRequest("claimed"), makeRequest("still-queued")]
            let reader = PumpRequestReader([.request(requests[0]), .request(requests[1])])
            let pump = FinderAuthorizationRequestPump()
            var windowAvailable = true
            var cancelled: [FinderAuthorizationRequest] = []
            await pump.drain(
                takePendingRequest: { try reader.take() }, willPresent: {},
                confirmAuthorization: { request in
                    windowAvailable = false // A modal panel can reenter the window event loop.
                    return returnsDirectory ? request.destinationFolder : nil
                },
                complete: { _, _ in XCTFail("A closed presentation must not start creation"); return false },
                didCancel: { XCTFail("Window loss has a separate single-claim cancellation status") },
                didFail: { XCTFail("Unexpected read failure: \($0)") },
                isPresentationAvailable: { windowAvailable },
                didCancelForUnavailableWindow: { cancelled.append($0) }
            )
            XCTAssertEqual(cancelled, [requests[0]])
            XCTAssertEqual(reader.readCount, 1)
        }
    }

    func testWindowClosingDuringEmptyReadIgnoresRecheckWithoutClaimingAnotherRequest() async {
        let request = makeRequest("still-queued")
        let reader = PumpRequestReader([.empty, .request(request), .empty], pauseFirstRead: true)
        defer { reader.resumeRead.signal() }
        let pump = FinderAuthorizationRequestPump()
        var windowAvailable = true
        let drain = Task {
            await pump.drain(
                takePendingRequest: { try reader.take() },
                willPresent: { XCTFail("The empty result needs no UI") },
                confirmAuthorization: { _ in XCTFail("No panel should open"); return nil },
                complete: { _, _ in XCTFail("No request was claimed"); return false },
                didCancel: { XCTFail("No request was claimed") },
                didFail: { XCTFail("Unexpected read failure: \($0)") },
                isPresentationAvailable: { windowAvailable },
                didCancelForUnavailableWindow: { _ in XCTFail("An empty read did not claim a request") }
            )
        }
        let started = await BackgroundWork.run { reader.readStarted.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        windowAvailable = false
        pump.requestRecheck()
        reader.resumeRead.signal()
        await drain.value
        XCTAssertEqual(reader.readCount, 1)
    }

    func testAuthorizationPanelMessageIdentifiesOneRequestAndExplicitCancelScope() {
        let request = makeRequest("requested-target")
        let message = AppKitFileActions.finderAuthorizationMessage(for: request, templateName: "Markdown")
        XCTAssertTrue(message.contains("Markdown"))
        XCTAssertFalse(message.contains(request.templateID.uuidString), "A known template should use its human-readable name")
        XCTAssertTrue(message.contains(request.id.uuidString))
        XCTAssertTrue(message.contains(request.destinationFolderPath))
        XCTAssertTrue(message.contains("保存所选文件夹及其子文件夹的 Finder 授权"))
        XCTAssertTrue(message.contains("后续创建也可使用"))
        XCTAssertTrue(message.contains("可在“诊断”中撤销"))
        XCTAssertFalse(message.contains("仅为该请求授权"))
        XCTAssertTrue(message.contains("取消仅取消当前请求"))
        XCTAssertTrue(message.contains("并暂停自动确认"))
        XCTAssertTrue(message.contains("其他待处理请求（如有）未被取消"))
        XCTAssertTrue(message.contains("点击“继续处理”后再逐个确认"))
        XCTAssertFalse(message.contains("其他待处理请求会继续逐个确认"))
        let unavailableTemplate = AppKitFileActions.finderAuthorizationMessage(for: request, templateName: nil)
        XCTAssertTrue(unavailableTemplate.contains(request.templateID.uuidString))
        XCTAssertTrue(unavailableTemplate.contains("将重新确认是否可用"))
    }

    func testClaimWaitsForPresentationAdmissionWithoutReadingNextOrPresenting() async throws {
        let first = makeRequest("waiting")
        let second = makeRequest("still-queued")
        let reader = PumpRequestReader([.request(first), .request(second), .empty])
        let pump = FinderAuthorizationRequestPump()
        let waiting = expectation(description: "Claim reached owner's interactive admission")
        let admissionGate = AsyncTestGate<Void>()
        defer { admissionGate.release(()) }
        var presentations = 0
        var completed: [FinderAuthorizationRequest] = []
        let drain = Task {
            await pump.drain(
                takePendingRequest: { try reader.take() },
                prepareForPresentation: {
                    waiting.fulfill()
                    await admissionGate.wait()
                },
                willPresent: { presentations += 1 },
                confirmAuthorization: { $0.destinationFolder },
                complete: { request, _ in completed.append(request); return false },
                didCancel: { XCTFail("The confirmed request was not cancelled") },
                didFail: { XCTFail("Unexpected failure: \($0)") })
        }
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(presentations, 0)
        XCTAssertTrue(completed.isEmpty)
        pump.requestRecheck()
        pump.requestRecheck()
        drain.cancel()
        XCTAssertEqual(reader.readCount, 1, "Cancellation/rechecks do not replace an outstanding claim")
        admissionGate.release(())
        await drain.value
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(completed, [first])
        XCTAssertEqual(reader.readCount, 1, "Failed completion still leaves the next request queued")
    }

    func testWindowLossDuringAdmissionWaitCancelsOnlyHeldClaimThenAllowsFreshDrain() async {
        let first = makeRequest("waiting")
        let second = makeRequest("still-queued")
        let reader = PumpRequestReader([.request(first), .request(second), .empty])
        let pump = FinderAuthorizationRequestPump()
        let waiting = expectation(description: "One claim waits for another operation")
        let admissionGate = AsyncTestGate<Void>()
        defer { admissionGate.release(()) }
        var available = true
        var cancelled: [FinderAuthorizationRequest] = []
        let drain = Task {
            await pump.drain(
                takePendingRequest: { try reader.take() },
                prepareForPresentation: {
                    waiting.fulfill()
                    await admissionGate.wait()
                },
                willPresent: { XCTFail("The waiting claim lost its window before admission resumed") },
                confirmAuthorization: { _ in XCTFail("No stale panel"); return nil },
                complete: { _, _ in XCTFail("No unconfirmed write"); return false },
                didCancel: { XCTFail("Window loss is not an explicit pause") },
                didFail: { XCTFail("Unexpected failure: \($0)") },
                isPresentationAvailable: { available },
                didCancelForUnavailableWindow: { cancelled.append($0) })
        }
        await fulfillment(of: [waiting], timeout: 5)
        available = false
        pump.requestRecheck()
        drain.cancel()
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertTrue(cancelled.isEmpty, "The owner still holds its outstanding operation")
        admissionGate.release(())
        await drain.value
        XCTAssertEqual(cancelled, [first])
        XCTAssertEqual(reader.readCount, 1)
        available = true
        var completed: [FinderAuthorizationRequest] = []
        await pump.drain(
            takePendingRequest: { try reader.take() }, willPresent: {},
            confirmAuthorization: { $0.destinationFolder },
            complete: { request, _ in completed.append(request); return true },
            didCancel: { XCTFail("Fresh window accepts the retained request") },
            didFail: { XCTFail("Unexpected failure: \($0)") },
            isPresentationAvailable: { available })
        XCTAssertEqual(completed, [second])
        XCTAssertEqual(reader.readCount, 3)
    }

    func testEmptyAndFailedReadsNeverAcquireInteractivePresentationAdmission() async {
        for response in [PumpRequestReader.Response.empty, .failure] {
            let reader = PumpRequestReader([response])
            let pump = FinderAuthorizationRequestPump()
            var failed = 0
            var empty = 0
            await pump.drain(
                takePendingRequest: { try reader.take() },
                prepareForPresentation: { XCTFail("No claimed request means no interactive reservation") },
                willPresent: { XCTFail("Queue-only feedback cannot navigate") },
                confirmAuthorization: { _ in XCTFail("No request to confirm"); return nil },
                complete: { _, _ in XCTFail("No request to create"); return false },
                didCancel: { XCTFail("No request to cancel") },
                didFail: { _ in failed += 1 },
                didFindNoClaimableRequest: { empty += 1 })
            XCTAssertEqual(failed + empty, 1)
            XCTAssertEqual(reader.readCount, 1)
        }
    }

    private func makeRequest(_ name: String) -> FinderAuthorizationRequest {
        FinderAuthorizationRequest(
            templateID: UUID(),
            destinationFolder: FileManager.default.temporaryDirectory.appendingPathComponent(name)
        )
    }
}

// Only the queue/read counter cross executors, and both are protected by lock.
// Semaphores explicitly control the empty-read race without a timing-based sleep.
private final class PumpRequestReader: @unchecked Sendable {
    enum Response {
        case request(FinderAuthorizationRequest)
        case empty
        case failure
    }

    enum ReadError: Error, Equatable {
        case unavailable
    }

    let emptyReadStarted = DispatchSemaphore(value: 0)
    let resumeEmptyRead = DispatchSemaphore(value: 0)
    let readStarted = DispatchSemaphore(value: 0)
    let resumeRead = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var responses: [Response]
    private var count = 0
    private var pauseNextEmptyRead: Bool
    private let pauseFirstRead: Bool

    init(_ responses: [Response], pauseFirstEmptyRead: Bool = false, pauseFirstRead: Bool = false) {
        self.responses = responses
        pauseNextEmptyRead = pauseFirstEmptyRead
        self.pauseFirstRead = pauseFirstRead
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func take() throws -> FinderAuthorizationRequest? {
        XCTAssertFalse(Thread.isMainThread, "Queue I/O must not run on MainActor")
        lock.lock()
        count += 1
        let response = responses.isEmpty ? .empty : responses.removeFirst()
        let shouldPauseRead = pauseFirstRead && count == 1
        let shouldPause: Bool
        if case .empty = response {
            shouldPause = pauseNextEmptyRead
            pauseNextEmptyRead = false
        } else {
            shouldPause = false
        }
        lock.unlock()

        if shouldPauseRead {
            readStarted.signal()
            XCTAssertEqual(resumeRead.wait(timeout: .now() + 10), .success)
        }
        if shouldPause {
            emptyReadStarted.signal()
            XCTAssertEqual(resumeEmptyRead.wait(timeout: .now() + 10), .success)
        }
        switch response {
        case let .request(request): return request
        case .empty: return nil
        case .failure: throw ReadError.unavailable
        }
    }
}
