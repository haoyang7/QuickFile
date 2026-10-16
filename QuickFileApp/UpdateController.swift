import QuickFileCore
import Combine
import Foundation
#if !QUICKFILE_COMMUNITY
import Sparkle
#endif

struct UpdateConfiguration {
    init?(info: [String: Any]) {
        guard info["QuickFileDistributionChannel"] as? String == "developer-id",
              let enabled = info["QuickFileUpdatesEnabled"],
              (enabled as? NSNumber)?.boolValue == true || (enabled as? String) == "YES",
              let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
    }
}

enum CommunityUpdateStatus: Equatable {
    case checked(CommunityReleaseCheckResult)
    case failed(CommunityReleaseCheckError)
}

@MainActor
final class UpdateController: NSObject, ObservableObject {
    typealias CommunityCheck = @Sendable (String, String, String?, Bool) async throws -> CommunityReleaseCheckResult

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var receivesBetaUpdates: Bool
    @Published private(set) var isAvailable = false
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var communityCheckStatus: CommunityUpdateStatus?
    let usesGitHubReleases: Bool

    private static let betaPreference = "QuickFileReceivesBetaUpdates"
    private let defaults: UserDefaults
    private let communityVersion: (version: String, build: String, releaseTag: String?)?
    private let checkCommunityRelease: CommunityCheck
    private let presentCommunityResult: (CommunityUpdateStatus) -> Void
    private var communityTask: Task<Void, Never>?
    private var communityGeneration = UUID()
    #if !QUICKFILE_COMMUNITY
    private var updaterController: SPUStandardUpdaterController?
    #endif

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard,
         isTesting: Bool = ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil,
         checkCommunityRelease: @escaping CommunityCheck = { version, build, releaseTag, betas in
             try await CommunityReleaseChecker().check(version: version, build: build, releaseTag: releaseTag,
                                                      includingBetas: betas)
         }, presentCommunityResult: @escaping (CommunityUpdateStatus) -> Void = { _ in }) {
        self.defaults = defaults
        self.checkCommunityRelease = checkCommunityRelease
        self.presentCommunityResult = presentCommunityResult
        usesGitHubReleases = bundle.object(forInfoDictionaryKey: "QuickFileDistributionChannel") as? String == "community"
        if usesGitHubReleases,
           let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !version.isEmpty,
           let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !build.isEmpty {
            communityVersion = (version, build, bundle.object(forInfoDictionaryKey: "QuickFileReleaseTag") as? String)
        } else {
            communityVersion = nil
        }
        receivesBetaUpdates = defaults.bool(forKey: Self.betaPreference)
        super.init()

        guard !isTesting else { return }
        if communityVersion != nil {
            isAvailable = true
            canCheckForUpdates = true
            return
        }
        #if !DEBUG && !QUICKFILE_COMMUNITY
        guard UpdateConfiguration(info: bundle.infoDictionary ?? [:]) != nil else { return }
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

    deinit {
        communityTask?.cancel()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        if let version = communityVersion {
            let check = checkCommunityRelease
            let betas = receivesBetaUpdates
            let generation = UUID()
            communityGeneration = generation
            communityCheckStatus = nil
            isCheckingForUpdates = true
            canCheckForUpdates = false
            communityTask = Task { [weak self] in
                let status: CommunityUpdateStatus?
                do {
                    let result = try await check(version.version, version.build, version.releaseTag, betas)
                    try Task.checkCancellation()
                    status = .checked(result)
                } catch is CancellationError {
                    status = nil
                } catch {
                    status = .failed(error as? CommunityReleaseCheckError ?? .requestFailed)
                }
                guard let self else { return }
                // A cancelled request keeps its slot until the transport has returned.
                self.communityTask = nil
                self.isCheckingForUpdates = false
                self.canCheckForUpdates = true
                guard self.communityGeneration == generation, self.receivesBetaUpdates == betas,
                      let status else { return }
                self.communityCheckStatus = status
                self.presentCommunityResult(status)
            }
            return
        }
        #if !QUICKFILE_COMMUNITY
        updaterController?.checkForUpdates(nil)
        #endif
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        #if !QUICKFILE_COMMUNITY
        updaterController?.updater.automaticallyChecksForUpdates = enabled
        #endif
    }

    func setReceivesBetaUpdates(_ enabled: Bool) {
        guard receivesBetaUpdates != enabled else { return }
        receivesBetaUpdates = enabled
        defaults.set(enabled, forKey: Self.betaPreference)
        if usesGitHubReleases {
            communityGeneration = UUID()
            communityCheckStatus = nil
            communityTask?.cancel()
            return
        }
        #if !QUICKFILE_COMMUNITY
        // Changing channel must not cause a network check when automatic checks are off.
        if automaticallyChecksForUpdates {
            updaterController?.updater.resetUpdateCycleAfterShortDelay()
        }
        #endif
    }
}

#if !QUICKFILE_COMMUNITY
extension UpdateController: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        receivesBetaUpdates ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // Sparkle can resume a delayed channel-change check after automatic checks are turned off.
        if updateCheck == .updatesInBackground && !updater.automaticallyChecksForUpdates {
            throw NSError(domain: "com.haoyoung.QuickFile.Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: QuickFileLocalization.text(.init("自动检查更新已关闭。"))])
        }
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        []
    }
}
#endif
