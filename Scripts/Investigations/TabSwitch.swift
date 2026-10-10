import AppKit
import QuickFileCore
import SwiftUI

@testable import QuickFileInfrastructure

// Uses production pages in an owned fixture. No App Group, real grants, or clipboard.
@MainActor private final class ProbeCounter { var value = 0 }
@MainActor private final class Driver: ObservableObject {
    let model: QuickFileViewModel
    let integration: FinderIntegrationViewModel
    let defaults: UserDefaults
    let suite = "QuickFile.TabSwitchProbe.\(UUID())"
    let output: URL
    @Published var tab = AppTab.create
    @Published var generation = 0
    var acknowledged = -1
    var rows: [[String: Any]] = []
    var started: UInt64 = 0
    var gaps: [Double] = []
    var lastTick: UInt64 = 0
    var timer: Timer?
    private let counter = ProbeCounter()
    var diagnostics: DiagnosticsViewModel!
    var probes: Int { counter.value }
    init() throws {
        guard CommandLine.arguments.count >= 3, ["8", "300"].contains(CommandLine.arguments[2]) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard output.path != "/" else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
        let grants = AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: output.appendingPathComponent("grants"),
            persistentBookmarkCreator: { Data($0.path.utf8) }, transferBookmarkCreator: { Data($0.path.utf8) },
            persistentBookmarkResolver: {
                ResolvedSecurityScopedBookmark(
                    url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false)
            },
            transferBookmarkResolver: {
                ResolvedSecurityScopedBookmark(
                    url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false)
            }, startAccessing: { _ in false }, stopAccessing: { _ in })
        let count = Int(CommandLine.arguments[2])!
        let templates = (0..<count).map { index in
            FileTemplate(
                name: "Owned template \(index)", fileExtension: "txt",
                content: "Fixture \(index)\n" + String(repeating: "body ", count: 3200))
        }
        model = QuickFileViewModel(
            templateStore: TemplateStore(
                defaults: defaults, storageURL: output.appendingPathComponent("templates.json"),
                changeNotificationName: suite), templates: templates, authorizedDirectoryStore: grants,
            clipboardProvider: { nil }, revealCreatedFile: { _ in })
        integration = FinderIntegrationViewModel(
            statusProvider: { false },
            runtimeProvider: { _ in
                FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: [], embeddingKnown: true, registration: .unknown,
                    registrationEvidence: "fixture", enabled: false, responded: nil)
            }, managementOpener: {})
        let counter = counter
        diagnostics = DiagnosticsViewModel(
            extensionEnabledProvider: { false },
            runtimeProvider: { _ in
                counter.value += 1
                return FinderExtensionDiagnosticSnapshot(
                    embeddedIdentifiers: [], embeddingKnown: true, registration: .unknown,
                    registrationEvidence: "fixture", enabled: false, responded: nil)
            },
            extensionActivityStore: FinderExtensionActivityStore(
                defaults: defaults, failureHistoryFileURL: output.appendingPathComponent("failures.json")),
            authorizedDirectoryStore: grants)
    }
    func acknowledge(_ g: Int) {
        guard g == generation, g > acknowledged else { return }
        NSApp.windows.forEach {
            $0.contentView?.layoutSubtreeIfNeeded()
            $0.displayIfNeeded()
        }
        acknowledged = g
    }
    func run() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        lastTick = DispatchTime.now().uptimeNanoseconds
        timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                self.gaps.append(Double(now - self.lastTick) / 1e6)
                self.lastTick = now
            }
        }
        for i in 0..<36 {
            let destination: AppTab = [.templates, .diagnostics, .create][i % 3]
            gaps.removeAll(keepingCapacity: true)
            started = DispatchTime.now().uptimeNanoseconds
            tab = destination
            generation += 1
            let expected = generation
            while acknowledged < expected && Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 < 5 {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            let duration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            try? await Task.sleep(nanoseconds: 80_000_000)
            rows.append([
                "to": String(describing: destination), "index": i, "layoutAckMS": duration,
                "maxRunLoopGapMS": gaps.max() ?? 0, "ack": acknowledged == expected, "probeCount": probes,
            ])
        }
        timer?.invalidate()
        try? JSONSerialization.data(
            withJSONObject: [
                "pid": getpid(), "templates": model.templates.count, "samples": rows,
                "scope":
                    "binding change through production tab container; AppKit layout/display submitted, not input-to-screen capture",
                "probes": probes,
            ], options: [.prettyPrinted, .sortedKeys]
        ).write(to: output.appendingPathComponent("results.json"), options: .atomic)
        defaults.removePersistentDomain(forName: suite)
        if CommandLine.arguments.contains("--hold") { try? await Task.sleep(nanoseconds: 120_000_000_000) }
        NSApp.terminate(nil)
    }
}
private struct Witness: NSViewRepresentable {
    let driver: Driver
    let generation: Int
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let g = generation
        DispatchQueue.main.async { driver.acknowledge(g) }
    }
}
private struct Root: View {
    @ObservedObject var driver: Driver
    var body: some View {
        AppTabsView(
            viewModel: driver.model, finderIntegrationViewModel: driver.integration,
            diagnosticsViewModel: driver.diagnostics, selectedTab: $driver.tab
        )
        .frame(width: 780, height: 650)
        .overlay(Witness(driver: driver, generation: driver.generation).frame(width: 1, height: 1))
        .task { await driver.run() }
    }
}
@main @MainActor private struct Probe {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let driver = try Driver()
        let window = NSWindow(
            contentRect: NSRect(x: 150, y: 150, width: 780, height: 650), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "QuickFile Tab Switch Fixture"
        window.contentView = NSHostingView(rootView: Root(driver: driver))
        window.makeKeyAndOrderFront(nil)
        withExtendedLifetime(window) { app.run() }
    }
}
