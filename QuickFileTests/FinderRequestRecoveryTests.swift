import AppKit
import Darwin
import Foundation
import XCTest
@testable import QuickFile
@testable import QuickFileInfrastructure

@MainActor
final class FinderRequestRecoveryTests: XCTestCase {
    func testNativeConfirmationEscapeCancels() {
        XCTAssertFalse(runNativeConfirmation(keyCode: 53, characters: "\u{1b}"))
    }

    func testNativeConfirmationReturnCancels() {
        XCTAssertFalse(runNativeConfirmation(keyCode: 36, characters: "\r"))
    }

    func testNativeConfirmationKeypadEnterCancels() {
        XCTAssertFalse(runNativeConfirmation(keyCode: 76, characters: "\u{3}"))
    }

    func testNativeConfirmationRequiresExplicitArchiveChoice() {
        XCTAssertTrue(runNativeConfirmation(keyCode: nil, characters: ""))
    }

    private func runNativeConfirmation(keyCode: UInt16?, characters: String) -> Bool {
        let alert = FinderRequestRecoveryView.makeArchiveConfirmation(RecoveryUIFixture().candidate)
        var timedOut = false
        let input = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated {
                if let keyCode {
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: alert.window.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: keyCode)!
                    NSApp.postEvent(event, atStart: true)
                } else {
                    alert.buttons[1].performClick(nil)
                }
            }
        }
        let timeout = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                timedOut = true
                NSApp.abortModal()
            }
        }
        RunLoop.main.add(input, forMode: .modalPanel)
        RunLoop.main.add(timeout, forMode: .modalPanel)
        defer { input.invalidate(); timeout.invalidate() }
        let approved = FinderRequestRecoveryView.runArchiveConfirmation(alert)
        alert.window.orderOut(nil)
        XCTAssertFalse(timedOut, "The actual NSAlert modal loop must handle the input")
        return approved
    }

    func testInitializationDoesNotTouchTheQueue() {
        let fixture = RecoveryUIFixture()
        let model = makeModel(fixture)
        XCTAssertFalse(model.isPresented)
        XCTAssertFalse(model.hasInspected)
        XCTAssertFalse(model.canInspect)
        XCTAssertFalse(model.canPrepareSelection)
        XCTAssertEqual(fixture.state.value.inspections, 0)
        XCTAssertEqual(fixture.state.value.preparations, 0)
        XCTAssertEqual(fixture.state.value.commits, 0)
    }

    func testInspectionIsReadOnlyOffMainThreadAndRequiresExplicitSelection() async {
        let fixture = RecoveryUIFixture(isTruncated: true, legacyUnsupported: true)
        let model = makeModel(fixture)
        model.open()
        await model.inspect()

        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(model.candidates, [fixture.candidate])
        XCTAssertTrue(model.hasInspected)
        XCTAssertTrue(model.isTruncated)
        XCTAssertTrue(model.legacyRecoveryUnsupported)
        XCTAssertNil(model.selectedCandidateID)
        XCTAssertFalse(model.canPrepareSelection)
        XCTAssertEqual(fixture.state.value.inspections, 1)
        XCTAssertEqual(fixture.state.value.preparations, 0)
        XCTAssertEqual(fixture.state.value.commits, 0)
        model.select(fixture.candidate.id)
        XCTAssertTrue(model.canPrepareSelection)
    }

    func testUnsafeAndUnknownRowsCannotPrepare() async {
        let fixture = RecoveryUIFixture(reason: .unsafeEntry)
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        XCTAssertFalse(model.canPrepareSelection)
        let archived = await model.prepareSelected { _ in XCTFail("Unsafe entry must not present confirmation"); return true }
        XCTAssertFalse(archived)
        model.select(UUID().uuidString)
        XCTAssertNil(model.selectedCandidateID)
        XCTAssertEqual(fixture.state.value.preparations, 0)
        XCTAssertEqual(fixture.state.value.commits, 0)
    }

    func testCancelAfterFreshPreparationReleasesTicketWithoutCommit() async {
        let fixture = RecoveryUIFixture()
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        var confirmations = 0
        let archived = await model.prepareSelected { candidate in
            confirmations += 1
            XCTAssertEqual(candidate, fixture.candidate)
            XCTAssertEqual(model.operation, .confirming)
            XCTAssertEqual(fixture.state.value.liveTickets.count, 1)
            return false
        }
        XCTAssertFalse(archived)
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(fixture.state.value.preparations, 1)
        XCTAssertEqual(fixture.state.value.cancellations, 1)
        XCTAssertEqual(fixture.state.value.commits, 0)
        XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
        XCTAssertNil(model.operation)
        XCTAssertEqual(model.candidates, [fixture.candidate])
        XCTAssertNotNil(model.status)
    }

    func testExplicitIdentifierRejectsPathsAndInvalidInputBeforeIO() async {
        let fixture = RecoveryUIFixture()
        let model = makeModel(fixture)
        model.open()
        for input in ["", "../" + fixture.candidate.id, fixture.candidate.id + ".json", String(repeating: "x", count: 65)] {
            let archived = await model.prepareRequest(withID: input) { _ in
                XCTFail("Invalid identifier must not reach confirmation")
                return true
            }
            XCTAssertFalse(archived)
        }
        XCTAssertEqual(fixture.state.value.preparations, 0)
        XCTAssertEqual(fixture.state.value.commits, 0)
    }

    func testExplicitIdentifierStillRejectsFreshUnsafeClassification() async {
        let fixture = RecoveryUIFixture(reason: .unsafeEntry)
        let model = makeModel(fixture)
        model.open()
        let archived = await model.prepareRequest(withID: fixture.candidate.id) { _ in
            XCTFail("An explicit ID cannot authorize an unsafe original")
            return true
        }
        XCTAssertFalse(archived)
        XCTAssertEqual(fixture.state.value.preparations, 1)
        XCTAssertEqual(fixture.state.value.cancellations, 1)
        XCTAssertEqual(fixture.state.value.commits, 0)
        XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
    }

    func testExplicitIdentifierCloseDuringPrepareReleasesLateTicket() async {
        let gate = RecoveryUIOperationGate()
        defer { gate.release.signal() }
        let fixture = RecoveryUIFixture(prepareGate: gate)
        let model = makeModel(fixture)
        model.open()
        let preparation = Task {
            await model.prepareRequest(withID: fixture.candidate.id) { _ in
                XCTFail("A closed generation must not present or commit")
                return true
            }
        }
        await assertStarted(gate)
        model.close()
        model.open()
        let duplicate = await model.prepareRequest(withID: fixture.candidate.id) { _ in
            XCTFail("Running I/O must retain its admission")
            return true
        }
        XCTAssertFalse(duplicate)
        XCTAssertEqual(fixture.state.value.preparations, 1)
        gate.release.signal()
        let archived = await preparation.value
        XCTAssertFalse(archived)
        XCTAssertEqual(fixture.state.value.cancellations, 1)
        XCTAssertEqual(fixture.state.value.commits, 0)
        XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
    }

    func testExplicitIdentifierReachesRealOriginalBeyondAnUnpreparablePrefix() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Unreadable fixtures require a non-root user") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickFileRecoveryPrefix-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let ids = (0..<65).map { _ in UUID().uuidString }
        let urls = ids.map { directory.appendingPathComponent($0 + ".json") }
        defer {
            for url in urls { _ = chmod(url.path, 0o600) }
            try? FileManager.default.removeItem(at: directory)
        }
        for url in urls {
            try Data("retained unreadable original".utf8).write(to: url)
            XCTAssertEqual(chmod(url.path, 0), 0)
        }
        let store = FinderAuthorizationRequestStore(defaults: nil, directoryURL: directory)
        let first = try store.inspectRecoveryCandidates()
        XCTAssertEqual(first.candidates.count, 64)
        XCTAssertTrue(first.isTruncated)
        XCTAssertTrue(first.candidates.allSatisfy { !$0.canPrepare })
        let hidden = try XCTUnwrap(Set(ids).subtracting(first.candidates.map(\.id)).first)
        let source = directory.appendingPathComponent(hidden + ".json")
        XCTAssertEqual(chmod(source.path, 0o600), 0)
        let original = Data(repeating: 32, count: FinderAuthorizationRequestStore.maximumRequestBytes + 1)
        try original.write(to: source)
        let model = FinderRequestRecoveryViewModel(backend: .init(store: store))
        model.open()
        await model.inspect()
        XCTAssertFalse(model.candidates.contains { $0.id == hidden })
        XCTAssertTrue(model.candidates.allSatisfy { !$0.canPrepare })
        var confirmations = 0
        let archived = await model.prepareRequest(withID: hidden) { candidate in
            confirmations += 1
            XCTAssertEqual(candidate.id, hidden)
            XCTAssertEqual(candidate.reason, .oversized)
            return true
        }
        XCTAssertTrue(archived)
        XCTAssertEqual(confirmations, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(model.lastArchive?.archiveURL)), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.count, 64)
        for url in urls where url != source {
            var metadata = stat()
            XCTAssertEqual(lstat(url.path, &metadata), 0)
            XCTAssertEqual(metadata.st_mode & 0o777, 0, "Unselected originals must not be changed")
        }
        model.close()
    }

    func testConfirmationUsesFreshPreparedClassificationInsteadOfOldInspection() async {
        let fixture = RecoveryUIFixture(reason: .malformed, preparedReason: .oversized)
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        let archived = await model.prepareSelected { candidate in
            XCTAssertEqual(candidate.reason, .oversized)
            return false
        }
        XCTAssertFalse(archived)
        XCTAssertEqual(fixture.state.value.commits, 0)
    }

    func testClosedInspectionRetainsOperationUntilActualReturnAndCannotPopulateReopenedSheet() async {
        let gate = RecoveryUIOperationGate()
        defer { gate.release.signal() }
        let fixture = RecoveryUIFixture(inspectGate: gate)
        let model = makeModel(fixture)
        model.open()
        let inspection = Task { await model.inspect() }
        await assertStarted(gate)
        model.close()
        model.open()
        XCTAssertTrue(model.isOperationInFlight)
        await model.inspect()
        XCTAssertEqual(fixture.state.value.inspections, 1)
        gate.release.signal()
        await inspection.value
        XCTAssertTrue(model.isPresented)
        XCTAssertFalse(model.hasInspected)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(model.isOperationInFlight)
        XCTAssertFalse(model.status?.message.contains("仍在结束") ?? true)
        await model.inspect()
        XCTAssertTrue(model.hasInspected)
        XCTAssertEqual(fixture.state.value.inspections, 2)
    }

    func testCloseDuringPrepareCancelsLateTicketAndNeverPresentsOrCommits() async {
        let gate = RecoveryUIOperationGate()
        defer { gate.release.signal() }
        let fixture = RecoveryUIFixture(prepareGate: gate)
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        let preparation = Task {
            await model.prepareSelected { _ in XCTFail("Closed generation must never present"); return true }
        }
        await assertStarted(gate)
        model.close()
        model.open()
        XCTAssertEqual(model.operation, .preparing)
        await model.inspect()
        XCTAssertEqual(fixture.state.value.inspections, 1)
        gate.release.signal()
        let archived = await preparation.value
        XCTAssertFalse(archived)
        XCTAssertEqual(fixture.state.value.cancellations, 1)
        XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
        XCTAssertEqual(fixture.state.value.commits, 0)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(model.hasInspected)
        XCTAssertFalse(model.isOperationInFlight)
    }

    func testCancelledPrepareWaitStillHoldsOperationUntilLateTicketIsReleased() async {
        let gate = RecoveryUIOperationGate()
        defer { gate.release.signal() }
        let fixture = RecoveryUIFixture(prepareGate: gate)
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        let preparation = Task {
            await model.prepareSelected { _ in XCTFail("Cancelled preparation must not present"); return true }
        }
        await assertStarted(gate)
        preparation.cancel()
        XCTAssertTrue(model.isOperationInFlight)
        let duplicate = await model.prepareSelected { _ in XCTFail("Duplicate must not present"); return true }
        XCTAssertFalse(duplicate)
        XCTAssertEqual(fixture.state.value.preparations, 1)
        gate.release.signal()
        let archived = await preparation.value
        XCTAssertFalse(archived)
        XCTAssertEqual(fixture.state.value.cancellations, 1)
        XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
        XCTAssertEqual(fixture.state.value.commits, 0)
        XCTAssertFalse(model.isOperationInFlight)
    }

    func testCloseInsideNativeConfirmationImmediatelyCancelsTicketAndRejectsStaleApproval() async {
        let fixture = RecoveryUIFixture()
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        let archived = await model.prepareSelected { _ in
            model.close()
            XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
            XCTAssertEqual(fixture.state.value.cancellations, 1)
            model.open()
            return true
        }
        XCTAssertFalse(archived)
        XCTAssertTrue(model.isPresented)
        XCTAssertFalse(model.hasInspected)
        XCTAssertEqual(model.status, .information("上次操作已结束。请重新检查当前队列；自动处理仍暂停。"))
        XCTAssertNil(model.lastArchive)
        XCTAssertEqual(fixture.state.value.commits, 0)
        XCTAssertEqual(fixture.state.value.cancellations, 1, "Repeated cancellation must not release a later ticket")
    }

    func testApplicationBecomingBusyDuringConfirmationCancelsWithoutCommit() async {
        let fixture = RecoveryUIFixture()
        var canOperate = true
        let model = makeModel(fixture, canOperate: { canOperate })
        await loadAndSelect(model, fixture)
        let archived = await model.prepareSelected { _ in canOperate = false; return true }
        XCTAssertFalse(archived)
        XCTAssertEqual(fixture.state.value.commits, 0)
        XCTAssertEqual(fixture.state.value.cancellations, 1)
        XCTAssertFalse(model.canInspect)
    }

    func testCommitRunsOnceAndCloseRetainsOnlyReceiptWithoutResurrectingStaleSelection() async {
        let gate = RecoveryUIOperationGate()
        defer { gate.release.signal() }
        let fixture = RecoveryUIFixture(commitGate: gate)
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        let commit = Task { await model.prepareSelected { _ in true } }
        await assertStarted(gate)
        XCTAssertEqual(model.operation, .archiving)
        XCTAssertEqual(fixture.state.value.liveTickets.count, 1)
        let duplicate = await model.prepareSelected { _ in XCTFail("Duplicate confirmation"); return true }
        XCTAssertFalse(duplicate)
        model.close()
        model.open()
        XCTAssertTrue(model.isOperationInFlight)
        XCTAssertEqual(fixture.state.value.liveTickets.count, 1, "The actual commit still owns the ticket")
        XCTAssertEqual(fixture.state.value.cancellations, 0)
        await model.inspect()
        XCTAssertEqual(fixture.state.value.inspections, 1)
        gate.release.signal()
        let archived = await commit.value
        XCTAssertTrue(archived, "Closing cannot turn an already-committed move into a failed operation")
        XCTAssertEqual(model.lastArchive?.requestID, fixture.candidate.id)
        XCTAssertNotNil(model.lastArchive?.archiveURL)
        XCTAssertEqual(fixture.state.value.commits, 1)
        XCTAssertEqual(fixture.state.value.completedCommits, 1)
        XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
        XCTAssertTrue(model.isPresented)
        XCTAssertFalse(model.hasInspected)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(model.isOperationInFlight)
        XCTAssertEqual(fixture.state.value.inspections, 1, "Commit must never automatically inspect or drain")
        if case .archived = model.status { XCTFail("Late receipt must not resurrect success") }
    }

    func testCancellationAfterCommitStartsReportsActualOutcomeWhenPresentationRemains() async {
        let gate = RecoveryUIOperationGate()
        defer { gate.release.signal() }
        let fixture = RecoveryUIFixture(commitGate: gate)
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        let commit = Task { await model.prepareSelected { _ in true } }
        await assertStarted(gate)
        commit.cancel()
        XCTAssertTrue(model.isOperationInFlight)
        gate.release.signal()
        let archived = await commit.value
        XCTAssertTrue(archived)
        XCTAssertEqual(model.status, .archived(durabilityWarning: false))
        XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
        XCTAssertEqual(fixture.state.value.commits, 1)
    }

    func testSuccessfulArchiveDoesNotRetryReinspectOrSelectAnotherRequest() async {
        let fixture = RecoveryUIFixture(durabilityWarning: true)
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        let archived = await model.prepareSelected { _ in true }
        XCTAssertTrue(archived)
        XCTAssertEqual(model.status, .archived(durabilityWarning: true))
        XCTAssertEqual(model.lastArchive?.requestID, fixture.candidate.id)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertNil(model.selectedCandidateID)
        XCTAssertFalse(model.canPrepareSelection)
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(fixture.state.value.inspections, 1)
        XCTAssertEqual(fixture.state.value.preparations, 1)
        XCTAssertEqual(fixture.state.value.commits, 1)
        XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
        let duplicate = await model.prepareSelected { _ in XCTFail("Success cannot be replayed"); return true }
        XCTAssertFalse(duplicate)
        XCTAssertEqual(fixture.state.value.commits, 1)
    }

    func testCommittedReceiptSurvivesCloseAndReopenWhenArchiveLocationIsUnverified() async {
        let fixture = RecoveryUIFixture(durabilityWarning: true, archiveLocationVerified: false)
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        let archived = await model.prepareSelected { _ in true }
        XCTAssertTrue(archived)
        let receipt = model.lastArchive
        XCTAssertNotNil(receipt)
        XCTAssertNil(receipt?.archiveURL)
        XCTAssertEqual(receipt?.durabilityWarning, true)
        model.close()
        model.open()
        XCTAssertEqual(model.lastArchive, receipt)
        XCTAssertNil(model.selectedCandidateID)
        XCTAssertFalse(model.hasInspected)
        XCTAssertEqual(fixture.state.value.commits, 1)
        XCTAssertEqual(fixture.state.value.inspections, 1)
    }

    func testOnlyLatestCommittedReceiptIsRetainedAndRefreshDoesNotEraseIt() async {
        let fixture = RecoveryUIFixture()
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        let firstArchived = await model.prepareSelected { _ in true }
        XCTAssertTrue(firstArchived)
        let firstReceipt = model.lastArchive
        await model.inspect()
        XCTAssertEqual(model.lastArchive, firstReceipt)
        model.select(fixture.candidate.id)
        let secondArchived = await model.prepareSelected { _ in true }
        XCTAssertTrue(secondArchived)
        XCTAssertNotEqual(model.lastArchive?.archiveURL, firstReceipt?.archiveURL)
        XCTAssertEqual(model.lastArchive?.requestID, fixture.candidate.id)
        XCTAssertEqual(fixture.state.value.commits, 2)
        XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
    }

    func testChangedSourceErrorReleasesTicketAndRequiresFreshPreparation() async {
        let fixture = RecoveryUIFixture(commitFailure: .changed)
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        let archived = await model.prepareSelected { _ in true }
        XCTAssertFalse(archived)
        XCTAssertEqual(model.status, .failure(FinderAuthorizationRequestStore.RecoveryError.changed.localizedDescription))
        XCTAssertNil(model.selectedCandidateID)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(model.hasInspected)
        XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
        XCTAssertEqual(fixture.state.value.commits, 1)
        XCTAssertEqual(fixture.state.value.completedCommits, 0)
        XCTAssertEqual(fixture.state.value.inspections, 1)
    }

    func testPreparationFailureNeverShowsRawPathOrPayloadAndDoesNotConfirm() async {
        let fixture = RecoveryUIFixture(prepareFailsWithPrivateError: true)
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        let archived = await model.prepareSelected { _ in XCTFail("Failed preparation must not present"); return true }
        XCTAssertFalse(archived)
        let message = model.status?.message ?? ""
        XCTAssertFalse(message.contains("PRIVATE_PAYLOAD"))
        XCTAssertFalse(message.contains("/Users/private"))
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(fixture.state.value.commits, 0)
        XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
    }

    func testMismatchedPreparedIDIsCancelledWithoutConfirmation() async {
        let fixture = RecoveryUIFixture(preparedID: UUID().uuidString)
        let model = makeModel(fixture)
        await loadAndSelect(model, fixture)
        let archived = await model.prepareSelected { _ in XCTFail("Wrong entry cannot be confirmed"); return true }
        XCTAssertFalse(archived)
        XCTAssertEqual(fixture.state.value.cancellations, 1)
        XCTAssertEqual(fixture.state.value.commits, 0)
        XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
    }

    func testAppBusyCheckRejectsReadAndPrepare() async {
        let fixture = RecoveryUIFixture()
        var canOperate = false
        let model = makeModel(fixture, canOperate: { canOperate })
        model.open()
        await model.inspect()
        XCTAssertEqual(fixture.state.value.inspections, 0)
        canOperate = true
        await model.inspect()
        model.select(fixture.candidate.id)
        canOperate = false
        let archived = await model.prepareSelected { _ in XCTFail("Busy app cannot prepare"); return true }
        XCTAssertFalse(archived)
        XCTAssertEqual(fixture.state.value.preparations, 0)
    }

    func testSettledModelReleasesAfterRepeatedInspectionAndCancelledConfirmations() async {
        let fixture = RecoveryUIFixture()
        var model: FinderRequestRecoveryViewModel? = makeModel(fixture)
        weak var released = model
        for _ in 0..<5 {
            await loadAndSelect(model!, fixture)
            let archived = await model!.prepareSelected { _ in false }
            XCTAssertFalse(archived)
            model!.close()
        }
        model = nil
        XCTAssertNil(released)
        XCTAssertTrue(fixture.state.value.liveTickets.isEmpty)
        XCTAssertEqual(fixture.state.value.cancellations, 5)
    }

    private func makeModel(
        _ fixture: RecoveryUIFixture,
        canOperate: @escaping @MainActor () -> Bool = { true }
    ) -> FinderRequestRecoveryViewModel {
        FinderRequestRecoveryViewModel(backend: .init(
            inspect: { try fixture.inspect() },
            prepare: { try fixture.prepare($0) },
            cancel: { fixture.cancel($0) },
            commit: { try fixture.commit($0) }
        ), canOperate: canOperate)
    }

    private func loadAndSelect(_ model: FinderRequestRecoveryViewModel, _ fixture: RecoveryUIFixture) async {
        model.open()
        await model.inspect()
        model.select(fixture.candidate.id)
    }

    private func assertStarted(_ gate: RecoveryUIOperationGate, file: StaticString = #filePath, line: UInt = #line) async {
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started, file: file, line: line)
    }
}

