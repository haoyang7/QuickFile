import Foundation
@testable import QuickFileCore
@testable import QuickFileInfrastructure

private enum FixtureError: Error { case ownedFailure }
private final class FixtureState: @unchecked Sendable {
    struct Values {
        var mutated = false
        var mutationFailed = false
        var starts = 0
        var stops = 0
        var operations = 0
        var resolutions = 0
    }
    private let lock = NSLock()
    private var values = Values()
    func update<T>(_ operation: (inout Values) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return operation(&values)
    }
}

@main
struct AuthorizationTimingCases {
    static func main() throws {
        let scenario = CommandLine.arguments[1]
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let suite = "QuickFileTests.AuthorizationTiming.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw FixtureError.ownedFailure }
        defer { defaults.removePersistentDomain(forName: suite) }
        let parent = root.appendingPathComponent("owned", isDirectory: true)
        let child = parent.appendingPathComponent("child", isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
        try manager.createDirectory(at: child, withIntermediateDirectories: true)
        try manager.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        let repository = AuthorizedDirectoryRepository(defaults: defaults, storageDirectory: storage)
        let state = FixtureState()
        let resolve: @Sendable (Data) throws -> ResolvedSecurityScopedBookmark = { data in
            guard let path = String(data: data, encoding: .utf8) else { throw FixtureError.ownedFailure }
            return ResolvedSecurityScopedBookmark(url: URL(fileURLWithPath: path), isStale: false)
        }
        let mutate: @Sendable () throws -> Void = {
            if scenario.contains("check-failure") {
                try Data("malformed-owned-table".utf8).write(
                    to: storage.appendingPathComponent("authorizedDirectories.v2.json"), options: .atomic
                )
            } else {
                try repository.update { $0.removeAll { $0.transferBookmarkData == Data(child.path.utf8) } }
            }
        }
        let store = AuthorizedDirectoryStore(
            defaults: scenario == "table-failure" ? nil : defaults, storageDirectory: storage,
            persistentBookmarkCreator: { Data($0.path.utf8) }, transferBookmarkCreator: { Data($0.path.utf8) },
            persistentBookmarkResolver: resolve,
            transferBookmarkResolver: { data in
                state.update { $0.resolutions += 1 }
                let resolved = try resolve(data)
                if scenario == "unresolved" || (["broken-bookmark-fallback", "exact-hint-skips-earlier-unrelated"].contains(scenario) && resolved.url == unrelated) {
                    throw FixtureError.ownedFailure
                }
                if resolved.url == child && (scenario.hasPrefix("revoke-before") || scenario == "before-check-failure"),
                   state.update({ values in
                       if values.mutated { return false }
                       values.mutated = true
                       return true
                   }) { try mutate() }
                return resolved
            },
            startAccessing: { url in
                if scenario == "scope-unavailable" || (scenario.hasPrefix("scope-fallback") && url == child) { return false }
                if url == child && (scenario.hasPrefix("revoke-after") || scenario == "after-check-failure"),
                   state.update({ values in
                       if values.mutated { return false }
                       values.mutated = true
                       return true
                   }) {
                    do { try mutate() }
                    catch { state.update { $0.mutationFailed = true }; return false }
                }
                state.update { $0.starts += 1 }
                return true
            },
            stopAccessing: { _ in state.update { $0.stops += 1 } }
        )
        if scenario != "table-failure" {
            if ["no-match", "broken-bookmark-fallback", "exact-hint-skips-earlier-unrelated"].contains(scenario) {
                try store.authorize(unrelated)
            }
            if scenario.contains("fallback") && scenario != "broken-bookmark-fallback" && !scenario.hasSuffix("parent-later") {
                try store.authorize(parent)
            }
            if scenario != "no-match" { try store.authorize(child) }
            if scenario.hasSuffix("parent-later") { try store.authorize(parent) }
            if scenario == "exact-first-unrelated" { try store.authorize(unrelated) }
            if scenario == "broken-bookmark-fallback" {
                // Exercise the legacy/hintless fallback, not the new exact-hint
                // fast path that correctly skips an unrelated failed resolver.
                try repository.update { records in
                    records = records.map { record in
                        StoredDirectoryAuthorization(id: record.id,
                            persistentBookmarkData: record.persistentBookmarkData,
                            transferBookmarkData: record.transferBookmarkData)
                    }
                }
            }
        }
        guard let timing = CreationTiming.begin("authorization-fixture") else { throw FixtureError.ownedFailure }
        var outcome = "admitted"
        do {
            try store.withAccess(to: child, timing: timing) {
                state.update { $0.operations += 1 }
                if scenario.hasPrefix("operation-failure") { throw FixtureError.ownedFailure }
            }
        } catch AuthorizedDirectoryStoreError.bookmarkResolutionFailed { outcome = "unresolved" }
        catch AuthorizedDirectoryStoreError.directoryNotAuthorized { outcome = "no-match" }
        catch AuthorizedDirectoryStoreError.authorizationChanged { outcome = "changed" }
        catch AuthorizedDirectoryStoreError.securityScopeUnavailable { outcome = "scope-unavailable" }
        catch AuthorizedDirectoryStoreError.sharedDefaultsUnavailable { outcome = "table-failure" }
        catch FixtureError.ownedFailure { outcome = "operation-failed" }
        catch { outcome = "storage-error" }
        timing.finish(outcome: outcome)
        CreationTiming.waitForPendingReports()
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUICKFILE_CREATION_TIMING_DIR"]!)
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(timing.id + ".json"))) as! [String: Any]
        let events = report["events"] as! [[String: Any]]
        let phases = events.map { $0["phase"] as! String }
        let ticks = events.map { ($0["uptimeNS"] as! NSNumber).uint64Value }
        let endIndices = phases.indices.filter { phases[$0].hasPrefix("authorization.") && phases[$0].hasSuffix(".end") }
        let incompleteAccepted = endIndices.filter { index in
            var mutant = phases; mutant.remove(at: index)
            return AuthorizationTimingEvidence.isComplete(mutant)
        }.count
        let values = state.update { $0 }
        guard !values.mutationFailed else { throw FixtureError.ownedFailure }
        let output: [String: Any] = [
            "outcome": outcome, "traceOutcome": report["outcome"]!, "phases": phases,
            "traceComplete": AuthorizationTimingEvidence.isComplete(phases),
            "missingEndMutantsAccepted": incompleteAccepted,
            "monotonic": zip(ticks, ticks.dropFirst()).allSatisfy { $0 <= $1 },
            "scopeStarts": values.starts, "scopeStops": values.stops, "operations": values.operations,
            "bookmarkResolutions": values.resolutions,
            "mutationPerformed": values.mutated, "droppedEvents": report["droppedEvents"]!
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self))
    }
}
