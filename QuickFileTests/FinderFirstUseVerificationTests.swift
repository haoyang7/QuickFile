import XCTest
import CryptoKit
import QuickFileCore
@testable import QuickFileInfrastructure

final class FinderFirstUseVerificationSessionTests: XCTestCase {
    private let installation = String(repeating: "a", count: 64)
    private let target = String(repeating: "b", count: 64)
    private let other = String(repeating: "c", count: 64)
    private let start: UInt64 = 1_000_000_000
    private let nonce = UUID()

    private func request(_ command: FinderFirstUseWire.Command = .arm, target: String? = nil,
                         nonce: UUID? = nil, start: UInt64? = nil,
                         installation: String? = nil) -> FinderFirstUseWire.Request {
        FinderFirstUseWire.Request(command: command, installation: installation ?? self.installation,
                                   nonce: nonce ?? self.nonce, directoryDigest: target ?? self.target,
                                   startedAt: start ?? self.start)
    }

    func testArmAcknowledgesThenOnlyMatchingCreationReports() {
        var session = FinderFirstUseVerificationSession(installation: installation)
        XCTAssertEqual(session.handle(request(), now: start), .awaitingCreation)
        session.reportSuccessfulCreation(directoryDigest: other, attemptNonce: nonce, now: start + 1)
        XCTAssertEqual(session.handle(request(.status), now: start + 2), .awaitingCreation)
        session.reportSuccessfulCreation(directoryDigest: target, attemptNonce: nonce, now: start + 3)
        XCTAssertEqual(session.handle(request(.status), now: start + 4), .creationReported)
    }

    func testCreationBeforeArmCannotSatisfyAttempt() {
        var session = FinderFirstUseVerificationSession(installation: installation)
        session.reportSuccessfulCreation(directoryDigest: target, attemptNonce: nonce, now: start - 1)
        XCTAssertEqual(session.handle(request(), now: start), .awaitingCreation)
        XCTAssertEqual(session.handle(request(.status), now: start + 1), .awaitingCreation)
    }

    func testAdmissionNoncePreventsPreArmAndPriorAttemptCompletions() {
        var session = FinderFirstUseVerificationSession(installation: installation)
        XCTAssertNil(session.verificationAttempt(directoryDigest: target, now: start - 1))
        _ = session.handle(request(), now: start)
        XCTAssertNil(session.verificationAttempt(directoryDigest: other, now: start + 1))
        XCTAssertEqual(session.verificationAttempt(directoryDigest: target, now: start + 1), nonce)
        let nextNonce = UUID()
        _ = session.handle(request(nonce: nextNonce, start: start + 2), now: start + 2)
        session.reportSuccessfulCreation(directoryDigest: target, attemptNonce: nonce, now: start + 3)
        XCTAssertEqual(session.handle(request(.status, nonce: nextNonce, start: start + 2), now: start + 4), .awaitingCreation)
        session.reportSuccessfulCreation(directoryDigest: target, attemptNonce: nextNonce, now: start + 5)
        XCTAssertEqual(session.handle(request(.status, nonce: nextNonce, start: start + 2), now: start + 6), .creationReported)
    }

    func testWrongCopyBuildVersionOrNonceCannotSatisfyAttempt() {
        let url = URL(fileURLWithPath: "/Applications/QuickFile.app/Contents/PlugIns/FinderExtension.appex")
        let running = FinderProbeNotification.identity(for: url, version: "0.1.0", build: "21")
        var session = FinderFirstUseVerificationSession(installation: running)
        let wrongIdentities = [
            FinderProbeNotification.identity(for: url, version: "0.1.0", build: "20"),
            FinderProbeNotification.identity(for: url, version: "0.2.0", build: "21"),
            FinderProbeNotification.identity(for: url.appendingPathComponent("AnotherCopy.appex"), version: "0.1.0", build: "21")
        ]
        for identity in wrongIdentities {
            XCTAssertNil(session.handle(request(installation: identity), now: start))
        }
        XCTAssertEqual(session.handle(request(installation: running), now: start), .awaitingCreation)
        session.reportSuccessfulCreation(directoryDigest: target, attemptNonce: nonce, now: start + 1)
        XCTAssertEqual(session.handle(request(.status, nonce: UUID(), installation: running), now: start + 2), .expiredOrMissing)
        XCTAssertEqual(session.handle(request(.status, target: other, installation: running), now: start + 2), .expiredOrMissing)
        XCTAssertEqual(session.handle(request(.status, installation: running), now: start + 2), .creationReported)
    }

