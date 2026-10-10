import Darwin
import Foundation
import QuickFileCore

// Stored properties are immutable, UserDefaults is thread-safe, and file mutations use flock.
public struct FinderExtensionActivityStore: @unchecked Sendable {
    public static let defaultMaximumFailureCount = 20
    public static let defaultFailureRetentionDays = 14

    public enum StoreError: LocalizedError, Equatable {
        case sharedDefaultsUnavailable

        public var errorDescription: String? {
            switch self {
            case .sharedDefaultsUnavailable:
                return "无法访问 QuickFile 的 Finder Extension 活动存储。"
            }
        }
    }

    private let defaults: UserDefaults?
    private let failureHistoryFileURL: URL?
    private let maximumFailureCount: Int
    private let failureRetentionInterval: TimeInterval
    private let activityKey = "finderExtension.latestActivity.v1"
    private let legacyFailureHistoryKey = "finderExtension.failureHistory.v1"

    public init() {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: QuickFileConfiguration.appGroupIdentifier
        )
        defaults = containerURL == nil
            ? nil
            : UserDefaults(suiteName: QuickFileConfiguration.appGroupIdentifier)
        failureHistoryFileURL = containerURL?.appendingPathComponent(
            "finderExtension.failureHistory.v1.json",
            isDirectory: false
        )
        maximumFailureCount = Self.defaultMaximumFailureCount
        failureRetentionInterval = TimeInterval(Self.defaultFailureRetentionDays * 24 * 60 * 60)
    }

    init(
        defaults: UserDefaults?,
        failureHistoryFileURL: URL?,
        maximumFailureCount: Int = FinderExtensionActivityStore.defaultMaximumFailureCount,
        failureRetentionDays: Int = FinderExtensionActivityStore.defaultFailureRetentionDays
    ) {
        self.defaults = defaults
        self.failureHistoryFileURL = failureHistoryFileURL
        self.maximumFailureCount = max(1, maximumFailureCount)
        failureRetentionInterval = TimeInterval(max(1, failureRetentionDays) * 24 * 60 * 60)
    }

    public var isAvailable: Bool {
        defaults != nil && failureHistoryFileURL != nil
    }

    // v2 is authoritative, including an empty initial state. The defaults value is only
    // imported once while holding the shared lock; old app/extension processes must exit.
    private struct LatestActivityState: Codable {
        let activity: FinderExtensionActivity?
    }

    public func latestActivity() -> FinderExtensionActivity? {
        try? withLockedFailureHistory { try loadLatestActivity(alongside: $0).activity }
    }

    private func latestActivityURL(alongside fileURL: URL) -> URL {
        fileURL.appendingPathExtension("latest-v2.json")
    }

    private func loadLatestActivity(alongside fileURL: URL) throws -> LatestActivityState {
        let latestURL = latestActivityURL(alongside: fileURL)
        if FileManager.default.fileExists(atPath: latestURL.path) {
            return try JSONDecoder().decode(LatestActivityState.self, from: Data(contentsOf: latestURL))
        }
        let legacyActivity = try defaults?.data(forKey: activityKey).map {
            try JSONDecoder().decode(FinderExtensionActivity.self, from: $0)
        }
        let state = LatestActivityState(activity: legacyActivity)
        try JSONEncoder().encode(state).write(to: latestURL, options: .atomic)
        defaults?.removeObject(forKey: activityKey)
        return state
    }

    public func recentFailures(referenceDate: Date = Date()) throws -> [FinderExtensionActivity] {
        let cutoffDate = referenceDate.addingTimeInterval(-failureRetentionInterval)

        return try withLockedFailureHistory { fileURL in
            let failureHistory = try loadFailureHistory(from: fileURL)
            var retainedFailures = failureHistory
                .filter { $0.failure != nil && $0.timestamp >= cutoffDate }
                .sorted { $0.timestamp < $1.timestamp }
            if retainedFailures.count > maximumFailureCount {
                retainedFailures.removeFirst(retainedFailures.count - maximumFailureCount)
            }

            if retainedFailures.count != failureHistory.count {
                try persistFailureHistory(retainedFailures, to: fileURL)
            }

            return retainedFailures.sorted { $0.timestamp > $1.timestamp }
        }
    }

    public func clearFailureHistory() throws {
        try withLockedFailureHistory { fileURL in
            try persistFailureHistory([], to: fileURL)
            defaults?.removeObject(forKey: legacyFailureHistoryKey)
        }
    }

    public func record(
        _ kind: FinderExtensionActivityKind,
        failure: FinderExtensionActivityFailure? = nil,
        at timestamp: Date = Date()
    ) throws {
        let activity = FinderExtensionActivity(kind: kind, timestamp: timestamp, failure: failure)
        try withLockedFailureHistory { fileURL in
            let latest: FinderExtensionActivity?
            do {
                latest = try loadLatestActivity(alongside: fileURL).activity
            } catch is DecodingError {
                // Only malformed latest-state data is replaceable. File and lock errors
                // must still reach the caller, and failure history keeps its own recovery.
                latest = nil
            }
            if latest.map({ timestamp >= $0.timestamp }) ?? true {
                try JSONEncoder().encode(LatestActivityState(activity: activity)).write(
                    to: latestActivityURL(alongside: fileURL), options: .atomic
                )
                defaults?.removeObject(forKey: activityKey)
            }
            guard failure != nil else { return }
            let cutoffDate = timestamp.addingTimeInterval(-failureRetentionInterval)
            var failureHistory = try loadFailureHistory(from: fileURL)
                .filter { $0.failure != nil && $0.timestamp >= cutoffDate }
            failureHistory.append(activity)
            failureHistory.sort { $0.timestamp < $1.timestamp }
            if failureHistory.count > maximumFailureCount {
                failureHistory.removeFirst(failureHistory.count - maximumFailureCount)
            }

            try persistFailureHistory(failureHistory, to: fileURL)
        }
    }

    private func withLockedFailureHistory<Result>(
        _ operation: (URL) throws -> Result
    ) throws -> Result {
        guard defaults != nil, let failureHistoryFileURL else {
            throw StoreError.sharedDefaultsUnavailable
        }

        let directoryURL = failureHistoryFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let lockURL = failureHistoryFileURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        defer { flock(descriptor, LOCK_UN) }

        return try operation(failureHistoryFileURL)
    }

    private func loadFailureHistory(from fileURL: URL) throws -> [FinderExtensionActivity] {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try JSONDecoder().decode(
                [FinderExtensionActivity].self,
                from: Data(contentsOf: fileURL)
            )
        }

        guard let legacyData = defaults?.data(forKey: legacyFailureHistoryKey) else {
            return []
        }

        let legacyHistory = try JSONDecoder().decode(
            [FinderExtensionActivity].self,
            from: legacyData
        )
        try persistFailureHistory(legacyHistory, to: fileURL)
        defaults?.removeObject(forKey: legacyFailureHistoryKey)
        return legacyHistory
    }

    private func persistFailureHistory(
        _ failureHistory: [FinderExtensionActivity],
        to fileURL: URL
    ) throws {
        try JSONEncoder().encode(failureHistory).write(to: fileURL, options: .atomic)
    }
}
