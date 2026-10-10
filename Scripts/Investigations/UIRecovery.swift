import AppKit
import Foundation
import SwiftUI
@testable import QuickFileCore
@testable import QuickFileInfrastructure

// This executable hosts production views and ViewModel in its own fixture directory.
// It deliberately omits ContentView's real extension/authorization-queue observers.
// The production-tabs variant uses the unchanged AppTabsView, including its three
// production pages, with every automatically read dependency injected below.
// Protocol: read-only AX tree inspection only. Do not click, press keys, open
// menus/sheets, or activate controls. Production buttons remain real so the view
// structure is comparable; this executable is not a sandbox for manual actions.
private enum Page: Hashable { case create, templates }

// Direct executable options (the historical Python runner intentionally retains
// its legacy checkpoint contract):
//   --transition legacy-count-tagged  : 8 -> 300 -> 8; count-tagged bodies
//   --transition identical-reload    : 8 -> 8 -> 8; byte-identical disk reload
//   --transition body-update         : 8 -> 8 -> 8; only body bytes change
//   --transition membership-only     : 8 -> 300 -> 8; surviving bodies unchanged
// Each sequence repeats twice. All modes still require read-only checkpoints.
private enum FixtureTransition: String {
    case legacyCountTagged = "legacy-count-tagged"
    case identicalReload = "identical-reload"
    case bodyUpdate = "body-update"
    case membershipOnly = "membership-only"

    var changedCount: Int {
        switch self {
        case .legacyCountTagged, .membershipOnly: return 300
        case .identicalReload, .bodyUpdate: return 8
        }
    }

    var changedCheckpoint: String {
        switch self {
        case .legacyCountTagged, .membershipOnly: return "large300"
        case .identicalReload: return "reloaded8"
        case .bodyUpdate: return "updated8"
        }
    }

    var bodyPolicy: String {
        switch self {
        case .legacyCountTagged: return "count-tagged; surviving bodies change with count"
        case .identicalReload: return "same IDs/order/count and identical on-disk bytes"
        case .bodyUpdate: return "same IDs/order/count; only body bytes change"
        case .membershipOnly: return "membership only; surviving IDs and body bytes unchanged"
        }
    }
}

private enum FixtureError: LocalizedError {
    case invalidArguments(String)
    case contractViolation(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message), let .contractViolation(message): return message
        }
    }
}

@MainActor
private final class RecoveryDriver: ObservableObject {
    let model: QuickFileViewModel
    let integration: FinderIntegrationViewModel
    let directory: URL
    let store: TemplateStore
    let defaults: UserDefaults
    let suite: String
    let variant: String
    let identityMode: String
    let restoreEntry: String
    let transition: FixtureTransition
    let diagnostics: DiagnosticsViewModel?
    let menuSettings: FinderMenuSettingsViewModel?
    @Published var page = Page.create
    @Published var productionTab = AppTab.create
    @Published var generation = 0
    var displayedGeneration = -1
    private var didRun = false
    private var timeline: [[String: Any]] = []