    func testDuplicateArmDoesNotResetReceiptOrExtendLifetime() {
        var session = FinderFirstUseVerificationSession(installation: installation, lifetime: 2)
        XCTAssertEqual(session.handle(request(), now: start), .awaitingCreation)
        session.reportSuccessfulCreation(directoryDigest: target, attemptNonce: nonce, now: start + 1)
        XCTAssertEqual(session.handle(request(), now: start + 1_999_999_999), .creationReported)
        XCTAssertEqual(session.handle(request(), now: start + 2_000_000_000), .expiredOrMissing)
        XCTAssertEqual(session.handle(request(.status), now: start + 2_000_000_001), .expiredOrMissing)
    }

    func testNewAttemptDiscardsOldReceiptAndLateOldArm() {
        var session = FinderFirstUseVerificationSession(installation: installation)
        _ = session.handle(request(), now: start)
        session.reportSuccessfulCreation(directoryDigest: target, attemptNonce: nonce, now: start + 1)
        let nextNonce = UUID()
        XCTAssertEqual(session.handle(request(nonce: nextNonce, start: start + 2), now: start + 2), .awaitingCreation)
        XCTAssertEqual(session.handle(request(), now: start + 3), .expiredOrMissing)
        XCTAssertEqual(session.handle(request(.status), now: start + 3), .expiredOrMissing)
        XCTAssertEqual(session.handle(request(.status, nonce: nextNonce, start: start + 2), now: start + 3), .awaitingCreation)
    }

    func testCancelledAttemptCannotReviveOnLateArmOrCreation() {
        var session = FinderFirstUseVerificationSession(installation: installation)
        _ = session.handle(request(), now: start)
        XCTAssertEqual(session.handle(request(.cancel), now: start + 1), .expiredOrMissing)
        session.reportSuccessfulCreation(directoryDigest: target, attemptNonce: nonce, now: start + 2)
        XCTAssertEqual(session.handle(request(), now: start + 3), .expiredOrMissing)
        XCTAssertEqual(session.handle(request(.status), now: start + 4), .expiredOrMissing)
        XCTAssertNil(session.verificationAttempt(directoryDigest: target, now: start + 4))
    }

    func testCancelBeforeArmFencesOutOfOrderDelivery() {
        var session = FinderFirstUseVerificationSession(installation: installation)
        _ = session.handle(request(.cancel), now: start)
        XCTAssertEqual(session.handle(request(), now: start + 1), .expiredOrMissing)
    }

    func testOldOrMismatchedCancelDoesNotDiscardNewAttempt() {
        var session = FinderFirstUseVerificationSession(installation: installation)
        let nextNonce = UUID()
        _ = session.handle(request(nonce: nextNonce, start: start + 2), now: start + 2)
        _ = session.handle(request(.cancel), now: start + 3)
        _ = session.handle(request(.cancel, target: other, nonce: nextNonce, start: start + 2), now: start + 4)
        _ = session.handle(request(.cancel, nonce: UUID(), start: start + 2), now: start + 4)
        XCTAssertEqual(session.handle(request(.status, nonce: nextNonce, start: start + 2), now: start + 5), .awaitingCreation)
    }

    func testExpiryBoundIsAtMostTenMinutesAndBackwardClockFailsClosed() {
        var session = FinderFirstUseVerificationSession(installation: installation, lifetime: 1_000_000)
        _ = session.handle(request(), now: start)
        session.reportSuccessfulCreation(directoryDigest: target, attemptNonce: nonce, now: start + 600_000_000_000)
        XCTAssertEqual(session.handle(request(.status), now: start + 600_000_000_000), .expiredOrMissing)
        var backwards = FinderFirstUseVerificationSession(installation: installation)
        _ = backwards.handle(request(), now: start)
        backwards.reportSuccessfulCreation(directoryDigest: target, attemptNonce: nonce, now: start - 1)
        XCTAssertEqual(backwards.handle(request(.status), now: start + 1), .expiredOrMissing)
    }

