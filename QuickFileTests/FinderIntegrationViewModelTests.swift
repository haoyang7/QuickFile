import XCTest
@testable import QuickFile
@testable import QuickFileCore
@testable import QuickFileInfrastructure

@MainActor
final class FinderIntegrationViewModelTests: XCTestCase {
    func testRefreshPublishesCurrentExtensionState() async {
        var currentState = false
        let viewModel = FinderIntegrationViewModel(
            statusProvider: { currentState },
            runtimeProvider: { self.snapshot(enabled: $0, responded: $0 ? true : nil) },
            managementOpener: {}
        )
        XCTAssertFalse(viewModel.isEnabled)

        currentState = true
        await viewModel.refresh()

        XCTAssertTrue(viewModel.isEnabled)
        XCTAssertTrue(viewModel.isResponding)
    }

    func testOpenManagementDelegatesToSystemAdapter() {
        var openCount = 0
        let viewModel = FinderIntegrationViewModel(
            statusProvider: { false },
            runtimeProvider: { self.snapshot(enabled: $0, responded: nil) },
            managementOpener: { openCount += 1 }
        )

        viewModel.openManagement()

        XCTAssertEqual(openCount, 1)
    }

    func testEnabledUnresponsiveExtensionOffersRecoveryUntilNewProbeResponds() async {
        var responded = false
        var managementOpenCount = 0
        let viewModel = FinderIntegrationViewModel(
            statusProvider: { true },
            runtimeProvider: { self.snapshot(enabled: $0, responded: responded) },
            managementOpener: { managementOpenCount += 1 }
        )
        XCTAssertFalse(viewModel.isResponding)
        await viewModel.refresh()
        XCTAssertTrue(viewModel.isEnabled)
        XCTAssertFalse(viewModel.isResponding)
        XCTAssertEqual(viewModel.snapshot?.state, .noResponse)
        XCTAssertNotNil(viewModel.snapshot?.state.recoveryGuidance)
        // Detection must not change the user's system settings automatically.
        XCTAssertEqual(managementOpenCount, 0)
        viewModel.openManagement()
        XCTAssertEqual(managementOpenCount, 1)

        responded = true
        await viewModel.refresh()
        XCTAssertTrue(viewModel.isResponding)
        XCTAssertNil(viewModel.snapshot?.state.recoveryGuidance)
    }

    func testSettingsChangedDuringProbeDiscardStaleSuccess() async {
        var enabled = true
        let viewModel = FinderIntegrationViewModel(
            statusProvider: { enabled },
            runtimeProvider: { wasEnabled in
                enabled = false
                return self.snapshot(enabled: wasEnabled, responded: true)
            },
            managementOpener: {}
        )
        await viewModel.refresh()
        XCTAssertFalse(viewModel.isEnabled)
        XCTAssertFalse(viewModel.isResponding)
        XCTAssertNil(viewModel.snapshot)
        XCTAssertFalse(viewModel.isRefreshing)
    }

    func testVerificationUpdatingEnabledDuringSuspendedProbeCannotValidateStaleSuccess() async {
        var enabled = true
        var resumeProbe: CheckedContinuation<Void, Never>?
        let started = expectation(description: "Enabled probe suspended")
        let viewModel = FinderIntegrationViewModel(
            statusProvider: { enabled },
            runtimeProvider: { enabledAtStart in
                await withCheckedContinuation { continuation in
                    resumeProbe = continuation
                    started.fulfill()
                }
                return self.snapshot(enabled: enabledAtStart, responded: true)
            },
            managementOpener: {}
        )
        let refresh = Task { await viewModel.refresh() }
        await fulfillment(of: [started], timeout: 1)
        enabled = false
        await viewModel.startVerification(in: URL(fileURLWithPath: "/test-target"))
        XCTAssertFalse(viewModel.isEnabled, "Another action has overwritten the published input")
        resumeProbe?.resume()
        await refresh.value
        XCTAssertFalse(viewModel.isEnabled)
        XCTAssertNil(viewModel.snapshot, "The old enabled response must compare against its own input")
        XCTAssertFalse(viewModel.isResponding)
        XCTAssertEqual(viewModel.statusText, "扩展未获用户启用")
        XCTAssertFalse(viewModel.isRefreshing)
    }

