import Foundation

@main
struct ProbeEvidenceCases {
    static func main() throws {
        let scenario = CommandLine.arguments[1]
        if scenario == "owned-bookmark-codec" {
            try checkOwnedBookmarkCodec()
            return
        }
        let fixtureDirectory = URL(fileURLWithPath: "/owned-trace-fixture")
        let sessionID = "1D9C5AEC-D308-4F06-9E57-2253F533C38F"
        let creationFailed = scenario.hasPrefix("failure-") || ["failed-creation", "recorder-valid-failure"].contains(scenario)
        let sample = CreationTimingProbeSample(durationNS: 50, success: !creationFailed,
                                              failurePhase: creationFailed ? "creation" : nil,
                                              failure: creationFailed ? "Owned creation failed." : nil)
        var traceID: String? = "owned-trace"
        var requested = true
        var directory: URL? = fixtureDirectory
        var successfulCreation = sample.success
        var expectedOutcome = sample.traceOutcome
        let phases = [
            "begin", "probe.begin", "destination.validation.begin", "destination.validation.validated", "destination.validation.end",
            "templates.load.begin", "templates.load.loaded", "templates.load.end", "authorization.begin",
            "authorization.table.begin", "authorization.table.loaded", "authorization.table.end", "authorization.bookmark.begin",
            "authorization.bookmark.resolved", "authorization.bookmark.end", "authorization.revision.before-scope.begin",
            "authorization.revision.before-scope.current", "authorization.revision.before-scope.end", "authorization.scope.begin", "authorization.scope.started",
            "authorization.revision.after-scope.begin", "authorization.revision.after-scope.current", "authorization.revision.after-scope.end",
            "authorization.admitted", "writer.preflight.begin", "writer.preflight.validated", "writer.preflight.end", "staging.begin",
            "staging.ready", "payload.permissions.ready", "payload.closed", "file.published",
            "file.location.verified", "staging.cleanup.attempt.begin", "staging.cleanup.attempt.end",
            "writer.result.ready", "writer.end", "authorization.scope.stopped", "authorization.end",
            "probe.return", "end"
        ]
        var events: [[String: Any]] = phases.enumerated().map { ["phase": $0.element, "uptimeNS": $0.offset + 100] }
        var report: [String: Any] = ["id": "owned-trace", "kind": "owned-fixture", "pid": 123,
                                   "outcome": sample.traceOutcome, "droppedEvents": 0,
                                   "delivery": ["sessionID": sessionID, "sequence": 1]]
        var receipt: [String: Any] = ["schemaVersion": 1, "sessionID": sessionID, "pid": 123, "closed": true,
                                     "acceptedReports": 1, "writtenReports": 1, "droppedReports": 0, "failedReports": 0]
        switch scenario {
        case "disabled": requested = false; traceID = nil; directory = nil
        case "requested-unavailable": traceID = nil
        case "external-signposts": directory = nil
        case "wrong-id": report["id"] = "other-trace"
        case "wrong-pid": report["pid"] = 124
        case "wrong-kind": report["kind"] = "menu"
        case "wrong-outcome": report["outcome"] = "fixture-failed"
        case "dropped": report["droppedEvents"] = 2
        case "negative-dropped": report["droppedEvents"] = -1
        case "legacy-json": report.removeValue(forKey: "delivery")
        case "receipt-unclosed": receipt["closed"] = false
        case "receipt-wrong-pid": receipt["pid"] = 124
        case "receipt-wrong-session": receipt["sessionID"] = UUID().uuidString
        case "receipt-wrong-version": receipt["schemaVersion"] = 2
        case "receipt-dropped": receipt["droppedReports"] = 1
        case "receipt-failed": receipt["failedReports"] = 1
        case "receipt-incomplete": receipt["writtenReports"] = 0
        case "receipt-negative": receipt["droppedReports"] = -1
        case "receipt-zero-sequence": report["delivery"] = ["sessionID": sessionID, "sequence": 0]
        case "receipt-forged-sequence": report["delivery"] = ["sessionID": sessionID, "sequence": 2]
        case "receipt-path-escape": report["delivery"] = ["sessionID": "../other", "sequence": 1]
        case "missing-end": events.removeLast()
        case "missing-phase": events.removeAll { $0["phase"] as? String == "payload.closed" }
        case "wrong-phase-order":
            let closed = phases.firstIndex(of: "payload.closed")!
            let published = phases.firstIndex(of: "file.published")!
            events[closed]["phase"] = "file.published"
            events[published]["phase"] = "payload.closed"
        case "nonmonotonic": events[3]["uptimeNS"] = 1
        case "extra-bookmark": events.insert(["phase": "authorization.bookmark.begin", "uptimeNS": 110], at: 11)
        case "duplicate-writer-end": events.insert(["phase": "writer.end", "uptimeNS": 118], at: 18)
        case "orphan-scope-stop": events.insert(["phase": "authorization.scope.stopped", "uptimeNS": 113], at: 13)
        case "unknown-phase": events.insert(["phase": "unknown", "uptimeNS": 133], at: 33)
        case "failed-creation":
            successfulCreation = false
            expectedOutcome = "fixture-failed"
            report["outcome"] = expectedOutcome
            events = [["phase": "begin", "uptimeNS": 100], ["phase": "probe.begin", "uptimeNS": 101],
                      ["phase": "end", "uptimeNS": 110]]
        case "failure-missing-probe-begin":
            events = [["phase": "begin", "uptimeNS": 100], ["phase": "end", "uptimeNS": 110]]
        case "failure-missing-destination-end", "failure-missing-template-end":
            var failurePhases = ["begin", "probe.begin", "destination.validation.begin", "destination.validation.validated",
                                 "destination.validation.end", "templates.load.begin", "templates.load.failed", "templates.load.end", "end"]
            failurePhases.removeAll { $0 == (scenario == "failure-missing-destination-end" ? "destination.validation.end" : "templates.load.end") }
            events = failurePhases.enumerated().map { ["phase": $0.element, "uptimeNS": $0.offset + 100] }
        case "failure-writer-preflight", "failure-missing-writer-end", "failure-missing-writer-result", "failure-reordered-writer":
            var failurePhases = ["begin", "probe.begin", "writer.preflight.begin", "writer.preflight.failed", "writer.preflight.end", "writer.end", "end"]
            if scenario == "failure-missing-writer-end" { failurePhases.removeAll { $0 == "writer.preflight.end" } }
            if scenario == "failure-missing-writer-result" { failurePhases.removeAll { $0 == "writer.preflight.failed" } }
            if scenario == "failure-reordered-writer" { failurePhases.swapAt(3, 4) }
            events = failurePhases.enumerated().map { ["phase": $0.element, "uptimeNS": $0.offset + 100] }
        default: break
        }
        report["events"] = events
        let data: Data
        if scenario == "malformed" { data = Data("invalid".utf8) }
        else { data = try JSONSerialization.data(withJSONObject: report) }
        let receiptData = try JSONSerialization.data(withJSONObject: receipt)
        let evidence: CreationTimingProbeEvidence
        var readCount = 0
        if scenario.hasPrefix("recorder-") {
            let timing = CreationTiming.begin("owned-fixture")
            traceID = timing?.id
            let path = ProcessInfo.processInfo.environment["QUICKFILE_CREATION_TIMING_DIR"] ?? ""
            directory = path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
            timing?.mark("probe.begin")
            if scenario == "recorder-overflow" {
                for _ in 0..<600 { timing?.mark("authorization.bookmark.begin") }
            }
            timing?.finish(outcome: expectedOutcome)
            CreationTiming.waitForPendingReports()
            evidence = CreationTimingProbeEvidence.inspect(
                requested: CreationTiming.isRequested, directory: directory, traceID: traceID,
                expectedOutcome: expectedOutcome, successfulCreation: successfulCreation, grantCount: 1
            )
        } else {
            evidence = CreationTimingProbeEvidence.inspect(
                requested: requested, directory: directory, traceID: traceID,
                expectedOutcome: expectedOutcome, successfulCreation: successfulCreation, grantCount: 1, pid: 123,
                read: { url in
                    readCount += 1
                    if scenario == "missing" { throw CocoaError(.fileReadNoSuchFile) }
                    if url.deletingLastPathComponent().lastPathComponent == "receipts" {
                        if scenario == "receipt-missing" { throw CocoaError(.fileReadNoSuchFile) }
                        if scenario == "receipt-malformed" { return Data("invalid".utf8) }
                        return receiptData
                    }
                    return data
                }
            )
        }
        var measurement = sample.measurement(sample: 0, traceID: traceID)
        measurement["traceEvidence"] = evidence.record
        let output: [String: Any] = ["measurement": measurement, "evidenceFailure": evidence.isFailure,
                                     "traceOutcome": sample.traceOutcome, "readCount": readCount,
                                     "recorderRequested": CreationTiming.isRequested]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self))
    }

    static func checkOwnedBookmarkCodec() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("owned-run", isDirectory: true)
        let grant = root.appendingPathComponent("owned-grant-0", isDirectory: true)
        try manager.createDirectory(at: grant, withIntermediateDirectories: true)
        let alias = temporary.appendingPathComponent("owned-run-alias", isDirectory: true)
        try manager.createSymbolicLink(at: alias, withDestinationURL: root)
        let outside = temporary.appendingPathComponent("outside/owned-grant-0", isDirectory: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        let codec = CreationTimingProbeOwnedBookmarks(root: alias, grantCount: 1)
        let token = try codec.encode(alias.appendingPathComponent("owned-grant-0", isDirectory: true))
        let decoded = try codec.decode(token)
        var rejected: [String] = []
        func reject(_ name: String, _ operation: () throws -> Void) {
            do { try operation() }
            catch { rejected.append(name) }
        }
        reject("outside-encode") { _ = try codec.encode(outside) }
        reject("arbitrary-path-token") { _ = try codec.decode(Data(outside.path.utf8)) }
        reject("out-of-range") { _ = try codec.decode(Data("quickfile-owned-bookmark-v1:1".utf8)) }
        reject("negative-index") { _ = try codec.decode(Data("quickfile-owned-bookmark-v1:-1".utf8)) }
        reject("noncanonical-index") { _ = try codec.decode(Data("quickfile-owned-bookmark-v1:00".utf8)) }
        let repeated = try codec.encode(grant)
        try manager.removeItem(at: grant)
        try manager.createSymbolicLink(at: grant, withDestinationURL: outside)
        reject("symlink-escape-decode") { _ = try codec.decode(token) }
        reject("symlink-escape-encode") { _ = try codec.encode(grant) }
        let result: [String: Any] = [
            "deterministic": repeated == token,
            "ownedRoundTrip": decoded.pathComponents == root.resolvingSymlinksInPath().appendingPathComponent("owned-grant-0").pathComponents,
            "token": String(decoding: token, as: UTF8.self),
            "rejected": rejected.sorted(),
            "outsideSentinel": try String(contentsOf: sentinel, encoding: .utf8)
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
}
