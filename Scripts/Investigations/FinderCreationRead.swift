import Foundation
import Darwin
import QuickFileCore
@testable import QuickFileInfrastructure

/// Read-stage benchmark only: no App Group, UI, authorization or file creation.
/// Generate inputs in another process. Build without QUICKFILE_CREATION_PROJECTION
/// to measure the pre-change store; define it to compare both paths in one binary.
@main
enum FinderCreationRead {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5, ["full", "selected"].contains(args[1]),
              let count = Int(args[3]), let id = UUID(uuidString: args[4]) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let mode = args[1]
        let url = URL(fileURLWithPath: args[2])
        let suite = "QuickFileInvestigation.CreationRead.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let reads = ReadTimings()
        var durations: [Double] = []
        for _ in 0..<30 {
            try autoreleasepool {
                let start = DispatchTime.now().uptimeNanoseconds
                let store = TemplateStore(defaults: defaults, storageURL: url, cachesReads: false,
                                          changeNotificationName: suite, readTemplatesData: { url in
                    let start = DispatchTime.now().uptimeNanoseconds
                    let data = try Data(contentsOf: url)
                    reads.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                    return data
                })
                let template: FileTemplate?
                let entries: [FinderTemplateMenuEntry]
                #if QUICKFILE_CREATION_PROJECTION
                if mode == "selected" {
                    let snapshot = try store.reloadCreationSnapshot(templateID: id)
                    template = snapshot.template
                    entries = snapshot.menuEntries
                } else {
                    let all = try store.reloadTemplates()
                    entries = FinderMenuModelBuilder().entries(from: all)
                    template = all.first { $0.id == id && $0.isEnabled }
                }
                #else
                precondition(mode == "full")
                let all = try store.reloadTemplates()
                entries = FinderMenuModelBuilder().entries(from: all)
                template = all.first { $0.id == id && $0.isEnabled }
                #endif
                precondition(entries.count == count && template?.id == id && template?.content.utf8.count == 16_384)
                durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                withExtendedLifetime((template, entries)) {}
            }
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw POSIXError(.EIO) }
        let result: [String: Any] = [
            "mode": mode, "templateCount": count, "selectedID": id.uuidString,
            "inputBytes": try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            "iterations": durations.count, "medianMs": durations.sorted()[durations.count / 2],
            "firstReadMs": durations[0], "durationsMs": durations, "fileReadMs": reads.values,
            "peakRSSBytes": usage.ru_maxrss, "os": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}

// The injected store reader is Sendable; protect the measurement collector too.
private final class ReadTimings: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    func append(_ value: Double) { lock.lock(); defer { lock.unlock() }; samples.append(value) }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return samples }
}
