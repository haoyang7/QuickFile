import AppKit
import Combine
import notify
import SwiftUI
import XCTest
@testable import QuickFile
@testable import QuickFileCore
@testable import QuickFileInfrastructure

@MainActor
final class TemplateRefreshTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var store: TemplateStore!

    override func setUpWithError() throws {
        suite = "QuickFileTests.Refresh.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = TemplateStore(defaults: defaults, storageURL: directory.appendingPathComponent("templates.json"),
                              changeNotificationName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
        store = nil
        defaults = nil
    }

    private func settle(_ model: QuickFileViewModel) async throws {
        for _ in 0..<300 {
            if !model.hasPendingTemplateRefresh && !model.isLoadingTemplates && !model.isSavingTemplates { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Template refresh did not settle")
    }

    private func waitForProbeCompletion(_ model: QuickFileViewModel) async throws {
        for _ in 0..<300 {
            if !model.isProbingTemplateRefresh { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Template probe did not complete")
    }

    func testUnchangedActivationPublishesNothingAndKeepsCreationAvailable() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "body")
        try store.saveTemplates([original])
        let source = store!
        let probe = RefreshGate()
        defer { probe.release.signal() }
        let tokens = RefreshCounter()
        let reads = RefreshCounter()
        let model = QuickFileViewModel(templateStore: source, authoritativeTemplateLoader: {
            reads.increment()
            return try source.reloadTemplates()
        }, templateChangeTokenReader: {
            tokens.increment()
            if tokens.count == 3 { probe.blockOnce() }
            return try source.changeToken()
        })
        await model.loadTemplatesIfNeeded()
        model.destinationFolder = directory
        let publications = RefreshCounter()
        let subscription = model.objectWillChange.sink { publications.increment() }
        defer { subscription.cancel() }
        model.requestTemplateRefresh()
        let started = await BackgroundWork.run { probe.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertTrue(model.canCreate)
        XCTAssertFalse(model.isLoadingTemplates)
        for _ in 0..<20 { model.requestTemplateRefresh() }
        probe.release.signal()
        try await settle(model)
        XCTAssertEqual(publications.count, 0)
        XCTAssertEqual(reads.count, 1)
        XCTAssertTrue(model.canCreate)
    }

    func testForcedRefreshAfterSaveSharesAuthoritativeBodyStorage() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        try store.saveTemplates([original])
        let source = store!
        let reads = RefreshCounter()
        let model = QuickFileViewModel(templateStore: source, authoritativeTemplateLoader: {
            reads.increment()
            return try source.reloadTemplates()
        })
        await model.loadTemplatesIfNeeded()
        model.destinationFolder = directory
        model.requestedFilename = "next file"
        var edited = original
        // Dynamic, multi-megabyte native storage avoids literal interning and small strings.
        edited.content = String(repeating: "\(UUID().uuidString):正文📝\n", count: 65_536)
        try await model.saveTemplate(edited, replacing: original)
        var editor = TemplateEditorState(template: edited)
        editor.draft.content = "unsaved draft"
        let generation = try templateGeneration(of: model)
        let savedStatus = model.status

        model.requestTemplateRefresh(force: true)
        try await settle(model)
        let authoritative = try source.reloadTemplates()
        XCTAssertEqual(model.templates, [edited])
        XCTAssertEqual(authoritative, [edited])
        // On the macOS Swift runtime, these long native strings expose contiguous
        // UTF-8. Compare only during both borrows; never retain either pointer.
        let sharesBodyStorage = try XCTUnwrap(model.templates[0].content.utf8.withContiguousStorageIfAvailable { modelBytes in
            authoritative[0].content.utf8.withContiguousStorageIfAvailable { storeBytes in
                modelBytes.baseAddress == storeBytes.baseAddress && modelBytes.count == storeBytes.count
            }
        })
        XCTAssertTrue(try XCTUnwrap(sharesBodyStorage), "The model must adopt the Store's decoded snapshot after saving")
        XCTAssertEqual(try templateGeneration(of: model), generation)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(model.status, savedStatus)
        XCTAssertEqual(model.selectedTemplateID, edited.id)
        XCTAssertEqual(model.requestedFilename, "next file")
        XCTAssertTrue(model.canCreate)
        XCTAssertEqual(editor.draft.content, "unsaved draft")
        XCTAssertTrue(editor.isDirty)

        let publications = RefreshCounter()
        let subscription = model.objectWillChange.sink { publications.increment() }
        defer { subscription.cancel() }
        model.requestTemplateRefresh()
        try await settle(model)
        XCTAssertEqual(publications.count, 0)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(try templateGeneration(of: model), generation)
    }

    func testAuthoritativeRefreshAdvancesGenerationOnlyForChangedTemplates() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        try store.saveTemplates([original])
        let model = QuickFileViewModel(templateStore: store)
        await model.loadTemplatesIfNeeded()
        let generation = try templateGeneration(of: model)
        model.requestTemplateRefresh(force: true)
        try await settle(model)
        XCTAssertEqual(try templateGeneration(of: model), generation)

        var external = original
        external.content = "external"
        try JSONEncoder().encode([external]).write(to: directory.appendingPathComponent("templates.json"), options: .atomic)
        model.requestTemplateRefresh(force: true)
        try await settle(model)
        XCTAssertEqual(model.templates, [external])
        XCTAssertEqual(try templateGeneration(of: model), generation + 1)
    }

    private func templateGeneration(of model: QuickFileViewModel) throws -> UInt64 {
        try XCTUnwrap(Mirror(reflecting: model).descendant("templateStateGeneration") as? UInt64)
    }

    private func reloadWaiterCount(_ model: QuickFileViewModel) throws -> Int {
        try XCTUnwrap(Mirror(reflecting: model).descendant("templateRefreshWaiters")
            as? [UUID: CheckedContinuation<Void, Never>]).count
    }

    @discardableResult
    private func waitForReloadCondition(
        _ message: String, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () throws -> Bool
    ) async throws -> Bool {
        for _ in 0..<300 {
            if try condition() { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(message, file: file, line: line)
        return false
    }

    func testRepeatedManualCommandsDuringProbeCoalesceWithoutWaitersAndPreserveNewInput() async throws {
        let first = FileTemplate(name: "First", fileExtension: "txt", content: "one")
        let second = FileTemplate(name: "Second", fileExtension: "md", content: "two")
        try store.saveTemplates([first, second])
        let source = store!
        let probe = RefreshGate()
        defer { probe.release.signal() }
        let tokens = RefreshCounter()
        let reads = LockedTestValue((count: 0, active: 0, maximum: 0))
        let model = QuickFileViewModel(templateStore: source, authoritativeTemplateLoader: {
            reads.update { $0.count += 1; $0.active += 1; $0.maximum = max($0.maximum, $0.active) }
            defer { reads.update { $0.active -= 1 } }
            return try source.reloadTemplates()
        }, templateChangeTokenReader: {
            tokens.increment()
            let token = try source.changeToken()
            if tokens.count == 3 { probe.blockOnce() }
            return token
        })
        await model.loadTemplatesIfNeeded()
        model.requestTemplateRefresh()
        let started = await BackgroundWork.run { probe.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertTrue(model.isProbingTemplateRefresh)
        XCTAssertFalse(model.isLoadingTemplates)
        for _ in 0..<1_000 {
            model.requestTemplateReload()
            XCTAssertEqual(try reloadWaiterCount(model), 0)
        }
        model.selectedTemplateID = second.id
        model.requestedFilename = "newer filename"
        XCTAssertEqual(reads.value.count, 1)
        probe.release.signal()
        try await settle(model)
        XCTAssertEqual(reads.value.count, 2, "The entire command burst needs one authoritative reload")
        XCTAssertEqual(reads.value.maximum, 1)
        XCTAssertEqual(try reloadWaiterCount(model), 0)
        XCTAssertEqual(model.templates, [first, second])
        XCTAssertEqual(model.selectedTemplateID, second.id)
        XCTAssertEqual(model.requestedFilename, "newer filename")
    }

    func testTwoWindowsShareReloadAndCancellingOneProbeWaiterPreservesTheOther() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "body")
        try store.saveTemplates([original])
        let source = store!
        let probe = RefreshGate()
        let authority = RefreshGate()
        defer { probe.release.signal(); authority.release.signal() }
        let tokens = RefreshCounter()
        let reads = RefreshCounter()
        let model = QuickFileViewModel(templateStore: source, authoritativeTemplateLoader: {
            reads.increment()
            let loaded = try source.reloadTemplates()
            if reads.count == 2 { authority.blockOnce() }
            return loaded
        }, templateChangeTokenReader: {
            tokens.increment()
            let token = try source.changeToken()
            if tokens.count == 3 { probe.blockOnce() }
            return token
        })
        await model.loadTemplatesIfNeeded()
        let firstHost = NSHostingView(rootView: TemplateManagerView(viewModel: model))
        let secondHost = NSHostingView(rootView: TemplateManagerView(viewModel: model))
        let windows = [firstHost, secondHost].map { host in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            return window
        }
        defer { windows.forEach { $0.contentView = nil; $0.close() } }
        XCTAssertFalse(windows[0] === windows[1])
        XCTAssertTrue(firstHost.rootView.viewModel === secondHost.rootView.viewModel)
        firstHost.rootView.viewModel.requestTemplateRefresh()
        let probing = await BackgroundWork.run { probe.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(probing)
        for _ in 0..<20 {
            firstHost.rootView.viewModel.requestTemplateReload()
            secondHost.rootView.viewModel.requestTemplateReload()
        }
        XCTAssertEqual(try reloadWaiterCount(model), 0)
        var firstCompletions = 0
        var secondCompletions = 0
        let firstWaiter = Task {
            await firstHost.rootView.viewModel.reloadTemplates()
            firstCompletions += 1
        }
        let secondWaiter = Task {
            await secondHost.rootView.viewModel.reloadTemplates()
            secondCompletions += 1
        }
        defer { firstWaiter.cancel(); secondWaiter.cancel() }
        guard try await waitForReloadCondition("Both windows must register their waits", {
            try self.reloadWaiterCount(model) == 2
        }) else { return }
        firstWaiter.cancel()
        guard try await waitForReloadCondition("Cancelling the first window must end its wait", {
            let count = try self.reloadWaiterCount(model)
            return firstCompletions == 1 && count == 1
        }) else { return }
        XCTAssertEqual(secondCompletions, 0)
        XCTAssertTrue(model.isProbingTemplateRefresh)
        XCTAssertEqual(reads.count, 1)
        windows[0].close()
        probe.release.signal()
        let loading = await BackgroundWork.run { authority.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(loading)
        XCTAssertTrue(model.isLoadingTemplates)
        XCTAssertEqual(secondCompletions, 0)
        XCTAssertEqual(try reloadWaiterCount(model), 1)
        XCTAssertEqual(reads.count, 2)
        authority.release.signal()
        guard try await waitForReloadCondition("The surviving window must finish after authority returns", {
            secondCompletions == 1
        }) else { return }
        await firstWaiter.value
        await secondWaiter.value
        try await settle(model)
        XCTAssertEqual(firstCompletions, 1)
        XCTAssertEqual(secondCompletions, 1)
        XCTAssertEqual(try reloadWaiterCount(model), 0)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(secondHost.rootView.viewModel.templates, [original])
    }

    func testCancellingAllAuthorityWaitersDoesNotReleaseTheSharedReadSlot() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "body")
        try store.saveTemplates([original])
        let source = store!
        let authority = RefreshGate()
        defer { authority.release.signal() }
        let reads = LockedTestValue((count: 0, active: 0, maximum: 0))
        let model = QuickFileViewModel(templateStore: source, authoritativeTemplateLoader: {
            let number = reads.update {
                $0.count += 1; $0.active += 1; $0.maximum = max($0.maximum, $0.active)
                return $0.count
            }
            defer { reads.update { $0.active -= 1 } }
            let loaded = try source.reloadTemplates()
            if number == 2 { authority.blockOnce() }
            return loaded
        })
        await model.loadTemplatesIfNeeded()
        var completions = 0
        let first = Task { await model.reloadTemplates(); completions += 1 }
        defer { first.cancel() }
        let loading = await BackgroundWork.run { authority.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(loading)
        let second = Task { await model.reloadTemplates(); completions += 1 }
        defer { second.cancel() }
        guard try await waitForReloadCondition("Both authority waiters must register", {
            try self.reloadWaiterCount(model) == 2
        }) else { return }
        first.cancel()
        second.cancel()
        guard try await waitForReloadCondition("All cancelled callers must finish while I/O is blocked", {
            let count = try self.reloadWaiterCount(model)
            return completions == 2 && count == 0
        }) else { return }
        XCTAssertTrue(model.isLoadingTemplates)
        XCTAssertTrue(model.hasPendingTemplateRefresh)
        for _ in 0..<100 { model.requestTemplateReload() }
        XCTAssertEqual(try reloadWaiterCount(model), 0)
        XCTAssertEqual(reads.value.count, 2)
        XCTAssertEqual(reads.value.active, 1)
        authority.release.signal()
        try await settle(model)
        await first.value
        await second.value
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(reads.value.count, 3, "Requests made during authority coalesce into one subsequent read")
        XCTAssertEqual(reads.value.maximum, 1)
        XCTAssertEqual(try reloadWaiterCount(model), 0)
        XCTAssertEqual(model.templates, [original])
    }

    func testPrecancelledInitialLoadAllowsTheNextWindowToLoadOnce() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "body")
        try store.saveTemplates([original])
        let source = store!
        let reads = RefreshCounter()
        let model = QuickFileViewModel(templateStore: source, authoritativeTemplateLoader: {
            reads.increment()
            return try source.reloadTemplates()
        })
        var firstFinished = false
        let firstWindowLoad = Task {
            await model.loadTemplatesIfNeeded()
            firstFinished = true
        }
        firstWindowLoad.cancel()
        guard try await waitForReloadCondition("The precancelled initial load must finish", {
            firstFinished
        }) else { return }
        await firstWindowLoad.value
        XCTAssertEqual(reads.count, 0)
        XCTAssertEqual(try reloadWaiterCount(model), 0)
        XCTAssertFalse(model.hasPendingTemplateRefresh)
        XCTAssertNil(model.templateLoadFailure)

        var secondFinished = false
        let secondWindowLoad = Task {
            await model.loadTemplatesIfNeeded()
            secondFinished = true
        }
        defer { secondWindowLoad.cancel() }
        guard try await waitForReloadCondition("The next window must complete initial loading", {
            secondFinished
        }) else { return }
        await secondWindowLoad.value
        XCTAssertEqual(model.templates, [original])
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(try reloadWaiterCount(model), 0)
        XCTAssertFalse(model.hasPendingTemplateRefresh)
        XCTAssertFalse(model.isLoadingTemplates)
        XCTAssertNil(model.templateLoadFailure)
        await model.loadTemplatesIfNeeded()
        XCTAssertEqual(reads.count, 1)
    }

    func testPrecancelledReloadAndCompletionCancellationRaceLeaveNoWaiters() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "body")
        try store.saveTemplates([original])
        let source = store!
        for _ in 0..<20 {
            let authority = RefreshGate()
            defer { authority.release.signal() }
            let reads = RefreshCounter()
            let model = QuickFileViewModel(templateStore: source, templates: [original],
                authoritativeTemplateLoader: {
                    reads.increment()
                    let loaded = try source.reloadTemplates()
                    authority.blockOnce()
                    return loaded
                })
            var precancelledCompletions = 0
            let precancelled = Task { await model.reloadTemplates(); precancelledCompletions += 1 }
            precancelled.cancel()
            guard try await waitForReloadCondition("A precancelled call must return without reading", {
                precancelledCompletions == 1
            }) else { return }
            await precancelled.value
            XCTAssertEqual(try reloadWaiterCount(model), 0)
            XCTAssertFalse(model.hasPendingTemplateRefresh)
            XCTAssertEqual(reads.count, 0)

            var completions = 0
            let waiter = Task { await model.reloadTemplates(); completions += 1 }
            defer { waiter.cancel() }
            let loading = await BackgroundWork.run { authority.started.wait(timeout: .now() + 5) == .success }
            XCTAssertTrue(loading)
            XCTAssertEqual(try reloadWaiterCount(model), 1)
            // Release synchronous I/O and cancel from another executor so completion
            // and cancellation can both contend for the same registered waiter.
            let cancellation = Task.detached { authority.release.signal(); waiter.cancel() }
            await cancellation.value
            guard try await waitForReloadCondition("A completion/cancellation race must resume once", {
                completions == 1
            }) else { return }
            await waiter.value
            try await settle(model)
            XCTAssertEqual(completions, 1)
            XCTAssertEqual(try reloadWaiterCount(model), 0)
            XCTAssertEqual(reads.count, 1)
        }
    }

    func testProbePreservesNotificationAndManualWaiter() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "body")
        try store.saveTemplates([original])
        let source = store!
        let probe = RefreshGate()
        let authority = RefreshGate()
        defer { probe.release.signal(); authority.release.signal() }
        let tokens = RefreshCounter()
        let reads = RefreshCounter()
        let model = QuickFileViewModel(templateStore: source, authoritativeTemplateLoader: {
            reads.increment()
            if reads.count == 2 { authority.blockOnce() }
            return try source.reloadTemplates()
        }, templateChangeTokenReader: {
            tokens.increment()
            if tokens.count == 3 { probe.blockOnce() }
            return try source.changeToken()
        })
        await model.loadTemplatesIfNeeded()
        model.requestTemplateRefresh()
        let started = await BackgroundWork.run { probe.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        model.requestTemplateRefresh(force: true)
        var manualStarted = false
        var manualFinished = false
        let manual = Task {
            manualStarted = true
            await model.reloadTemplates()
            manualFinished = true
        }
        while !manualStarted { await Task.yield() }
        XCTAssertFalse(manualFinished)
        probe.release.signal()
        let loading = await BackgroundWork.run { authority.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(loading)
        XCTAssertFalse(manualFinished)
        XCTAssertTrue(model.isLoadingTemplates)
        authority.release.signal()
        await manual.value
        try await settle(model)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(model.status, .success("模板已重新加载。"))
    }

    func testChangedProbeWaitsForExportAndPreservesItsLoadingOwnership() async throws {
        try await checkProbeDuringOperation(.export, failProbe: false)
    }

    func testFailedProbeWaitsForCreationAndPreservesItsResult() async throws {
        try await checkProbeDuringOperation(.create, failProbe: true)
    }

    func testGenerationChangeDuringProbeWaitsForSaveAndPreservesItsResult() async throws {
        try await checkProbeDuringOperation(.save, failProbe: false)
    }

    private enum ProbeOperation: Sendable { case export, create, save }

    private func checkProbeDuringOperation(_ operation: ProbeOperation, failProbe: Bool) async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "body")
        try store.saveTemplates([original])
        let source = store!
        let probe = RefreshGate()
        let interactive = RefreshGate()
        defer { probe.release.signal(); interactive.release.signal() }
        let tokens = RefreshCounter()
        let reads = RefreshCounter()
        let model = QuickFileViewModel(templateStore: source, authoritativeTemplateLoader: {
            reads.increment()
            if reads.count == 2 { interactive.blockOnce() }
            return try source.reloadTemplates()
        }, templateChangeTokenReader: {
            tokens.increment()
            if tokens.count == 3 {
                // Save changes generation while this unchanged token is in flight.
                let token = try source.changeToken()
                probe.blockOnce()
                if failProbe { throw CocoaError(.fileReadUnknown) }
                if operation == .save { return token }
            }
            return try source.changeToken()
        })
        await model.loadTemplatesIfNeeded()
        model.destinationFolder = directory
        model.requestedFilename = "created"
        model.requestTemplateRefresh()
        let probing = await BackgroundWork.run { probe.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(probing)
        let exportURL = directory.appendingPathComponent("export.json")
        let action = Task {
            switch operation {
            case .export: try await model.exportTemplates(to: exportURL)
            case .create: await model.createFile()
            case .save: _ = try await model.saveTemplateAsNew(original)
            }
        }
        let acting = await BackgroundWork.run { interactive.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(acting)
        if operation == .export {
            var external = original
            external.content = "external"
            try JSONEncoder().encode([external]).write(to: directory.appendingPathComponent("templates.json"), options: .atomic)
            // Busy reload returns after queuing, even though a probe owns the task.
            await model.reloadTemplates()
        }
        probe.release.signal()
        try await waitForProbeCompletion(model)
        XCTAssertEqual(reads.count, 2)
        XCTAssertTrue(model.hasPendingTemplateRefresh)
        switch operation {
        case .export: XCTAssertTrue(model.isLoadingTemplates)
        case .create: XCTAssertTrue(model.isCreatingFile); XCTAssertFalse(model.isLoadingTemplates)
        case .save: XCTAssertTrue(model.isSavingTemplates); XCTAssertFalse(model.isLoadingTemplates)
        }
        interactive.release.signal()
        try await action.value
        let interactiveStatus = model.status
        try await settle(model)
        XCTAssertEqual(reads.count, 3)
        XCTAssertEqual(model.status, interactiveStatus)
        XCTAssertEqual(model.templates, try source.reloadTemplates())
        if operation == .create { XCTAssertNotNil(model.createdFileURL) }
        if operation == .save { XCTAssertEqual(model.templates.count, 2) }
    }

    func testUnavailableTokensStillLoadAuthorityWithoutRetryLoop() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "body")
        try store.saveTemplates([original])
        let source = store!
        let tokens = RefreshCounter()
        let reads = RefreshCounter()
        let model = QuickFileViewModel(templateStore: source, authoritativeTemplateLoader: {
            reads.increment()
            return try source.reloadTemplates()
        }, templateChangeTokenReader: {
            tokens.increment()
            if tokens.count >= 3 { throw CocoaError(.fileReadUnknown) }
            return try source.changeToken()
        })
        await model.loadTemplatesIfNeeded()
        model.requestTemplateRefresh()
        try await settle(model)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(model.templates, [original])
        XCTAssertNil(model.templateLoadFailure)
        XCTAssertFalse(model.hasPendingTemplateRefresh)
    }

    func testReplacementDuringAuthorityAutomaticallyReloadsWithoutNotification() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        let external = FileTemplate(name: "External", fileExtension: "txt", content: "new")
        try store.saveTemplates([original])
        let source = store!
        let gate = RefreshGate()
        defer { gate.release.signal() }
        let reads = RefreshCounter()
        let model = QuickFileViewModel(templateStore: source, templates: [original],
            authoritativeTemplateLoader: {
                reads.increment()
                let loaded = try source.reloadTemplates()
                gate.blockOnce()
                return loaded
            })
        model.requestTemplateRefresh()
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(model.templates, [original])
        // No observer or notification: the token spanning the read must detect this replacement.
        try JSONEncoder().encode([external]).write(to: directory.appendingPathComponent("templates.json"), options: .atomic)
        gate.release.signal()
        try await settle(model)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(model.templates, [external])
        XCTAssertNil(model.templateLoadFailure)
        XCTAssertFalse(model.hasPendingTemplateRefresh)
        XCTAssertFalse(model.isLoadingTemplates)
    }

    func testBeforeTokenFailureKeepsAuthorityAndRequiresNextEventToReadAgain() async throws {
        try await checkOneSidedTokenFailure(failingCall: 1)
    }

    func testAfterTokenFailureKeepsAuthorityAndRequiresNextEventToReadAgain() async throws {
        try await checkOneSidedTokenFailure(failingCall: 2)
    }

    private func checkOneSidedTokenFailure(failingCall: Int) async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        let external = FileTemplate(name: "External", fileExtension: "txt", content: "new")
        try store.saveTemplates([external])
        let source = store!
        let gate = RefreshGate()
        defer { gate.release.signal() }
        let tokens = RefreshCounter()
        let reads = RefreshCounter()
        let model = QuickFileViewModel(templateStore: source, templates: [original],
            authoritativeTemplateLoader: {
                reads.increment()
                return try source.reloadTemplates()
            }, templateChangeTokenReader: {
                tokens.increment()
                if tokens.count == failingCall {
                    gate.blockOnce()
                    throw CocoaError(.fileReadUnknown)
                }
                return try source.changeToken()
            })
        model.requestTemplateRefresh()
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertEqual(reads.count, failingCall == 1 ? 0 : 1)
        XCTAssertEqual(model.templates, [original])
        gate.release.signal()
        try await settle(model)
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(model.templates, [external])
        XCTAssertNil(model.templateLoadFailure)
        XCTAssertFalse(model.hasPendingTemplateRefresh)
        XCTAssertFalse(model.isLoadingTemplates)

        // A single valid token cannot bind the snapshot; the next event must read authority.
        model.requestTemplateRefresh()
        try await settle(model)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(tokens.count, 4)
        XCTAssertEqual(model.templates, [external])
        XCTAssertNil(model.templateLoadFailure)
        XCTAssertFalse(model.hasPendingTemplateRefresh)

        // The successful pair reestablishes the healthy probe path.
        model.requestTemplateRefresh()
        try await settle(model)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(tokens.count, 5)
        XCTAssertFalse(model.hasPendingTemplateRefresh)
    }

    func testModelReleasesWhileHealthyProbeIsBlocked() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "body")
        try store.saveTemplates([original])
        let source = store!
        let probe = RefreshGate()
        defer { probe.release.signal() }
        let tokens = RefreshCounter()
        var model: QuickFileViewModel? = QuickFileViewModel(templateStore: source, templateChangeTokenReader: {
            tokens.increment()
            if tokens.count == 3 {
                defer { probe.finished.signal() }
                probe.blockOnce()
                return try source.changeToken()
            }
            return try source.changeToken()
        })
        await model?.loadTemplatesIfNeeded()
        weak var weakModel = model
        model?.requestTemplateRefresh()
        let started = await BackgroundWork.run { probe.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        model = nil
        XCTAssertNil(weakModel)
        probe.release.signal()
        let finished = await BackgroundWork.run { probe.finished.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(finished)
    }

    func testActivationDetectsDirectReplacementAndUnchangedChecksSkipBodies() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        let external = FileTemplate(name: "External", fileExtension: "txt", content: "new")
        try store.saveTemplates([original])
        let reads = RefreshCounter()
        let source = store!
        let model = QuickFileViewModel(templateStore: source, authoritativeTemplateLoader: {
            reads.increment()
            return try source.reloadTemplates()
        })
        await model.loadTemplatesIfNeeded()
        model.startTemplateSynchronization()
        try await settle(model)
        for _ in 0..<20 { model.requestTemplateRefresh() }
        try await settle(model)
        XCTAssertEqual(reads.count, 1)
        let bytes = try JSONEncoder().encode([external])
        try bytes.write(to: directory.appendingPathComponent("templates.json"), options: .atomic)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<300 {
            if model.templates == [external] { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.templates, [external])
        XCTAssertEqual(reads.count, 2)
        XCTAssertNil(model.templateLoadFailure)
    }

    func testIdentityOnlyReplacementPublishesOnAutomaticAndManualRefresh() async throws {
        let original = FileTemplate(name: "Template", fileExtension: "txt", content: "unchanged")
        let automaticReplacement = FileTemplate(name: original.name, fileExtension: original.fileExtension,
                                               content: original.content)
        let manualReplacement = FileTemplate(name: original.name, fileExtension: original.fileExtension,
                                            content: original.content)
        try store.saveTemplates([original])
        let model = QuickFileViewModel(templateStore: store, templates: [original])
        model.requestTemplateRefresh()
        try await settle(model)
        let url = directory.appendingPathComponent("templates.json")
        try JSONEncoder().encode([automaticReplacement]).write(to: url, options: .atomic)
        model.requestTemplateRefresh()
        try await settle(model)
        XCTAssertEqual(model.templates.map(\.id), [automaticReplacement.id])
        XCTAssertEqual(model.selectedTemplateID, automaticReplacement.id)
        XCTAssertNil(model.templateLoadFailure)
        try JSONEncoder().encode([manualReplacement]).write(to: url, options: .atomic)
        await model.reloadTemplates()
        XCTAssertEqual(model.templates.map(\.id), [manualReplacement.id])
        XCTAssertEqual(model.selectedTemplateID, manualReplacement.id)
        XCTAssertNil(model.templateLoadFailure)
    }

    func testAutomaticRefreshDetectsChangesToSymbolicLinkTarget() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        var external = original
        external.content = "new"
        try store.saveTemplates([original])
        let url = directory.appendingPathComponent("templates.json")
        let target = directory.appendingPathComponent("target.json")
        try FileManager.default.moveItem(at: url, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let model = QuickFileViewModel(templateStore: store, templates: [original])
        model.requestTemplateRefresh()
        try await settle(model)
        try JSONEncoder().encode([external]).write(to: target, options: .atomic)
        model.requestTemplateRefresh()
        try await settle(model)
        XCTAssertEqual(model.templates, [external])
        XCTAssertNil(model.templateLoadFailure)
    }

    func testNotificationRefreshPreservesDraftAndRejectsItsOldBaseline() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        try store.saveTemplates([original])
        let model = QuickFileViewModel(templateStore: store, templates: [original])
        model.startTemplateSynchronization()
        try await settle(model)
        var editor = TemplateEditorState(template: original)
        editor.draft.content = "unsaved"
        var external = original
        external.content = "external"
        try store.saveTemplates([external])
        for _ in 0..<300 {
            if model.templates == [external] { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.templates, [external])
        XCTAssertEqual(editor.draft.content, "unsaved")
        XCTAssertTrue(editor.isDirty)
        do {
            try await model.saveTemplate(editor.makeTemplate(), replacing: original)
            XCTFail("Old editor baseline must not overwrite the external change")
        } catch { editor.finishSave(error: error) }
        XCTAssertTrue(editor.offersConflictRecovery)
        XCTAssertEqual(try store.reloadTemplates(), [external])
    }

    func testRepeatedEventsKeepOneReadAndRetainNewSelectionAndFilename() async throws {
        let first = FileTemplate(name: "First", fileExtension: "txt", content: "one")
        let second = FileTemplate(name: "Second", fileExtension: "md", content: "two")
        try store.saveTemplates([first, second])
        let source = store!
        let gate = RefreshGate()
        defer { gate.release.signal() }
        let reads = RefreshCounter()
        let model = QuickFileViewModel(templateStore: source, templates: [first], authoritativeTemplateLoader: {
            reads.increment()
            let loaded = try source.reloadTemplates()
            gate.blockOnce()
            return loaded
        })
        model.requestTemplateRefresh()
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        for _ in 0..<100 { model.requestTemplateRefresh() }
        model.selectedTemplateID = second.id
        model.requestedFilename = "next form"
        XCTAssertEqual(reads.count, 1)
        gate.release.signal()
        try await settle(model)
        XCTAssertEqual(model.templates, [first, second])
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(model.selectedTemplateID, second.id)
        XCTAssertEqual(model.requestedFilename, "next form")
    }

    func testBadFileInvalidatesOldListAndRecoversAutomatically() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        try store.saveTemplates([original])
        let model = QuickFileViewModel(templateStore: store, templates: [original])
        model.requestTemplateRefresh()
        try await settle(model)
        let url = directory.appendingPathComponent("templates.json")
        let good = try Data(contentsOf: url)
        try Data("broken".utf8).write(to: url, options: .atomic)
        model.requestTemplateRefresh()
        try await settle(model)
        XCTAssertEqual(model.templateLoadFailure, .malformedConfiguration)
        XCTAssertEqual(model.templates, [original])
        XCTAssertFalse(model.canCreate)
        try good.write(to: url, options: .atomic)
        model.requestTemplateRefresh()
        try await settle(model)
        XCTAssertNil(model.templateLoadFailure)
        XCTAssertEqual(model.templates, [original])
    }

    func testRefreshDuringSaveIsReplayedWithoutReplacingSaveResult() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        try store.saveTemplates([original])
        let gate = RefreshGate()
        defer { gate.release.signal() }
        let savingStore = TemplateStore(defaults: defaults,
            storageURL: directory.appendingPathComponent("templates.json"),
            writeTemplatesData: { data, url in
                gate.blockOnce()
                try data.write(to: url, options: .atomic)
            })
        let model = QuickFileViewModel(templateStore: savingStore, templates: [original])
        var edited = original
        edited.content = "saved"
        let save = Task { try await model.saveTemplate(edited, replacing: original) }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        model.requestTemplateRefresh(force: true)
        await model.reloadTemplates()
        XCTAssertFalse(model.isLoadingTemplates)
        gate.release.signal()
        try await save.value
        try await settle(model)
        XCTAssertEqual(model.templates, [edited])
        XCTAssertEqual(model.status, .success("模板已保存。"))
    }

    func testRefreshDuringCreationWaitsAndPreservesSuccessfulCreation() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "body")
        try store.saveTemplates([original])
        let gate = RefreshGate()
        defer { gate.release.signal() }
        let source = store!
        let model = QuickFileViewModel(templateStore: source, templates: [original],
            authoritativeTemplateLoader: {
                gate.blockOnce()
                return try source.reloadTemplates()
            })
        model.destinationFolder = directory
        model.requestedFilename = "created"
        let create = Task { await model.createFile() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        for _ in 0..<20 { model.requestTemplateRefresh(force: true) }
        XCTAssertFalse(model.isLoadingTemplates)
        gate.release.signal()
        await create.value
        try await settle(model)
        XCTAssertNotNil(model.createdFileURL)
        XCTAssertEqual(model.status, .success("已创建 created.txt"))
        XCTAssertEqual(model.requestedFilename, "created")
    }

    func testModelAndObserversReleaseWhileSynchronousReadIsBlocked() async throws {
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        try store.saveTemplates([original])
        let gate = RefreshGate()
        defer { gate.release.signal() }
        let source = store!
        var model: QuickFileViewModel? = QuickFileViewModel(templateStore: source, templates: [original],
            authoritativeTemplateLoader: {
                defer { gate.finished.signal() }
                gate.blockOnce()
                return try source.reloadTemplates()
            })
        weak var weakModel = model
        model?.startTemplateSynchronization()
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        model = nil
        XCTAssertNil(weakModel)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        notify_post(suite)
        gate.release.signal()
        // Wait until the worker has left the fixture before tearDown removes it.
        let finished = await BackgroundWork.run { gate.finished.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(finished)
    }
}

private final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class RefreshGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blocked = false
    func blockOnce() {
        lock.lock()
        let shouldBlock = !blocked
        blocked = true
        lock.unlock()
        if shouldBlock {
            started.signal()
            _ = release.wait(timeout: .now() + 10)
        }
    }
}
