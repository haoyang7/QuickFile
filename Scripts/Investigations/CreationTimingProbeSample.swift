import Foundation

/// Deterministic CI-only stand-in for bookmark encoding/resolution. Tokens contain
/// an owned grant index, never an arbitrary path, and resolve only within this run.
/// This does not validate Foundation bookmarks or grant any security-scope access.
struct CreationTimingProbeOwnedBookmarks {
    private let root: URL
    private let grantCount: Int
    private let prefix = "quickfile-owned-bookmark-v1:"

    init(root: URL, grantCount: Int) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.grantCount = grantCount
    }

    func encode(_ url: URL) throws -> Data {
        let name = url.lastPathComponent
        let namePrefix = "owned-grant-"
        guard url.isFileURL, name.hasPrefix(namePrefix),
              let index = Int(name.dropFirst(namePrefix.count)),
              name == namePrefix + String(index),
              url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.pathComponents == root.pathComponents,
              try ownedGrant(index).pathComponents == url.resolvingSymlinksInPath().standardizedFileURL.pathComponents else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return Data((prefix + String(index)).utf8)
    }

    func decode(_ data: Data) throws -> URL {
        guard let token = String(data: data, encoding: .utf8), token.hasPrefix(prefix),
              let index = Int(token.dropFirst(prefix.count)), token == prefix + String(index) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try ownedGrant(index)
    }

    private func ownedGrant(_ index: Int) throws -> URL {
        guard (0..<grantCount).contains(index) else { throw CocoaError(.fileReadInvalidFileName) }
        let url = root.appendingPathComponent("owned-grant-\(index)", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard url.resolvingSymlinksInPath().standardizedFileURL.pathComponents == url.pathComponents,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return url
    }
}

/// One final verdict per sample; validation and cleanup stay outside creation timing.
struct CreationTimingProbeSample {
    let durationNS: UInt64
    let success: Bool
    let failurePhase: String?
    let failure: String?

    var traceOutcome: String { success ? "fixture-created-no-finder" : "fixture-failed" }

    func measurement(sample: Int, traceID: String?) -> [String: Any] {
        var record: [String: Any] = ["sample": sample, "durationNS": durationNS, "success": success]
        if let traceID { record["traceID"] = traceID }
        if let failurePhase { record["failurePhase"] = failurePhase }
        if let failure { record["failure"] = failure }
        return record
    }

