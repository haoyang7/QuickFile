import Foundation
import Darwin
import os

/// One bounded JSON sink per process. The lock owns admission and all counters;
/// the serial queue owns encoding and I/O. No filesystem work or capacity wait
/// occurs during submit. Only the explicit investigation drain may block.
final class CreationTimingJSONWriter: @unchecked Sendable {
    struct Delivery: Codable, Sendable {
        let sessionID: String
        let sequence: UInt64
    }
    private struct Session {
        var acceptedReports: UInt64 = 0
        var writtenReports: UInt64 = 0
        var droppedReports: UInt64 = 0
        var failedReports: UInt64 = 0
    }
    private struct Receipt: Encodable {
        let schemaVersion = 1
        let sessionID: String
        let pid: Int32
        let closed = true
        let acceptedReports: UInt64
        let writtenReports: UInt64
        let droppedReports: UInt64
        let failedReports: UInt64
    }

    private let directory: URL
    private let maximumPendingReports: Int
    private let queue = DispatchQueue(label: "com.haoyoung.QuickFile.timing-output", qos: .utility)
    private let lock = NSLock()
    private let drainLock = NSLock()
    private let write: @Sendable (Data, URL) throws -> Void
    private var pending = 0
    private var currentSessionID: String?
    private var sessions: [String: Session] = [:]

    init(directory: URL, maximumPendingReports: Int = 32,
         write: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
             try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
             try data.write(to: url, options: .atomic)
         }) {
        precondition((1...32).contains(maximumPendingReports))
        self.directory = directory
        self.maximumPendingReports = maximumPendingReports
        self.write = write
    }

    @discardableResult
    func submit(id: String, encode: @escaping @Sendable (Delivery) throws -> Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let sessionID = currentSessionID ?? UUID().uuidString
        currentSessionID = sessionID
        var session = sessions[sessionID] ?? Session()
        guard pending < maximumPendingReports else {
            session.droppedReports += 1
            sessions[sessionID] = session
            return false
        }
        session.acceptedReports += 1
        sessions[sessionID] = session
        let delivery = Delivery(sessionID: sessionID, sequence: session.acceptedReports)
        pending += 1
        // Queue submission shares the admission lock with sealing, so a receipt
        // cannot overtake an accepted report. The active writer keeps its slot.
        queue.async {
            let succeeded: Bool
            do {
                try self.write(encode(delivery), self.directory.appendingPathComponent(id + ".json"))
                succeeded = true
            } catch { succeeded = false }
            self.lock.lock()
            if succeeded { self.sessions[sessionID]!.writtenReports += 1 }
            else { self.sessions[sessionID]!.failedReports += 1 }
            self.pending -= 1
            self.lock.unlock()
        }
        return true
    }

    /// Seals this session permanently, then persists its final counters. New
    /// submissions use a new UUID. A missing/failed receipt is invalid evidence;
    /// live or crashed sessions never have a stale clean receipt to reuse.
    func waitForPendingReports() {
        // At most one receipt closure can wait behind the bounded reports, even
        // if several investigation callers try to drain concurrently.
        drainLock.lock(); defer { drainLock.unlock() }
        lock.lock()
        if let sessionID = currentSessionID {
            currentSessionID = nil
            queue.async {
                self.lock.lock()
                let session = self.sessions.removeValue(forKey: sessionID)!
                self.lock.unlock()
                let receipt = Receipt(sessionID: sessionID, pid: ProcessInfo.processInfo.processIdentifier,
                                      acceptedReports: session.acceptedReports, writtenReports: session.writtenReports,
                                      droppedReports: session.droppedReports, failedReports: session.failedReports)
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    try self.write(encoder.encode(receipt), self.directory.appendingPathComponent("receipts", isDirectory: true)
                        .appendingPathComponent(sessionID + ".json"))
                } catch {
                    // No successful receipt is ever published for this session.
                    // Validators treat absence as failure, independently of logs.
                }
            }
        }
        lock.unlock()
        queue.sync {}
    }

    // Deterministic owned-fixture inspection; includes the currently active I/O.
    var pendingReportCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }
}

/// Opt-in investigation timestamps. Never contains paths, filenames, templates or bookmarks.
/// Normally nil: build with QUICKFILE_CREATION_TIMING and record Points of Interest,
/// or explicitly set QUICKFILE_CREATION_TIMING_DIR for a controlled local run. JSON encoding/I/O happen
/// after the measured path on a separate queue; logging failures cannot fail creation.
/// JSON admits at most 32 pending reports, including active I/O. A controlled
/// capture must drain explicitly and retain its receipt to establish lossless
/// delivery; undrained/live sessions are deliberately incomplete evidence.
public final class CreationTiming: @unchecked Sendable {
    private struct Stamp: Codable, Sendable {
        let phase: String
        let uptimeNS: UInt64
        let relatedID: String?
    }
    private struct Report: Codable, Sendable {
        let id: String
        let kind: String
        let parentID: String?
        let clockAnchor: ClockAnchor
        let pid: Int32
        let outcome: String
        let droppedEvents: Int
        let events: [Stamp]
        var delivery: CreationTimingJSONWriter.Delivery?
    }
    /// Bracket the native input recorder's mach clock with the report's uptime clock.
    /// Consumers retain this uncertainty interval rather than assuming an exact offset.
    private struct ClockAnchor: Codable, Sendable {
        let uptimeBeforeNS: UInt64
        let machTimeTicks: UInt64
        let uptimeAfterNS: UInt64
        let numerator: UInt32
        let denominator: UInt32

