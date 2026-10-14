import QuickFileCore
import SwiftUI

@main
struct QuickFileApp: App {
    @StateObject private var updates = UpdateController()
    @StateObject private var creationSettings = CreationSettingsViewModel()
    @StateObject private var languageSettings = LanguageSettingsViewModel()
    @StateObject private var finderMenuSettings = FinderMenuSettingsViewModel()
    @StateObject private var finderIntegration = FinderIntegrationViewModel()
    @StateObject private var viewModel = QuickFileViewModel(
        templates: ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil ? nil : [],
        clipboardProvider: AppKitFileActions.clipboardString,
        revealCreatedFile: AppKitFileActions.reveal,
        automaticallyOpenCreatedFile: AppKitFileActions.automaticallyOpenCreatedFile
    )

    init() {
        let enabled = QuickFileInstallAXCompatibility()
        NSLog("QuickFile AX compatibility enabled=%@ status=%s", enabled ? "YES" : "NO", QuickFileAXCompatibilityStatus())
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil {
                // Keep the receiving view mounted while loading preferences so
                // cold-launch Finder URLs and an existing editor keep their owner.
                ContentView(viewModel: viewModel, finderMenuSettings: finderMenuSettings,
                            finderIntegrationViewModel: finderIntegration)
                    .environment(\.locale, languageSettings.locale)
                    .task {
                        if !languageSettings.hasLoaded { await languageSettings.reload() }
                        viewModel.startTemplateSynchronization()
                    }
            } else {
                EmptyView()
            }
        }
        // Prefer an existing receiving window, but permit a new one when the
        // app is cold or every window has been closed. URL validation stays in Core.
        .handlesExternalEvents(matching: QuickFileAppRoute.externalEventIdentifiers)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(QuickFileLocalization.text(.init("检查更新…")), action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates)
            }
        }

        Settings {
            TabView {
                VStack(alignment: .leading, spacing: 0) {
                    LanguageSettingsView(model: languageSettings).padding([.top, .horizontal], 24)
                    Divider().padding(.top, 20)
                    CreationSettingsView(model: creationSettings)
                }
                    .tabItem { Label("通用", systemImage: "gearshape") }
                UpdateSettingsView(updates: updates)
                    .tabItem { Label("更新", systemImage: "arrow.triangle.2.circlepath") }
            }
            .frame(width: 488, height: 490)
            .environment(\.locale, languageSettings.locale)
            .task { if !languageSettings.hasLoaded { await languageSettings.reload() } }
        }
    }
}
