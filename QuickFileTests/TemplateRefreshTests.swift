import AppKit
import notify
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
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
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
            if !model.isLoadingTemplates && !model.isSavingTemplates { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Template refresh did not settle")
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
