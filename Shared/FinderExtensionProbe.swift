import Foundation
import CryptoKit
import QuickFileCore

// No userInfo: distributed notifications from an App Sandbox must not carry a dictionary.
// This probe observes responsiveness only; it is not an authentication or authorization channel.
enum FinderProbeNotification {
    static func identity(for url: URL, version: String, build: String) -> String {
        let value = [url.standardizedFileURL.resolvingSymlinksInPath().path, version, build]
            .joined(separator: "\0")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    static func installedIdentity(for extensionURL: URL) async -> String? {
        // Read the installed file rather than Bundle's cached metadata after a replacement.
        await Task.detached { () -> String? in
            guard let data = try? Data(contentsOf: extensionURL.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty,
                  let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return nil }
            return identity(for: extensionURL, version: version, build: build)
        }.value
    }

    static let request = Notification.Name("com.haoyoung.QuickFile.FinderExtension.diagnosticPing.v3")
    static let response = Notification.Name("com.haoyoung.QuickFile.FinderExtension.diagnosticAck.v3")
}

@MainActor
public final class FinderExtensionProbeResponder: NSObject {
    private let identity: String
    private var firstUseSession: FinderFirstUseVerificationSession

    public override convenience init() {
        self.init(
            extensionURL: Bundle.main.bundleURL,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        )
    }

    // Capture the running bundle's version once; replacing its files must not change this identity.
    init(extensionURL: URL, version: String, build: String) {
        identity = FinderProbeNotification.identity(for: extensionURL, version: version, build: build)
        firstUseSession = FinderFirstUseVerificationSession(installation: identity, minimumStart: FinderFirstUseWire.now)
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(respond(_:)), name: FinderProbeNotification.request,
            object: nil, suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(respondToFirstUse(_:)), name: FinderFirstUseWire.request,
            object: nil, suspensionBehavior: .deliverImmediately
        )
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    /// Capture at direct Finder action admission, before asynchronous creation begins.
    /// This reads memory only. A pre-arm operation cannot qualify a later attempt.
    public func verificationAttempt(in directoryIdentity: DirectoryIdentity) -> UUID? {
        firstUseSession.verificationAttempt(
            directoryDigest: FinderFirstUseVerification.identityDigest(for: directoryIdentity),
            now: FinderFirstUseWire.now
        )
    }

    /// Call synchronously after direct Finder-extension creation succeeds with its admission
    /// nonce and verified destination. Main-app creation and activity snapshots never call here.
    public func reportSuccessfulCreation(in directoryIdentity: DirectoryIdentity, attemptNonce: UUID) {
        firstUseSession.reportSuccessfulCreation(
            directoryDigest: FinderFirstUseVerification.identityDigest(for: directoryIdentity),
            attemptNonce: attemptNonce, now: FinderFirstUseWire.now
        )
    }

    @objc private func respondToFirstUse(_ notification: Notification) {
        guard let token = notification.object as? String,
              let request = FinderFirstUseWire.Request(token: token),
              let status = firstUseSession.handle(request, now: FinderFirstUseWire.now) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            FinderFirstUseWire.response, object: FinderFirstUseWire.responseToken(for: request, status: status),
            userInfo: nil, deliverImmediately: true
        )
    }

    @objc private func respond(_ notification: Notification) {
        guard let token = notification.object as? String, token.utf8.count <= 128 else { return }
        let fields = token.split(separator: ":")
        guard fields.count == 2, fields[0] == identity,
              UUID(uuidString: String(fields[1])) != nil else { return }
        DistributedNotificationCenter.default().postNotificationName(
            FinderProbeNotification.response, object: token, userInfo: nil, deliverImmediately: true
        )
    }
}

@MainActor
public final class FinderExtensionProbe: NSObject {
    private let token: String

    init(identity: String) {
        token = identity + ":" + UUID().uuidString
        super.init()
    }
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    public static func check(extensionURL: URL, timeout: TimeInterval = 1.5) async -> Bool {
        guard let identity = await FinderProbeNotification.installedIdentity(for: extensionURL) else { return false }
        let probe = FinderExtensionProbe(identity: identity)
        return await probe.run(timeout: timeout)
    }

    func run(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(receive(_:)), name: FinderProbeNotification.response,
                object: token, suspensionBehavior: .deliverImmediately
            )
            timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0.01, min(timeout, 5)) * 1_000_000_000))
                } catch { return }
                self?.finish(false)
            }
            DistributedNotificationCenter.default().postNotificationName(
                FinderProbeNotification.request, object: token, userInfo: nil, deliverImmediately: true
            )
        }
    }

    @objc private func receive(_ notification: Notification) {
        guard notification.object as? String == token else { return }
        finish(true)
    }

    private func finish(_ received: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        DistributedNotificationCenter.default().removeObserver(self)
        continuation.resume(returning: received)
    }
}
