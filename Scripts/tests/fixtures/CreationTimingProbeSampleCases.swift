import Foundation

@main
struct ProbeSampleCases {
    static func main() throws {
        let scenario = CommandLine.arguments[1]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("owned.txt")
        var ticks = [UInt64(100), 150, 9_000]
        var validationCalls = 0
        var cleanupCalls = 0
        let result = CreationTimingProbeSample.run(clock: { ticks.removeFirst() }, create: {
            if scenario == "creation-failure" { throw CocoaError(.fileWriteNoPermission) }
            try Data(scenario == "nonempty" ? [1] : []).write(to: output)
            return output
        }, validate: { url in
            validationCalls += 1
            if scenario == "read-failure" { throw CocoaError(.fileReadNoPermission) }
            try CreationTimingProbeSample.validateEmptyOutput(url)
        }, cleanup: { url in
            cleanupCalls += 1
            if scenario == "cleanup-failure" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        let report: [String: Any] = [
            "measurements": [result.measurement(sample: 0, traceID: "owned-trace")],
            "traceOutcome": result.traceOutcome, "validationCalls": validationCalls,
            "cleanupCalls": cleanupCalls, "remainingTicks": ticks.count,
            "outputExists": FileManager.default.fileExists(atPath: output.path)
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
    }
}