private final class RecoveryUIFixture: Sendable {
    typealias Store = FinderAuthorizationRequestStore
    struct State: Sendable {
        var inspections = 0
        var preparations = 0
        var commits = 0
        var completedCommits = 0
        var cancellations = 0
        var liveTickets: Set<UUID> = []
    }

    let state = LockedTestValue(State())
    let candidate: Store.RecoveryCandidate
    private let preparedReason: Store.RecoveryReason?
    private let preparedID: String?
    private let isTruncated: Bool
    private let legacyUnsupported: Bool
    private let durabilityWarning: Bool
    private let archiveLocationVerified: Bool
    private let commitFailure: Store.RecoveryError?
    private let prepareFailsWithPrivateError: Bool
    private let inspectGate: RecoveryUIOperationGate?
    private let prepareGate: RecoveryUIOperationGate?
    private let commitGate: RecoveryUIOperationGate?

    init(
        reason: Store.RecoveryReason = .malformed,
        preparedReason: Store.RecoveryReason? = nil,
        preparedID: String? = nil,
        isTruncated: Bool = false,
        legacyUnsupported: Bool = false,
        durabilityWarning: Bool = false,
        archiveLocationVerified: Bool = true,
        commitFailure: Store.RecoveryError? = nil,
        prepareFailsWithPrivateError: Bool = false,
        inspectGate: RecoveryUIOperationGate? = nil,
        prepareGate: RecoveryUIOperationGate? = nil,
        commitGate: RecoveryUIOperationGate? = nil
    ) {
        candidate = Store.RecoveryCandidate(id: UUID().uuidString, reason: reason)
        self.preparedReason = preparedReason
        self.preparedID = preparedID
        self.isTruncated = isTruncated
        self.legacyUnsupported = legacyUnsupported
        self.durabilityWarning = durabilityWarning
        self.archiveLocationVerified = archiveLocationVerified
        self.commitFailure = commitFailure
        self.prepareFailsWithPrivateError = prepareFailsWithPrivateError
        self.inspectGate = inspectGate
        self.prepareGate = prepareGate
        self.commitGate = commitGate
    }