    func testExpiredDelayedArmCannotStartAndFutureArmDoesNotPoisonFence() {
        var session = FinderFirstUseVerificationSession(installation: installation)
        XCTAssertEqual(session.handle(request(start: start + 10), now: start), .expiredOrMissing)
        XCTAssertEqual(session.handle(request(), now: start), .awaitingCreation)
        var delayed = FinderFirstUseVerificationSession(installation: installation)
        XCTAssertEqual(delayed.handle(request(), now: start + 600_000_000_000), .expiredOrMissing)
    }

    func testRestartRejectsOldAttemptAndQueuedArm() {
        var restarted = FinderFirstUseVerificationSession(installation: installation, minimumStart: start + 10)
        XCTAssertEqual(restarted.handle(request(.status), now: start + 20), .expiredOrMissing)
        XCTAssertEqual(restarted.handle(request(), now: start + 20), .expiredOrMissing)
        XCTAssertEqual(restarted.handle(request(nonce: UUID(), start: start + 30), now: start + 30), .awaitingCreation)
    }

    func testWireRoundTripAndResponsesMatchEveryField() {
        let original = request()
        XCTAssertEqual(FinderFirstUseWire.Request(token: original.token), original)
        let response = FinderFirstUseWire.responseToken(for: original, status: .creationReported)
        XCTAssertEqual(FinderFirstUseWire.status(from: response, matching: original), .creationReported)
        // Even a new check for the same attempt gets a new request identifier.
        XCTAssertNil(FinderFirstUseWire.status(from: response, matching: request()))
        XCTAssertNil(FinderFirstUseWire.status(from: response, matching: request(nonce: UUID())))
        XCTAssertNil(FinderFirstUseWire.status(from: response, matching: request(target: other)))
        XCTAssertNil(FinderFirstUseWire.status(from: response, matching: request(installation: other)))
        XCTAssertNil(FinderFirstUseWire.status(from: response + ":extra", matching: original))
        XCTAssertNil(FinderFirstUseWire.status(from: original.token + ":selected", matching: original))
        XCTAssertNil(FinderFirstUseWire.status(from: String(repeating: "a", count: 513), matching: original))
    }

    func testWireRejectsMalformedOversizedAndUnknownFields() {
        let original = request().token
        let invalid = [
            original + ":extra", ":" + original, original + ":", "", String(repeating: "a", count: 513),
            original.replacingOccurrences(of: "1:arm:", with: "2:arm:"),
            original.replacingOccurrences(of: "1:arm:", with: "1:complete:"),
            original.replacingOccurrences(of: installation, with: String(repeating: "A", count: 64)),
            original.replacingOccurrences(of: target, with: "/Users/private-name/Documents"),
            original.replacingOccurrences(of: ":1000000000:", with: ":01000000000:"),
            original.replacingOccurrences(of: ":1000000000:", with: ":-1:"),
            original.replacingOccurrences(of: ":1000000000:", with: ":18446744073709551616:"),
            original.replacingOccurrences(of: nonce.uuidString, with: "not-a-uuid")
        ]
        for token in invalid { XCTAssertNil(FinderFirstUseWire.Request(token: token), token) }
    }

    func testIdentityDigestIsStablePrivateAndDistinguishesDirectories() throws {
        let identity = try Self.identity(inode: 7)
        let reversedJSON = Data("{\"inode\":7,\"generation\":3,\"device\":1,\"birthSeconds\":4,\"birthNanoseconds\":5}".utf8)
        let sameIdentity = try JSONDecoder().decode(DirectoryIdentity.self, from: reversedJSON)
        let digest = FinderFirstUseVerification.identityDigest(for: identity)
        let expectedData = Data("{\"birthNanoseconds\":5,\"birthSeconds\":4,\"device\":1,\"generation\":3,\"inode\":7}".utf8)
        let expected = SHA256.hash(data: expectedData).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, expected)
        XCTAssertEqual(digest, FinderFirstUseVerification.identityDigest(for: sameIdentity))
        XCTAssertNotEqual(digest, FinderFirstUseVerification.identityDigest(for: try Self.identity(inode: 8)))
        XCTAssertTrue(FinderFirstUseWire.isDigest(digest))
        let token = request(target: digest).token
        XCTAssertFalse(token.contains("inode"))
        XCTAssertFalse(token.contains("device"))
        XCTAssertFalse(token.contains("/"))
    }

    static func identity(inode: UInt64) throws -> DirectoryIdentity {
        let data = Data("{\"device\":1,\"inode\":\(inode),\"generation\":3,\"birthSeconds\":4,\"birthNanoseconds\":5}".utf8)
        return try JSONDecoder().decode(DirectoryIdentity.self, from: data)
    }
}

