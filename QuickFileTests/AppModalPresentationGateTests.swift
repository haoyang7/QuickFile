import XCTest
@testable import QuickFile
@testable import QuickFileCore

@MainActor
final class AppModalPresentationGateTests: XCTestCase {
    func testNativePanelRejectsReentrancyAndReleasesItsSlotOnReturn() {
        let gate = AppModalPresentationGate()
        let result = gate.present {
            XCTAssertTrue(gate.isPresenting)
            XCTAssertNil(gate.present { XCTFail("Cannot nest another application's modal panel"); return 0 })
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertFalse(gate.isPresenting)
        XCTAssertEqual(gate.present { 7 }, 7)
    }

    func testFinderWaitsBeforeNavigationAndCancelsClosedWindowWithoutDrainingAnotherRequest() async {
        for closeWindow in [false, true] {
            let gate = AppModalPresentationGate()
            let pump = FinderAuthorizationRequestPump(presentationGate: gate)
            let request = FinderAuthorizationRequest(templateID: UUID(), destinationFolder: URL(fileURLWithPath: "/synthetic"))
            let reads = LockedTestValue(0)
            let prepared = expectation(description: "request claimed behind native panel")
            var windowAvailable = true
            var selectedTab = AppTab.templates
            var confirmations = 0
            var cancellations = 0
            var unavailableCancellations = 0
            XCTAssertTrue(gate.tryBegin())
            let drain = Task {
                await pump.drain(
                    takePendingRequest: {
                        reads.update { $0 += 1 }
                        return request
                    },
                    prepareForPresentation: { prepared.fulfill() },
                    willPresent: { selectedTab = .create },
                    confirmAuthorization: { _ in
                        confirmations += 1
                        XCTAssertTrue(gate.isPresenting)
                        XCTAssertNil(gate.present { XCTFail("Finder owns this presentation"); return 0 })
                        return nil
                    },
                    complete: { _, _ in XCTFail("No directory was confirmed"); return false },
                    didCancel: { cancellations += 1 },
                    didFail: { XCTFail("Unexpected failure: \($0)") },
                    isPresentationAvailable: { windowAvailable },
                    didCancelForUnavailableWindow: { claimed in
                        XCTAssertEqual(claimed.id, request.id)
                        unavailableCancellations += 1
                    }
                )
            }
            await fulfillment(of: [prepared], timeout: 2)
            XCTAssertTrue(gate.isFinderReserved)
            XCTAssertEqual(selectedTab, .templates)
            XCTAssertEqual(confirmations, 0)
            if closeWindow { windowAvailable = false; drain.cancel() }
            gate.finish()
            XCTAssertFalse(gate.tryBegin(), "A new panel cannot steal the reserved continuation's slot")
            await drain.value
            XCTAssertEqual(reads.value, 1)
            XCTAssertEqual(confirmations, closeWindow ? 0 : 1)
            XCTAssertEqual(cancellations, closeWindow ? 0 : 1)
            XCTAssertEqual(unavailableCancellations, closeWindow ? 1 : 0)
            XCTAssertEqual(selectedTab, closeWindow ? .templates : .create)
            XCTAssertFalse(gate.isPresenting)
            XCTAssertFalse(gate.isFinderReserved)
            XCTAssertEqual(gate.present { 9 }, 9)
        }
    }
}
