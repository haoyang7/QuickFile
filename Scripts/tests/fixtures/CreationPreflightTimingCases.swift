import Foundation
@testable import QuickFileCore
@testable import QuickFileApplication

private enum FixtureError: Error { case ownedFailure }
private final class PreflightState: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = ["loads": 0, "accesses": 0, "creates": 0]
    func increment(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        counts[key, default: 0] += 1
    }
    var snapshot: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return counts
    }
}

/// Calls the production coordinator with owned directories. No Finder, App Group,
/// real bookmarks, or security-scope claims; this certifies preflight spans only.
@main
struct CreationPreflightTimingCases {
    static func main() throws {
        let scenario = CommandLine.arguments[1]
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = root.appendingPathComponent("owned", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let identity = try DirectoryIdentity.capture(at: scenario == "identity-changed" ? other : target)
        if scenario == "directory-removed" { try manager.removeItem(at: target) }
        let template = FileTemplate(name: "Owned", fileExtension: "txt", content: "owned")
        let state = PreflightState()
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in
                state.increment("loads")
                if scenario == "template-read-failure" { throw FixtureError.ownedFailure }
                if scenario == "template-removed" { return nil }
                var current = template
                if scenario == "template-disabled" { current.isEnabled = false }
                return current
            },
            performWithAccess: { _, operation in state.increment("accesses"); return try operation() },
            createFile: { request in
                state.increment("creates")
                return try FileCreationService().createFile(for: request)
            },
            requiresAuthorization: { _ in false },
            resolveSelection: { _, _, _ in nil }
        )
        let action: FinderMenuAction
        if scenario == "unresolved-selection" {
            action = FinderMenuAction(templateID: template.id, context: .items,
                targetedURL: target, selectedItemURLs: [],
                preparedDestination: FinderMenuDestination(folder: target, identity: identity))
        } else {
            action = FinderMenuAction(templateID: template.id, context: .container, destinationFolder: target,
                destinationIdentity: scenario == "missing-prepared" ? nil : identity)
        }
        guard let timing = CreationTiming.begin("preflight-fixture") else { throw FixtureError.ownedFailure }
        var outcome = "created"
        do {
            let result = try coordinator.createFile(for: action, timing: timing)
            guard try String(contentsOf: result.fileURL, encoding: .utf8) == "owned" else { throw FixtureError.ownedFailure }
        } catch FinderFileCreationError.destinationUnavailable { outcome = "destination-unavailable" }
        catch FileCreationError.destinationIdentityChanged { outcome = "identity-changed" }
        catch FinderFileCreationError.templateUnavailable { outcome = "template-unavailable" }
        catch FixtureError.ownedFailure { outcome = "template-read-failed" }
        catch { outcome = "directory-read-failed" }
        timing.finish(outcome: outcome)
        CreationTiming.waitForPendingReports()
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUICKFILE_CREATION_TIMING_DIR"]!)
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(timing.id + ".json"))) as! [String: Any]
        let events = report["events"] as! [[String: Any]]
        let phases = events.map { $0["phase"] as! String }
        let ticks = events.map { ($0["uptimeNS"] as! NSNumber).uint64Value }
        let preflightIndices = phases.indices.filter {
            phases[$0].hasPrefix("destination.validation.") || phases[$0].hasPrefix("templates.load.")
        }
        let incompleteAccepted = preflightIndices.filter { index in
            var mutant = phases; mutant.remove(at: index)
            return CreationPreflightTimingEvidence.isComplete(mutant)
        }.count
        let output: [String: Any] = [
            "outcome": outcome, "traceOutcome": report["outcome"]!, "phases": phases,
            "preflightComplete": CreationPreflightTimingEvidence.isComplete(phases),
            "missingPhaseMutantsAccepted": incompleteAccepted, "counts": state.snapshot,
            "monotonic": zip(ticks, ticks.dropFirst()).allSatisfy { $0 <= $1 },
            "droppedEvents": report["droppedEvents"]!
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self))
    }
}
