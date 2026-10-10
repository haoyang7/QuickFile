import Foundation
import CryptoKit
import QuickFileCore

/// A bounded, extension-reported UX receipt. This is not authentication, authorization,
/// a filesystem check, or evidence that Finder displayed or selected the created file.
public enum FinderFirstUseVerificationStatus: String, Equatable, Sendable {
    case awaitingCreation
    case creationReported
    case expiredOrMissing
    case unavailable
}

// Only fixed-format digests and random identifiers cross the notification channel.
// No raw path, directory identity, template name, bookmark, or filename is transmitted.
enum FinderFirstUseWire {
    static let request = Notification.Name("com.haoyoung.QuickFile.FinderExtension.firstUseRequest.v1")
    static let response = Notification.Name("com.haoyoung.QuickFile.FinderExtension.firstUseResponse.v1")
    static let maximumBytes = 512
    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    enum Command: String { case arm, status, cancel }

    struct Request: Equatable {
        let command: Command
        let installation: String
        let nonce: UUID
        let directoryDigest: String
        let startedAt: UInt64
        let requestID: UUID

        var token: String {
            ["1", command.rawValue, installation, nonce.uuidString, directoryDigest, String(startedAt), requestID.uuidString]
                .joined(separator: ":")
        }

        init(command: Command, installation: String, nonce: UUID, directoryDigest: String,
             startedAt: UInt64 = FinderFirstUseWire.now, requestID: UUID = UUID()) {
            self.command = command
            self.installation = installation
            self.nonce = nonce
            self.directoryDigest = directoryDigest
            self.startedAt = startedAt
            self.requestID = requestID
        }

        init?(token: String) {
            guard token.utf8.count <= maximumBytes else { return nil }
            let fields = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, fields[0] == "1", let command = Command(rawValue: fields[1]),
                  FinderFirstUseWire.isDigest(fields[2]), let nonce = UUID(uuidString: fields[3]), nonce.uuidString == fields[3],
                  FinderFirstUseWire.isDigest(fields[4]), let startedAt = UInt64(fields[5]), String(startedAt) == fields[5],
                  let requestID = UUID(uuidString: fields[6]), requestID.uuidString == fields[6]
            else { return nil }
            self.init(command: command, installation: fields[2], nonce: nonce,
                      directoryDigest: fields[4], startedAt: startedAt, requestID: requestID)
        }
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func responseToken(for request: Request, status: FinderFirstUseVerificationStatus) -> String {
        request.token + ":" + status.rawValue
    }

    static func status(from token: String, matching request: Request) -> FinderFirstUseVerificationStatus? {
        guard token.utf8.count <= maximumBytes else { return nil }
        let fields = token.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 8, let status = FinderFirstUseVerificationStatus(rawValue: String(fields[7])),
              token == responseToken(for: request, status: status) else { return nil }
        return status
    }
}

/// One memory-only session. Expiry is monotonic and lazy; no file, timer, or task is retained.
/// The latest start tick is a constant-space replay fence after expiry/cancel. All processes
/// use the same host uptime clock. This ordering is UX correlation, not sender authentication.
struct FinderFirstUseVerificationSession {
    static let maximumLifetime: TimeInterval = 10 * 60
    static let maximumLifetimeNanoseconds: UInt64 = 600_000_000_000
    let installation: String
    private let lifetimeNanoseconds: UInt64
    private let minimumStart: UInt64
    private struct Attempt {
        let nonce: UUID
        let directoryDigest: String
        let startedAt: UInt64
        var status: FinderFirstUseVerificationStatus
    }
    private var attempt: Attempt?
    private var latestStart: UInt64?

    init(installation: String, lifetime: TimeInterval = maximumLifetime, minimumStart: UInt64 = 0) {
        self.installation = installation
        self.minimumStart = minimumStart
        let boundedLifetime = lifetime.isFinite ? max(0, min(lifetime, Self.maximumLifetime)) : Self.maximumLifetime
        lifetimeNanoseconds = UInt64(boundedLifetime * 1_000_000_000)
    }

    mutating func handle(_ request: FinderFirstUseWire.Request, now: UInt64) -> FinderFirstUseVerificationStatus? {
        guard request.installation == installation else { return nil }
        expire(now: now)
        // Reject a malformed/future timestamp rather than poisoning the ordering fence.
        guard request.startedAt >= minimumStart, request.startedAt <= now else { return .expiredOrMissing }
        switch request.command {
        case .arm:
            if matches(request) { return attempt?.status ?? .expiredOrMissing }
            guard latestStart.map({ request.startedAt > $0 }) ?? true else { return .expiredOrMissing }
            latestStart = request.startedAt
            attempt = nil
            guard now - request.startedAt < lifetimeNanoseconds else { return .expiredOrMissing }
            attempt = Attempt(nonce: request.nonce, directoryDigest: request.directoryDigest,
                              startedAt: request.startedAt, status: .awaitingCreation)
            return .awaitingCreation
        case .status:
            guard matches(request) else { return .expiredOrMissing }
            return attempt?.status ?? .expiredOrMissing
        case .cancel:
            if matches(request) { attempt = nil }
            // Cancellation can arrive before its arm. Fence that nonce's start even then,
            // but an old cancel must never discard a more recently started attempt.
            if latestStart.map({ request.startedAt > $0 }) ?? true {
                latestStart = request.startedAt
                attempt = nil
            }
            return .expiredOrMissing
        }
    }