@MainActor
final class FinderFirstUseVerificationTransportTests: XCTestCase {
    private func installation(build: String = "21") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".appex")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try install(build: build, at: url)
        return url
    }

    private func install(build: String, at url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": build], format: .xml, options: 0
        )
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"), options: .atomic)
    }

    func testAcknowledgedAttemptReportsOnlyMatchingDirectHook() async throws {
        let url = try installation()
        defer { try? FileManager.default.removeItem(at: url) }
        let responder = FinderExtensionProbeResponder(extensionURL: url, version: "0.1.0", build: "21")
        let client = FinderFirstUseVerification(extensionURL: url)
        let target = try FinderFirstUseVerificationSessionTests.identity(inode: 7)
        XCTAssertNil(responder.verificationAttempt(in: target))
        let begin = await client.begin(in: target)
        XCTAssertEqual(begin, .awaitingCreation)
        let attempt = try XCTUnwrap(responder.verificationAttempt(in: target))
        responder.reportSuccessfulCreation(in: try FinderFirstUseVerificationSessionTests.identity(inode: 8), attemptNonce: attempt)
        let stillWaiting = await client.check()
        XCTAssertEqual(stillWaiting, .awaitingCreation)
        responder.reportSuccessfulCreation(in: target, attemptNonce: try XCTUnwrap(responder.verificationAttempt(in: target)))
        let reported = await client.check()
        XCTAssertEqual(reported, .creationReported)
        client.cancel()
        let cancelled = await client.check()
        XCTAssertEqual(cancelled, .expiredOrMissing)
        withExtendedLifetime(responder) {}
    }

    func testCurrentInstalledBuildReplacementInvalidatesReceipt() async throws {
        let url = try installation()
        defer { try? FileManager.default.removeItem(at: url) }
        let responder = FinderExtensionProbeResponder(extensionURL: url, version: "0.1.0", build: "21")
        let client = FinderFirstUseVerification(extensionURL: url)
        let target = try FinderFirstUseVerificationSessionTests.identity(inode: 7)
        let begin = await client.begin(in: target)
        XCTAssertEqual(begin, .awaitingCreation)
        responder.reportSuccessfulCreation(in: target, attemptNonce: try XCTUnwrap(responder.verificationAttempt(in: target)))
        try install(build: "22", at: url)
        let replaced = await client.check()
        XCTAssertEqual(replaced, .expiredOrMissing)
        let stale = await client.begin(in: target, timeout: 0.05)
        XCTAssertEqual(stale, .unavailable)
        withExtendedLifetime(responder) {}
    }

    func testMissingResponderTimesOutAndDoesNotLeaveAnAttempt() async throws {
        let url = try installation()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = FinderFirstUseVerification(extensionURL: url)
        let begin = await client.begin(in: try FinderFirstUseVerificationSessionTests.identity(inode: 7), timeout: 0.02)
        XCTAssertEqual(begin, .unavailable)
        let check = await client.check()
        XCTAssertEqual(check, .expiredOrMissing)
    }

    func testCancellationWhileWaitingDiscardsLocalAttempt() async throws {
        let url = try installation()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = FinderFirstUseVerification(extensionURL: url)
        let target = try FinderFirstUseVerificationSessionTests.identity(inode: 7)
        let operation = Task { @MainActor in await client.begin(in: target, timeout: 5) }
        try await Task.sleep(nanoseconds: 20_000_000)
        client.cancel()
        let status = await operation.value
        XCTAssertTrue(status == .expiredOrMissing || status == .unavailable)
        let check = await client.check()
        XCTAssertEqual(check, .expiredOrMissing)
    }

    func testTaskCancellationDuringArmDiscardsLocalAttempt() async throws {
        let url = try installation()
        defer { try? FileManager.default.removeItem(at: url) }
        let armSent = expectation(description: "Arm reached transport")
        let peer = SelectiveVerificationResponder(extensionURL: url, acknowledgeArm: false) { command in
            if command == .arm { armSent.fulfill() }
        }
        let client = FinderFirstUseVerification(extensionURL: url)
        let target = try FinderFirstUseVerificationSessionTests.identity(inode: 7)
        let operation = Task { @MainActor in await client.begin(in: target, timeout: 5) }
        await fulfillment(of: [armSent], timeout: 2)
        operation.cancel()
        let status = await operation.value
        XCTAssertEqual(status, .expiredOrMissing)
        let check = await client.check()
        XCTAssertEqual(check, .expiredOrMissing)
        withExtendedLifetime(peer) {}
    }

    func testTaskCancellationDuringCheckDiscardsAcknowledgedAttempt() async throws {
        let url = try installation()
        defer { try? FileManager.default.removeItem(at: url) }
        let statusSent = expectation(description: "Status reached transport")
        let peer = SelectiveVerificationResponder(extensionURL: url, acknowledgeArm: true) { command in
            if command == .status { statusSent.fulfill() }
        }
        let client = FinderFirstUseVerification(extensionURL: url)
        let target = try FinderFirstUseVerificationSessionTests.identity(inode: 7)
        let begin = await client.begin(in: target)
        XCTAssertEqual(begin, .awaitingCreation)
        let operation = Task { @MainActor in await client.check(timeout: 5) }
        await fulfillment(of: [statusSent], timeout: 2)
        operation.cancel()
        let status = await operation.value
        XCTAssertEqual(status, .expiredOrMissing)
        let check = await client.check()
        XCTAssertEqual(check, .expiredOrMissing)
        withExtendedLifetime(peer) {}
    }

    func testCancelledCheckAlsoDiscardsAttemptWhenInstalledMetadataIsMissing() async throws {
        let url = try installation()
        defer { try? FileManager.default.removeItem(at: url) }
        let responder = FinderExtensionProbeResponder(extensionURL: url, version: "0.1.0", build: "21")
        let client = FinderFirstUseVerification(extensionURL: url)
        let target = try FinderFirstUseVerificationSessionTests.identity(inode: 7)
        let begin = await client.begin(in: target)
        XCTAssertEqual(begin, .awaitingCreation)
        try FileManager.default.removeItem(at: url.appendingPathComponent("Contents/Info.plist"))
        let operation = Task { @MainActor in await client.check() }
        operation.cancel()
        let status = await operation.value
        XCTAssertEqual(status, .expiredOrMissing)
        let check = await client.check()
        XCTAssertEqual(check, .expiredOrMissing)
        withExtendedLifetime(responder) {}
    }

    func testNewBeginRequiresNewCreationRatherThanOldReceipt() async throws {
        let url = try installation()
        defer { try? FileManager.default.removeItem(at: url) }
        let responder = FinderExtensionProbeResponder(extensionURL: url, version: "0.1.0", build: "21")
        let client = FinderFirstUseVerification(extensionURL: url)
        let target = try FinderFirstUseVerificationSessionTests.identity(inode: 7)
        let first = await client.begin(in: target)
        XCTAssertEqual(first, .awaitingCreation)
        responder.reportSuccessfulCreation(in: target, attemptNonce: try XCTUnwrap(responder.verificationAttempt(in: target)))
        let reported = await client.check()
        XCTAssertEqual(reported, .creationReported)
        let second = await client.begin(in: target)
        XCTAssertEqual(second, .awaitingCreation)
        let check = await client.check()
        XCTAssertEqual(check, .awaitingCreation)
        client.cancel()
        withExtendedLifetime(responder) {}
    }
}

