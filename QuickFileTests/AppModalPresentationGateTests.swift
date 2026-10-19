import AppKit
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

    func testRealOpenSheetAllowsServiceDeliveryAndKeepsNativeAdmissionUntilCompletion() async throws {
        let owner = makeWindow()
        let other = makeWindow()
        defer { owner.close(); other.close() }
        let gate = AppModalPresentationGate()
        let panel = NSOpenPanel()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        panel.directoryURL = directory
        let panelFinished = expectation(description: "native open sheet completed")
        var result: URL?
        let presentation = Task {
            result = await AppKitFileActions.chooseURL(using: panel, for: owner, presentationGate: gate)
            panelFinished.fulfill()
        }
        defer {
            presentation.cancel()
            if owner.attachedSheet === panel { owner.endSheet(panel, returnCode: .cancel) }
            panel.orderOut(nil)
        }
        guard await waitForSheet(panel, on: owner) else { return }
        XCTAssertTrue(gate.isPresenting)
        XCTAssertNil(gate.present { XCTFail("Another window must not open a native panel"); return 0 })
        other.close()
        XCTAssertTrue(panel.isVisible, "Closing a different window must not cancel the owner sheet")

        let opened = expectation(description: "Services navigation task ran while the picker stayed open")
        let service = QuickFileFolderService(openCreationWindow: {
            XCTAssertTrue(panel.isVisible)
            opened.fulfill()
            return true
        })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(directory.absoluteString, forType: .fileURL)
        var error: NSString?
        service.newFileWithQuickFile(pasteboard, userData: nil, error: &error)
        XCTAssertNil(error)
        await fulfillment(of: [opened], timeout: 3)
        XCTAssertEqual(service.pendingRequest?.folderHint, directory)
        XCTAssertTrue(gate.isPresenting)
        panel.cancel(nil)
        await fulfillment(of: [panelFinished], timeout: 3)
        XCTAssertNil(result)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(gate.isPresenting)
        XCTAssertNotNil(service.pendingRequest, "Native picker cancellation must not consume the service request")
    }

    func testRealSaveSheetControlledCompletionAndOwnerCloseReleaseAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for closeOwner in [false, true] {
            let owner = makeWindow()
            defer { owner.close() }
            let gate = AppModalPresentationGate()
            let panel = NSSavePanel()
            panel.directoryURL = directory
            panel.nameFieldStringValue = "export.json"
            let finished = expectation(description: "native save sheet completed")
            var result: URL?
            let presentation = Task {
                result = await AppKitFileActions.chooseURL(using: panel, for: owner, presentationGate: gate)
                finished.fulfill()
            }
            defer {
                presentation.cancel()
                if owner.attachedSheet === panel { owner.endSheet(panel, returnCode: .cancel) }
                panel.orderOut(nil)
            }
            if closeOwner {
                guard await waitForSheet(panel, on: owner) else { return }
            } else {
                guard try await waitForSaveSelection(panel, on: owner, in: directory, named: "export.json") else { return }
            }
            // NSSavePanel.ok(_:) raises "not implemented" on current AppKit.
            // Drive the real sheet's completion, without pretending to exercise
            // remote Save-button validation (covered by installed-app checks).
            if closeOwner { owner.close() } else { owner.endSheet(panel, returnCode: .OK) }
            await fulfillment(of: [finished], timeout: 3)
            if closeOwner {
                XCTAssertNil(result)
            } else {
                let selected = try XCTUnwrap(result)
                XCTAssertEqual(selected.lastPathComponent, "export.json")
                XCTAssertEqual(try DirectoryIdentity.capture(at: selected.deletingLastPathComponent()),
                               try DirectoryIdentity.capture(at: directory))
            }
            XCTAssertFalse(panel.isVisible, "Completion must hide the panel before releasing the slot")
            XCTAssertFalse(gate.isPresenting)
            XCTAssertEqual(gate.present { 7 }, 7)
        }
    }

    func testQueuedRealOpenSheetOwnerCloseAndUnblockingReleaseAdmission() async throws {
        try await exerciseQueuedNativePanel(isOpenPanel: true)
    }

    func testQueuedRealSaveSheetOwnerCloseAndUnblockingReleaseAdmission() async throws {
        try await exerciseQueuedNativePanel(isOpenPanel: false)
    }

    func testRealOpenSheetOwnerCloseAtStartupReleasesAdmission() async {
        await exerciseNativePanelOwnerCloseAtStartup(isOpenPanel: true)
    }

    func testRealSaveSheetOwnerCloseAtStartupReleasesAdmission() async {
        await exerciseNativePanelOwnerCloseAtStartup(isOpenPanel: false)
    }

    private func exerciseNativePanelOwnerCloseAtStartup(isOpenPanel: Bool) async {
        for closeBeforeStarting in [true, false] {
            let panel: NSSavePanel = isOpenPanel ? NSOpenPanel() : NSSavePanel()
            let owner = makeWindow()
            let gate = AppModalPresentationGate()
            let finished = expectation(description: "native panel cancels on owner close at startup")
            var completed = false
            let presentation = Task {
                let selection = await AppKitFileActions.chooseURL(using: panel, for: owner, presentationGate: gate)
                XCTAssertNil(selection)
                completed = true
                finished.fulfill()
            }
            defer {
                presentation.cancel()
                if owner.sheets.contains(panel) { owner.endSheet(panel, returnCode: .cancel) }
                panel.orderOut(nil)
                owner.close()
            }
            if !closeBeforeStarting {
                for _ in 0..<100 {
                    if gate.isPresenting { break }
                    await Task.yield()
                }
                XCTAssertTrue(gate.isPresenting)
                // AppKit can display synchronously before the first MainActor yield.
            }
            owner.close()
            await fulfillment(of: [finished], timeout: 3)
            XCTAssertTrue(completed)
            XCTAssertFalse(gate.isPresenting)
            try? await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertFalse(panel.isVisible, "Initialization must not resurrect the closed owner's panel")
            XCTAssertEqual(gate.present { 9 }, 9)
        }
    }

    private func exerciseQueuedNativePanel(isOpenPanel: Bool) async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/Temporary/recovery-sheet-20261018/fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for closeOwner in [true, false] {
            let owner = makeWindow()
            let blocker = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            blocker.isReleasedWhenClosed = false
            owner.beginSheet(blocker, completionHandler: { _ in })
            let gate = AppModalPresentationGate()
            let panel: NSSavePanel = isOpenPanel ? NSOpenPanel() : NSSavePanel()
            panel.directoryURL = directory
            if let open = panel as? NSOpenPanel {
                open.canChooseDirectories = true
                open.canChooseFiles = false
            } else {
                panel.nameFieldStringValue = "stale-export.json"
            }
            let finished = expectation(description: "queued native panel completes, closeOwner=\(closeOwner)")
            var completed = false
            var result: URL?
            let presentation = Task {
                result = await AppKitFileActions.chooseURL(using: panel, for: owner, presentationGate: gate)
                completed = true
                finished.fulfill()
            }
            defer {
                presentation.cancel()
                if owner.sheets.contains(panel) { owner.endSheet(panel, returnCode: .cancel) }
                if owner.sheets.contains(blocker) { owner.endSheet(blocker, returnCode: .cancel) }
                panel.orderOut(nil)
                blocker.orderOut(nil)
                owner.close()
            }
            for _ in 0..<100 {
                if gate.isPresenting { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // Admission covers the transition while the owner's existing sheet closes.
            try? await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertFalse(completed)
            XCTAssertTrue(owner.attachedSheet === blocker)
            XCTAssertFalse(panel.isVisible)
            XCTAssertTrue(gate.isPresenting)

            let finderFinished = expectation(description: "Finder reservation releases after queued panel")
            var finderMayPresent = true
            var finderPresented = false
            let finder = Task {
                await gate.withFinderPresentation {
                    if finderMayPresent { finderPresented = true }
                }
                finderFinished.fulfill()
            }
            defer { finder.cancel() }
            for _ in 0..<100 {
                if gate.isFinderReserved { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(gate.isFinderReserved)
            finderMayPresent = false
            if closeOwner {
                owner.close()
            } else {
                let otherOwner = makeWindow()
                otherOwner.close()
                XCTAssertFalse(completed, "Closing another owner must not end this transition")
                owner.endSheet(blocker, returnCode: .cancel)
                blocker.orderOut(nil)
                guard await waitForSheet(panel, on: owner) else { return }
                XCTAssertTrue(gate.isPresenting)
                XCTAssertTrue(gate.isFinderReserved)
                panel.cancel(nil)
            }
            await fulfillment(of: [finished, finderFinished], timeout: 3)
            XCTAssertTrue(completed)
            XCTAssertNil(result, "A queued selection cannot survive cancellation or owner closure")
            XCTAssertFalse(finderPresented)
            XCTAssertFalse(gate.isPresenting)
            XCTAssertFalse(gate.isFinderReserved)

            // Unblocking the old queue must not resurrect a cancelled native sheet.
            if owner.sheets.contains(blocker) { owner.endSheet(blocker, returnCode: .cancel) }
            blocker.orderOut(nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(owner.sheets.contains(panel))
            guard completed, !gate.isPresenting, !gate.isFinderReserved else { return }

            let nextOwner = makeWindow()
            let nextPanel = NSOpenPanel()
            nextPanel.directoryURL = directory
            let nextFinished = expectation(description: "new window can use native admission")
            let next = Task {
                let selection = await AppKitFileActions.chooseURL(using: nextPanel, for: nextOwner, presentationGate: gate)
                XCTAssertNil(selection)
                nextFinished.fulfill()
            }
            defer {
                next.cancel()
                if nextOwner.sheets.contains(nextPanel) { nextOwner.endSheet(nextPanel, returnCode: .cancel) }
                nextPanel.orderOut(nil)
                nextOwner.close()
            }
            guard await waitForSheet(nextPanel, on: nextOwner) else { return }
            nextPanel.cancel(nil)
            await fulfillment(of: [nextFinished], timeout: 3)
            XCTAssertFalse(gate.isPresenting)
            XCTAssertFalse(panel.isVisible)
        }
    }

    func testFinderRetainsReservationAcrossAsyncConfirmationAndRejectsClosedWindowResult() async {
        let gate = AppModalPresentationGate()
        let pump = FinderAuthorizationRequestPump(presentationGate: gate)
        let request = FinderAuthorizationRequest(templateID: UUID(), destinationFolder: URL(fileURLWithPath: "/synthetic"))
        let presented = expectation(description: "async confirmation started")
        let finished = expectation(description: "async Finder drain ended")
        var resume: CheckedContinuation<URL?, Never>?
        var available = true
        var cancelled = 0
        let reads = LockedTestValue(0)
        let drain = Task {
            await pump.drain(takePendingRequest: { reads.update { $0 += 1 }; return request },
                willPresent: {}, confirmAuthorization: { _ in
                    await withCheckedContinuation { continuation in
                        resume = continuation
                        presented.fulfill()
                    }
                }, complete: { _, _ in XCTFail("A closed owner's late selection must not create"); return false },
                didCancel: { XCTFail("A closed window is distinct from user cancellation") },
                didFail: { XCTFail("Unexpected failure: \($0)") },
                isPresentationAvailable: { available },
                didCancelForUnavailableWindow: { _ in cancelled += 1 })
            finished.fulfill()
        }
        defer {
            available = false
            if let pending = resume {
                resume = nil
                pending.resume(returning: nil)
            }
            drain.cancel()
        }
        await fulfillment(of: [presented], timeout: 3)
        guard let confirmation = resume else { return }
        resume = nil
        XCTAssertTrue(gate.isPresenting)
        XCTAssertTrue(gate.isFinderReserved)
        XCTAssertNil(gate.present { XCTFail("Cannot steal async Finder admission"); return 0 })
        available = false
        confirmation.resume(returning: request.destinationFolder)
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(reads.value, 1)
        XCTAssertFalse(gate.isPresenting)
        XCTAssertFalse(gate.isFinderReserved)
    }

    private func waitForSaveSelection(
        _ panel: NSSavePanel, on owner: NSWindow, in directory: URL, named filename: String
    ) async throws -> Bool {
        let expectedDirectory = try DirectoryIdentity.capture(at: directory)
        // The remote sheet can be visible while its URL still points at the previous
        // directory. Controlled completion must wait for the actual selection.
        for _ in 0..<100 {
            if owner.attachedSheet === panel, panel.isVisible,
               let selected = panel.url, selected.lastPathComponent == filename,
               (try? DirectoryIdentity.capture(at: selected.deletingLastPathComponent())) == expectedDirectory {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("The real save panel did not select the fixture destination; URL: \(String(describing: panel.url))")
        panel.cancel(nil)
        return false
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func waitForSheet(_ panel: NSSavePanel, on owner: NSWindow) async -> Bool {
        for _ in 0..<100 {
            if owner.attachedSheet === panel, panel.isVisible { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("The real native panel did not attach to its owner")
        panel.cancel(nil)
        return false
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