    func testDisabledStateRemainsVisibleWhenRegistrationQueryIsUnavailable() async {
        let viewModel = FinderIntegrationViewModel(
            statusProvider: { false },
            runtimeProvider: { enabled in
                FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
                    registration: .unknown, registrationEvidence: "sandbox denied query",
                    enabled: enabled, responded: nil
                )
            },
            managementOpener: {}
        )
        await viewModel.refresh()
        XCTAssertEqual(viewModel.statusText, "尚未启用；安装或注册状态待确认")
        XCTAssertFalse(viewModel.isResponding)
    }

    func testConcurrentRefreshesShareInFlightProbe() async {
        var probeCount = 0
        var resumeProbe: CheckedContinuation<Bool, Never>?
        let started = expectation(description: "probe started")
        let viewModel = FinderIntegrationViewModel(
            statusProvider: { true },
            runtimeProvider: { enabled in
                probeCount += 1
                let responded = await withCheckedContinuation { continuation in
                    resumeProbe = continuation
                    started.fulfill()
                }
                return self.snapshot(enabled: enabled, responded: responded)
            },
            managementOpener: {}
        )
        let first = Task { await viewModel.refresh() }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(viewModel.isRefreshing)
        await viewModel.refresh()
        XCTAssertEqual(probeCount, 1)
        resumeProbe?.resume(returning: true)
        await first.value
        XCTAssertTrue(viewModel.isResponding)
        XCTAssertFalse(viewModel.isRefreshing)
    }

    func testSetupOffersOneNextActionForEnablementAndAuthorization() {
        var enabled = false
        let model = FinderIntegrationViewModel(statusProvider: { enabled },
            runtimeProvider: { self.snapshot(enabled: $0, responded: nil) }, managementOpener: {})
        XCTAssertEqual(model.setupPresentation(hasDestination: false, authorization: .notConfirmed, hasTemplates: true).action, .openSettings)
        enabled = true
        let enabledModel = FinderIntegrationViewModel(statusProvider: { enabled },
            runtimeProvider: { self.snapshot(enabled: $0, responded: true) }, managementOpener: {})
        XCTAssertEqual(enabledModel.setupPresentation(hasDestination: false, authorization: .saved, hasTemplates: true).action, .chooseFolder)
        XCTAssertEqual(enabledModel.setupPresentation(hasDestination: true, authorization: .notConfirmed, hasTemplates: true).action, .saveAuthorization)
        XCTAssertEqual(enabledModel.setupPresentation(hasDestination: true, authorization: .failed("保存失败"), hasTemplates: true).action, .saveAuthorization)
        XCTAssertEqual(enabledModel.setupPresentation(hasDestination: true, authorization: .saving, hasTemplates: true).action, .none)
        XCTAssertEqual(enabledModel.setupPresentation(hasDestination: true, authorization: .saved, hasTemplates: true).action, .startVerification)
        XCTAssertEqual(enabledModel.setupPresentation(hasDestination: true, authorization: .saved, hasTemplates: false).action, .manageTemplates)
    }

    func testMissingInstallationOrRegistrationDoesNotOfferEnableAsRepair() async {
        for embedded in [false, true] {
            let model = FinderIntegrationViewModel(statusProvider: { false }, runtimeProvider: { enabled in
                FinderExtensionDiagnosticSnapshot(embeddedIdentifiers: embedded ? ["test.extension"] : [],
                    embeddingKnown: true, registration: .notRegistered, registrationEvidence: "test",
                    enabled: enabled, responded: nil)
            }, managementOpener: {})
            await model.refresh()
            let presentation = model.setupPresentation(hasDestination: false, authorization: .notConfirmed, hasTemplates: true)
            XCTAssertEqual(presentation.action, .refreshStatus)
            XCTAssertFalse(presentation.message.contains("启用"))
        }
    }

    func testCreationReportRequiresSeparateUserVisibleConfirmation() async throws {
        let client = VerificationClient()
        var opens = 0
        let model = try verificationModel(client: client, folderOpener: { _ in opens += 1; return true })
        await model.confirmVisibleFile()
        XCTAssertEqual(model.verificationState, .idle)
        await model.startVerification(in: URL(fileURLWithPath: "/test-target"))
        XCTAssertEqual(model.verificationState, .awaitingCreation)
        XCTAssertEqual(opens, 1)
        await model.confirmVisibleFile()
        XCTAssertEqual(model.verificationState, .awaitingCreation)
        client.checkResult = .creationReported
        await model.checkVerification()
        XCTAssertEqual(model.verificationState, .creationReported)
        await model.confirmVisibleFile()
        XCTAssertEqual(model.verificationState, .confirmed)
        XCTAssertEqual(client.cancelCount, 1)
    }

    func testBeginFailureDoesNotOpenFolderOrConfirmCreation() async throws {
        let client = VerificationClient()
        client.beginResult = .unavailable
        var opens = 0
        let model = try verificationModel(client: client, folderOpener: { _ in opens += 1; return true })
        await model.startVerification(in: URL(fileURLWithPath: "/test-target"))
        XCTAssertEqual(model.verificationState, .unavailable)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(model.setupPresentation(hasDestination: true, authorization: .saved, hasTemplates: true).action, .openFolder)
    }

    func testMissingDirectoryNeverStartsVerificationClient() async {
        let client = VerificationClient()
        let model = FinderIntegrationViewModel(statusProvider: { true },
            runtimeProvider: { self.snapshot(enabled: $0, responded: true) }, managementOpener: {},
            verificationClientProvider: { client },
            directoryIdentityProvider: { _ in throw CocoaError(.fileNoSuchFile) }, folderOpener: { _ in true })
        await model.startVerification(in: URL(fileURLWithPath: "/missing"))
        XCTAssertEqual(model.verificationState, .destinationUnavailable)
        XCTAssertEqual(client.beginCount, 0)
    }

    func testCancellationDiscardsLateReceiptAndClearsBusyState() async throws {
        let client = VerificationClient()
        let model = try verificationModel(client: client)
        await model.startVerification(in: URL(fileURLWithPath: "/test-target"))
        let entered = expectation(description: "check entered")
        var resume: CheckedContinuation<FinderFirstUseVerificationStatus, Never>?
        client.checkProvider = {
            await withCheckedContinuation { continuation in resume = continuation; entered.fulfill() }
        }
        let check = Task { await model.checkVerification() }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertTrue(model.isCheckingVerification)
        model.cancelVerification()
        XCTAssertFalse(model.isCheckingVerification)
        XCTAssertTrue(model.isVerificationOperationInFlight, "Do not admit replacement work until the old operation actually ends")
        await model.startVerification(in: URL(fileURLWithPath: "/replacement"))
        XCTAssertEqual(client.beginCount, 1)
        resume?.resume(returning: .creationReported)
        await check.value
        XCTAssertEqual(model.verificationState, .idle)
        XCTAssertFalse(model.isVerificationOperationInFlight)
    }

    func testDestinationChangeAndDisabledExtensionInvalidateAttempt() async throws {
        let client = VerificationClient()
        let model = try verificationModel(client: client)
        await model.startVerification(in: URL(fileURLWithPath: "/test-target"))
        model.destinationDidChange(to: URL(fileURLWithPath: "/other-target"))
        XCTAssertEqual(model.verificationState, .idle)
        XCTAssertEqual(client.cancelCount, 1)

        var enabled = true
        let identity = try makeDirectoryIdentity()
        let changing = FinderIntegrationViewModel(statusProvider: { enabled },
            runtimeProvider: { self.snapshot(enabled: $0, responded: true) }, managementOpener: {},
            verificationClientProvider: { client }, directoryIdentityProvider: { _ in identity }, folderOpener: { _ in true })
        await changing.startVerification(in: URL(fileURLWithPath: "/test-target"))
        enabled = false
        await changing.refresh()
        XCTAssertEqual(changing.verificationState, .idle)
        XCTAssertFalse(changing.isEnabled)
    }

    func testExpiredAttemptHasExplicitRestartAndCannotBeConfirmed() async throws {
        let client = VerificationClient()
        let model = try verificationModel(client: client)
        await model.startVerification(in: URL(fileURLWithPath: "/test-target"))
        client.checkResult = .expiredOrMissing
        await model.checkVerification()
        XCTAssertEqual(model.verificationState, .expired)
        await model.confirmVisibleFile()
        XCTAssertEqual(model.verificationState, .expired)
        XCTAssertEqual(model.setupPresentation(hasDestination: true, authorization: .saved, hasTemplates: true).action, .startVerification)
    }

    func testVisibleConfirmationRechecksReceiptInsteadOfAcceptingExpiredUI() async throws {
        let client = VerificationClient()
        let model = try verificationModel(client: client)
        await model.startVerification(in: URL(fileURLWithPath: "/test-target"))
        client.checkResult = .creationReported
        await model.checkVerification()
        XCTAssertEqual(model.verificationState, .creationReported)
        client.checkResult = .expiredOrMissing
        await model.confirmVisibleFile()
        XCTAssertEqual(model.verificationState, .expired)
    }

    func testResponseProbeAloneCannotCompleteFirstUseVerification() async throws {
        let client = VerificationClient()
        let model = try verificationModel(client: client)
        await model.startVerification(in: URL(fileURLWithPath: "/test-target"))
        await model.refresh()
        XCTAssertTrue(model.isResponding)
        XCTAssertEqual(model.verificationState, .awaitingCreation)
        await model.confirmVisibleFile()
        XCTAssertEqual(model.verificationState, .awaitingCreation)
    }

    func testUserCancellationWarnsThatExistingFileWorkMayStillComplete() async throws {
        let model = try verificationModel(client: VerificationClient())
        await model.startVerification(in: URL(fileURLWithPath: "/test-target"))
        model.cancelUserVerification()
        XCTAssertEqual(model.verificationState, .cancelled)
        let presentation = model.setupPresentation(hasDestination: true, authorization: .saved, hasTemplates: true)
        XCTAssertTrue(presentation.detail.contains("不会因此取消"))
        XCTAssertEqual(presentation.action, .startVerification)
    }

    func testTransientCheckFailureRetriesSameAttemptWithoutReopeningOrCreating() async throws {
        let client = VerificationClient()
        var opens = 0
        let model = try verificationModel(client: client, folderOpener: { _ in opens += 1; return true })
        await model.startVerification(in: URL(fileURLWithPath: "/test-target"))
        client.checkResult = .unavailable
        await model.checkVerification()
        XCTAssertEqual(model.verificationState, .responseUnavailable)
        let presentation = model.setupPresentation(hasDestination: true, authorization: .saved, hasTemplates: true)
        XCTAssertEqual(presentation.action, .checkVerification)
        XCTAssertTrue(presentation.detail.contains("文件可能已经创建"))
        client.checkResult = .creationReported
        await model.checkVerification()
        XCTAssertEqual(model.verificationState, .creationReported)
        XCTAssertEqual(client.beginCount, 1)
        XCTAssertEqual(client.cancelCount, 0)
        XCTAssertEqual(opens, 1)
    }

    func testOnlyClosingLastWindowCancelsSharedVerification() async throws {
        let client = VerificationClient()
        let model = try verificationModel(client: client)
        let first = UUID(), second = UUID()
        model.windowDidAppear(first)
        model.windowDidAppear(second)
        await model.startVerification(in: URL(fileURLWithPath: "/test-target"))
        model.windowDidDisappear(first)
        XCTAssertEqual(model.verificationState, .awaitingCreation)
        XCTAssertEqual(client.cancelCount, 0)
        model.windowDidDisappear(second)
        XCTAssertEqual(model.verificationState, .idle)
        XCTAssertEqual(client.cancelCount, 1)
    }

    func testOldVisibleConfirmationCannotConfirmReplacementAttempt() async throws {
        let client = VerificationClient()
        let model = try verificationModel(client: client)
        let folder = URL(fileURLWithPath: "/test-target")
        await model.startVerification(in: folder)
        client.checkResult = .creationReported
        await model.checkVerification()
        let checkingOldReceipt = expectation(description: "Old confirmation is checking its receipt")
        var resumeOldCheck: CheckedContinuation<FinderFirstUseVerificationStatus, Never>?
        client.checkProvider = {
            await withCheckedContinuation { continuation in
                resumeOldCheck = continuation
                checkingOldReceipt.fulfill()
            }
        }
        let oldConfirmation = Task { await model.confirmVisibleFile() }
        await fulfillment(of: [checkingOldReceipt], timeout: 1)
        model.cancelVerification()
        client.checkProvider = nil
        let replacement = Task {
            // Cancellation cannot bypass the bounded admission guard. Start the new
            // attempt as soon as the old read really ends, racing its outer return.
            for _ in 0..<1_000 {
                if !model.isVerificationOperationInFlight { break }
                await Task.yield()
            }
            guard !model.isVerificationOperationInFlight else {
                return XCTFail("The cancelled receipt check did not release its admission")
            }
            await model.startVerification(in: folder)
            await model.checkVerification()
        }
        resumeOldCheck?.resume(returning: .creationReported)
        await replacement.value
        await oldConfirmation.value
        XCTAssertEqual(client.beginCount, 2)
        XCTAssertEqual(model.verificationState, .creationReported,
                       "A replacement receipt still requires its own explicit visibility confirmation")
        await model.confirmVisibleFile()
        XCTAssertEqual(model.verificationState, .confirmed)
    }

    func testHistoricalGuideCompletionRelaunchesCollapsedWithoutCurrentReadiness() async {
        var saves: [Bool] = []
        let model = FinderIntegrationViewModel(
            statusProvider: { true },
            runtimeProvider: { self.snapshot(enabled: $0, responded: true) },
            managementOpener: {},
            guidePreferences: .init(loadCompleted: { true }, saveCompleted: { saves.append($0) })
        )
        XCTAssertTrue(model.hasCompletedGuide)
        XCTAssertFalse(model.isGuideExpanded)
        XCTAssertEqual(model.verificationState, .idle)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.isResponding)
        XCTAssertFalse(model.isCurrentVerificationConfirmed)
        XCTAssertTrue(model.guideHistoryText.contains("当前状态仍需"))
        await model.refresh()
        XCTAssertTrue(model.isResponding)
        XCTAssertFalse(model.isCurrentVerificationConfirmed, "A new probe is not a new completed creation verification")
        XCTAssertEqual(model.verificationState, .idle)
        XCTAssertTrue(saves.isEmpty, "Checks must not write readiness to guide preferences")
    }

    func testGuideCompletionPersistsOnlyHistoryAndWindowCloseClearsCurrentReceipt() async throws {
        let client = VerificationClient()
        let identity = try makeDirectoryIdentity()
        var persistedHistory = false
        var writes = 0
        let preferences = FinderIntegrationViewModel.GuidePreferences(
            loadCompleted: { persistedHistory },
            saveCompleted: { persistedHistory = $0; writes += 1 }
        )
        let model = FinderIntegrationViewModel(
            statusProvider: { true },
            runtimeProvider: { self.snapshot(enabled: $0, responded: true) },
            managementOpener: {}, verificationClientProvider: { client },
            directoryIdentityProvider: { _ in identity }, folderOpener: { _ in true },
            guidePreferences: preferences
        )
        let window = UUID()
        model.windowDidAppear(window)
        XCTAssertFalse(model.isGuideExpanded, "Optional Finder setup starts collapsed, including before the first use")
        await model.refresh()
        await model.startVerification(in: URL(fileURLWithPath: "/test-target"))
        XCTAssertEqual(writes, 0)
        client.checkResult = .creationReported
        await model.checkVerification()
        XCTAssertEqual(writes, 0, "An extension receipt alone must not complete guide history")
        await model.confirmVisibleFile()
        XCTAssertTrue(persistedHistory)
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(model.isGuideExpanded)
        XCTAssertTrue(model.isCurrentVerificationConfirmed)
        model.windowDidDisappear(window)
        XCTAssertEqual(model.verificationState, .idle)
        XCTAssertFalse(model.isCurrentVerificationConfirmed)
        XCTAssertTrue(model.hasCompletedGuide)
        XCTAssertFalse(model.isGuideExpanded)
        XCTAssertEqual(writes, 1)

        let restarted = FinderIntegrationViewModel(
            statusProvider: { true }, runtimeProvider: { self.snapshot(enabled: $0, responded: nil) },
            managementOpener: {}, guidePreferences: preferences
        )
        XCTAssertFalse(restarted.isGuideExpanded)
        XCTAssertEqual(restarted.verificationState, .idle)
        XCTAssertFalse(restarted.isCurrentVerificationConfirmed)
    }

    func testHistoricalCompletionDoesNotHideDisabledExtensionOrUnknownRuntime() async {
        let disabled = FinderIntegrationViewModel(
            statusProvider: { false }, runtimeProvider: { self.snapshot(enabled: $0, responded: nil) },
            managementOpener: {}, guidePreferences: .init(loadCompleted: { true })
        )
        XCTAssertEqual(disabled.setupPresentation(hasDestination: true, authorization: .saved, hasTemplates: true).action, .openSettings)
        XCTAssertFalse(disabled.isCurrentVerificationConfirmed)
        let unknown = FinderIntegrationViewModel(
            statusProvider: { true }, runtimeProvider: { enabled in
                FinderExtensionDiagnosticSnapshot(embeddedIdentifiers: ["test.extension"],
                    embeddingKnown: true, registration: .unknown, registrationEvidence: "unavailable",
                    enabled: enabled, responded: nil)
            }, managementOpener: {}, guidePreferences: .init(loadCompleted: { true })
        )
        await unknown.refresh()
        XCTAssertFalse(unknown.isCurrentVerificationConfirmed)
        XCTAssertEqual(unknown.setupPresentation(hasDestination: true, authorization: .saved, hasTemplates: true).action, .refreshStatus)
        XCTAssertFalse(unknown.isGuideExpanded)
    }

    func testLostRuntimeResponseInvalidatesCurrentConfirmationWithoutErasingGuideHistory() async throws {
        let client = VerificationClient()
        let identity = try makeDirectoryIdentity()
        var responds = true
        let model = FinderIntegrationViewModel(
            statusProvider: { true }, runtimeProvider: { self.snapshot(enabled: $0, responded: responds) },
            managementOpener: {}, verificationClientProvider: { client },
            directoryIdentityProvider: { _ in identity }, folderOpener: { _ in true }
        )
        await model.refresh()
        await model.startVerification(in: URL(fileURLWithPath: "/test-target"))
        client.checkResult = .creationReported
        await model.checkVerification()
        await model.confirmVisibleFile()
        XCTAssertTrue(model.isCurrentVerificationConfirmed)
        responds = false
        await model.refresh()
        XCTAssertFalse(model.isCurrentVerificationConfirmed)
        XCTAssertEqual(model.verificationState, .idle)
        XCTAssertTrue(model.hasCompletedGuide)
        XCTAssertFalse(model.isGuideExpanded)
    }

    func testSavedAuthorizationInventorySharesAdmissionAndRequiresExplicitRetry() async {
        let gate = DiagnosticsInventoryReadGate()
        let reader = OnboardingInventoryReader()
        let first = inventoryModel(reader: reader, gate: gate)
        let second = inventoryModel(reader: reader, gate: gate)
        let read = Task { await first.refreshAuthorizedDirectories() }
        let began = await BackgroundWork.run { reader.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(began)
        defer { reader.resume.signal() }
        XCTAssertEqual(first.authorizationInventoryState, .loading)
        await first.refreshAuthorizedDirectories()
        await second.refreshAuthorizedDirectories()
        XCTAssertEqual(second.authorizationInventoryState, .busy)
        XCTAssertEqual(reader.readCount, 1, "Busy callers cannot enqueue or start more bookmark resolvers")
        reader.resume.signal()
        await read.value
        XCTAssertEqual(first.authorizationInventoryState, .loaded)
        XCTAssertEqual(first.authorizedDirectories, reader.inventory.availableDirectories)
        XCTAssertEqual(first.unavailableAuthorizationCount, 1)
        XCTAssertFalse(gate.isReading)
        XCTAssertEqual(second.authorizationInventoryState, .busy, "Finishing another owner must not create an implicit retry loop")
        await second.refreshAuthorizedDirectories()
        XCTAssertEqual(second.authorizationInventoryState, .loaded)
        XCTAssertEqual(reader.readCount, 2)
    }

    func testCancelledInventoryReadKeepsSharedSlotUntilSynchronousWorkReturns() async {
        let gate = DiagnosticsInventoryReadGate()
        let reader = OnboardingInventoryReader()
        let model = inventoryModel(reader: reader, gate: gate)
        let other = inventoryModel(reader: reader, gate: gate)
        let read = Task { await model.refreshAuthorizedDirectories() }
        let began = await BackgroundWork.run { reader.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(began)
        defer { reader.resume.signal() }
        read.cancel()
        XCTAssertTrue(gate.isReading)
        await other.refreshAuthorizedDirectories()
        XCTAssertEqual(other.authorizationInventoryState, .busy)
        XCTAssertEqual(reader.readCount, 1)
        reader.resume.signal()
        await read.value
        XCTAssertFalse(gate.isReading)
        XCTAssertEqual(model.authorizationInventoryState, .idle)
        XCTAssertTrue(model.authorizedDirectories.isEmpty, "Cancelled result cannot repopulate choices")
    }

    func testInventoryFailureReleasesAdmissionAndCanBeRetried() async {
        let gate = DiagnosticsInventoryReadGate()
        let model = FinderIntegrationViewModel(
            statusProvider: { false }, runtimeProvider: { self.snapshot(enabled: $0, responded: nil) },
            managementOpener: {}, authorizationInventoryLoader: { throw CocoaError(.fileReadNoPermission) },
            inventoryReadGate: gate
        )
        await model.refreshAuthorizedDirectories()
        guard case .failed = model.authorizationInventoryState else { return XCTFail("Expected a visible retryable failure") }
        XCTAssertFalse(gate.isReading)
        await model.refreshAuthorizedDirectories()
        guard case .failed = model.authorizationInventoryState else { return XCTFail("Expected retry to return an explicit failure") }
        XCTAssertFalse(gate.isReading)
    }

    private func inventoryModel(reader: OnboardingInventoryReader, gate: DiagnosticsInventoryReadGate) -> FinderIntegrationViewModel {
        FinderIntegrationViewModel(statusProvider: { false },
            runtimeProvider: { self.snapshot(enabled: $0, responded: nil) }, managementOpener: {},
            authorizationInventoryLoader: { try reader.read() }, inventoryReadGate: gate)
    }

    private func makeDirectoryIdentity() throws -> DirectoryIdentity {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try DirectoryIdentity.capture(at: folder)
    }

    private func verificationModel(client: VerificationClient, folderOpener: @escaping (URL) -> Bool = { _ in true }) throws -> FinderIntegrationViewModel {
        let identity = try makeDirectoryIdentity()
        return FinderIntegrationViewModel(statusProvider: { true },
            runtimeProvider: { self.snapshot(enabled: $0, responded: true) }, managementOpener: {},
            verificationClientProvider: { client }, directoryIdentityProvider: { _ in
                XCTAssertFalse(Thread.isMainThread)
                return identity
            }, folderOpener: folderOpener)
    }

    private final class VerificationClient: FinderVerificationClient {
        var beginResult: FinderFirstUseVerificationStatus = .awaitingCreation
        var checkResult: FinderFirstUseVerificationStatus = .awaitingCreation
        var checkProvider: (() async -> FinderFirstUseVerificationStatus)?
        var beginCount = 0
        var cancelCount = 0
        func begin(in identity: DirectoryIdentity, timeout: TimeInterval) async -> FinderFirstUseVerificationStatus {
            beginCount += 1
            return beginResult
        }
        func check(timeout: TimeInterval) async -> FinderFirstUseVerificationStatus {
            if let checkProvider { return await checkProvider() }
            return checkResult
        }
        func cancel() { cancelCount += 1 }
    }

    private func snapshot(enabled: Bool, responded: Bool?) -> FinderExtensionDiagnosticSnapshot {
        FinderExtensionDiagnosticSnapshot(
            embeddedIdentifiers: ["test.extension"], embeddingKnown: true,
            registration: .registered, registrationEvidence: "test",
            enabled: enabled, responded: responded
        )
    }
}

// The reader is shared with BackgroundWork. Only the counter is mutable and it is
// protected by a lock; the semaphore bounds the first read for deterministic races.
private final class OnboardingInventoryReader: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let inventory = AuthorizedDirectoryInventory(
        availableDirectories: [AuthorizedDirectory(id: UUID(), url: URL(fileURLWithPath: "/saved-folder"), isBookmarkStale: false)],
        unavailableDirectories: [UnavailableAuthorizedDirectory(id: UUID())]
    )
    private let lock = NSLock()
    private var count = 0
    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func read() throws -> AuthorizedDirectoryInventory {
        XCTAssertFalse(Thread.isMainThread)
        lock.lock()
        count += 1
        let shouldPause = count == 1
        lock.unlock()
        if shouldPause {
            started.signal()
            guard resume.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileReadUnknown) }
        }
        return inventory
    }
}