/// Deterministic transport fixture: acknowledge only arm, or hold all replies so a
/// cancellation test can wait until the operation really owns an armed local attempt.
@MainActor
private final class SelectiveVerificationResponder: NSObject {
    private let installation: String
    private let acknowledgeArm: Bool
    private let received: (FinderFirstUseWire.Command) -> Void

    init(extensionURL: URL, acknowledgeArm: Bool, received: @escaping (FinderFirstUseWire.Command) -> Void) {
        installation = FinderProbeNotification.identity(for: extensionURL, version: "0.1.0", build: "21")
        self.acknowledgeArm = acknowledgeArm
        self.received = received
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receive(_:)), name: FinderFirstUseWire.request,
            object: nil, suspensionBehavior: .deliverImmediately
        )
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    @objc private func receive(_ notification: Notification) {
        guard let token = notification.object as? String,
              let request = FinderFirstUseWire.Request(token: token), request.installation == installation else { return }
        received(request.command)
        if request.command == .arm && acknowledgeArm {
            DistributedNotificationCenter.default().postNotificationName(
                FinderFirstUseWire.response,
                object: FinderFirstUseWire.responseToken(for: request, status: .awaitingCreation),
                userInfo: nil, deliverImmediately: true
            )
        }
    }
}

/// Script delivery and the deadline on the main actor, independently of notification
/// scheduling or wall-clock delays. The production distributed transport remains covered above.
@MainActor
final class FinderFirstUseReplyAggregationTests: XCTestCase {
    private let installation = String(repeating: "a", count: 64)
    private let target = String(repeating: "b", count: 64)
    private let start: UInt64 = 1_000_000_000
    private let nonce = UUID()