    mutating func verificationAttempt(directoryDigest: String, now: UInt64) -> UUID? {
        expire(now: now)
        guard attempt?.status == .awaitingCreation,
              attempt?.directoryDigest == directoryDigest else { return nil }
        return attempt?.nonce
    }

    mutating func reportSuccessfulCreation(directoryDigest: String, attemptNonce: UUID, now: UInt64) {
        expire(now: now)
        guard attempt?.status == .awaitingCreation, attempt?.nonce == attemptNonce,
              attempt?.directoryDigest == directoryDigest else { return }
        attempt?.status = .creationReported
    }

    private func matches(_ request: FinderFirstUseWire.Request) -> Bool {
        attempt?.nonce == request.nonce && attempt?.directoryDigest == request.directoryDigest
            && attempt?.startedAt == request.startedAt
    }

    private mutating func expire(now: UInt64) {
        guard let attempt else { return }
        if now < attempt.startedAt || now - attempt.startedAt >= lifetimeNanoseconds {
            self.attempt = nil
        }
    }
}

@MainActor
public final class FinderFirstUseVerification {
    private struct Attempt {
        let installation: String
        let nonce: UUID
        let directoryDigest: String
        let startedAt: UInt64
    }

    private let extensionURL: URL
    private var generation = UUID()
    private var latestStart: UInt64 = 0
    private var attempt: Attempt?
    private var pendingRequest: FinderFirstUseNotificationRequest?
    // Synchronous plist I/O cannot be forcibly cancelled. Keep admission held until it
    // actually returns, even if cancel invalidates its result in the meantime.
    private var operationInFlight = false

    public init(extensionURL: URL) { self.extensionURL = extensionURL }

    deinit {
        guard let request = pendingRequest else { return }
        Task { @MainActor in request.cancel() }
    }

    /// Deterministic hashing only. Capture DirectoryIdentity off the main actor beforehand.
    public nonisolated static func identityDigest(for identity: DirectoryIdentity) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // DirectoryIdentity contains only fixed-width integers; encoding cannot fail.
        guard let data = try? encoder.encode(identity) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the arm acknowledgement before the caller opens the folder in Finder.
    /// Starting again invalidates all results from the previous local attempt immediately.
    public func begin(in identity: DirectoryIdentity, timeout: TimeInterval = 1.5) async -> FinderFirstUseVerificationStatus {
        guard !operationInFlight else { return .unavailable }
        operationInFlight = true
        defer { operationInFlight = false }
        cancel()
        let expectedGeneration = generation
        let directoryDigest = Self.identityDigest(for: identity)
        guard FinderFirstUseWire.isDigest(directoryDigest),
              let installation = await FinderProbeNotification.installedIdentity(for: extensionURL),
              expectedGeneration == generation, !Task.isCancelled else { return .unavailable }
        latestStart = max(FinderFirstUseWire.now, latestStart + 1)
        let newAttempt = Attempt(installation: installation, nonce: UUID(), directoryDigest: directoryDigest,
                                 startedAt: latestStart)
        attempt = newAttempt
        let status = await send(.arm, for: newAttempt, timeout: timeout)
        guard expectedGeneration == generation else { return .expiredOrMissing }
        guard !Task.isCancelled else { cancel(); return .expiredOrMissing }
        if status != .awaitingCreation && status != .creationReported { cancel() }
        return status
    }

    /// One explicit bounded check; no polling or automatic retry. Replacement builds fail closed.
    public func check(timeout: TimeInterval = 1.5) async -> FinderFirstUseVerificationStatus {
        guard let attempt else { return .expiredOrMissing }
        guard !operationInFlight else { return .unavailable }
        operationInFlight = true
        defer { operationInFlight = false }
        let expectedGeneration = generation
        let now = FinderFirstUseWire.now
        guard now >= attempt.startedAt,
              now - attempt.startedAt < FinderFirstUseVerificationSession.maximumLifetimeNanoseconds else {
            cancel()
            return .expiredOrMissing
        }
        let installedIdentity = await FinderProbeNotification.installedIdentity(for: extensionURL)
        guard expectedGeneration == generation else { return .expiredOrMissing }
        guard !Task.isCancelled else { cancel(); return .expiredOrMissing }
        guard let installation = installedIdentity else { return .unavailable }
        guard installation == attempt.installation else {
            cancel()
            return .expiredOrMissing
        }
        let status = await send(.status, for: attempt, timeout: timeout)
        guard expectedGeneration == generation else { return .expiredOrMissing }
        guard !Task.isCancelled else { cancel(); return .expiredOrMissing }
        if status == .expiredOrMissing { cancel() }
        return status
    }

