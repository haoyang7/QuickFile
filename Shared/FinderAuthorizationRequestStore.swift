import Darwin
import Foundation
import QuickFileCore

// A stable flock serializes producers, consumers, and one-time defaults migration across processes.
// Store fields are immutable; queue files and the migration marker are authoritative.
// Transient pinned snapshots have process-wide admission and never cache queue state.
public struct FinderAuthorizationRequestStore: @unchecked Sendable {
    public static let defaultRetentionInterval: TimeInterval = 10 * 60
    // Admission bounds new queue files. Oversized pre-upgrade queues and the one
    // legacy defaults entry are preserved until consumed, never evicted to fit.
    public static let maximumPendingRequests = 64
    // A request contains only IDs, a timestamp and one path, never template bodies.
    // Bound actual reads as well as new writes; oversized existing files are retained.
    public static let maximumRequestBytes = 64 * 1024
    // Raw defaults migration gets a separate, finite 256 KiB parsing budget: four
    // times the canonical claim budget allows historical JSON overhead, including
    // whitespace and unknown fields, without unbounded decode/re-encode work.
    // UserDefaults has already materialized Data; this cannot bound that allocation.
    // Larger originals stay untouched in defaults, even when queue slots are free.
    public static let maximumLegacyInputBytes = 256 * 1024
    public static let didSaveRequestNotification = Notification.Name(
        "com.haoyoung.QuickFile.finderAuthorizationRequestSaved"
    )

    public enum StoreError: LocalizedError {
        case sharedStoreUnavailable
        case persistenceFailed(Error)
        case queueFull
        case requestTooLarge

        public var errorDescription: String? {
            switch self {
            case .sharedStoreUnavailable:
                return "无法访问 QuickFile 的快捷授权请求。"
            case .queueFull:
                return "Finder 的快捷授权请求已达上限（64 个），请先处理待办请求后重试。"
            case .requestTooLarge:
                return "Finder 的快捷授权请求超过大小上限，请从 Finder 重新发起。"
            case .persistenceFailed:
                return "无法保存或读取 Finder 的快捷授权请求。"
            }
        }
    }

    private let defaults: UserDefaults?
    private let directoryURL: URL?
    private let fileManager: FileManager
    private let retentionInterval: TimeInterval
    private let readRequestData: (URL) throws -> Data
    private let decodeLegacyRequest: (Data) throws -> FinderAuthorizationRequest
    private let readPinnedRequestData: (Int32, URL) throws -> Data
    private let currentDate: () -> Date
    private let usesPinnedReads: Bool
    private let recoveryArchiveName: () -> String
    private let recoveryCheckpoint: ((RecoveryCheckpoint) throws -> Void)?
    // Per process, across all store instances/directories. Admission never waits while
    // holding flock. A stalled synchronous read keeps its slot until it actually ends.
    static let maximumConcurrentSnapshots = 2
    static let maximumSnapshotAttempts = 2
    private static let snapshotAdmission = DispatchSemaphore(value: maximumConcurrentSnapshots)
    private let legacyRequestKey = "finderAuthorizationRequest.v1"