    private func wireRequest(_ command: FinderFirstUseWire.Command = .status) -> FinderFirstUseWire.Request {
        FinderFirstUseWire.Request(command: command, installation: installation, nonce: nonce,
                                  directoryDigest: target, startedAt: start)
    }

    private func run(_ request: FinderFirstUseWire.Request, timeout: TimeInterval = 1.5,
                     script: @escaping @MainActor (ManualVerificationTransport, ManualVerificationDeadline) -> Void)
    async -> FinderFirstUseVerificationStatus {
        let transport = ManualVerificationTransport()
        let deadline = ManualVerificationDeadline()
        transport.onStart = { script(transport, deadline) }
        let operation = FinderFirstUseNotificationRequest(request: request, transport: transport,
                                                         scheduleDeadline: deadline.schedule)
        let result = await operation.run(timeout: timeout)
        XCTAssertEqual(transport.stopCount, 1, "Completion must release the one transport subscription")
        XCTAssertEqual(deadline.cancelCount, 1, "Completion must cancel its one bounded deadline")
        return result
    }

    func testTwoRespondersWaitingAndCreationReceiptWinInEitherOrder() async throws {
        for receiptFirst in [false, true] {
            var waiting = FinderFirstUseVerificationSession(installation: installation)
            var creator = FinderFirstUseVerificationSession(installation: installation)
            let arm = wireRequest(.arm)
            XCTAssertEqual(waiting.handle(arm, now: start), .awaitingCreation)
            XCTAssertEqual(creator.handle(arm, now: start), .awaitingCreation)
            creator.reportSuccessfulCreation(directoryDigest: target, attemptNonce: nonce, now: start + 1)
            let request = wireRequest()
            let waitingReply = try XCTUnwrap(waiting.handle(request, now: start + 2))
            let receipt = try XCTUnwrap(creator.handle(request, now: start + 2))
            let replies = receiptFirst ? [receipt, waitingReply] : [waitingReply, receipt]
            let result = await run(request) { transport, deadline in
                transport.send(replies[0])
                XCTAssertEqual(transport.stopCount, receiptFirst ? 1 : 0,
                               "A waiting instance must not close the actual creator's reply window")
                transport.send(replies[1])
                XCTAssertEqual(transport.stopCount, 1, "Creation can finish without waiting for the deadline")
                deadline.fire() // A late deadline cannot change or complete the result again.
            }
            XCTAssertEqual(result, .creationReported)
        }
    }

    func testLateRestartedResponderCannotHideHealthyCreationReceiptInEitherOrder() async throws {
        for expiredFirst in [false, true] {
            var creator = FinderFirstUseVerificationSession(installation: installation)
            _ = creator.handle(wireRequest(.arm), now: start)
            creator.reportSuccessfulCreation(directoryDigest: target, attemptNonce: nonce, now: start + 1)
            var restarted = FinderFirstUseVerificationSession(installation: installation, minimumStart: start + 2)
            let request = wireRequest()
            let expired = try XCTUnwrap(restarted.handle(request, now: start + 3))
            let receipt = try XCTUnwrap(creator.handle(request, now: start + 3))
            XCTAssertEqual(expired, .expiredOrMissing)
            let result = await run(request) { transport, deadline in
                transport.send(expiredFirst ? expired : receipt)
                XCTAssertEqual(transport.stopCount, expiredFirst ? 0 : 1)
                transport.send(expiredFirst ? receipt : expired)
                deadline.fire()
            }
            XCTAssertEqual(result, .creationReported)
        }
    }

