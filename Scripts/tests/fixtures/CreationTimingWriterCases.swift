import Foundation

private enum FixtureError: Error { case timeout, failed }

/// Mutable fixture counters are shared only under this lock. Semaphores control
/// the injected writer; no real Finder, bookmarks, input or user paths are used.
private final class WriterGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var encodes = 0
    private var receipts = 0

    func didEncode() { lock.lock(); encodes += 1; lock.unlock() }
    var encodeCount: Int { lock.lock(); defer { lock.unlock() }; return encodes }
    func didStartReceipt() -> Bool {
        lock.lock(); defer { lock.unlock() }
        receipts += 1
        return receipts == 1
    }
}

@main
struct CreationTimingWriterCases {
    static func main() throws {
        let scenario = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let gate = WriterGate()
        defer { gate.release.signal() }
        let writer = CreationTimingJSONWriter(directory: directory, maximumPendingReports: 2) { data, url in
            if url.deletingLastPathComponent().lastPathComponent == "receipts",
               gate.didStartReceipt(), scenario == "receipt-concurrency" {
                gate.entered.signal()
                guard gate.release.wait(timeout: .now() + 10) == .success else { throw FixtureError.timeout }
            }
            if scenario == "overflow" && url.lastPathComponent == "first.json" {
                gate.entered.signal()
                guard gate.release.wait(timeout: .now() + 10) == .success else { throw FixtureError.timeout }
            }
            if scenario == "write-failure" && url.lastPathComponent == "first.json" { throw FixtureError.failed }
            if scenario == "receipt-failure" && url.deletingLastPathComponent().lastPathComponent == "receipts" {
                throw FixtureError.failed
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        func submit(_ id: String) -> Bool {
            writer.submit(id: id) { delivery in
                gate.didEncode()
                if scenario == "encode-failure" { throw FixtureError.failed }
                return try JSONSerialization.data(withJSONObject: [
                    "id": id, "pid": ProcessInfo.processInfo.processIdentifier,
                    "delivery": ["sessionID": delivery.sessionID, "sequence": delivery.sequence]
                ])
            }
        }
        guard submit("first") else { throw FixtureError.failed }
        var accepted = 1
        var rejected = 0
        var pendingWhileBlocked: Int?
        var encodedWhileBlocked: Int?
        if scenario == "receipt-concurrency" {
            let drains = DispatchGroup()
            drains.enter()
            DispatchQueue.global().async { writer.waitForPendingReports(); drains.leave() }
            guard gate.entered.wait(timeout: .now() + 5) == .success else { throw FixtureError.timeout }
            if submit("second") { accepted += 1 }
            if submit("third") { accepted += 1 }
            for index in 0..<1024 {
                if submit("rejected-\(index)") { accepted += 1 } else { rejected += 1 }
            }
            pendingWhileBlocked = writer.pendingReportCount
            encodedWhileBlocked = gate.encodeCount
            let started = DispatchSemaphore(value: 0)
            for _ in 0..<8 {
                drains.enter()
                DispatchQueue.global().async {
                    started.signal()
                    writer.waitForPendingReports()
                    drains.leave()
                }
            }
            for _ in 0..<8 {
                guard started.wait(timeout: .now() + 5) == .success else { throw FixtureError.timeout }
            }
            gate.release.signal()
            guard drains.wait(timeout: .now() + 5) == .success else { throw FixtureError.timeout }
        } else if scenario == "overflow" {
            guard gate.entered.wait(timeout: .now() + 5) == .success else { throw FixtureError.timeout }
            if submit("second") { accepted += 1 }
            for index in 0..<1024 {
                if submit("rejected-\(index)") { accepted += 1 } else { rejected += 1 }
            }
            pendingWhileBlocked = writer.pendingReportCount
            encodedWhileBlocked = gate.encodeCount
            gate.release.signal()
        }
        if scenario == "unclosed" {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while writer.pendingReportCount != 0 {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw FixtureError.timeout }
                Thread.sleep(forTimeInterval: 0.001)
            }
        } else {
            writer.waitForPendingReports()
        }
        let encodedAfterFirstSession = gate.encodeCount
        if scenario == "overflow" || scenario == "rotation" {
            guard submit("next-session") else { throw FixtureError.failed }
            writer.waitForPendingReports()
        }
        // Empty repeated drains must not manufacture extra receipt sessions.
        if scenario != "unclosed" { writer.waitForPendingReports() }
        var output: [String: Any] = ["accepted": accepted, "rejected": rejected,
                                     "pendingAfterDrain": writer.pendingReportCount,
                                     "encodedAfterFirstSession": encodedAfterFirstSession]
        if let pendingWhileBlocked { output["pendingWhileBlocked"] = pendingWhileBlocked }
        if let encodedWhileBlocked { output["encodedWhileBlocked"] = encodedWhileBlocked }
        print(String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self))
    }
}
