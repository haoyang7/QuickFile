import AppKit
import Darwin
import notify
import SwiftUI
import XCTest
@testable import QuickFile
@testable import QuickFileCore
@testable import QuickFileInfrastructure

/// Drives the production manager and preview in a real window. External URL
/// delivery belongs to a SwiftUI Scene and is not simulated by this fixture.
@MainActor
final class TemplateRecoveryLifecycleTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var source: URL!
    private var model: QuickFileViewModel!
    private var presentation: TemplateModalPresentation!
    private var window: NSWindow!
    private var host: NSHostingController<AnyView>!
    private var enhancedAccessibility: Any?
    private var oldLanguage: QuickFileLanguage!
    private var readCount: LockedTestValue<Int>!
    private let original = Data("malformed original 🌏".utf8)

    override func setUpWithError() throws {
        _ = NSApplication.shared
        oldLanguage = QuickFileLanguage(rawValue: QuickFileLocalization.identifier) ?? .system
        QuickFileLocalization.apply(.simplifiedChinese)
        enhancedAccessibility = NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        suite = "QuickFileTests.RecoveryLifecycle.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/Temporary/recovery-sheet-20261018/fixtures/\(suite!)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("templates.json")
        try original.write(to: source)
        let reads = LockedTestValue(0)
        readCount = reads
        let store = TemplateStore(defaults: defaults, storageURL: source, changeNotificationName: suite,
            readTemplatesData: { url in
                reads.update { $0 += 1 }
                return try Data(contentsOf: url)
            })
        let grants = AuthorizedDirectoryStore(defaults: defaults, storageDirectory: directory.appendingPathComponent("grants"),
            persistentBookmarkCreator: { Data($0.path.utf8) }, transferBookmarkCreator: { Data($0.path.utf8) },
            persistentBookmarkResolver: { _ in throw CocoaError(.fileReadCorruptFile) },
            transferBookmarkResolver: { _ in throw CocoaError(.fileReadCorruptFile) })
        model = QuickFileViewModel(templateStore: store, authorizedDirectoryStore: grants, clipboardProvider: { nil })
        presentation = TemplateModalPresentation()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 750),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let owner = window!
        host = NSHostingController(rootView: AnyView(TemplateManagerView(viewModel: model,
            presentation: presentation, presentationWindow: { [weak owner] in owner })
            .environment(\.locale, Locale(identifier: "zh-Hans"))))
        window.contentViewController = host
    }

    override func tearDownWithError() throws {
        defer {
            QuickFileLocalization.apply(oldLanguage)
            NSApp.accessibilitySetValue(enhancedAccessibility, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        }
        window.contentViewController = nil
        window.close()
        host = nil
        window = nil
        presentation = nil
        model = nil
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        // Recovery evidence is intentionally read-only. Restore owner write
        // permission only for this isolated test fixture before removing it.
        for name in try backupNames() {
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                ofItemAtPath: directory.appendingPathComponent(name).path)
        }
        try FileManager.default.removeItem(at: directory)
    }

    func testPreparationFailureReleasesLeaseWithoutSheetOrBackup() async throws {
        try await showManager()
        // Keep the visible failure stale, as happens when another process repairs
        // the source after the window last loaded it.
        let repaired = try JSONEncoder().encode([FileTemplate(name: "Repaired", fileExtension: "txt", content: "keep")])
        try repaired.write(to: source)
        try await startRecovery()
        try await waitUntil { !self.presentation.isActive && !self.model.isLoadingTemplates }
        XCTAssertNil(window.attachedSheet)
        XCTAssertNil(presentation.recoveryPreview)
        XCTAssertEqual(try Data(contentsOf: source), repaired)
        try assertNoBackups()
    }

    func testCancelActualRecoveryPreviewPreservesSourceAndExistingBackup() async throws {
        try await showManager()
        let existing = directory.appendingPathComponent("QuickFile-template-backup-existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let evidence = existing.appendingPathComponent("templates.original.json")
        try Data("existing evidence".utf8).write(to: evidence)
        try await startRecovery()
        try await waitUntil { self.window.attachedSheet != nil }
        XCTAssertTrue(presentation.isActive)
        try press("取消", in: XCTUnwrap(window.attachedSheet).contentView!)
        try await waitUntil { self.window.attachedSheet == nil && !self.presentation.isActive }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: evidence), Data("existing evidence".utf8))
        XCTAssertEqual(try backupNames(), [existing.lastPathComponent])
        XCTAssertNil(model.recoveryBackupURL)
    }

    func testConfirmActualRecoveryPreviewBacksUpOriginalAndDismisses() async throws {
        try await showManager()
        try await startRecovery()
        try await waitUntil { self.window.attachedSheet != nil }
        try press("备份原配置并恢复", in: XCTUnwrap(window.attachedSheet).contentView!)
        try await waitUntil { self.window.attachedSheet == nil && !self.presentation.isActive }
        XCTAssertEqual(model.templates, BuiltInTemplates.all)
        let backup = try XCTUnwrap(model.recoveryBackupURL)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("templates.original.json")), original)
        XCTAssertNil(model.templateLoadFailure)
    }

    func testRefreshNotificationDoesNotReplacePreviewBaselineAndStaleConfirmationFails() async throws {
        try await showManager()
        model.startTemplateSynchronization()
        try await waitUntil { !self.model.isLoadingTemplates }
        try await startRecovery()
        try await waitUntil { self.window.attachedSheet != nil }
        let previewID = try XCTUnwrap(presentation.recoveryPreview).id
        let changed = Data("different malformed source".utf8)
        try changed.write(to: source)
        let readsBeforeNotification = readCount.value
        XCTAssertEqual(notify_post(suite), UInt32(NOTIFY_STATUS_OK))
        // Require an actual authority read from the Darwin observer, not just
        // enough elapsed time for an assumed notification delivery.
        try await waitUntil { self.readCount.value > readsBeforeNotification && !self.model.isLoadingTemplates }
        XCTAssertEqual(presentation.recoveryPreview?.id, previewID)
        XCTAssertEqual(try Data(contentsOf: source), changed)
        try assertNoBackups()
        let sheet = try XCTUnwrap(window.attachedSheet)
        try press("备份原配置并恢复", in: XCTUnwrap(sheet.contentView))
        try await waitUntil { self.texts(sheet.contentView!).contains { $0.contains("配置已在恢复预览后发生变化") } }
        XCTAssertTrue(window.attachedSheet === sheet)
        XCTAssertEqual(presentation.recoveryPreview?.id, previewID)
        XCTAssertEqual(try Data(contentsOf: source), changed)
        try assertNoBackups()
        try press("取消", in: XCTUnwrap(sheet.contentView))
        try await waitUntil { self.window.attachedSheet == nil && !self.presentation.isActive }
    }

    func testContentViewToolbarDepartureRejectsLatePreviewAndAllowsFreshRecovery() async throws {
        try await showContentView()
        let controller = window.contentViewController
        let descriptor = open(source.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        try await startRecovery()
        try await waitUntil { self.model.isLoadingTemplates }
        try await selectTab(.create)
        XCTAssertTrue(window.contentViewController === controller)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        try await waitUntil { !self.model.isLoadingTemplates }
        try await selectTab(.templates)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(window.contentViewController === controller)
        XCTAssertEqual(try Data(contentsOf: source), original)
        try assertNoBackups()
        try await startRecovery()
        try await waitUntil { self.window.attachedSheet != nil }
        try press("取消", in: XCTUnwrap(window.attachedSheet).contentView!)
        try await waitUntil { self.window.attachedSheet == nil }
        XCTAssertEqual(try Data(contentsOf: source), original)
        try assertNoBackups()
    }

    func testContentViewRefreshPreservesRecoverySheetAndRejectsChangedBaseline() async throws {
        try await showContentView()
        model.startTemplateSynchronization()
        await settle()
        try await waitUntil { !self.model.isLoadingTemplates }
        try await startRecovery()
        try await waitUntil { self.window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let changed = Data("ContentView concurrent change".utf8)
        try changed.write(to: source)
        let reads = readCount.value
        XCTAssertEqual(notify_post(suite), UInt32(NOTIFY_STATUS_OK))
        try await waitUntil { self.readCount.value > reads && !self.model.isLoadingTemplates }
        XCTAssertTrue(window.attachedSheet === sheet)
        try press("备份原配置并恢复", in: XCTUnwrap(sheet.contentView))
        try await waitUntil { self.texts(sheet.contentView!).contains { $0.contains("配置已在恢复预览后发生变化") } }
        XCTAssertEqual(try Data(contentsOf: source), changed)
        try assertNoBackups()
        try press("取消", in: XCTUnwrap(sheet.contentView))
        try await waitUntil { self.window.attachedSheet == nil }
        XCTAssertEqual(window.toolbar?.selectedItemIdentifier?.rawValue, AppTab.templates.rawValue)
    }

    func testContentViewWindowCloseRejectsPreparationAfterRealStoreLockRelease() async throws {
        try await showContentView()
        let descriptor = open(source.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        try await startRecovery()
        try await waitUntil { self.model.isLoadingTemplates }
        let otherPresentation = TemplateModalPresentation()
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 750),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.contentViewController = NSHostingController(rootView: TemplateManagerView(viewModel: model,
            presentation: otherPresentation, presentationWindow: { [weak other] in other }))
        other.orderFront(nil)
        defer { other.contentViewController = nil; other.close() }
        window.close()
        await settle()
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        try await waitUntil { !self.model.isLoadingTemplates }
        await settle()
        XCTAssertNil(window.attachedSheet)
        XCTAssertNil(other.attachedSheet)
        XCTAssertFalse(otherPresentation.isActive)
        // Keep the same root/controller alive, reopen the same window, and
        // inspect it before a tab change could clear a stale presentation.
        let controller = window.contentViewController
        window.orderFront(nil)
        await settle()
        XCTAssertTrue(window.contentViewController === controller)
        XCTAssertNil(window.attachedSheet, "Closing must invalidate preparation even when the window is retained")
        try await selectTab(.create)
        try await selectTab(.templates)
        XCTAssertNil(window.attachedSheet)
        XCTAssertNil(other.attachedSheet)
        XCTAssertEqual(try Data(contentsOf: source), original)
        try assertNoBackups()
    }

    private func showContentView() async throws {
        let integration = FinderIntegrationViewModel(statusProvider: { false }, runtimeProvider: { _ in
            FinderExtensionDiagnosticSnapshot(embeddedIdentifiers: [], embeddingKnown: true, registration: .unknown,
                registrationEvidence: "fixture", enabled: false, responded: nil)
        }, managementOpener: {})
        let requests = FinderAuthorizationRequestStore(defaults: defaults,
            directoryURL: directory.appendingPathComponent("requests"))
        host.rootView = AnyView(ContentView(viewModel: model,
            finderMenuSettings: FinderMenuSettingsViewModel(load: { .all }, save: { _ in }),
            finderIntegrationViewModel: integration, authorizationRequestStore: requests)
            .environment(\.locale, Locale(identifier: "zh-Hans")))
        window.orderFront(nil)
        try await waitUntil { self.window.toolbar != nil && self.model.templateLoadFailure != nil }
        try await selectTab(.templates)
    }

    private func selectTab(_ tab: AppTab) async throws {
        let item = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == tab.rawValue })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        await settle()
        XCTAssertEqual(window.toolbar?.selectedItemIdentifier?.rawValue, tab.rawValue)
    }

    private func showManager() async throws {
        await model.loadTemplatesIfNeeded()
        XCTAssertEqual(model.templateLoadFailure, .malformedConfiguration)
        window.orderFront(nil)
        await settle()
    }

    private func startRecovery() async throws {
        // SwiftUI lazily materializes the menu when AppKit starts tracking it.
        // Select its real menu item, then end the native tracking loop.
        let selected = LockedTestValue(false)
        let titles = LockedTestValue<[String]>([])
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                              object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu else { return }
                let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        titles.value = menu.items.map(\.title)
                        let index = menu.items.firstIndex(where: { $0.title == "从默认模板恢复…" })
                        menu.cancelTracking()
                        if let index {
                            selected.value = true
                            menu.performActionForItem(at: index)
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .eventTracking)
                RunLoop.main.add(timer, forMode: .common)

            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try press("修复损坏的配置…", in: host.view)
        await settle()
        XCTAssertTrue(selected.value, "The production recovery menu action must run; items: \(titles.value)")
        if !selected.value { throw CocoaError(.featureUnsupported) }
    }

    private func nodes(_ element: Any) -> [NSObject] {
        guard let node = element as? NSObject else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = (node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [Any] : nil)
            ?? node.accessibilityAttributeValue(.children) as? [Any] ?? (node as? NSView)?.subviews ?? []
        return [node] + children.flatMap(nodes)
    }

    private func accessibilityString(_ name: String, of node: NSObject) -> String? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue() as? String
    }

    private func controlNames(_ node: NSObject) -> [String] {
        // AXTitle is the visible text; AXDescription (accessibilityLabel) is a
        // separate description. Native menu controls may expose either one.
        [accessibilityString("accessibilityLabel", of: node),
         accessibilityString("accessibilityTitle", of: node),
         (node as? NSButton)?.title].compactMap { $0 }
    }

    private func isPressable(_ node: NSObject) -> Bool {
        if node is NSButton { return true }
        let roles = [NSAccessibility.Role.button, .popUpButton, .menuButton].map(\.rawValue)
        return node.responds(to: NSSelectorFromString("accessibilityPerformPress"))
            && accessibilityString("accessibilityRole", of: node).map(roles.contains) == true
    }

    private func texts(_ element: Any) -> [String] {
        nodes(element).flatMap { node in
            controlNames(node) + [accessibilityString("accessibilityValue", of: node)].compactMap { $0 }
        }
    }

    private func controlDiagnostics(in view: NSView) -> [String] {
        // Inspect only this fixture. The bounded native subtree helps distinguish
        // missing AX nodes from changed names without printing template text.
        var candidates = nodes(view)
        var views = [view]
        var remaining = 256
        while let current = views.popLast(), remaining > 0 {
            remaining -= 1
            candidates.append(current)
            views.append(contentsOf: current.subviews)
        }
        var seen = Set<ObjectIdentifier>()
        return candidates.filter { seen.insert(ObjectIdentifier($0)).inserted && isPressable($0) }
            .prefix(40).map { node in
                let role = accessibilityString("accessibilityRole", of: node) ?? "unknown"
                let names = controlNames(node).map { String($0.prefix(100)) }
                return "\(type(of: node)): role=\(role.prefix(100)); names=\(names)"
            }
    }

    private func press(_ label: String, in view: NSView) throws {
        let matches = nodes(view).filter { isPressable($0) && controlNames($0).contains(label) }
        let node = try XCTUnwrap(matches.first { $0 is NSButton } ?? matches.first,
            "Missing button: \(label); controls: \(controlDiagnostics(in: view))")
        if let button = node as? NSButton {
            button.performClick(nil)
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: selector) else {
            XCTFail("Button does not implement accessibilityPerformPress")
            throw CocoaError(.featureUnsupported)
        }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(node.method(for: selector), to: Press.self)
        // Menu dismissal can report false even after its selected action ran.
        // Each caller verifies the resulting production state or sheet.
        _ = action(node, selector)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for recovery lifecycle", file: file, line: line)
        throw CocoaError(.userCancelled)
    }

    private func settle() async {
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func backupNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("QuickFile-template-backup-") }.sorted()
    }

    private func assertNoBackups(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try backupNames(), [], file: file, line: line)
        XCTAssertNil(model.recoveryBackupURL, file: file, line: line)
    }
}