    func testArmAcknowledgesHealthyResponderPromptlyDespiteEarlierExpiredReply() async {
        let result = await run(wireRequest(.arm)) { transport, deadline in
            transport.send(.expiredOrMissing)
            XCTAssertEqual(transport.stopCount, 0)
            transport.send(.awaitingCreation)
            XCTAssertEqual(transport.stopCount, 1, "A valid arm does not add the full aggregation delay")
            XCTAssertEqual(deadline.cancelCount, 1)
            transport.send(.expiredOrMissing)
            deadline.fire()
        }
        XCTAssertEqual(result, .awaitingCreation)
    }

    func testWaitingResponderWinsOverExpiredAndUnavailableOnlyAtStatusDeadline() async {
        for waitingFirst in [false, true] {
            let result = await run(wireRequest()) { transport, deadline in
                transport.send(waitingFirst ? .awaitingCreation : .expiredOrMissing)
                transport.send(.unavailable)
                transport.send(waitingFirst ? .expiredOrMissing : .awaitingCreation)
                XCTAssertEqual(transport.stopCount, 0, "Even awaitingCreation is provisional on a status check")
                deadline.fire()
            }
            XCTAssertEqual(result, .awaitingCreation)
        }
    }

    func testAllExpiredRespondersReturnExpiredOnlyAtDeadlineForArmAndStatus() async throws {
        for command in [FinderFirstUseWire.Command.arm, .status] {
            var expired = FinderFirstUseVerificationSession(installation: installation, lifetime: 0)
            var restarted = FinderFirstUseVerificationSession(installation: installation, minimumStart: start + 1)
            let request = wireRequest(command)
            let first = try XCTUnwrap(expired.handle(request, now: start + 2))
            let second = try XCTUnwrap(restarted.handle(request, now: start + 2))
            XCTAssertEqual(first, .expiredOrMissing)
            XCTAssertEqual(second, .expiredOrMissing)
            let result = await run(request) { transport, deadline in
                transport.send(first)
                transport.send(second)
                transport.send(.unavailable)
                XCTAssertEqual(transport.stopCount, 0)
                deadline.fire()
            }
            XCTAssertEqual(result, .expiredOrMissing)
        }
    }

    func testSilentResponderDoesNotExtendDeadlineOrInventSuccess() async {
        let cases: [[FinderFirstUseVerificationStatus]] = [[], [.awaitingCreation], [.expiredOrMissing], [.unavailable]]
        for replies in cases {
            let result = await run(wireRequest(), timeout: 0.25) { transport, deadline in
                for reply in replies { transport.send(reply) }
                // The other instance never replies. No responder count or extra wait is needed.
                XCTAssertEqual(deadline.seconds, 0.25)
                XCTAssertEqual(transport.stopCount, 0)
                deadline.fire()
                transport.send(.creationReported) // Outside the deadline, this receipt is stale.
            }
            XCTAssertEqual(result, replies.first ?? .unavailable)
        }
    }

    func testMismatchedNonceBuildPathVersionDirectoryStartCommandAndRequestIDAreIgnored() async {
        let url = URL(fileURLWithPath: "/Applications/QuickFile.app/Contents/PlugIns/FinderExtension.appex")
        let installed = FinderProbeNotification.identity(for: url, version: "0.1.0", build: "40")
        let request = FinderFirstUseWire.Request(command: .status, installation: installed, nonce: nonce,
                                                directoryDigest: target, startedAt: start)
        func changed(command: FinderFirstUseWire.Command = .status, installation: String? = nil,
                     nonce: UUID? = nil, directory: String? = nil, start: UInt64? = nil,
                     requestID: UUID? = nil) -> FinderFirstUseWire.Request {
            FinderFirstUseWire.Request(command: command, installation: installation ?? installed,
                                       nonce: nonce ?? request.nonce, directoryDigest: directory ?? target,
                                       startedAt: start ?? request.startedAt, requestID: requestID ?? request.requestID)
        }
        let staleRequests = [
            changed(nonce: UUID()),
            changed(installation: FinderProbeNotification.identity(for: url, version: "0.1.0", build: "39")),
            changed(installation: FinderProbeNotification.identity(for: url.appendingPathComponent("Other.appex"), version: "0.1.0", build: "40")),
            changed(installation: FinderProbeNotification.identity(for: url, version: "0.2.0", build: "40")),
            changed(directory: String(repeating: "c", count: 64)),
            changed(start: start - 1), changed(command: .arm), changed(requestID: UUID())
        ]
        let result = await run(request) { transport, deadline in
            for stale in staleRequests {
                transport.send(.creationReported, matching: stale)
                XCTAssertEqual(transport.stopCount, 0)
            }
            transport.send(.awaitingCreation)
            deadline.fire()
        }
        XCTAssertEqual(result, .awaitingCreation)
    }