    func inspect() throws -> Store.RecoveryInspection {
        XCTAssertFalse(Thread.isMainThread)
        state.update { $0.inspections += 1 }
        inspectGate?.blockOnce()
        return Store.RecoveryInspection(candidates: [candidate], isTruncated: isTruncated,
                                       legacyRecoveryUnsupported: legacyUnsupported)
    }

    func prepare(_ id: String) throws -> Store.PreparedRecovery {
        XCTAssertFalse(Thread.isMainThread)
        XCTAssertEqual(id, candidate.id)
        state.update { $0.preparations += 1 }
        prepareGate?.blockOnce()
        if prepareFailsWithPrivateError {
            throw NSError(domain: "TestPrivate", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "/Users/private/PRIVATE_PAYLOAD"])
        }
        let ticket = Store.PreparedRecovery(id: UUID(), candidate: .init(
            id: preparedID ?? id, reason: preparedReason ?? candidate.reason
        ))
        state.update { $0.liveTickets.insert(ticket.id) }
        return ticket
    }

    func cancel(_ ticket: Store.PreparedRecovery) {
        state.update {
            if $0.liveTickets.remove(ticket.id) != nil { $0.cancellations += 1 }
        }
    }

    func commit(_ ticket: Store.PreparedRecovery) throws -> Store.RecoveryResult {
        XCTAssertFalse(Thread.isMainThread)
        state.update {
            $0.commits += 1
            XCTAssertTrue($0.liveTickets.contains(ticket.id))
        }
        defer { state.update { _ = $0.liveTickets.remove(ticket.id) } }
        commitGate?.blockOnce()
        if let commitFailure { throw commitFailure }
        state.update { $0.completedCommits += 1 }
        return Store.RecoveryResult(requestID: ticket.candidate.id,
            archiveURL: archiveLocationVerified
                ? URL(fileURLWithPath: "/private/test-archive/\(ticket.id.uuidString).json") : nil,
            durabilityWarning: durabilityWarning)
    }
}

private final class RecoveryUIOperationGate: Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let didBlock = LockedTestValue(false)

    func blockOnce() {
        let shouldBlock = didBlock.update { blocked in
            guard !blocked else { return false }
            blocked = true
            return true
        }
        guard shouldBlock else { return }
        started.signal()
        XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
    }
}
