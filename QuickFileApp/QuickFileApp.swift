import QuickFileCore
import SwiftUI

@main
struct QuickFileApp: App {
    @StateObject private var updates = UpdateController()
    @StateObject private var finderMenuSettings = FinderMenuSettingsViewModel()
    @StateObject private var finderIntegration = FinderIntegrationViewModel()
    @StateObject private var viewModel = QuickFileViewModel(
        templates: ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil ? nil : [],
        clipboardProvider: AppKitFileActions.clipboardString,
        revealCreatedFile: AppKitFileActions.reveal
    )

    init() {
        let enabled = QuickFileInstallAXCompatibility()
        NSLog("QuickFile AX compatibility enabled=%@ status=%s", enabled ? "YES" : "NO", QuickFileAXCompatibilityStatus())
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil {
                ContentView(viewModel: viewModel, finderMenuSettings: finderMenuSettings,
                            finderIntegrationViewModel: finderIntegration)
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
                Button("检查更新…", action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates)
            }
        }

        Settings {
            UpdateSettingsView(updates: updates)
        }
    }
}