    /// Local cancellation is immediate. Remote cancellation is one best-effort notification;
    /// it adds no task, observer, or timer, and lazy expiry handles a lost notification.
    public func cancel() {
        let cancelledAttempt = attempt
        generation = UUID()
        attempt = nil
        pendingRequest?.cancel()
        pendingRequest = nil
        guard let cancelledAttempt else { return }
        let request = Self.request(.cancel, for: cancelledAttempt)
        DistributedNotificationCenter.default().postNotificationName(
            FinderFirstUseWire.request, object: request.token, userInfo: nil, deliverImmediately: true
        )
    }

    private static func request(_ command: FinderFirstUseWire.Command, for attempt: Attempt) -> FinderFirstUseWire.Request {
        FinderFirstUseWire.Request(command: command, installation: attempt.installation,
                                  nonce: attempt.nonce, directoryDigest: attempt.directoryDigest, startedAt: attempt.startedAt)
    }

    private func send(_ command: FinderFirstUseWire.Command, for attempt: Attempt,
                      timeout: TimeInterval) async -> FinderFirstUseVerificationStatus {
        pendingRequest?.cancel()
        let request = FinderFirstUseNotificationRequest(request: Self.request(command, for: attempt))
        pendingRequest = request
        let status = await request.run(timeout: timeout)
        if pendingRequest === request { pendingRequest = nil }
        return status
    }
}

/// One request owns its transport and maximum-five-second deadline. Arm can finish on
/// any valid acknowledgement without binding to that responder. Status replies aggregate
/// until the deadline or a creation receipt, so a waiting/restarted instance cannot hide it.
@MainActor
final class FinderFirstUseNotificationRequest {
    typealias ScheduleDeadline = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (() -> Void)

    private let request: FinderFirstUseWire.Request
    private let transport: any FinderFirstUseNotificationTransport
    private let scheduleDeadline: ScheduleDeadline
    private var continuation: CheckedContinuation<FinderFirstUseVerificationStatus, Never>?
    private var cancelDeadline: (() -> Void)?
    private var bestReply: FinderFirstUseVerificationStatus = .unavailable
    private var finished = false

    init(request: FinderFirstUseWire.Request,
         transport: (any FinderFirstUseNotificationTransport)? = nil,
         scheduleDeadline: ScheduleDeadline? = nil) {
        self.request = request
        self.transport = transport ?? FinderFirstUseDistributedNotificationTransport()
        self.scheduleDeadline = scheduleDeadline ?? Self.scheduleLiveDeadline
    }

    func run(timeout: TimeInterval) async -> FinderFirstUseVerificationStatus {
        guard !finished, !Task.isCancelled else { return .unavailable }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                let seconds = timeout.isFinite ? max(0.01, min(timeout, 5)) : 1.5
                cancelDeadline = scheduleDeadline(seconds) { [weak self] in
                    guard let self else { return }
                    self.finish(self.bestReply)
                }
                transport.start(request: request) { [weak self] token in self?.receive(token) }
                if Task.isCancelled { finish(.unavailable) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
    }

    func cancel() { finish(.unavailable) }

    private func receive(_ token: String) {
        guard !finished, let status = FinderFirstUseWire.status(from: token, matching: request) else { return }
        switch status {
        case .creationReported:
            finish(.creationReported)
        case .awaitingCreation:
            if request.command == .arm { finish(.awaitingCreation) }
            else { bestReply = .awaitingCreation }
        case .expiredOrMissing:
            if bestReply != .awaitingCreation { bestReply = .expiredOrMissing }
        case .unavailable:
            break
        }
    }

    private func finish(_ status: FinderFirstUseVerificationStatus) {
        guard !finished else { return }
        finished = true
        cancelDeadline?()
        cancelDeadline = nil
        transport.stop()
        let completion = continuation
        continuation = nil
        completion?.resume(returning: status)
    }

    private static func scheduleLiveDeadline(seconds: TimeInterval, fire: @escaping @MainActor () -> Void) -> (() -> Void) {
        let task = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            fire()
        }
        return { task.cancel() }
    }
}

/// Request transport and deadline are injected together in deterministic ordering tests.
/// Production still uses one sandbox-compatible distributed notification subscription.
@MainActor
protocol FinderFirstUseNotificationTransport: AnyObject {
    func start(request: FinderFirstUseWire.Request, receive: @escaping @MainActor (String) -> Void)
    func stop()
}

@MainActor
private final class FinderFirstUseDistributedNotificationTransport: NSObject, FinderFirstUseNotificationTransport {
    private var receiveToken: (@MainActor (String) -> Void)?

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    func start(request: FinderFirstUseWire.Request, receive: @escaping @MainActor (String) -> Void) {
        receiveToken = receive
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(self.receive(_:)), name: FinderFirstUseWire.response,
            object: nil, suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().postNotificationName(
            FinderFirstUseWire.request, object: request.token, userInfo: nil, deliverImmediately: true
        )
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        receiveToken = nil
    }

    @objc private func receive(_ notification: Notification) {
        guard let token = notification.object as? String else { return }
        receiveToken?(token)
    }
}
