import XCTest
@testable import QuickFileCore

final class FinderOperationSchedulerTests: XCTestCase {
    func testSlowTargetDoesNotBlockLocalCreationAndDuplicateClicksAreRejected() throws {
        let scheduler = FinderOperationScheduler()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = action("/Volumes/Slow")
        let started = expectation(description: "slow target started")
        let finished = expectation(description: "slow target finished")
        let localCreated = expectation(description: "local file created before slow target finishes")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        XCTAssertEqual(scheduler.submitCreation(blocked) {
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            finished.fulfill()
        }, .accepted)
        wait(for: [started], timeout: 2)
        // A different template targeting the same captured context must not enqueue a second click.
        XCTAssertEqual(scheduler.submitCreation(action("/Volumes/Slow")) { XCTFail("Rejected work executed") }, .targetBusy)
        XCTAssertEqual(scheduler.submitCreation(action(root.path)) {
            do {
                let result = try FileCreationService().createFile(for: FileCreationRequest(
                    template: FileTemplate(name: "Markdown", fileExtension: "md", content: "# Local"),
                    destinationFolder: root, requestedFilename: "local"
                ))
                XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "# Local")
            } catch { XCTFail("Local creation failed: \(error)") }
            localCreated.fulfill()
        }, .accepted)
        wait(for: [localCreated], timeout: 2)
        release.signal()
        wait(for: [finished], timeout: 2)
    }

    func testFullCapacityRejectsWithoutQueueingAndAuthorizationHasIndependentBoundedSlot() {
        let scheduler = FinderOperationScheduler()
        let firstStarted = expectation(description: "first started")
        let secondStarted = expectation(description: "second started")
        let creationsFinished = expectation(description: "creations finished")
        creationsFinished.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        let authRelease = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal(); authRelease.signal() }
        XCTAssertEqual(scheduler.submitCreation(action("/Volumes/A")) {
            firstStarted.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            creationsFinished.fulfill()
        }, .accepted)
        XCTAssertEqual(scheduler.submitCreation(action("/Volumes/B")) {
            secondStarted.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            creationsFinished.fulfill()
        }, .accepted)
        wait(for: [firstStarted, secondStarted], timeout: 2)
        XCTAssertFalse(scheduler.hasCreationCapacity)
        let third = action("/Volumes/C")
        for _ in 0..<1_000 {
            XCTAssertEqual(scheduler.submitCreation(third) { XCTFail("Rejected work was queued") }, .capacityReached)
        }
        let authorizationStarted = expectation(description: "authorization starts independently")
        let authorizationFinished = expectation(description: "authorization finishes")
        XCTAssertTrue(scheduler.submitAuthorization {
            authorizationStarted.fulfill()
            XCTAssertEqual(authRelease.wait(timeout: .now() + 5), .success)
            authorizationFinished.fulfill()
        })
        wait(for: [authorizationStarted], timeout: 2)
        XCTAssertFalse(scheduler.submitAuthorization { XCTFail("Extra authorization queued") })
        release.signal(); release.signal(); authRelease.signal()
        wait(for: [creationsFinished, authorizationFinished], timeout: 2)

        // Workers release admission after their closures return, not at an expectation inside them.
        let slotReleased = NSPredicate { _, _ in scheduler.hasCreationCapacity }
        expectation(for: slotReleased, evaluatedWith: nil)
        waitForExpectations(timeout: 2)
        let retried = expectation(description: "explicit retry accepted")
        XCTAssertEqual(scheduler.submitCreation(third) { retried.fulfill() }, .accepted)
        wait(for: [retried], timeout: 2)
    }

    func testLargeSelectionAdmissionUsesOnlyBoundedContextAndStillRejectsRepeat() {
        let scheduler = FinderOperationScheduler()
        let parent = URL(fileURLWithPath: "/tmp/Selection")
        let items = (0..<50_000).map { parent.appendingPathComponent("item\($0)") }
        let first = FinderMenuAction(templateID: UUID(), context: .items, targetedURL: parent, selectedItemURLs: items)
        var alteredTail = items
        alteredTail[49_999] = parent.appendingPathComponent("changed")
        let second = FinderMenuAction(templateID: UUID(), context: .items, targetedURL: parent, selectedItemURLs: alteredTail)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "selection finished")
        defer { release.signal() }
        XCTAssertEqual(scheduler.submitCreation(first) {
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            finished.fulfill()
        }, .accepted)
        // Admission is conservative: differing tails do not require scanning 50,000 URLs.
        XCTAssertEqual(scheduler.submitCreation(second) { XCTFail("Repeated context should be rejected") }, .targetBusy)
        release.signal()
        wait(for: [finished], timeout: 2)
    }

    private func action(_ path: String) -> FinderMenuAction {
        FinderMenuAction(templateID: UUID(), context: .container, destinationFolder: URL(fileURLWithPath: path))
    }
}