        init() {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            numerator = timebase.numer
            denominator = timebase.denom
            uptimeBeforeNS = DispatchTime.now().uptimeNanoseconds
            machTimeTicks = mach_absolute_time()
            uptimeAfterNS = DispatchTime.now().uptimeNanoseconds
        }
    }
    private static let log = OSLog(subsystem: "com.haoyoung.QuickFile", category: .pointsOfInterest)
    private static let directory: URL? = {
        guard let path = ProcessInfo.processInfo.environment["QUICKFILE_CREATION_TIMING_DIR"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()
    private static let writer: CreationTimingJSONWriter? = directory.map { CreationTimingJSONWriter(directory: $0) }
    private static let requested: Bool = {
        #if QUICKFILE_CREATION_TIMING
        return true
        #else
        return directory != nil || ProcessInfo.processInfo.environment["QUICKFILE_CREATION_TIMING"] == "1"
        #endif
    }()
    public let id = UUID().uuidString
    private let kind: String
    private let parentID: String?
    private let clockAnchor: ClockAnchor
    private let signpostID: OSSignpostID
    private let signposts: Bool
    private let lock = NSLock()
    private var events: [Stamp] = []
    private var droppedEvents = 0
    private var finished = false

    public static func begin(_ kind: String = "creation", parentID: String? = nil) -> CreationTiming? {
        guard requested else { return nil }
        // Use one output path. Duplicating each event to OSLog during a JSON probe
        // measurably perturbs the short authorization/write intervals.
        let signposts = directory == nil && log.signpostsEnabled
        guard signposts || directory != nil else { return nil }
        return CreationTiming(kind: kind, parentID: parentID, signposts: signposts)
    }

    private init(kind: String, parentID: String?, signposts: Bool) {
        self.kind = kind
        self.parentID = parentID
        clockAnchor = ClockAnchor()
        self.signposts = signposts
        signpostID = OSSignpostID(log: Self.log)
        if signposts {
            os_signpost(.begin, log: Self.log, name: "QuickFileOperation", signpostID: signpostID,
                        "id=%{public}@ kind=%{public}@ parent=%{public}@", id as NSString, kind as NSString,
                        (parentID ?? "") as NSString)
            os_signpost(.event, log: Self.log, name: "QuickFileClockAnchor", signpostID: signpostID,
                        "id=%{public}@ before=%{public}llu mach=%{public}llu after=%{public}llu numer=%{public}u denom=%{public}u",
                        id as NSString, clockAnchor.uptimeBeforeNS, clockAnchor.machTimeTicks,
                        clockAnchor.uptimeAfterNS, clockAnchor.numerator, clockAnchor.denominator)
        }
        mark("begin")
    }

    /// Links contain only trace UUIDs, never destination or template identifiers.
    public func mark(_ phase: StaticString, relatedID: String? = nil) {
        // Serialize capture and delivery with finish, including signpost-only runs.
        // A timestamp captured before waiting for the lock can invert report order.
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        let timestamp = DispatchTime.now().uptimeNanoseconds
        let name = String(describing: phase)
        if signposts {
            os_signpost(.event, log: Self.log, name: "QuickFilePhase", signpostID: signpostID,
                        "id=%{public}@ phase=%{public}@ uptime=%{public}llu related=%{public}@",
                        id as NSString, name as NSString, timestamp, (relatedID ?? "") as NSString)
        }
        guard Self.directory != nil else { return }
        if events.count < 512 { events.append(Stamp(phase: name, uptimeNS: timestamp, relatedID: relatedID)) }
        else { droppedEvents += 1 }
    }

    /// "reveal-returned" is only the return of NSWorkspace's request. A separate
    /// Finder observation must establish the actual visible/selected endpoint.
    public func finish(outcome: String) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let endUptimeNS = DispatchTime.now().uptimeNanoseconds
        if events.count < 512 { events.append(Stamp(phase: "end", uptimeNS: endUptimeNS, relatedID: nil)) }
        else { droppedEvents += 1 }
        finished = true
        let report = Report(id: id, kind: kind, parentID: parentID, clockAnchor: clockAnchor,
                            pid: ProcessInfo.processInfo.processIdentifier,
                            outcome: outcome, droppedEvents: droppedEvents, events: events, delivery: nil)
        lock.unlock()
        if signposts {
            os_signpost(.end, log: Self.log, name: "QuickFileOperation", signpostID: signpostID,
                        "id=%{public}@ outcome=%{public}@ uptime=%{public}llu",
                        id as NSString, outcome as NSString, endUptimeNS)
        }
        guard let writer = Self.writer else { return }
        writer.submit(id: report.id) { delivery in
            var deliveredReport = report
            deliveredReport.delivery = delivery
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(deliveredReport)
        }
    }

    // Investigation tools must distinguish intentionally disabled tracing from a
    // requested sink that was unavailable. This does not change creation behavior.
    static var isRequested: Bool { requested }

    // Seals the current JSON session outside the measured span. Callers must
    // still verify both expected reports and the matching persistent receipt.
    static func waitForPendingReports() { writer?.waitForPendingReports() }
}