    init() throws {
        let flags = ["--output", "--variant", "--identities", "--restore", "--transition"]
        var options: [String: String] = [:]
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            guard arguments.count >= 2, flags.contains(arguments[0]),
                  !arguments[1].hasPrefix("--"), options[arguments[0]] == nil else {
                throw FixtureError.invalidArguments("Expected unique known --option value pairs")
            }
            options[arguments[0]] = arguments[1]
            arguments.removeFirst(2)
        }
        let output = options["--output"] ?? ""
        guard !output.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        directory = URL(fileURLWithPath: output, isDirectory: true)
        guard directory.path != "/" else { throw CocoaError(.fileWriteInvalidFileName) }
        variant = options["--variant"] ?? "both"
        identityMode = options["--identities"] ?? "superset"
        restoreEntry = options["--restore"] ?? "reload"
        guard let selectedTransition = FixtureTransition(rawValue: options["--transition"] ?? "legacy-count-tagged") else {
            throw FixtureError.invalidArguments("Unknown --transition")
        }
        transition = selectedTransition
        guard ["both", "picker", "list", "production-tabs"].contains(variant),
              ["superset", "disjoint"].contains(identityMode),
              ["reload", "create-preflight"].contains(restoreEntry) else {
            throw FixtureError.invalidArguments("Unknown variant, identities, or restore option")
        }
        guard transition == .legacyCountTagged || identityMode == "superset" else {
            throw FixtureError.invalidArguments("Only legacy-count-tagged accepts disjoint identities")
        }
        guard restoreEntry != "create-preflight" || transition.changedCount > 8 else {
            throw FixtureError.invalidArguments("create-preflight requires an actually removed selected ID; fixed-count transitions cannot use it")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "QuickFileInvestigation.UIRecovery.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        try JSONSerialization.data(withJSONObject: ["suite": suite]).write(to: directory.appendingPathComponent("namespace.json"), options: .atomic)
        store = TemplateStore(defaults: defaults, storageURL: directory.appendingPathComponent("templates.json"),
                              changeNotificationName: suite)
        try store.saveTemplates(Self.fixture(count: 8, identities: identityMode, transition: transition))
        let grants = AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: directory.appendingPathComponent("grants"),
            persistentBookmarkCreator: { Data($0.path.utf8) }, transferBookmarkCreator: { Data($0.path.utf8) },
            persistentBookmarkResolver: { ResolvedSecurityScopedBookmark(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false) },
            transferBookmarkResolver: { ResolvedSecurityScopedBookmark(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false) },
            startAccessing: { _ in false }, stopAccessing: { _ in }
        )
        model = QuickFileViewModel(templateStore: store, templates: try store.reloadTemplates(),
                                   authorizedDirectoryStore: grants, clipboardProvider: { nil }, revealCreatedFile: { _ in })
        integration = FinderIntegrationViewModel(
            statusProvider: { false },
            runtimeProvider: { _ in
                FinderExtensionDiagnosticSnapshot(embeddedIdentifiers: [], embeddingKnown: false,
                    registration: .unknown, registrationEvidence: "isolated fixture", enabled: false, responded: nil)
            }, managementOpener: {}
        )
        if variant == "production-tabs" {
            // No default DiagnosticsViewModel/Settings model may be constructed:
            // their production defaults would inspect real integration/storage.
            diagnostics = DiagnosticsViewModel(
                extensionEnabledProvider: { false },
                runtimeProvider: { _ in
                    FinderExtensionDiagnosticSnapshot(embeddedIdentifiers: [], embeddingKnown: false,
                        registration: .unknown, registrationEvidence: "isolated fixture", enabled: false, responded: nil)
                },
                extensionActivityStore: FinderExtensionActivityStore(
                    defaults: defaults, failureHistoryFileURL: directory.appendingPathComponent("failures.json")),
                authorizedDirectoryStore: grants
            )
            let settings = FinderMenuSettingsStore(
                storageURL: directory.appendingPathComponent("finder-menu-settings.json"),
                changeNotificationName: suite + ".menu-settings"
            )
            menuSettings = FinderMenuSettingsViewModel(
                load: { try settings.load() }, save: { try settings.save($0) }
            )
        } else {
            // Keep legacy List/Picker/TabView controls free of the new retained
            // diagnostics/settings objects so their historical scope is preserved.
            diagnostics = nil
            menuSettings = nil
        }
        if restoreEntry == "create-preflight" {
            let target = directory.appendingPathComponent("creation-must-remain-empty", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            model.destinationFolder = target
        }
    }

    // UUIDs and bodies are deterministic. This synchronous helper returns no
    // array to an async frame or stored driver property after a disk transition.
    private static func fixture(count: Int, identities: String, transition: FixtureTransition,
                                bodyRevision: Int = 0) -> [FileTemplate] {
        (0..<count).map { index in
            let base = count == 300 && identities == "disjoint" ? 10_000 : 0
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", base + index + 1))!
            let marker: String
            switch transition {
            case .legacyCountTagged:
                // Preserve historical fixture bytes/IDs, including disjoint runs.
                marker = "UIRECOVERY-BODY-\(count)-\(index)-"
            case .identicalReload, .bodyUpdate:
                marker = "UIRECOVERY-BODY-REV\(bodyRevision)-\(index)-"
            case .membershipOnly:
                marker = "UIRECOVERY-BODY-STABLE-\(index)-"
            }
            // Distinct nonempty ~16 KiB strings, rather than a shared empty body.
            return FileTemplate(id: id, name: String(format: "Owned template %03d", index), fileExtension: "txt",
                                content: marker + String(repeating: "body-\(index) ", count: 2048))
        }
    }

