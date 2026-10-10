import Foundation
import Darwin
import QuickFileCore
@testable import QuickFileInfrastructure

/// Isolated CLI benchmark: generate the input in another process so fixture
/// construction cannot determine this process's peak RSS. No App Group or UI.
@main
enum FinderMenuDecode {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, ["full", "projected", "cached"].contains(arguments[1]),
              let expectedCount = Int(arguments[3]), expectedCount >= 0 else {
            throw NSError(domain: "FinderMenuDecode.Usage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "full|projected|cached <json-file> <enabled-count>"])
        }
        let mode = arguments[1]
        let url = URL(fileURLWithPath: arguments[2])
        let suite = "QuickFileInvestigation.MenuDecode.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Isolated defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let menuStore = mode == "cached"
            ? TemplateStore(defaults: defaults, storageURL: url, cachesReads: false, cachesMenuReads: true,
                            changeNotificationName: suite) : nil
        var durations: [Double] = []
        for _ in 0..<30 {
            try autoreleasepool {
                let start = DispatchTime.now().uptimeNanoseconds
                let store = menuStore ?? TemplateStore(defaults: defaults, storageURL: url, cachesReads: false,
                                                       changeNotificationName: suite)
                let entries = mode == "full"
                    ? FinderMenuModelBuilder().entries(from: try store.reloadTemplates())
                    : try store.reloadMenuEntries()
                precondition(entries.count == expectedCount)
                durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw POSIXError(.EIO) }
        let result: [String: Any] = [
            "mode": mode, "enabledCount": expectedCount,
            "inputBytes": try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            "iterations": durations.count, "medianMs": durations.sorted()[durations.count / 2],
            "warmMedianMs": durations.dropFirst().sorted()[durations.count / 2 - 1],
            "firstReadMs": durations[0], "durationsMs": durations,
            "peakRSSBytes": usage.ru_maxrss,
            "os": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