    public init() {
        fileManager = .default
        defaults = UserDefaults(suiteName: QuickFileConfiguration.appGroupIdentifier)
        directoryURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: QuickFileConfiguration.appGroupIdentifier
        )?.appendingPathComponent("finder-authorization-requests", isDirectory: true)
        retentionInterval = Self.defaultRetentionInterval
        readRequestData = { try Self.readBoundedRequest(at: $0) }
        decodeLegacyRequest = { try JSONDecoder().decode(FinderAuthorizationRequest.self, from: $0) }
        readPinnedRequestData = { descriptor, _ in try Self.readBoundedRequest(descriptor: descriptor) }
        currentDate = Date.init
        usesPinnedReads = true
        recoveryArchiveName = { UUID().uuidString }
        recoveryCheckpoint = nil
    }

    init(
        defaults: UserDefaults?,
        directoryURL: URL?,
        fileManager: FileManager = .default,
        retentionInterval: TimeInterval = FinderAuthorizationRequestStore.defaultRetentionInterval,
        readRequestData: ((URL) throws -> Data)? = nil,
        decodeLegacyRequest: @escaping (Data) throws -> FinderAuthorizationRequest = {
            try JSONDecoder().decode(FinderAuthorizationRequest.self, from: $0)
        },
        readPinnedRequestData: @escaping (Int32, URL) throws -> Data = { descriptor, _ in
            try FinderAuthorizationRequestStore.readBoundedRequest(descriptor: descriptor)
        },
        currentDate: @escaping () -> Date = Date.init,
        recoveryArchiveName: @escaping () -> String = { UUID().uuidString },
        recoveryCheckpoint: ((RecoveryCheckpoint) throws -> Void)? = nil
    ) {
        self.defaults = defaults
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.retentionInterval = max(0, retentionInterval)
        self.readRequestData = readRequestData ?? { try Self.readBoundedRequest(at: $0) }
        self.decodeLegacyRequest = decodeLegacyRequest
        self.readPinnedRequestData = readPinnedRequestData
        self.currentDate = currentDate
        self.recoveryArchiveName = recoveryArchiveName
        self.recoveryCheckpoint = recoveryCheckpoint
        // A URL-reader override retains the original locked test/fault-injection path.
        // Production and pinned-reader tests always read the already-open descriptor.
        usesPinnedReads = readRequestData == nil
    }

    public func save(_ request: FinderAuthorizationRequest, referenceDate: Date? = nil) throws {
        guard directoryURL != nil else {
            throw StoreError.sharedStoreUnavailable
        }

        do {
            let data = try Self.encodeBoundedRequest(request)
            try withLockedQueue { try persist(request, in: $0, referenceDate: referenceDate ?? currentDate(), encoded: data) }
        } catch StoreError.requestTooLarge {
            throw StoreError.requestTooLarge
        } catch StoreError.queueFull {
            throw StoreError.queueFull
        } catch {
            throw StoreError.persistenceFailed(error)
        }
    }

    private static func encodeBoundedRequest(_ request: FinderAuthorizationRequest) throws -> Data {
        // Bound encoder input first, then account for JSON escaping and metadata.
        guard request.destinationFolderPath.utf8.prefix(maximumRequestBytes + 1).count
                <= maximumRequestBytes else { throw StoreError.requestTooLarge }
        let data = try JSONEncoder().encode(request)
        guard data.count <= maximumRequestBytes else { throw StoreError.requestTooLarge }
        return data
    }

    private func persist(
        _ request: FinderAuthorizationRequest, in directoryURL: URL, referenceDate: Date,
        encoded: Data? = nil
    ) throws {
        let fileURL = directoryURL.appendingPathComponent("\(request.id.uuidString).json")
        let files = try requestFiles(in: directoryURL)
        // These entries were enumerated from the same locked directory. Compare
        // exact filenames: equivalent filesystem URLs can retain different bases
        // or aliases, while case-folding could conflate two case-sensitive entries.
        // Re-saving an existing ID replaces its one entry and needs no new slot.
        if !files.contains(where: { $0.lastPathComponent == fileURL.lastPathComponent }) {
            var retainedCount = files.count
            if retainedCount >= Self.maximumPendingRequests {
                for existingURL in files {
                    // Admission may prune only readable, decoded, expired requests.
                    // Future, unreadable, malformed, and unremovable files keep their
                    // slots; takePendingRequest retains its existing fault semantics.
                    guard let data = try? readRequestData(existingURL),
                          let existing = try? JSONDecoder().decode(FinderAuthorizationRequest.self, from: data),
                          referenceDate.timeIntervalSince(existing.createdAt) > retentionInterval else { continue }
                    do {
                        try fileManager.removeItem(at: existingURL)
                        retainedCount -= 1
                    } catch {
                        continue
                    }
                }
            }
            guard retainedCount < Self.maximumPendingRequests else { throw StoreError.queueFull }
        }
        try (encoded ?? JSONEncoder().encode(request)).write(to: fileURL, options: .atomic)
    }

    /// O_NONBLOCK avoids waiting for a FIFO open; regular files still may have slow
    /// underlying I/O. A byte budget does not make that I/O cancellable.
    static func readBoundedRequest(at url: URL, maximumBytes: Int = maximumRequestBytes) throws -> Data {
        precondition(maximumBytes >= 0 && maximumBytes < Int.max)
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        return try readBoundedRequest(descriptor: descriptor, maximumBytes: maximumBytes)
    }

    // Does not own/close the descriptor. The snapshot retains it through final validation.
    static func readBoundedRequest(descriptor: Int32, maximumBytes: Int = maximumRequestBytes) throws -> Data {
        precondition(maximumBytes >= 0 && maximumBytes < Int.max)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        guard metadata.st_size >= 0, metadata.st_size <= Int64(maximumBytes) else {
            throw StoreError.requestTooLarge
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(4096, maximumBytes + 1))
        while data.count <= maximumBytes {
            let capacity = min(buffer.count, maximumBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, capacity)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumBytes else { throw StoreError.requestTooLarge }
        return data
    }

    private func requestFiles(in directoryURL: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ).filter {
            $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
        }
    }

    /// Only call after acquiring the app's request-processing state. Busy callers leave the queue intact.
    /// Claims healthy entries before reporting per-file errors; unreadable or unremovable entries
    /// remain queued for a later activation. Raw-oversized legacy input is retained without
    /// blocking healthy files. Other queue-wide and migration failures still abort the take.
    public func takePendingRequest(referenceDate: Date? = nil) throws -> FinderAuthorizationRequest? {
        guard directoryURL != nil else {
            throw StoreError.sharedStoreUnavailable
        }
        do {
            if usesPinnedReads, Self.snapshotAdmission.wait(timeout: .now()) == .success {
                defer { Self.snapshotAdmission.signal() }
                for _ in 0..<Self.maximumSnapshotAttempts {
                    switch try takePinnedSnapshot(referenceDate: referenceDate) {
                    case .completed(let request): return request
                    case .changed: continue
                    case .fallback: return try takeWithLockedPayloads(referenceDate: referenceDate)
                    }
                }
                // Active writers cannot force an unbounded decode/retry loop.
                return try takeWithLockedPayloads(referenceDate: referenceDate)
            }
            return try takeWithLockedPayloads(referenceDate: referenceDate)
        } catch {
            throw StoreError.persistenceFailed(error)
        }
    }

    private typealias PendingRequest = (request: FinderAuthorizationRequest, fileURL: URL?)

    private func takeWithLockedPayloads(referenceDate: Date?) throws -> FinderAuthorizationRequest? {
        try withLockedQueue { directoryURL in
            let migration = try migrateLegacyRequest(
                in: directoryURL, referenceDate: referenceDate ?? currentDate()
            )
            let files = try requestFiles(in: directoryURL)
            var pending: [PendingRequest] = []
            var retainedError: Error?
            // A pre-upgrade full queue must still drain. Keep the legacy entry
            // in defaults until it can migrate or wins the same oldest-first
            // claim order, without ever creating a 65th queue file.
            switch migration {
            case .finished:
                break
            case .retainedOversizedInput:
                retainedError = StoreError.requestTooLarge
            case .deferred(let deferredLegacy):
                do {
                    // This in-memory claim bypasses the bounded file reader. Apply the
                    // same serialized budget before age checks: oversized legacy data
                    // must remain in defaults until it can migrate to a retained file,
                    // even when expired or future-dated. Healthy entries still drain.
                    _ = try Self.encodeBoundedRequest(deferredLegacy)
                    let age = (referenceDate ?? currentDate()).timeIntervalSince(deferredLegacy.createdAt)
                    if age > retentionInterval {
                        try finishLegacyMigration(in: directoryURL)
                    } else if age >= 0 {
                        pending.append((deferredLegacy, nil))
                    }
                } catch StoreError.requestTooLarge {
                    retainedError = StoreError.requestTooLarge
                }
            }
            for fileURL in files {
                do {
                    // I/O failures say nothing about payload validity. Preserve unreadable
                    // files, but do not let one faulty entry block healthy queued requests.
                    let data = try readRequestData(fileURL)
                    let request: FinderAuthorizationRequest
                    do {
                        request = try JSONDecoder().decode(
                            FinderAuthorizationRequest.self,
                            from: data
                        )
                    } catch {
                        // Only successfully-read malformed payloads may be discarded.
                        // A cleanup failure is also isolated to this entry.
                        try fileManager.removeItem(at: fileURL)
                        throw error
                    }
                    // Evaluate age at consumption time unless a caller supplies a fixed reference.
                    let age = (referenceDate ?? currentDate()).timeIntervalSince(request.createdAt)
                    // A clock adjustment must not destroy a request that can become eligible later.
                    if age < 0 { continue }
                    if age > retentionInterval {
                        try fileManager.removeItem(at: fileURL)
                    } else {
                        pending.append((request, fileURL))
                    }
                } catch {
                    if retainedError == nil { retainedError = error }
                }
            }

            return try claimPending(pending, retainedError: retainedError,
                in: directoryURL, referenceDate: referenceDate)
        }
    }

    // Both paths commit at most one claim under flock. Sample age immediately
    // before each removal attempt: another read or failed removal may have stalled.
    // Once unlink succeeds the claim is committed; no post-unlink clock guarantee
    // is possible, and a backward clock jump must not discard that committed result.
    private func claimPending(
        _ pending: [PendingRequest], retainedError initialError: Error?,
        in directoryURL: URL, referenceDate: Date?
    ) throws -> FinderAuthorizationRequest? {
        var retainedError = initialError
        let ordered = pending.sorted {
            if $0.request.createdAt == $1.request.createdAt {
                return $0.request.id.uuidString < $1.request.id.uuidString
            }
            return $0.request.createdAt < $1.request.createdAt
        }
        for next in ordered {
            let age = (referenceDate ?? currentDate()).timeIntervalSince(next.request.createdAt)
            if age < 0 { continue }
            guard let fileURL = next.fileURL else {
                // Legacy completion failures remain queue-wide migration failures.
                try finishLegacyMigration(in: directoryURL)
                if age <= retentionInterval { return next.request }
                continue
            }
            do {
                // Removal is the claim commit. Never return a failed removal or a
                // now-expired request; attempt each entry only once in this take.
                try fileManager.removeItem(at: fileURL)
                if age <= retentionInterval { return next.request }
            } catch {
                if retainedError == nil { retainedError = error }
            }
        }
        if let retainedError { throw retainedError }
        return nil
    }

    private enum SnapshotAttempt {
        case completed(FinderAuthorizationRequest?)
        case changed
        case fallback
    }

    private enum Payload {
        case decoded(FinderAuthorizationRequest)
        case malformed(Error)
        case unreadable(Error)
    }

    // Holding the original descriptor prevents inode reuse from turning a replaced
    // pathname into a false match. Metadata is an extra conservative check, not a
    // protocol for concurrent in-place writes: supported writers use flock + atomic
    // replacement, including build 43, with no new marker/version/cache required.
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let generation: UInt32
        let size: off_t
        let links: nlink_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init?(_ metadata: stat) {
            guard metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_ino != 0 else { return nil }
            device = metadata.st_dev
            inode = metadata.st_ino
            generation = metadata.st_gen
            size = metadata.st_size
            links = metadata.st_nlink
            modifiedSeconds = metadata.st_mtimespec.tv_sec
            modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
            changedSeconds = metadata.st_ctimespec.tv_sec
            changedNanoseconds = metadata.st_ctimespec.tv_nsec
        }
    }

    private struct PinnedFile {
        let url: URL
        let descriptor: Int32
        let identity: FileIdentity
    }

    private func pinSnapshot(in directoryURL: URL) throws -> [PinnedFile]? {
        guard fileManager.fileExists(atPath: directoryURL.appendingPathComponent(".legacy-v1-migrated").path)
        else { return nil }
        let files = try requestFiles(in: directoryURL)
        guard files.count <= Self.maximumPendingRequests else { return nil }
        var pinned: [PinnedFile] = []
        var keepDescriptors = false
        defer { if !keepDescriptors { for file in pinned { close(file.descriptor) } } }
        for url in files {
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { return nil }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_nlink == 1,
                  let identity = FileIdentity(metadata) else {
                close(descriptor)
                return nil
            }
            pinned.append(PinnedFile(url: url, descriptor: descriptor, identity: identity))
        }
        keepDescriptors = true
        return pinned
    }

    private func takePinnedSnapshot(referenceDate: Date?) throws -> SnapshotAttempt {
        guard let pinned = try withLockedQueue({ try pinSnapshot(in: $0) }) else { return .fallback }
        defer { for file in pinned { close(file.descriptor) } }
        // All payload reads and JSON decoding are outside flock. Each normal-case
        // attempt is bounded by 64 files x 64 KiB, but has no I/O time guarantee.
        let payloads: [Payload] = pinned.map { file in
            do {
                let data = try readPinnedRequestData(file.descriptor, file.url)
                do { return .decoded(try JSONDecoder().decode(FinderAuthorizationRequest.self, from: data)) }
                catch { return .malformed(error) }
            } catch { return .unreadable(error) }
        }
        return try withLockedQueue { directoryURL in
            guard fileManager.fileExists(atPath: directoryURL.appendingPathComponent(".legacy-v1-migrated").path)
            else { return .fallback }
            let files = try requestFiles(in: directoryURL)
            guard files.count <= Self.maximumPendingRequests else { return .fallback }
            let names = Set(files.map(\.lastPathComponent))
            guard names.count == files.count,
                  names == Set(pinned.map { $0.url.lastPathComponent }) else { return .changed }
            // Validate the whole filename -> original object mapping before ANY
            // cleanup or claim, including nonwinners, malformed and expired files.
            // An older insertion or replacement must invalidate the entire decision.
            for file in pinned {
                var named = stat()
                var opened = stat()
                guard lstat(file.url.path, &named) == 0,
                      fstat(file.descriptor, &opened) == 0,
                      let namedIdentity = FileIdentity(named),
                      let openedIdentity = FileIdentity(opened) else { return .fallback }
                guard namedIdentity == file.identity, openedIdentity == file.identity else { return .changed }
            }
            var pending: [PendingRequest] = []
            var retainedError: Error?
            for (file, payload) in zip(pinned, payloads) {
                do {
                    switch payload {
                    case .unreadable(let error): throw error
                    case .malformed(let error):
                        try fileManager.removeItem(at: file.url)
                        throw error
                    case .decoded(let request):
                        // Defer age decisions to the final removal/claim pass.
                        pending.append((request, file.url))
                    }
                } catch {
                    if retainedError == nil { retainedError = error }
                }
            }
            return .completed(try claimPending(pending, retainedError: retainedError,
                in: directoryURL, referenceDate: referenceDate))
        }
    }

    // Recovery is opt-in and independent of normal queue consumption. Inspection
    // never mutates requests, defaults, or the migration marker. Only the selected
    // original may move, atomically and without replacement, into a private archive.
    public enum RecoveryReason: String, Sendable, Equatable {
        case oversized, malformed, futureDated, expired, unreadable, unsafeEntry

        public var localizedDescription: String {
            switch self {
            case .oversized: return "请求文件超过读取大小上限"
            case .malformed: return "请求文件格式无效"
            case .futureDated: return "请求时间晚于当前时间"
            case .expired: return "请求已过期"
            case .unreadable: return "无法读取原件，暂不能安全归档"
            case .unsafeEntry: return "文件类型或元数据不安全，暂不能归档"
            }
        }
    }

    public struct RecoveryCandidate: Identifiable, Sendable, Equatable {
        // Exact validated UUID spelling preserves case-sensitive filename identity.
        public let id: String
        public let reason: RecoveryReason
        public var canPrepare: Bool { reason != .unreadable && reason != .unsafeEntry }
    }

    public struct RecoveryInspection: Sendable, Equatable {
        public let candidates: [RecoveryCandidate]
        public let isTruncated: Bool
        public let legacyRecoveryUnsupported: Bool
    }

    public struct PreparedRecovery: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let candidate: RecoveryCandidate
    }

    public struct RecoveryResult: Sendable, Equatable {
        public let requestID: String
        public let archiveURL: URL?
        // The move already committed. A durability warning must never be treated
        // as a failed move or invite retrying against a replacement source file.
        public let durabilityWarning: Bool
    }

    public enum RecoveryError: LocalizedError, Equatable {
        case busy, changed, healthyRequest, unsafeEntry, unreadable, unavailable, archiveFailed, invalidTicket

        public var errorDescription: String? {
            switch self {
            case .busy: return "另一项检查或归档仍在进行，请完成或取消后重试。"
            case .changed: return "所选请求已变化或已被处理。原位置未作更改，请重新检查。"
            case .healthyRequest: return "所选请求当前可以正常续办，不能归档移出。请重试处理待办请求。"
            case .unsafeEntry: return "无法安全确认所选原件或存储位置，未移出请求。"
            case .unreadable: return "无法安全读取并确认所选原件，未移出请求。"
            case .unavailable: return "暂时无法检查授权请求，请稍后重试。"
            case .archiveFailed: return "归档未完成，所选请求仍保留在待办队列。"
            case .invalidTicket: return "本次确认已失效，请重新检查并选择请求。"
            }
        }
    }

    static let maximumRecoveryDirectoryEntries = 256
    // One process-wide permit covers actual synchronous I/O AND the sole prepared
    // lease. Canceling an async UI wait cannot release running I/O's permit.
    private static let recoveryAdmission = DispatchSemaphore(value: 1)
    private static let recoveryLeaseLock = NSLock()
    // Access only while holding recoveryLeaseLock. Descriptors are transferred,
    // never copied into independent owners, and closed on cancel/commit/failure.
    private static var recoveryLease: RecoveryLease?

    enum RecoveryCheckpoint: Equatable { case beforeArchive, afterArchiveCommit }

    private struct RecoveryNodeIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let generation: UInt32
        let owner: uid_t
        let mode: mode_t

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
            generation = metadata.st_gen
            owner = metadata.st_uid
            mode = metadata.st_mode
        }
    }

    private struct RecoveryContext {
        let url: URL
        let directory: Int32
        let lock: Int32
        let directoryIdentity: RecoveryNodeIdentity
        let lockIdentity: RecoveryNodeIdentity

        func closeDescriptors() { close(lock); close(directory) }
    }

    private struct RecoveryLease {
        let ticket: PreparedRecovery
        let context: RecoveryContext
        let source: Int32
        let identity: FileIdentity
        let createdAt: Date?
        let retentionInterval: TimeInterval

        var filename: String { ticket.candidate.id + ".json" }
        func closeDescriptors() { close(source); context.closeDescriptors() }
    }

    public func inspectRecoveryCandidates(referenceDate: Date? = nil) throws -> RecoveryInspection {
        guard Self.recoveryAdmission.wait(timeout: .now()) == .success else { throw RecoveryError.busy }
        defer { Self.recoveryAdmission.signal() }
        guard let directoryURL else { throw RecoveryError.unavailable }
        // A never-created queue is empty; do not create it or finish migration here.
        var status = stat()
        if lstat(directoryURL.path, &status) != 0, errno == ENOENT {
            return RecoveryInspection(candidates: [], isTruncated: false,
                legacyRecoveryUnsupported: hasUnsupportedLegacyRecovery())
        }
        let context = try openRecoveryContext()
        defer { context.closeDescriptors() }
        let listing = try withRecoveryLock(context) { try recoveryNames(in: context) }
        var candidates: [RecoveryCandidate] = []
        for id in listing.ids {
            let filename = id + ".json"
            let source: (descriptor: Int32, identity: FileIdentity)
            do { source = try withRecoveryLock(context) { try pinRecoverySource(filename, in: context) } }
            catch RecoveryError.changed { continue }
            catch {
                candidates.append(RecoveryCandidate(id: id,
                    reason: error as? RecoveryError == .unreadable ? .unreadable : .unsafeEntry))
                continue
            }
            // One source FD at a time, including on every error/changed branch.
            defer { close(source.descriptor) }
            let classification = classifyRecoverySource(source.descriptor, id: id,
                size: source.identity.size, referenceDate: referenceDate ?? currentDate())
            do {
                try withRecoveryLock(context) {
                    try validateRecoverySource(filename, descriptor: source.descriptor,
                        identity: source.identity, in: context)
                }
            } catch { continue }
            if let reason = classification.reason {
                candidates.append(RecoveryCandidate(id: id, reason: reason))
            }
        }
        let unsupported = try withRecoveryLock(context) {
            var marker = stat()
            return fstatat(context.directory, ".legacy-v1-migrated", &marker, AT_SYMLINK_NOFOLLOW) != 0
                && hasUnsupportedLegacyRecovery()
        }
        return RecoveryInspection(candidates: candidates, isTruncated: listing.truncated,
            legacyRecoveryUnsupported: unsupported)
    }

    public func prepareRecovery(candidateID: String, referenceDate: Date? = nil) throws -> PreparedRecovery {
        guard Self.isRecoveryID(candidateID) else { throw RecoveryError.unsafeEntry }
        guard Self.recoveryAdmission.wait(timeout: .now()) == .success else { throw RecoveryError.busy }
        var transferred = false
        defer { if !transferred { Self.recoveryAdmission.signal() } }
        let context = try openRecoveryContext()
        var source: Int32 = -1
        defer { if !transferred { if source >= 0 { close(source) }; context.closeDescriptors() } }
        let filename = candidateID + ".json"
        let pinned = try withRecoveryLock(context) { try pinRecoverySource(filename, in: context) }
        source = pinned.descriptor
        let classification = classifyRecoverySource(source, id: candidateID,
            size: pinned.identity.size, referenceDate: referenceDate ?? currentDate())
        try withRecoveryLock(context) {
            try validateRecoverySource(filename, descriptor: source, identity: pinned.identity, in: context)
        }
        let reason = try recoverableReason(classification.reason, createdAt: classification.createdAt,
            referenceDate: referenceDate ?? currentDate(), retention: retentionInterval)
        let ticket = PreparedRecovery(id: UUID(), candidate: RecoveryCandidate(id: candidateID, reason: reason))
        let lease = RecoveryLease(ticket: ticket, context: context, source: source, identity: pinned.identity,
            createdAt: classification.createdAt, retentionInterval: retentionInterval)
        Self.recoveryLeaseLock.lock()
        Self.recoveryLease = lease
        Self.recoveryLeaseLock.unlock()
        transferred = true
        return ticket
    }

    public func cancelRecovery(_ ticket: PreparedRecovery) {
        guard let lease = Self.takeRecoveryLease(ticket) else { return }
        lease.closeDescriptors()
        Self.recoveryAdmission.signal()
    }

    public func commitRecovery(_ ticket: PreparedRecovery, referenceDate: Date? = nil) throws -> RecoveryResult {
        guard let lease = Self.takeRecoveryLease(ticket) else { throw RecoveryError.invalidTicket }
        defer { lease.closeDescriptors(); Self.recoveryAdmission.signal() }
        guard directoryURL == lease.context.url else { throw RecoveryError.invalidTicket }
        return try withRecoveryLock(lease.context) {
            try validateRecoverySource(lease.filename, descriptor: lease.source,
                identity: lease.identity, in: lease.context)
            _ = try recoverableReason(ticket.candidate.reason, createdAt: lease.createdAt,
                referenceDate: referenceDate ?? currentDate(), retention: lease.retentionInterval)
            do { try recoveryCheckpoint?(.beforeArchive) }
            catch { throw RecoveryError.archiveFailed }
            let archive: Int32
            do { archive = try openRecoveryArchive(in: lease.context) }
            catch { throw RecoveryError.archiveFailed }
            defer { close(archive) }
            let archiveName = recoveryArchiveName() + ".original.json"
            guard Self.isRecoveryID(String(archiveName.dropLast(".original.json".count))) else {
                throw RecoveryError.archiveFailed
            }
            // Persist the original and newly-created archive directory before moving.
            // A failed precommit sync leaves the source name and bytes untouched.
            guard fsync(lease.source) == 0, fsync(archive) == 0,
                  fsync(lease.context.directory) == 0 else { throw RecoveryError.archiveFailed }
            try validateRecoveryContext(lease.context)
            try validateRecoveryArchive(archive, in: lease.context)
            try validateRecoverySource(lease.filename, descriptor: lease.source,
                identity: lease.identity, in: lease.context)
            _ = try recoverableReason(ticket.candidate.reason, createdAt: lease.createdAt,
                referenceDate: referenceDate ?? currentDate(), retention: lease.retentionInterval)
            guard renameatx_np(lease.context.directory, lease.filename, archive, archiveName,
                              UInt32(RENAME_EXCL)) == 0 else { throw RecoveryError.archiveFailed }
            // COMMIT POINT: the exact original is now archived. Nothing below may
            // throw, unlink, roll back, or act on a newly-created live pathname.
            var warning = false
            do { try recoveryCheckpoint?(.afterArchiveCommit) } catch { warning = true }
            if fsync(archive) != 0 { warning = true }
            if fsync(lease.context.directory) != 0 { warning = true }
            var verifiedURL: URL?
            do {
                try validateRecoveryContext(lease.context)
                try validateRecoveryArchive(archive, in: lease.context)
                var archived = stat(), original = stat()
                guard fstatat(archive, archiveName, &archived, AT_SYMLINK_NOFOLLOW) == 0,
                      fstat(lease.source, &original) == 0,
                      archived.st_mode & S_IFMT == S_IFREG,
                      archived.st_nlink == 1,
                      RecoveryNodeIdentity(archived) == RecoveryNodeIdentity(original),
                      archived.st_dev == lease.identity.device, archived.st_ino == lease.identity.inode,
                      archived.st_gen == lease.identity.generation, archived.st_size == lease.identity.size else {
                    throw RecoveryError.changed
                }
                verifiedURL = lease.context.url.appendingPathComponent(".recovery-archive", isDirectory: true)
                    .appendingPathComponent(archiveName)
            } catch { warning = true }
            return RecoveryResult(requestID: ticket.candidate.id,
                archiveURL: verifiedURL, durabilityWarning: warning)
        }
    }

    private static func takeRecoveryLease(_ ticket: PreparedRecovery) -> RecoveryLease? {
        recoveryLeaseLock.lock()
        defer { recoveryLeaseLock.unlock() }
        guard let lease = recoveryLease, lease.ticket == ticket else { return nil }
        recoveryLease = nil
        return lease
    }

    private static func isRecoveryID(_ id: String) -> Bool {
        // Match the legacy parser without canonicalizing a filename. The short,
        // printable, separator-free component is safe for FD-relative operations.
        !id.isEmpty && id.utf8.count <= 64 && UUID(uuidString: id) != nil
            && id.utf8.allSatisfy { $0 > 32 && $0 < 127 && $0 != 47 && $0 != 92 }
    }

    private func hasUnsupportedLegacyRecovery() -> Bool {
        // UserDefaults materializes the value itself. No JSON decoding, migration,
        // marker write or defaults removal is part of limited file recovery.
        guard let data = defaults?.data(forKey: legacyRequestKey) else { return false }
        return data.count > Self.maximumLegacyInputBytes
    }

    private func classifyRecoverySource(
        _ descriptor: Int32, id: String, size: off_t, referenceDate: Date
    ) -> (reason: RecoveryReason?, createdAt: Date?) {
        guard size >= 0, size <= Int64(Self.maximumRequestBytes) else { return (.oversized, nil) }
        let data: Data
        do {
            data = try readPinnedRequestData(descriptor,
                directoryURL!.appendingPathComponent(id + ".json"))
            guard data.count <= Self.maximumRequestBytes else { return (.oversized, nil) }
        } catch StoreError.requestTooLarge { return (.oversized, nil) }
        catch { return (.unreadable, nil) }
        guard let request = try? JSONDecoder().decode(FinderAuthorizationRequest.self, from: data) else {
            return (.malformed, nil)
        }
        let age = referenceDate.timeIntervalSince(request.createdAt)
        guard age.isFinite else { return (.malformed, nil) }
        return (age < 0 ? .futureDated : age > retentionInterval ? .expired : nil, request.createdAt)
    }

    private func recoverableReason(
        _ reason: RecoveryReason?, createdAt: Date?, referenceDate: Date, retention: TimeInterval
    ) throws -> RecoveryReason {
        if let createdAt {
            let age = referenceDate.timeIntervalSince(createdAt)
            guard age.isFinite else { throw RecoveryError.changed }
            guard age < 0 || age > retention else { throw RecoveryError.healthyRequest }
            return age < 0 ? .futureDated : .expired
        }
        guard let reason else { throw RecoveryError.healthyRequest }
        guard reason != .unsafeEntry else { throw RecoveryError.unsafeEntry }
        guard reason != .unreadable else { throw RecoveryError.unreadable }
        return reason
    }

    private func openRecoveryContext() throws -> RecoveryContext {
        guard let directoryURL else { throw RecoveryError.unavailable }
        let directory = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw RecoveryError.unavailable }
        var transferred = false
        defer { if !transferred { close(directory) } }
        var directoryStatus = stat()
        guard fstat(directory, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR, directoryStatus.st_ino != 0,
              directoryStatus.st_uid == geteuid() else { throw RecoveryError.unsafeEntry }
        try validateRecoveryPermissions(directory)
        let lock = openat(directory, ".queue.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
                          S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw RecoveryError.unsafeEntry }
        defer { if !transferred { close(lock) } }
        var lockStatus = stat()
        guard fstat(lock, &lockStatus) == 0, lockStatus.st_mode & S_IFMT == S_IFREG,
              lockStatus.st_ino != 0, lockStatus.st_uid == geteuid(), lockStatus.st_nlink == 1 else { throw RecoveryError.unsafeEntry }
        let context = RecoveryContext(url: directoryURL, directory: directory, lock: lock,
            directoryIdentity: RecoveryNodeIdentity(directoryStatus), lockIdentity: RecoveryNodeIdentity(lockStatus))
        try validateRecoveryContext(context)
        transferred = true
        return context
    }

    private func withRecoveryLock<T>(_ context: RecoveryContext, _ operation: () throws -> T) throws -> T {
        while flock(context.lock, LOCK_EX) != 0 {
            guard errno == EINTR else { throw RecoveryError.unavailable }
        }
        defer { flock(context.lock, LOCK_UN) }
        try validateRecoveryContext(context)
        return try operation()
    }

    private func validateRecoveryContext(_ context: RecoveryContext) throws {
        var namedDirectory = stat(), openedDirectory = stat(), namedLock = stat(), openedLock = stat()
        guard lstat(context.url.path, &namedDirectory) == 0,
              fstat(context.directory, &openedDirectory) == 0,
              fstatat(context.directory, ".queue.lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(context.lock, &openedLock) == 0,
              RecoveryNodeIdentity(namedDirectory) == context.directoryIdentity,
              RecoveryNodeIdentity(openedDirectory) == context.directoryIdentity,
              RecoveryNodeIdentity(namedLock) == context.lockIdentity,
              RecoveryNodeIdentity(openedLock) == context.lockIdentity,
              namedLock.st_nlink == 1, openedLock.st_nlink == 1 else { throw RecoveryError.changed }
        try validateRecoveryPermissions(context.directory)
    }

    private func recoveryNames(in context: RecoveryContext) throws -> (ids: [String], truncated: Bool) {
        // fdopendir owns a separate descriptor. Never materialize an unbounded
        // contentsOfDirectory array for a pathological historical directory.
        let descriptor = openat(context.directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecoveryError.unavailable }
        guard let stream = fdopendir(descriptor) else { close(descriptor); throw RecoveryError.unavailable }
        defer { closedir(stream) }
        var ids: [String] = []
        var visited = 0
        while visited < Self.maximumRecoveryDirectoryEntries {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw RecoveryError.unavailable }
                return (ids.sorted(), false)
            }
            visited += 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name.hasSuffix(".json") else { continue }
            let id = String(name.dropLast(5))
            guard Self.isRecoveryID(id) else { continue }
            guard ids.count < Self.maximumPendingRequests else { return (ids.sorted(), true) }
            ids.append(id)
        }
        return (ids.sorted(), true)
    }

    private func pinRecoverySource(_ filename: String, in context: RecoveryContext) throws
        -> (descriptor: Int32, identity: FileIdentity) {
        var named = stat()
        guard fstatat(context.directory, filename, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw errno == ENOENT ? RecoveryError.changed : RecoveryError.unreadable
        }
        guard named.st_mode & S_IFMT == S_IFREG, named.st_uid == geteuid(),
              named.st_size >= 0, named.st_nlink == 1 else {
            throw RecoveryError.unsafeEntry
        }
        let descriptor = openat(context.directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecoveryError.unreadable }
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_uid == geteuid(), opened.st_nlink == 1,
              RecoveryNodeIdentity(opened) == RecoveryNodeIdentity(named),
              let identity = FileIdentity(opened), identity == FileIdentity(named) else {
            throw RecoveryError.changed
        }
        guard opened.st_dev == context.directoryIdentity.device else { throw RecoveryError.unsafeEntry }
        try validateRecoveryPermissions(descriptor)
        transferred = true
        return (descriptor, identity)
    }

    private func validateRecoverySource(
        _ filename: String, descriptor: Int32, identity: FileIdentity, in context: RecoveryContext
    ) throws {
        var named = stat(), opened = stat()
        guard fstatat(context.directory, filename, &named, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(descriptor, &opened) == 0,
              named.st_uid == geteuid(), opened.st_uid == geteuid(),
              named.st_nlink == 1, opened.st_nlink == 1,
              FileIdentity(named) == identity, FileIdentity(opened) == identity,
              RecoveryNodeIdentity(named) == RecoveryNodeIdentity(opened) else { throw RecoveryError.changed }
        try validateRecoveryPermissions(descriptor)
    }

    private func openRecoveryArchive(in context: RecoveryContext) throws -> Int32 {
        if mkdirat(context.directory, ".recovery-archive", S_IRWXU) != 0, errno != EEXIST {
            throw RecoveryError.archiveFailed
        }
        let descriptor = openat(context.directory, ".recovery-archive",
                                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecoveryError.archiveFailed }
        do { try validateRecoveryArchive(descriptor, in: context) }
        catch { close(descriptor); throw error }
        return descriptor
    }

    private func validateRecoveryArchive(_ descriptor: Int32, in context: RecoveryContext) throws {
        var named = stat(), opened = stat()
        guard fstatat(context.directory, ".recovery-archive", &named, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFDIR,
              opened.st_mode & 0o7777 == 0o700,
              opened.st_uid == geteuid(), opened.st_dev == context.directoryIdentity.device,
              RecoveryNodeIdentity(named) == RecoveryNodeIdentity(opened) else { throw RecoveryError.archiveFailed }
        try validateRecoveryPermissions(descriptor)
    }

    private func validateRecoveryPermissions(_ descriptor: Int32) throws {
        // The mode/ACL boundary excludes other-UID mutation between validation and
        // rename. Same-UID/root tampering is outside the private namespace boundary,
        // just as for PrivateFileStagingDirectory; supported writers use flock.
        var metadata = stat()
        var volume = statfs()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid(),
              metadata.st_mode & 0o022 == 0,
              fstatfs(descriptor, &volume) == 0,
              volume.f_flags & UInt32(MNT_UNKNOWNPERMISSIONS) == 0 else { throw RecoveryError.unsafeEntry }
        if let acl = acl_get_fd(descriptor) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            var entryID = Int32(ACL_FIRST_ENTRY.rawValue)
            while acl_get_entry(acl, entryID, &entry) == 0 {
                guard let entry else { throw RecoveryError.unsafeEntry }
                var tag = ACL_UNDEFINED_TAG
                guard acl_get_tag_type(entry, &tag) == 0, tag != ACL_EXTENDED_ALLOW else {
                    throw RecoveryError.unsafeEntry
                }
                entryID = Int32(ACL_NEXT_ENTRY.rawValue)
            }
        } else if errno != ENOENT && errno != ENOTSUP {
            throw RecoveryError.unsafeEntry
        }
    }

    private func withLockedQueue<Result>(_ operation: (URL) throws -> Result) throws -> Result {
        guard let directoryURL else { throw StoreError.sharedStoreUnavailable }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let lockURL = directoryURL.appendingPathComponent(".queue.lock")
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
        return try operation(directoryURL)
    }

    private enum LegacyMigrationOutcome {
        case finished
        case deferred(FinderAuthorizationRequest)
        case retainedOversizedInput
    }

    private func migrateLegacyRequest(
        in directoryURL: URL, referenceDate: Date
    ) throws -> LegacyMigrationOutcome {
        // Upgrade requires old processes to exit. Never consult cached defaults again after
        // this on-disk marker is published, even when another instance retains the old value.
        let markerURL = directoryURL.appendingPathComponent(".legacy-v1-migrated")
        if fileManager.fileExists(atPath: markerURL.path) { return .finished }
        if let data = defaults?.data(forKey: legacyRequestKey) {
            // Check original bytes before decoding, encoding, age checks or admission.
            // This also preserves malformed oversized input for explicit recovery.
            guard data.count <= Self.maximumLegacyInputBytes else {
                return .retainedOversizedInput
            }
            let request: FinderAuthorizationRequest
            do {
                request = try decodeLegacyRequest(data)
            } catch {
                try Data().write(to: markerURL, options: .atomic)
                defaults?.removeObject(forKey: legacyRequestKey)
                throw error
            }
            do {
                try persist(request, in: directoryURL, referenceDate: referenceDate)
            } catch StoreError.queueFull {
                return .deferred(request)
            }
        }
        try finishLegacyMigration(in: directoryURL)
        return .finished
    }

    private func finishLegacyMigration(in directoryURL: URL) throws {
        let markerURL = directoryURL.appendingPathComponent(".legacy-v1-migrated")
        // Commit before consumption: a crash before this point may rewrite the same queued
        // ID, but cannot resurrect a request already returned to a consumer.
        try Data().write(to: markerURL, options: .atomic)
        defaults?.removeObject(forKey: legacyRequestKey)
    }
}