    static func run(
        clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        create: () throws -> URL,
        didCreate: () -> Void = {},
        validate: (URL) throws -> Void = validateEmptyOutput,
        cleanup: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> Self {
        let begin = clock()
        var duration: UInt64?
        var phase = "creation"
        do {
            let output = try create()
            duration = clock() - begin
            didCreate()
            phase = "validation"
            try validate(output)
            phase = "cleanup"
            try cleanup(output)
            return Self(durationNS: duration!, success: true, failurePhase: nil, failure: nil)
        } catch {
            return Self(durationNS: duration ?? (clock() - begin), success: false,
                        failurePhase: phase, failure: error.localizedDescription)
        }
    }

    static func validateEmptyOutput(_ url: URL) throws {
        guard try Data(contentsOf: url).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
    }
}

/// Checks authorization attempt boundaries, including rejection and fallback.
/// This does not certify the rest of a Finder operation or its visible endpoint.
struct AuthorizationTimingEvidence {
    static func isComplete(_ phases: [String]) -> Bool {
        let phases = phases.filter { $0.hasPrefix("authorization.") }
        var index = 0
        func consume(_ phase: String) -> Bool {
            guard index < phases.count, phases[index] == phase else { return false }
            index += 1
            return true
        }
        func span(_ prefix: String, results: [String]) -> String? {
            guard consume(prefix + ".begin"), index < phases.count,
                  let result = results.first(where: { phases[index] == prefix + "." + $0 }) else { return nil }
            index += 1
            return consume(prefix + ".end") ? result : nil
        }
        func finish() -> Bool { consume("authorization.end") && index == phases.count }
        guard consume("authorization.begin"),
              let table = span("authorization.table", results: ["loaded", "failed"]) else { return false }
        if table == "failed" { return finish() }

        var resolved = 0
        var failed = 0
        var changed = false
        var attempts = 0
        while index < phases.count {
            // Exact grants can attempt admission before later bookmarks are resolved.
            // Rejected/changed exact grants resume discovery before parent fallbacks.
            if phases[index] == "authorization.bookmark.begin" {
                guard let result = span("authorization.bookmark", results: ["resolved", "failed"]) else { return false }
                if result == "resolved" { resolved += 1 } else { failed += 1 }
                continue
            }
            if consume("authorization.unresolved") {
                return attempts == 0 && resolved == 0 && failed > 0 && finish()
            }
            if consume("authorization.no-match") {
                return attempts == 0 && (resolved > 0 || failed == 0) && finish()
            }
            if consume(changed ? "authorization.changed" : "authorization.scope-unavailable") {
                return attempts > 0 && finish()
            }
            guard resolved > 0, phases[index] == "authorization.revision.before-scope.begin" else { return false }
            attempts += 1
            guard let before = span("authorization.revision.before-scope", results: ["current", "changed", "failed"]) else { return false }
            if before == "failed" { return finish() }
            if before == "changed" { changed = true; continue }
            guard consume("authorization.scope.begin") else { return false }
            if consume("authorization.scope.rejected") { continue }
            guard consume("authorization.scope.started"),
                  let after = span("authorization.revision.after-scope", results: ["current", "changed", "failed"]) else { return false }
            if after == "current" {
                return consume("authorization.admitted") && consume("authorization.scope.stopped") && finish()
            }
            guard consume("authorization.scope.stopped") else { return false }
            if after == "failed" { return finish() }
            changed = true
        }
        return false
    }
}

/// Certifies only the coordinator's destination/template preflight stages.
/// A complete preflight is not a complete writer or Finder timeline.
struct CreationPreflightTimingEvidence {
    static func isComplete(_ phases: [String]) -> Bool {
        let phases = phases.filter {
            $0.hasPrefix("destination.validation.") || $0.hasPrefix("templates.load.")
        }
        let destination = ["destination.validation.begin", "destination.validation.validated", "destination.validation.end"]
        return phases == ["destination.validation.begin", "destination.validation.failed", "destination.validation.end"]
            || phases == destination + ["templates.load.begin", "templates.load.loaded", "templates.load.end"]
            || phases == destination + ["templates.load.begin", "templates.load.failed", "templates.load.end"]
    }
}

/// Writer preflight may reject before opening a destination or staging a payload.
/// A later write failure must retain its successful preflight result.
struct WriterPreflightTimingEvidence {
    static func isComplete(_ phases: [String]) -> Bool {
        let phases = phases.filter { $0.hasPrefix("writer.preflight.") }
        return phases == ["writer.preflight.begin", "writer.preflight.validated", "writer.preflight.end"]
            || phases == ["writer.preflight.begin", "writer.preflight.failed", "writer.preflight.end"]
    }
}

/// Evidence validity is separate from file creation/validation/cleanup success.
/// A recorder failure must never rewrite a successful file operation as a failure.
struct CreationTimingProbeEvidence {
    let status: String
    let failure: String?
    let droppedEvents: Int?
    var droppedReports: UInt64? = nil
    var failedReports: UInt64? = nil

    var isFailure: Bool { status != "not-requested" && status != "verified" }

    var record: [String: Any] {
        var result: [String: Any] = ["status": status, "expected": status != "not-requested"]
        if status != "not-requested" { result["valid"] = !isFailure }
        if status == "failure-envelope-only" {
            result["envelopeValid"] = true
            result["complete"] = false
        }
        if let failure { result["failure"] = failure }
        if let droppedEvents { result["droppedEvents"] = droppedEvents }
        if let droppedReports { result["droppedReports"] = droppedReports }
        if let failedReports { result["failedReports"] = failedReports }
        return result
    }

    private struct Report: Decodable {
        struct Delivery: Decodable {
            let sessionID: String
            let sequence: UInt64
        }
        struct Event: Decodable {
            let phase: String
            let uptimeNS: UInt64
        }
        let id: String
        let kind: String
        let pid: Int32
        let outcome: String
        let droppedEvents: Int
        let events: [Event]
        let delivery: Delivery?
    }

    private struct Receipt: Decodable {
        let schemaVersion: Int
        let sessionID: String
        let pid: Int32
        let closed: Bool
        let acceptedReports: UInt64
        let writtenReports: UInt64
        let droppedReports: UInt64
        let failedReports: UInt64
    }