    func testCancellationDiscardsProvisionalRepliesAndLateSuccess() async {
        let transport = ManualVerificationTransport()
        let deadline = ManualVerificationDeadline()
        let operation = FinderFirstUseNotificationRequest(request: wireRequest(), transport: transport,
                                                         scheduleDeadline: deadline.schedule)
        transport.onStart = {
            transport.send(.expiredOrMissing)
            transport.send(.awaitingCreation)
            XCTAssertEqual(transport.stopCount, 0)
            operation.cancel()
            transport.send(.creationReported)
            deadline.fire()
        }
        let result = await operation.run(timeout: 5)
        XCTAssertEqual(result, .unavailable, "Cancellation must not publish the accumulated waiting response")
        XCTAssertEqual(transport.stopCount, 1)
        XCTAssertEqual(deadline.cancelCount, 1)
    }

    func testTaskCancellationReleasesTransportAfterProvisionalReply() async {
        let started = expectation(description: "Status received a provisional response")
        let transport = ManualVerificationTransport()
        let deadline = ManualVerificationDeadline()
        let operation = FinderFirstUseNotificationRequest(request: wireRequest(), transport: transport,
                                                         scheduleDeadline: deadline.schedule)
        transport.onStart = { transport.send(.awaitingCreation); started.fulfill() }
        let task = Task { await operation.run(timeout: 5) }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(transport.stopCount, 0)
        task.cancel()
        let result = await task.value
        transport.send(.creationReported)
        deadline.fire()
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(transport.stopCount, 1)
        XCTAssertEqual(deadline.cancelCount, 1)
    }

    func testDeadlineClampingRemainsFiniteAndBounded() async {
        for (input, expected) in [(0.0, 0.01), (-1.0, 0.01), (100.0, 5.0), (.infinity, 1.5), (.nan, 1.5)] {
            let result = await run(wireRequest(), timeout: input) { transport, deadline in
                XCTAssertEqual(deadline.seconds, expected)
                deadline.fire()
            }
            XCTAssertEqual(result, .unavailable)
        }
    }
}

@MainActor
private final class ManualVerificationTransport: FinderFirstUseNotificationTransport {
    var onStart: (() -> Void)?
    private var request: FinderFirstUseWire.Request?
    // Keep the callback to deliberately simulate delivery already queued before stop.
    private var receive: (@MainActor (String) -> Void)?
    private(set) var stopCount = 0

    func start(request: FinderFirstUseWire.Request, receive: @escaping @MainActor (String) -> Void) {
        self.request = request
        self.receive = receive
        let script = onStart
        onStart = nil
        script?()
    }

    func stop() { stopCount += 1 }

    func send(_ status: FinderFirstUseVerificationStatus, matching request: FinderFirstUseWire.Request? = nil) {
        guard let request = request ?? self.request else { return XCTFail("Transport was not started") }
        receive?(FinderFirstUseWire.responseToken(for: request, status: status))
    }
}

@MainActor
private final class ManualVerificationDeadline {
    private var callback: (@MainActor () -> Void)?
    private(set) var seconds: TimeInterval?
    private(set) var cancelCount = 0

    func schedule(seconds: TimeInterval, fire: @escaping @MainActor () -> Void) -> (() -> Void) {
        self.seconds = seconds
        callback = fire
        return { self.cancelCount += 1 }
    }

    func fire() { callback?() }
}
