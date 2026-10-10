import Foundation
@testable import QuickFileCore

private enum FixtureError: Error { case failed, timeout }

private func waitUntil(_ predicate: () throws -> Bool) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while try !predicate() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw FixtureError.timeout }
        Thread.sleep(forTimeInterval: 0.005)
    }
}

/// Owned directories only. No Finder, App Group, real bookmarks or input events.
@main
struct CreationBoundaryTimingCases {
    static func main() throws {
        let scenario = CommandLine.arguments[1]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUICKFILE_CREATION_TIMING_DIR"]!)
        let output: [String: Any]
        if scenario.hasPrefix("timing-") { output = try concurrentTiming(scenario, directory: directory) }
        else if scenario.hasPrefix("writer-") { output = try writer(scenario, root: root, directory: directory) }
        else { output = try preparation(scenario, root: root, directory: directory) }
        print(String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self))
    }

    private static func read(_ id: String, in directory: URL) throws -> [String: Any] {
        let url = directory.appendingPathComponent(id + ".json")
        try waitUntil { FileManager.default.fileExists(atPath: url.path) }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private static func concurrentTiming(_ scenario: String, directory: URL) throws -> [String: Any] {
        var reports: [[String: Any]] = []
        var ownersReleased = true
        for _ in 0..<16 {
            var timing = CreationTiming.begin("concurrent-fixture")
            weak var owner = timing
            let id = timing!.id
            recordConcurrentEvents(timing!, finishDuringMarks: scenario == "timing-finish-race")
            timing = nil
            CreationTiming.waitForPendingReports()
            ownersReleased = ownersReleased && owner == nil
            reports.append(try read(id, in: directory))
        }
        return ["traces": reports, "ownersReleased": ownersReleased,
                "reportCount": try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }.count]
    }

    private static func recordConcurrentEvents(_ timing: CreationTiming, finishDuringMarks: Bool) {
        DispatchQueue.concurrentPerform(iterations: 64) { worker in
            for _ in 0..<6 { timing.mark("parallel") }
            if finishDuringMarks && worker == 0 { timing.finish(outcome: "finished") }
        }
        timing.finish(outcome: "finished")
        timing.mark("after-finish")
        timing.finish(outcome: "duplicate-finish")
    }

    private static func writer(_ scenario: String, root: URL, directory: URL) throws -> [String: Any] {
        let manager = FileManager.default
        let target = root.appendingPathComponent("target", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        try manager.createDirectory(at: other, withIntermediateDirectories: false)
        var destination = target
        if scenario == "writer-non-file" { destination = URL(string: "https://example.invalid/owned")! }
        if scenario == "writer-missing" { destination = root.appendingPathComponent("missing") }
        if scenario == "writer-not-directory" {
            destination = root.appendingPathComponent("regular-file")
            try Data().write(to: destination)
        }
        let timing = CreationTiming.begin("writer-fixture")!
        let request = FileCreationRequest(template: FileTemplate(name: "Owned", fileExtension: "txt", content: "owned"),
            destinationFolder: destination, requestedFilename: nil,
            expectedDirectoryIdentity: scenario == "writer-identity-changed" ? try DirectoryIdentity.capture(at: other) : nil,
            timing: timing)
        let beforeCommit: (@Sendable (URL) throws -> Void)?
        if scenario == "writer-late-failure" { beforeCommit = { _ in throw FixtureError.failed } }
        else { beforeCommit = nil }
        let service = FileCreationService(beforeCommit: beforeCommit)
        var result = "created"
        do {
            let output = try service.createFile(for: request)
            guard try String(contentsOf: output.fileURL, encoding: .utf8) == "owned" else { throw FixtureError.failed }
        } catch FileCreationError.destinationIsNotFileURL { result = "not-file-url" }
        catch FileCreationError.destinationDoesNotExist { result = "missing" }
        catch FileCreationError.destinationIsNotDirectory { result = "not-directory" }
        catch FileCreationError.destinationIdentityChanged { result = "identity-changed" }
        catch FileCreationError.writeFailed { result = "write-failed" }
        timing.finish(outcome: result)
        CreationTiming.waitForPendingReports()
        let report = try read(timing.id, in: directory)
        let events = report["events"] as! [[String: Any]]
        let phases = events.map { $0["phase"] as! String }
        let indices = phases.indices.filter { phases[$0].hasPrefix("writer.preflight.") }
        let acceptedMutants = indices.filter { index in
            var mutant = phases; mutant.remove(at: index)
            return WriterPreflightTimingEvidence.isComplete(mutant)
        }.count
        return ["result": result, "trace": report,
                "preflightComplete": WriterPreflightTimingEvidence.isComplete(phases),
                "missingPhaseMutantsAccepted": acceptedMutants,
                "targetFiles": try manager.contentsOfDirectory(atPath: target.path).sorted()]
    }

    private static func preparation(_ scenario: String, root: URL, directory: URL) throws -> [String: Any] {
        let identity = try DirectoryIdentity.capture(at: root)
        let destination = FinderMenuDestination(folder: root, identity: identity)
        let selection = FinderMenuSelection(context: .container, targetedURL: root, selectedItemURLs: [])
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        var cache: FinderMenuDestinationCache? = FinderMenuDestinationCache(maximumConcurrentPreparations: 1) { _ in
            started.signal()
            guard release.wait(timeout: .now() + 5) == .success else { return nil }
            return scenario == "unavailable" ? nil : destination
        }
        weak let weakCache = cache
        let first = CreationTiming.begin("menu")!
        guard cache!.currentSnapshot(for: selection, timing: first) == .loading,
              started.wait(timeout: .now() + 5) == .success else { throw FixtureError.failed }
        let second = CreationTiming.begin("menu")!
        var snapshot: FinderMenuDestinationCache.Snapshot
        if scenario == "busy" {
            snapshot = cache!.currentSnapshot(for: FinderMenuSelection(context: .container,
                targetedURL: root.appendingPathComponent("other"), selectedItemURLs: []), timing: second)
        } else {
            snapshot = cache!.currentSnapshot(for: selection, timing: second)
        }
        if scenario == "invalidated" {
            cache!.invalidate(selection)
            cache!.invalidate(FinderMenuSelection(context: .toolbar, targetedURL: root, selectedItemURLs: []))
        }
        if scenario == "owner-ended" { cache = nil }
        release.signal()
        if let cache { try waitUntil { cache.activePreparationCount == 0 } }
        first.finish(outcome: "menu-returned")
        second.finish(outcome: "menu-returned")
        CreationTiming.waitForPendingReports()
        let firstReport = try read(first.id, in: directory)
        let firstEvents = firstReport["events"] as! [[String: Any]]
        let preparationID = firstEvents.first { $0["phase"] as? String == "menu.destination.preparation.link" }!["relatedID"] as! String
        let preparedReport = try read(preparationID, in: directory)
        var result: [String: Any] = ["firstMenu": firstReport, "secondMenu": try read(second.id, in: directory),
            "preparation": preparedReport, "secondWasBusy": snapshot == .busy, "ownerReleased": weakCache == nil]
        if scenario == "refresh" {
            let reopened = CreationTiming.begin("menu")!
            guard cache!.currentSnapshot(for: selection, timing: reopened) == .ready(destination),
                  started.wait(timeout: .now() + 5) == .success else { throw FixtureError.failed }
            reopened.finish(outcome: "menu-returned")
            CreationTiming.waitForPendingReports()
            result["reopenedMenu"] = try read(reopened.id, in: directory)
            release.signal()
            try waitUntil { cache!.activePreparationCount == 0 }
            var refreshReport: [String: Any]?
            try waitUntil {
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    where file.pathExtension == "json" {
                    let report = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                    if report["parentID"] as? String == reopened.id { refreshReport = report }
                }
                return refreshReport != nil
            }
            result["refreshPreparation"] = refreshReport
        }
        return result
    }
}
