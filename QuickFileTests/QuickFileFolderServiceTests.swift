import AppKit
import XCTest
@testable import QuickFile
@testable import QuickFileCore
@testable import QuickFileInfrastructure

@MainActor
final class QuickFileFolderServiceTests: XCTestCase {
    private func pasteboard(_ values: [String]) -> NSPasteboard {
        let board = NSPasteboard(name: .init("QuickFileFolderServiceTests.\(UUID().uuidString)"))
        board.clearContents()
        let items = values.map { value in
            let item = NSPasteboardItem()
            item.setString(value, forType: .fileURL)
            return item
        }
        if !items.isEmpty { XCTAssertTrue(board.writeObjects(items)) }
        return board
    }

    private func model() -> QuickFileViewModel {
        let template = FileTemplate(name: "Fixture", fileExtension: "txt", content: "Keep content")
        let model = QuickFileViewModel(templates: [template])
        model.requestedFilename = "Keep filename"
        return model
    }

    private func integration(
        verificationClientProvider: @escaping () async -> (any FinderVerificationClient)? = { nil },
        folderOpener: @escaping (URL) -> Bool = { _ in true }
    ) -> FinderIntegrationViewModel {
        FinderIntegrationViewModel(
            statusProvider: { true },
            runtimeProvider: {
                FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
                    registration: .registered, registrationEvidence: "test", enabled: $0, responded: true
                )
            },
            managementOpener: {}, verificationClientProvider: verificationClientProvider,
            directoryIdentityProvider: { _ in
                try DirectoryIdentity.capture(at: FileManager.default.temporaryDirectory)
            }, folderOpener: folderOpener
        )
    }

    func testReadsOneFileURLFromServicesPasteboardWithoutRequiringDiskAccess() throws {
        let board = pasteboard([])
        defer { board.releaseGlobally() }
        // No fixture is created. Services input is a hint, not a disk capability.
        let hint = URL(fileURLWithPath: "/QuickFile-service-fixture/nonexistent folder", isDirectory: true)
        XCTAssertTrue(board.writeObjects([hint as NSURL]))
        XCTAssertEqual(try QuickFileFolderService.folderHint(from: board), hint)
    }

    func testRejectsEmptyMultipleRemoteRelativeParameterizedAndOversizedPayloads() {
        let selections: [[String]] = [
            [], ["file:///one", "file:///two"], ["https://example.com/folder"],
            ["file://server/share"], ["relative/folder"], ["file:relative"],
            ["file:///folder?create=true"], ["file:///folder#fragment"],
            ["file://user@localhost/folder"], ["file://localhost:123/folder"],
            ["file:///folder%00suffix"], [""],
            ["file:///" + String(repeating: "a", count: QuickFileFolderService.maximumURLBytes)]
        ]
        for values in selections {
            let board = pasteboard(values)
            defer { board.releaseGlobally() }
            XCTAssertThrowsError(try QuickFileFolderService.folderHint(from: board),
                                 "Unexpectedly accepted \(values)") { error in
                XCTAssertEqual(error as? QuickFileFolderService.RequestError, .invalidSelection)
            }
        }
        let textOnly = pasteboard([])
        defer { textOnly.releaseGlobally() }
        textOnly.setString("file:///folder", forType: .string)
        XCTAssertThrowsError(try QuickFileFolderService.folderHint(from: textOnly))
    }

    func testRejectsDecodedNULWhilePreservingLiteralPercentEscapes() throws {
        let invalid = [
            "file:///%00folder", "file:///folder%00suffix", "file:///folder%00",
            "file:///folder\u{0}suffix", "file:///folder%00%FF", "file:///folder%FF%00"
        ]
        for payload in invalid {
            let board = pasteboard([payload])
            defer { board.releaseGlobally() }
            XCTAssertEqual(board.pasteboardItems?.first?.data(forType: .fileURL), Data(payload.utf8))
            XCTAssertThrowsError(try QuickFileFolderService.folderHint(from: board), payload) { error in
                XCTAssertEqual(error as? QuickFileFolderService.RequestError, .invalidSelection)
            }
        }
        // Decode once: %2500 names a literal %00, not a NUL character.
        let hint = URL(fileURLWithPath: "/QuickFile-service-fixture/literal%00 folder", isDirectory: true)
        let board = pasteboard([hint.absoluteString])
        defer { board.releaseGlobally() }
        XCTAssertEqual(try QuickFileFolderService.folderHint(from: board), hint)
    }

    func testServiceSelectorReportsDuplicateAndInvalidInputWithoutReplacingPendingRequest() throws {
        let service = QuickFileFolderService(openCreationWindow: { true })
        let invalid = pasteboard([])
        let valid = pasteboard(["file:///first"])
        let other = pasteboard(["file:///second"])
        defer { invalid.releaseGlobally(); valid.releaseGlobally(); other.releaseGlobally() }
        var error: NSString?
        service.newFileWithQuickFile(invalid, userData: nil, error: &error)
        XCTAssertEqual(error as String?, QuickFileFolderService.RequestError.invalidSelection.errorDescription)
        XCTAssertNil(service.pendingRequest)
        error = nil
        service.newFileWithQuickFile(valid, userData: nil, error: &error)
        XCTAssertNil(error)
        let first = try XCTUnwrap(service.pendingRequest)
        for _ in 0..<100 {
            error = nil
            service.newFileWithQuickFile(other, userData: nil, error: &error)
            XCTAssertEqual(error as String?, QuickFileFolderService.RequestError.requestPending.errorDescription)
            XCTAssertEqual(service.pendingRequest, first)
        }
        service.cancel(requestID: UUID())
        XCTAssertEqual(service.pendingRequest, first)
    }

    func testArrivalBusySelectionAndPanelCancellationPreserveExistingForm() async throws {
        let service = QuickFileFolderService(openCreationWindow: { true })
        let board = pasteboard(["file:///hint"])
        defer { board.releaseGlobally() }
        let model = model()
        let original = URL(fileURLWithPath: "/original")
        await model.selectDestinationFolder(original)
        let templateID = model.selectedTemplateID
        let templates = model.templates
        var finishBusySelection: CheckedContinuation<URL?, Never>?
        let busy = expectation(description: "existing selection owns admission")
        let operation = Task { @MainActor in
            await model.selectDestinationFolder(choosing: {
                await withCheckedContinuation { continuation in
                    finishBusySelection = continuation
                    busy.fulfill()
                }
            })
        }
        await fulfillment(of: [busy], timeout: 2)
        let request = try service.receive(board)
        await service.selectFolder(requestID: request.id, viewModel: model,
                                   finderIntegration: integration(),
                                   isPresentationAvailable: { true }, choose: { _ in
            XCTFail("A busy application must not present a service panel")
            return URL(fileURLWithPath: "/unexpected")
        })
        XCTAssertEqual(service.pendingRequest, request)
        finishBusySelection?.resume(returning: nil)
        await operation.value
        await service.selectFolder(requestID: request.id, viewModel: model,
                                   finderIntegration: integration(),
                                   isPresentationAvailable: { true }, choose: { hint in
            XCTAssertEqual(hint.path, "/hint")
            return nil
        })
        XCTAssertEqual(model.destinationFolder, original)
        XCTAssertEqual(model.selectedTemplateID, templateID)
        XCTAssertEqual(model.templates, templates)
        XCTAssertEqual(model.requestedFilename, "Keep filename")
        XCTAssertEqual(service.pendingRequest, request, "Canceling the panel leaves an explicit retry available")
        service.cancel(requestID: request.id)
        XCTAssertNil(service.pendingRequest)
        XCTAssertEqual(model.destinationFolder, original)
    }

    func testOnlyPanelReturnValueIsAppliedAndRequestCanBeConsumedOnlyOnce() async throws {
        let service = QuickFileFolderService(openCreationWindow: { true })
        let board = pasteboard(["file:///hint"])
        defer { board.releaseGlobally() }
        let model = model()
        let selected = URL(fileURLWithPath: "/explicit-panel-selection")
        let request = try service.receive(board)
        var selections = 0
        var navigations = 0
        for _ in 0..<2 {
            await service.selectFolder(requestID: request.id, viewModel: model,
                finderIntegration: integration(),
                isPresentationAvailable: { true }, willPresent: {
                    XCTAssertTrue(model.isAuthorizingDirectory)
                    XCTAssertTrue(service.isSelectingFolder)
                    navigations += 1
                }, choose: { _ in
                XCTAssertEqual(navigations, 1, "Explicit navigation precedes the panel under its lease")
                selections += 1
                return selected
            })
        }
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(navigations, 1)
        XCTAssertEqual(model.destinationFolder, selected)
        XCTAssertEqual(model.requestedFilename, "Keep filename")
        XCTAssertNil(service.pendingRequest)
        XCTAssertFalse(model.isBusy)
    }

    func testTwoWindowsCannotConsumeConcurrentlyAndClosedWindowCannotApplyLateSelection() async throws {
        let service = QuickFileFolderService(openCreationWindow: { true })
        let board = pasteboard(["file:///hint"])
        defer { board.releaseGlobally() }
        let model = model()
        let original = URL(fileURLWithPath: "/original")
        await model.selectDestinationFolder(original)
        let request = try service.receive(board)
        var window = QuickFileWindowPresentationState()
        window.appear()
        let generation = try XCTUnwrap(window.generation)
        var completeSelection: CheckedContinuation<URL?, Never>?
        let presented = expectation(description: "first window presented")
        let firstWindow = Task { @MainActor in
            await service.selectFolder(requestID: request.id, viewModel: model,
                finderIntegration: integration(),
                isPresentationAvailable: { window.canPresent(generation) }, choose: { _ in
                    await withCheckedContinuation { continuation in
                        completeSelection = continuation
                        presented.fulfill()
                    }
                })
        }
        await fulfillment(of: [presented], timeout: 2)
        await service.selectFolder(requestID: request.id, viewModel: model,
                                   finderIntegration: integration(),
                                   isPresentationAvailable: { true }, choose: { _ in
            XCTFail("Another window cannot consume the active request")
            return nil
        })
        window.disappear()
        window.appear()
        completeSelection?.resume(returning: URL(fileURLWithPath: "/late-selection"))
        await firstWindow.value
        XCTAssertEqual(model.destinationFolder, original)
        XCTAssertEqual(service.pendingRequest, request)
        XCTAssertFalse(service.isSelectingFolder)
        await service.selectFolder(requestID: request.id, viewModel: model,
            finderIntegration: integration(),
            isPresentationAvailable: { window.canPresent(generation) }, willPresent: {
                XCTFail("A queued action from the closed window cannot navigate")
            }, choose: { _ in
                XCTFail("A queued action from the closed window cannot present")
                return nil
            })
        let reopenedGeneration = try XCTUnwrap(window.generation)
        await service.selectFolder(requestID: request.id, viewModel: model,
            finderIntegration: integration(),
            isPresentationAvailable: { window.canPresent(reopenedGeneration) },
            choose: { _ in URL(fileURLWithPath: "/reopened-selection") })
        XCTAssertEqual(model.destinationFolder?.path, "/reopened-selection")
        XCTAssertNil(service.pendingRequest)
    }

    func testCancelDuringPanelRejectsLateReturnAndKeepsAdmissionBounded() async throws {
        let service = QuickFileFolderService(openCreationWindow: { true })
        let board = pasteboard(["file:///hint"])
        defer { board.releaseGlobally() }
        let model = model()
        let request = try service.receive(board)
        let presented = expectation(description: "selection started")
        var finish: CheckedContinuation<URL?, Never>?
        let selection = Task { @MainActor in
            await service.selectFolder(requestID: request.id, viewModel: model,
                                       finderIntegration: integration(),
                                       isPresentationAvailable: { true }, choose: { _ in
                await withCheckedContinuation { continuation in
                    finish = continuation
                    presented.fulfill()
                }
            })
        }
        await fulfillment(of: [presented], timeout: 2)
        service.cancel(requestID: request.id)
        XCTAssertThrowsError(try service.receive(board))
        finish?.resume(returning: URL(fileURLWithPath: "/canceled-selection"))
        await selection.value
        XCTAssertNil(model.destinationFolder)
        XCTAssertNil(service.pendingRequest)
        XCTAssertFalse(service.isSelectingFolder)
        XCTAssertNoThrow(try service.receive(board))
    }

    func testLateOpenerFailureCannotChangeNewRequestAndOnlyOneOpenRunsAtATime() async throws {
        var completions: [CheckedContinuation<Bool, Never>] = []
        let firstOpen = expectation(description: "first opener")
        let nextOpen = expectation(description: "new request opener")
        let service = QuickFileFolderService(openCreationWindow: {
            await withCheckedContinuation { continuation in
                completions.append(continuation)
                if completions.count == 1 { firstOpen.fulfill() } else { nextOpen.fulfill() }
            }
        })
        let board = pasteboard(["file:///hint"])
        defer { board.releaseGlobally() }
        let first = try service.receive(board)
        await fulfillment(of: [firstOpen], timeout: 2)
        service.cancel(requestID: first.id)
        let second = try service.receive(board)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(completions.count, 1, "Opening has one in-flight slot too")
        completions[0].resume(returning: false)
        await fulfillment(of: [nextOpen], timeout: 2)
        XCTAssertEqual(service.pendingRequest, second)
        XCTAssertFalse(service.couldNotOpenWindow, "The old result belongs only to its original request")
        completions[1].resume(returning: false)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(service.pendingRequest, second)
        XCTAssertTrue(service.couldNotOpenWindow)
    }

    func testReselectingSameFolderCancelsPendingVerificationBeforeFinderCanOpen() async throws {
        let client = VerificationClient()
        let providerStarted = expectation(description: "verification provider started")
        var finishProvider: CheckedContinuation<Void, Never>?
        var finderOpens = 0
        let integration = integration(verificationClientProvider: {
            await withCheckedContinuation { continuation in
                finishProvider = continuation
                providerStarted.fulfill()
            }
            return client
        }, folderOpener: { _ in finderOpens += 1; return true })
        let folder = URL(fileURLWithPath: "/same-service-target", isDirectory: true)
        let model = model()
        await model.selectDestinationFolder(folder)
        let verification = integration.startVerification(in: folder)
        await fulfillment(of: [providerStarted], timeout: 2)
        XCTAssertEqual(integration.verificationState, .preparing)
        XCTAssertFalse(model.isAuthorizationCheckBusy)

        let service = QuickFileFolderService(openCreationWindow: { true })
        let board = pasteboard([folder.absoluteString])
        defer { board.releaseGlobally() }
        let request = try service.receive(board)
        await service.selectFolder(requestID: request.id, viewModel: model,
            finderIntegration: integration, isPresentationAvailable: { true }, choose: { _ in folder })
        integration.destinationDidChange(to: model.destinationFolder)
        XCTAssertEqual(model.destinationFolder, folder)
        XCTAssertEqual(model.finderAuthorizationState, .notConfirmed)
        XCTAssertEqual(model.requestedFilename, "Keep filename")
        XCTAssertNil(service.pendingRequest)
        XCTAssertEqual(integration.verificationState, .idle)

        finishProvider?.resume()
        await verification?.value
        XCTAssertEqual(client.beginCount, 0)
        XCTAssertEqual(finderOpens, 0)
        XCTAssertEqual(integration.verificationState, .idle)
        XCTAssertFalse(integration.isVerificationOperationInFlight)
    }

    func testReselectingSameFolderDiscardsLateVerificationReceipt() async throws {
        let client = VerificationClient()
        let integration = integration(verificationClientProvider: { client })
        let folder = URL(fileURLWithPath: "/same-service-target", isDirectory: true)
        let model = model()
        await model.selectDestinationFolder(folder)
        await integration.startVerification(in: folder)?.value
        XCTAssertEqual(integration.verificationState, .awaitingCreation)
        let checkStarted = expectation(description: "verification check started")
        var finishCheck: CheckedContinuation<FinderFirstUseVerificationStatus, Never>?
        client.checkProvider = {
            await withCheckedContinuation { continuation in
                finishCheck = continuation
                checkStarted.fulfill()
            }
        }
        let check = Task { @MainActor in await integration.checkVerification() }
        await fulfillment(of: [checkStarted], timeout: 2)

        let service = QuickFileFolderService(openCreationWindow: { true })
        let board = pasteboard([folder.absoluteString])
        defer { board.releaseGlobally() }
        let request = try service.receive(board)
        await service.selectFolder(requestID: request.id, viewModel: model,
            finderIntegration: integration, isPresentationAvailable: { true }, choose: { _ in folder })
        XCTAssertEqual(client.cancelCount, 1)
        finishCheck?.resume(returning: .creationReported)
        await check.value
        XCTAssertEqual(integration.verificationState, .idle)
        XCTAssertFalse(integration.isCheckingVerification)
        XCTAssertFalse(integration.isVerificationOperationInFlight)
    }

    func testCanceledOrInvalidatedSelectionsPreserveExistingVerification() async throws {
        for cancellation in ["panel", "request", "window"] {
            let client = VerificationClient()
            let integration = integration(verificationClientProvider: { client })
            let folder = URL(fileURLWithPath: "/same-service-target", isDirectory: true)
            let model = model()
            await model.selectDestinationFolder(folder)
            await integration.startVerification(in: folder)?.value
            let service = QuickFileFolderService(openCreationWindow: { true })
            let board = pasteboard([folder.absoluteString])
            defer { board.releaseGlobally() }
            let request = try service.receive(board)
            var windowAvailable = true
            await service.selectFolder(requestID: request.id, viewModel: model,
                finderIntegration: integration, isPresentationAvailable: { windowAvailable }, choose: { _ in
                    if cancellation == "panel" { return nil }
                    if cancellation == "request" { service.cancel(requestID: request.id) }
                    if cancellation == "window" { windowAvailable = false }
                    return folder
                })
            XCTAssertEqual(model.destinationFolder, folder)
            XCTAssertEqual(client.cancelCount, 0, cancellation)
            XCTAssertEqual(integration.verificationState, .awaitingCreation, cancellation)
            XCTAssertEqual(service.pendingRequest == nil, cancellation == "request", cancellation)
        }
    }

    private final class VerificationClient: FinderVerificationClient {
        var beginCount = 0
        var cancelCount = 0
        var checkProvider: (() async -> FinderFirstUseVerificationStatus)?

        func begin(in identity: DirectoryIdentity, timeout: TimeInterval) async -> FinderFirstUseVerificationStatus {
            beginCount += 1
            return .awaitingCreation
        }

        func check(timeout: TimeInterval) async -> FinderFirstUseVerificationStatus {
            if let checkProvider { return await checkProvider() }
            return .awaitingCreation
        }

        func cancel() { cancelCount += 1 }
    }
}