    private func verifyModel(count: Int, bodyRevision: Int = 0) throws {
        guard model.templates == Self.fixture(count: count, identities: identityMode,
                                              transition: transition, bodyRevision: bodyRevision) else {
            throw FixtureError.contractViolation("Model does not match the expected fixture state")
        }
    }

    private func event(_ stage: String, extra: [String: Any] = [:]) throws {
        var entry: [String: Any] = ["stage": stage, "uptimeNS": DispatchTime.now().uptimeNanoseconds,
            "modelCount": model.templates.count, "selectedIDValid": model.selectedTemplate != nil,
            "generation": generation, "displayedGeneration": displayedGeneration]
        extra.forEach { entry[$0.key] = $0.value }
        timeline.append(entry)
        let result: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "variant": variant,
            "identities": identityMode, "restoreEntry": restoreEntry, "events": timeline,
            "fixtureProtocolVersion": 2, "transition": transition.rawValue,
            "bodyPolicy": transition.bodyPolicy,
            "fixtureCountSequence": [8, transition.changedCount, 8, transition.changedCount, 8],
            "checkpointSequence": ["baseline8", "\(transition.changedCheckpoint)-1", "restored8-1",
                                   "\(transition.changedCheckpoint)-2", "restored8-2"],
            "noFileCreation": model.createdFileURL == nil, "appGroupUsed": false,
            "fixtureArrayRetainedByDriver": false,
            "container": variant == "production-tabs" ? "production AppTabsView / NSTabViewController" : "legacy isolated pages",
            "inputPolicy": "read-only AX; do not activate production controls",
            "contentViewObserversIncluded": false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("timeline.json"), options: .atomic)
    }

    private func display() async throws {
        generation += 1
        let expected = generation
        // The witness acknowledges an actual SwiftUI->NSView update. This is not
        // proof that every platform/AX object was destroyed; leaks/heap follow later.
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while displayedGeneration < expected && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard displayedGeneration >= expected else { throw CocoaError(.coderInvalidValue) }
        if variant == "both" {
            page = .create
            try await Task.sleep(nanoseconds: 300_000_000)
            page = .templates
        } else if variant == "production-tabs" {
            // Match the legacy two-page visit sequence. Diagnostics is retained
            // by the real container but not deliberately visited by this protocol.
            productionTab = .create
            try await Task.sleep(nanoseconds: 300_000_000)
            productionTab = .templates
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        NSApp.windows.forEach { $0.displayIfNeeded() }
        try event("ui-update-acknowledged")
    }

    private func checkpoint(_ name: String) async throws {
        guard !model.isLoadingTemplates, !model.isSavingTemplates,
              !model.isCreatingFile, !model.isAuthorizingDirectory else {
            throw FixtureError.contractViolation("Checkpoint requires idle model operations")
        }
        try event("checkpoint-\(name)")
        let ready: [String: Any] = ["checkpoint": name, "pid": ProcessInfo.processInfo.processIdentifier,
                                   "modelCount": model.templates.count, "selectedIDValid": model.selectedTemplate != nil,
                                   "variant": variant, "transition": transition.rawValue,
                                   "bodyPolicy": transition.bodyPolicy,
                                   "modelOperationsIdle": true,
                                   "driverTaskWaitingForHandshake": true,
                                   "inputPolicy": "read-only AX; do not activate production controls"]
        try JSONSerialization.data(withJSONObject: ready).write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
        let acknowledgement = directory.appendingPathComponent("continue-\(name)")
        let deadline = ProcessInfo.processInfo.systemUptime + 1800
        while !FileManager.default.fileExists(atPath: acknowledgement.path) {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("abort").path) {
                throw CocoaError(.userCancelled)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func changeDisk(to count: Int, bodyRevision: Int = 0, label: String) throws {
        // All full-body arrays/Data here have synchronous scope. Only scalar
        // evidence enters the timeline; no 300-body snapshot survives a shrink.
        let target = Self.fixture(count: count, identities: identityMode,
                                  transition: transition, bodyRevision: bodyRevision)
        let oldIDs = Set(model.templates.map(\.id))
        let newIDs = Set(target.map(\.id))
        let oldByID = Dictionary(uniqueKeysWithValues: model.templates.map { ($0.id, $0) })
        var changedSurvivingBodies = 0
        var changedSurvivingOtherFields = 0
        for value in target {
            guard let old = oldByID[value.id] else { continue }
            if !old.content.utf8.elementsEqual(value.content.utf8) { changedSurvivingBodies += 1 }
            if old.name != value.name || old.fileExtension != value.fileExtension || old.isEnabled != value.isEnabled {
                changedSurvivingOtherFields += 1
            }
        }
        let identityOrderUnchanged = model.templates.map(\.id) == target.map(\.id)
        let survivingIdentityOrderUnchanged = model.templates.map(\.id).filter { newIDs.contains($0) }
            == target.map(\.id).filter { oldIDs.contains($0) }
        let location = directory.appendingPathComponent("templates.json")
        let previousBytes = try Data(contentsOf: location)
        let data: Data
        if transition == .identicalReload {
            guard try JSONDecoder().decode([FileTemplate].self, from: previousBytes) == target else {
                throw FixtureError.contractViolation("Identical reload requires the expected on-disk fixture")
            }
            // Reuse disk bytes, rather than relying on JSONEncoder key ordering.
            data = previousBytes
        } else {
            data = try JSONEncoder().encode(target)
        }
        let diskBytesIdentical = previousBytes == data
        switch transition {
        case .identicalReload:
            guard identityOrderUnchanged, changedSurvivingBodies == 0,
                  changedSurvivingOtherFields == 0, diskBytesIdentical else {
                throw FixtureError.contractViolation("Identical-reload contract violated")
            }
        case .bodyUpdate:
            guard identityOrderUnchanged, changedSurvivingBodies == count,
                  changedSurvivingOtherFields == 0, !diskBytesIdentical else {
                throw FixtureError.contractViolation("Body-update contract violated")
            }
        case .membershipOnly:
            guard oldIDs != newIDs, changedSurvivingBodies == 0, changedSurvivingOtherFields == 0,
                  survivingIdentityOrderUnchanged,
                  oldIDs.isSubset(of: newIDs) || newIDs.isSubset(of: oldIDs) else {
                throw FixtureError.contractViolation("Membership-only contract violated")
            }
        case .legacyCountTagged: break
        }
        // Direct disk replacement intentionally does NOT notify/reload the ViewModel.
        // Unlike store.saveTemplates, this does not prematurely replace its cache.
        try data.write(to: location, options: .atomic)
        try event(label, extra: ["diskCount": count, "bodyRevision": bodyRevision,
            "addedIdentities": newIDs.subtracting(oldIDs).count,
            "removedIdentities": oldIDs.subtracting(newIDs).count,
            "survivingIdentities": oldIDs.intersection(newIDs).count,
            "changedSurvivingBodies": changedSurvivingBodies,
            "changedSurvivingOtherFields": changedSurvivingOtherFields,
            "identityOrderUnchanged": identityOrderUnchanged,
            "survivingIdentityOrderUnchanged": survivingIdentityOrderUnchanged,
            "diskBytesIdentical": diskBytesIdentical])
    }

    private func selectRemovedIdentityForPreflight() throws {
        // Only IDs cross this synchronous boundary. No old template/body may be
        // captured by the async createFile call or kept by the recovery driver.
        let restoredIDs = Set(Self.fixture(count: 8, identities: identityMode, transition: transition).map(\.id))
        guard let removedID = model.templates.last(where: { !restoredIDs.contains($0.id) })?.id else {
            throw FixtureError.contractViolation("create-preflight requires an actually removed selected ID")
        }
        model.selectedTemplateID = removedID
        guard model.selectedTemplate != nil, !restoredIDs.contains(removedID) else {
            throw FixtureError.contractViolation("Preflight selected ID is not a removed fixture identity")
        }
        try event("preflight-removed-selection", extra: ["selectedIDRemovedOnRestore": true])
    }

    func run() async {
        guard !didRun else { return }; didRun = true
        do {
            try await display()
            try await checkpoint("baseline8")
            for cycle in 1...2 {
                let changedCount = transition.changedCount
                let changedRevision = transition == .bodyUpdate ? 1 : 0
                try changeDisk(to: changedCount, bodyRevision: changedRevision,
                               label: "disk\(changedCount)-before-model-\(cycle)")
                try verifyModel(count: 8)
                await model.reloadTemplates()
                try verifyModel(count: changedCount, bodyRevision: changedRevision)
                let removedCount = identityMode == "disjoint" ? changedCount : changedCount - 8
                let modelStage = transition == .legacyCountTagged ? "model300-\(cycle)" : "model-\(transition.changedCheckpoint)-\(cycle)"
                try event(modelStage,
                          extra: ["removedIdentitiesOnRestore": removedCount])
                try await display()
                try await checkpoint("\(transition.changedCheckpoint)-\(cycle)")
                if restoreEntry == "create-preflight" { try selectRemovedIdentityForPreflight() }
                try changeDisk(to: 8, label: "disk8-before-model-\(cycle)")
                try verifyModel(count: changedCount, bodyRevision: changedRevision)
                try await Task.sleep(nanoseconds: 300_000_000)
                if restoreEntry == "reload" {
                    await model.reloadTemplates()
                } else {
                    // The guarded selected UUID was removed. Production preflight
                    // must reload, reject that UUID, and return before the writer.
                    await model.createFile()
                    guard model.createdFileURL == nil else { throw CocoaError(.fileWriteUnknown) }
                    guard model.selectedTemplate != nil, model.canCreate else {
                        throw CocoaError(.coderInvalidValue)
                    }
                }
                try verifyModel(count: 8)
                try event("model8-\(cycle)")
                try await display()
                try await checkpoint("restored8-\(cycle)")
            }
            try event("completed")
        } catch {
            try? event("failed", extra: ["error": error.localizedDescription])
        }
        defaults.removePersistentDomain(forName: suite)
        NSApp.terminate(nil)
    }
}

private struct RenderWitness: NSViewRepresentable {
    let driver: RecoveryDriver
    let generation: Int
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let generation = generation
        DispatchQueue.main.async { driver.displayedGeneration = generation }
    }
}

private struct RecoveryPages: View {
    let driver: RecoveryDriver
    @Binding var page: Page
    @Binding var productionTab: AppTab
    var body: some View {
        if driver.variant == "production-tabs" {
            AppTabsView(
                viewModel: driver.model, finderIntegrationViewModel: driver.integration,
                finderMenuSettings: driver.menuSettings!, diagnosticsViewModel: driver.diagnostics!,
                selectedTab: $productionTab
            )
        } else if driver.variant == "picker" {
            CreateFileView(viewModel: driver.model, finderIntegrationViewModel: driver.integration)
        } else if driver.variant == "list" {
            TemplateManagerView(viewModel: driver.model)
        } else {
            TabView(selection: $page) {
                CreateFileView(viewModel: driver.model, finderIntegrationViewModel: driver.integration)
                    .tag(Page.create).tabItem { Label("创建文件", systemImage: "doc.badge.plus") }
                TemplateManagerView(viewModel: driver.model)
                    .tag(Page.templates).tabItem { Label("模板管理", systemImage: "list.bullet.rectangle") }
            }
        }
    }
}

private struct RecoveryRoot: View {
    @StateObject private var driver: RecoveryDriver
    init(driver: RecoveryDriver) { _driver = StateObject(wrappedValue: driver) }
    var body: some View {
        RecoveryPages(driver: driver, page: $driver.page, productionTab: $driver.productionTab)
            .overlay(RenderWitness(driver: driver, generation: driver.generation).frame(width: 1, height: 1))
            .frame(width: 780, height: 650)
            .task { await driver.run() }
    }
}

@main
@MainActor
private struct RecoveryApp {
    static func main() {
        let driver: RecoveryDriver
        do { driver = try RecoveryDriver() }
        catch {
            FileHandle.standardError.write(Data("UIRecovery: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 780, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "QuickFile UI Recovery Fixture"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RecoveryRoot(driver: driver))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(window) { app.run() }
    }
}
