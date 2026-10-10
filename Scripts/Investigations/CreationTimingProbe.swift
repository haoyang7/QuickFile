import Foundation
@testable import QuickFileCore
@testable import QuickFileInfrastructure
import QuickFileApplication

/// Owned fixture: production repository, coordinator and writer; live bookmarks by default.
/// This is not Finder input/selection timing or a sandbox acceptance test.
@main
struct CreationTimingProbe {
    static func main() throws {
        func argument(_ key: String, default fallback: String) -> String {
            guard let index = CommandLine.arguments.firstIndex(of: key),
                  CommandLine.arguments.indices.contains(index + 1) else { return fallback }
            return CommandLine.arguments[index + 1]
        }
        let path = argument("--output", default: "")
        guard !path.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let grantCount = Int(argument("--grants", default: "11"))!
        let samples = Int(argument("--samples", default: "30"))!
        let mode = argument("--scope", default: "live")
        let bookmarkMode = argument("--bookmarks", default: "live")
        precondition(["live", "fixture"].contains(mode) && grantCount > 0 && samples > 0)
        guard ["live", "owned-fixture"].contains(bookmarkMode) else {
            throw NSError(domain: "QuickFileInvestigation.CreationTiming", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown bookmark mode; use live or owned-fixture."])
        }
        guard bookmarkMode != "owned-fixture" || mode == "fixture" else {
            throw NSError(domain: "QuickFileInvestigation.CreationTiming", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Owned-fixture bookmarks require --scope fixture; they do not validate live bookmark APIs or security scopes."])
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let suite = "QuickFileInvestigation.CreationTiming.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks: SecurityScopedBookmarkClient
        if bookmarkMode == "owned-fixture" {
            let codec = CreationTimingProbeOwnedBookmarks(root: root, grantCount: grantCount)
            bookmarks = SecurityScopedBookmarkClient(
                createPersistentBookmark: { try codec.encode($0) },
                createTransferBookmark: { try codec.encode($0) },
                resolvePersistentBookmark: { ResolvedSecurityScopedBookmark(url: try codec.decode($0), isStale: false) },
                resolveTransferBookmark: { ResolvedSecurityScopedBookmark(url: try codec.decode($0), isStale: false) },
                // This client is permitted only with explicitly injected fixture scopes.
                startAccessing: { _ in false }, stopAccessing: { _ in }
            )
        } else {
            bookmarks = .live
        }
        let store = AuthorizedDirectoryStore(
            defaults: defaults, storageDirectory: root.appendingPathComponent("grants"),
            persistentBookmarkCreator: bookmarks.createPersistentBookmark,
            transferBookmarkCreator: bookmarks.createTransferBookmark,
            persistentBookmarkResolver: bookmarks.resolvePersistentBookmark,
            transferBookmarkResolver: bookmarks.resolveTransferBookmark,
            startAccessing: { mode == "fixture" ? true : bookmarks.startAccessing($0) },
            stopAccessing: { if mode == "live" { bookmarks.stopAccessing($0) } }
        )
        for index in 0..<grantCount {
            let grant = root.appendingPathComponent("owned-grant-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: grant, withIntermediateDirectories: false)
            try store.authorize(grant)
        }
        let target = root.appendingPathComponent("owned-grant-0/Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let identity = try DirectoryIdentity.capture(at: target)
        let template = FileTemplate(name: "Owned empty file", fileExtension: "txt", content: "")
        let action = FinderMenuAction(templateID: template.id, context: .container,
                                      destinationFolder: target, destinationIdentity: identity)
        let service = FileCreationService()
        var measurements: [[String: Any]] = []
        var tracing: Bool?
        var failedSample: [String: Any]?
        var failedEvidenceSample: [String: Any]?
        let tracePath = ProcessInfo.processInfo.environment["QUICKFILE_CREATION_TIMING_DIR"] ?? ""
        let traceDirectory = tracePath.isEmpty ? nil : URL(fileURLWithPath: tracePath, isDirectory: true)
        var evidenceStatus = "not-requested"
        for sample in 0..<(samples + 3) {
            let timing = CreationTiming.begin("owned-fixture")
            tracing = timing != nil
            let coordinator = FinderFileCreationCoordinator(
                loadTemplate: { _ in template },
                performWithAccess: { url, operation in try store.withAccess(to: url, timing: timing, perform: operation) },
                createFile: { try service.createFile(for: $0) },
                requiresAuthorization: { AuthorizedDirectoryFailureClassifier.requiresAuthorization($0) }
            )
            timing?.mark("probe.begin")
            let result = CreationTimingProbeSample.run(create: {
                let result = try coordinator.createFile(for: action, timing: timing)
                return result.fileURL
            }, didCreate: { timing?.mark("probe.return") })
            timing?.finish(outcome: result.traceOutcome)
            CreationTiming.waitForPendingReports()
            let evidence = CreationTimingProbeEvidence.inspect(
                requested: CreationTiming.isRequested, directory: traceDirectory, traceID: timing?.id,
                expectedOutcome: result.traceOutcome, successfulCreation: result.success, grantCount: grantCount
            )
            evidenceStatus = evidence.status
            var measurement = result.measurement(sample: sample - 3, traceID: timing?.id)
            measurement["traceEvidence"] = evidence.record
            if sample >= 3 { measurements.append(measurement) }
            if evidence.isFailure { failedEvidenceSample = measurement }
            if !result.success {
                // Warmup failures also stop the run and remain separate from measured samples.
                failedSample = measurement
            }
            if !result.success || evidence.isFailure { break }
        }
        var report: [String: Any] = ["grants": grantCount, "requestedSamples": samples,
            "scopeMode": mode, "tracingEnabled": tracing ?? false, "traceEvidenceStatus": evidenceStatus,
            "measurements": measurements,
            "bookmarkMode": bookmarkMode, "realBookmarkAPIs": bookmarkMode == "live",
            "bookmarkEvidenceScope": bookmarkMode == "live"
                ? "Foundation bookmark creation and resolution; security scope mode reported separately"
                : "deterministic owned-path codec only; excludes real bookmark APIs, their cost, and security-scope validation",
            "scopeStartInjected": mode == "fixture",
            "scope": "owned unsandboxed fixture, warmed samples; excludes input, Finder, queue and UI selection",
            "mainAppOrAppGroupAccess": false]
        if let failedSample { report["failedSample"] = failedSample }
        if let failedEvidenceSample { report["failedEvidenceSample"] = failedEvidenceSample }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("measurements.json"), options: .atomic)
        print("grants=\(grantCount) scope=\(mode) bookmarks=\(bookmarkMode) tracing=\(tracing ?? false) evidence=\(evidenceStatus) samples=\(measurements.count)")
        if let failedSample {
            let failure = failedSample["failure"] ?? "unknown"
            throw NSError(domain: "QuickFileInvestigation.CreationTiming", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Sample failed: \(failure). See measurements.json."])
        }
        if failedEvidenceSample != nil {
            throw NSError(domain: "QuickFileInvestigation.CreationTiming", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Timing evidence could not be verified. File operation results are recorded separately in measurements.json."])
        }
    }
}
