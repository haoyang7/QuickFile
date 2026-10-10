import AppKit
import QuickFileCore
import QuickFileInfrastructure

@MainActor
enum ContainingApplicationLauncher {
    enum LaunchError: LocalizedError {
        case applicationUnavailable

        var errorDescription: String? {
            "无法定位当前扩展所属的 QuickFile。请从“应用程序”打开 QuickFile 后继续。"
        }
    }

    /// Resolve only the expected embedded-extension layout. Never ask Launch
    /// Services for the default owner of a custom scheme or a bundle identifier.
    static func applicationURL(for extensionURL: URL) -> URL? {
        guard extensionURL.isFileURL, extensionURL.pathExtension == "appex" else { return nil }
        let plugIns = extensionURL.deletingLastPathComponent()
        let contents = plugIns.deletingLastPathComponent()
        let application = contents.deletingLastPathComponent()
        guard plugIns.lastPathComponent == "PlugIns", contents.lastPathComponent == "Contents",
              application.pathExtension == "app" else { return nil }
        return application
    }

    static func openConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Even an explicit application URL otherwise permits substitution by a
        // running copy from a different installation (Launch Services defaults true).
        configuration.allowsRunningApplicationSubstitution = false
        return configuration
    }

    static func open(
        _ route: QuickFileAppRoute,
        extensionURL: URL = Bundle.main.bundleURL,
        completion: @escaping @MainActor @Sendable (Error?) -> Void
    ) {
        guard let application = applicationURL(for: extensionURL),
              Bundle(url: application)?.bundleIdentifier == QuickFileConfiguration.appBundleIdentifier else {
            completion(LaunchError.applicationUnavailable)
            return
        }
        NSWorkspace.shared.open(
            [route.url],
            withApplicationAt: application,
            configuration: openConfiguration(),
            completionHandler: { _, error in
                Task { @MainActor in completion(error) }
            }
        )
    }
}
