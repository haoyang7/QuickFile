import Foundation
@testable import QuickFileCore
@testable import QuickFileInfrastructure

// An isolated, non-UI cache fixture. No App Group, real bookmarks, creation,
// accessibility reads, input or installed application is involved.
// Compile the pre-change cache with -D QUICKFILE_BASELINE_FULL_TEMPLATE_CACHE.
@main
private struct FinderTemplateMemory {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let count = Int(arguments[2]), [8, 300].contains(count),
              let bodyBytes = Int(arguments[3]), (0...65_536).contains(bodyBytes) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let suite = "QuickFileInvestigation.FinderTemplateMemory.\(UUID().uuidString)"
        let notificationName = suite + ".changed"
        let storage = output.appendingPathComponent("templates.json")
        let makeStore: @Sendable () -> TemplateStore = {
            TemplateStore(defaults: UserDefaults(suiteName: suite), storageURL: storage,
                          changeNotificationName: notificationName)
        }
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try writeFixture(count: count, bodyBytes: bodyBytes, to: storage)
        try write(["suite": suite, "templateCount": count, "bodyBytes": bodyBytes,
                   "appGroupUsed": false, "noUIActions": true], to: output.appendingPathComponent("namespace.json"))

        let prepareStart = DispatchTime.now().uptimeNanoseconds
        #if QUICKFILE_BASELINE_FULL_TEMPLATE_CACHE
        let cache = FinderTemplateCache(templateStore: makeStore(), refreshInterval: 3600)
        #else
        let cache = FinderTemplateCache(
            loadForCreation: { try makeStore().reloadCreationSnapshot(templateID: $0) },
            loadMenuEntries: { try makeStore().reloadMenuEntries() },
            changeNotificationName: notificationName, refreshInterval: 3600
        )
        #endif
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !isReady(cache, count: count) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileReadUnknown) }
            Thread.sleep(forTimeInterval: 0.001)
        }
        let prepareMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - prepareStart) / 1_000_000
        try checkpoint("ready", output: output)
        var timings: [Double] = []
        for _ in 0..<30 {
            timings.append(try readForCreation(cache, count: count, bodyBytes: bodyBytes))
        }
        try write(["reloadMilliseconds": timings, "authoritativeReloads": timings.count,
                   "prepareMillisecondsIncludingPolling": prepareMilliseconds,
                   "noFileCreation": true], to: output.appendingPathComponent("timings.json"))
        try checkpoint("after-creation-reads", output: output)
        withExtendedLifetime(cache) {}
        try write(["completed": true], to: output.appendingPathComponent("completed.json"))
    }

    private static func writeFixture(count: Int, bodyBytes: Int, to storage: URL) throws {
        try autoreleasepool {
            let templates = (0..<count).map { index in
                FileTemplate(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
                    name: "Owned template \(index)", fileExtension: "txt",
                    content: bodyBytes == 0 ? "" : String(index) + String(repeating: "x", count: bodyBytes))
            }
            try JSONEncoder().encode(templates).write(to: storage, options: .atomic)
        }
    }

    private static func isReady(_ cache: FinderTemplateCache, count: Int) -> Bool {
        if case let .ready(entries) = cache.currentSnapshot() { return entries.count == count }
        return false
    }

    private static func readForCreation(_ cache: FinderTemplateCache, count: Int, bodyBytes: Int) throws -> Double {
        try autoreleasepool {
            let start = DispatchTime.now().uptimeNanoseconds
            #if QUICKFILE_BASELINE_FULL_TEMPLATE_CACHE
            let templates = try cache.templatesForCreation()
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            guard templates.count == count,
                  templates.enumerated().allSatisfy({ index, template in
                      template.content == (bodyBytes == 0 ? "" : String(index) + String(repeating: "x", count: bodyBytes))
                  }) else { throw CocoaError(.fileReadCorruptFile) }
            #else
            let index = count - 1
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", count))!
            let template = try cache.templateForCreation(id: id)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            guard template?.content == (bodyBytes == 0 ? "" : String(index) + String(repeating: "x", count: bodyBytes)),
                  cache.currentEntries().count == count else { throw CocoaError(.fileReadCorruptFile) }
            #endif
            return milliseconds
        }
    }

    private static func checkpoint(_ stage: String, output: URL) throws {
        try write(["checkpoint": stage, "pid": ProcessInfo.processInfo.processIdentifier],
                  to: output.appendingPathComponent("ready.json"))
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while !FileManager.default.fileExists(atPath: output.appendingPathComponent("continue-\(stage)").path) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.userCancelled) }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }
}