    static func inspect(
        requested: Bool,
        directory: URL?,
        traceID: String?,
        expectedOutcome: String,
        successfulCreation: Bool,
        grantCount: Int,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        read: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> Self {
        guard requested || directory != nil || traceID != nil else {
            return Self(status: "not-requested", failure: nil, droppedEvents: nil)
        }
        guard let traceID else {
            return Self(status: "unavailable", failure: "Requested tracing did not start.", droppedEvents: nil)
        }
        guard let directory else {
            return Self(status: "external-validation-required",
                        failure: "This probe requires JSON reports to verify requested tracing; signposts need independent validation.",
                        droppedEvents: nil)
        }
        let data: Data
        do { data = try read(directory.appendingPathComponent("\(traceID).json")) }
        catch {
            // Do not expose a trace destination or an arbitrary filesystem error.
            return Self(status: "unavailable", failure: "Expected JSON trace is missing or unreadable.", droppedEvents: nil)
        }
        let report: Report
        do { report = try JSONDecoder().decode(Report.self, from: data) }
        catch { return Self(status: "invalid", failure: "JSON trace is malformed.", droppedEvents: nil) }
        func invalid(_ failure: String) -> Self {
            Self(status: "invalid", failure: failure, droppedEvents: report.droppedEvents)
        }
        guard pid > 0, report.id == traceID, report.kind == "owned-fixture", report.pid == pid,
              report.outcome == expectedOutcome else {
            return invalid("Trace identity or outcome does not match this sample.")
        }
        guard let delivery = report.delivery, UUID(uuidString: delivery.sessionID) != nil else {
            return invalid("JSON trace lacks delivery metadata; legacy or live JSON is not complete session evidence.")
        }
        let receipt: Receipt
        do {
            receipt = try JSONDecoder().decode(Receipt.self, from: read(directory
                .appendingPathComponent("receipts", isDirectory: true).appendingPathComponent(delivery.sessionID + ".json")))
        } catch { return invalid("Closed JSON session receipt is missing, unreadable or malformed.") }
        guard receipt.schemaVersion == 1, receipt.sessionID == delivery.sessionID, receipt.pid == pid,
              receipt.closed, receipt.acceptedReports == receipt.writtenReports,
              delivery.sequence > 0, delivery.sequence <= receipt.acceptedReports,
              receipt.droppedReports == 0, receipt.failedReports == 0 else {
            var result = invalid("JSON session receipt is unclosed, mismatched or records lost reports.")
            result.droppedReports = receipt.droppedReports
            result.failedReports = receipt.failedReports
            return result
        }
        guard report.droppedEvents == 0 else { return invalid("Trace contains dropped events.") }
        let phases = report.events.map(\.phase)
        guard phases.first == "begin", phases.dropFirst().first == "probe.begin", phases.last == "end",
              phases.filter({ $0 == "begin" }).count == 1,
              phases.filter({ $0 == "probe.begin" }).count == 1,
              phases.filter({ $0 == "end" }).count == 1 else {
            return invalid("Trace lifecycle is incomplete.")
        }
        guard zip(report.events, report.events.dropFirst()).allSatisfy({ pair in
            pair.0.uptimeNS <= pair.1.uptimeNS
        }) else {
            return invalid("Trace timestamps are not monotonic.")
        }
        if phases.contains(where: { $0.hasPrefix("authorization.") }),
           !AuthorizationTimingEvidence.isComplete(phases) {
            return invalid("Authorization attempt phases are incomplete or out of order.")
        }
        if phases.contains(where: { $0.hasPrefix("destination.validation.") || $0.hasPrefix("templates.load.") }),
           !CreationPreflightTimingEvidence.isComplete(phases) {
            return invalid("Creation preflight phases are incomplete or out of order.")
        }
        if phases.contains(where: { $0.hasPrefix("writer.preflight.") }),
           !WriterPreflightTimingEvidence.isComplete(phases) {
            return invalid("Writer preflight phases are incomplete or out of order.")
        }
        if successfulCreation {
            // The owned fixture has one matching grant and no filename conflict.
            // Require all measured success spans, including scope and writer cleanup.
            let required = [
                "begin", "probe.begin", "destination.validation.begin", "destination.validation.validated", "destination.validation.end",
                "templates.load.begin", "templates.load.loaded", "templates.load.end", "authorization.begin",
                "authorization.table.begin", "authorization.table.loaded", "authorization.table.end"
            ] + Array(repeating: ["authorization.bookmark.begin", "authorization.bookmark.resolved", "authorization.bookmark.end"], count: grantCount).flatMap { $0 } + [
                "authorization.revision.before-scope.begin", "authorization.revision.before-scope.current", "authorization.revision.before-scope.end",
                "authorization.scope.begin", "authorization.scope.started",
                "authorization.revision.after-scope.begin", "authorization.revision.after-scope.current", "authorization.revision.after-scope.end",
                "authorization.admitted", "writer.preflight.begin", "writer.preflight.validated", "writer.preflight.end",
                "staging.begin", "staging.ready", "payload.permissions.ready", "payload.closed",
                "file.published", "file.location.verified", "staging.cleanup.attempt.begin",
                "staging.cleanup.attempt.end", "writer.result.ready", "writer.end",
                "authorization.scope.stopped", "authorization.end", "probe.return", "end"
            ]
            guard phases == required else {
                return invalid("Success phases do not exactly match the controlled fixture.")
            }
        } else {
            // Failures have different prefixes and unwind/defer paths. Envelope
            // validation alone cannot certify their complete operation timeline.
            return Self(status: "failure-envelope-only",
                        failure: "Failure trace envelope is valid; operation phases have not been verified.",
                        droppedEvents: 0)
        }
        return Self(status: "verified", failure: nil, droppedEvents: 0)
    }
}
