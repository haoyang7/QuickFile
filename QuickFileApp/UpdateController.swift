import Combine
import Foundation
import Sparkle

struct UpdateConfiguration {
    init?(info: [String: Any]) {
        guard let enabled = info["QuickFileUpdatesEnabled"],
              (enabled as? NSNumber)?.boolValue == true || (enabled as? String) == "YES",
              let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
    }
}

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var receivesBetaUpdates: Bool
    @Published private(set) var isAvailable = false

    private static let betaPreference = "QuickFileReceivesBetaUpdates"
    private let defaults: UserDefaults
    private var updaterController: SPUStandardUpdaterController?

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard, isTesting: Bool = ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil) {
        self.defaults = defaults
        receivesBetaUpdates = defaults.bool(forKey: Self.betaPreference)
        super.init()

        #if !DEBUG
        guard !isTesting, UpdateConfiguration(info: bundle.infoDictionary ?? [:]) != nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        updaterController = controller
        let updater = controller.updater
        // Disable system profiling even if an older user preference enabled it.
        updater.sendsSystemProfile = false
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        controller.startUpdater()
        isAvailable = true
        #endif
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updaterController?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController?.updater.automaticallyChecksForUpdates = enabled
    }

    func setReceivesBetaUpdates(_ enabled: Bool) {
        receivesBetaUpdates = enabled
        defaults.set(enabled, forKey: Self.betaPreference)
        // Changing channel must not cause a network check when automatic checks are off.
        if automaticallyChecksForUpdates {
            updaterController?.updater.resetUpdateCycleAfterShortDelay()
        }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        receivesBetaUpdates ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // Sparkle can resume a delayed channel-change check after automatic checks are turned off.
        if updateCheck == .updatesInBackground && !updater.automaticallyChecksForUpdates {
            throw NSError(domain: "com.haoyoung.QuickFile.Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "自动检查更新已关闭。"])
        }
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        []
    }
}
