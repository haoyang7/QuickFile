import Foundation
import Darwin
import os
import QuickFileCore

struct StoredDirectoryAuthorization: Codable, Equatable, Sendable {
    let id: UUID
    let revision: UUID?
    let persistentBookmarkData: Data
    let transferBookmarkData: Data
    // A candidate-selection hint only. Bookmark resolution and revision checks
    // remain authoritative; absent/old hints may conservatively retain duplicates.
    let canonicalPathHint: String?
    let directoryIdentityHint: DirectoryIdentity?

    private enum CodingKeys: String, CodingKey {
        case id
        case revision
        case persistentBookmarkData
        case transferBookmarkData
        case canonicalPathHint
        case directoryIdentityHint
        case bookmarkData
    }

    init(id: UUID, persistentBookmarkData: Data, transferBookmarkData: Data,
         canonicalPathHint: String? = nil, directoryIdentityHint: DirectoryIdentity? = nil) {
        self.id = id
        revision = UUID()
        self.persistentBookmarkData = persistentBookmarkData
        self.transferBookmarkData = transferBookmarkData
        self.canonicalPathHint = canonicalPathHint
        self.directoryIdentityHint = directoryIdentityHint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        revision = try container.decodeIfPresent(UUID.self, forKey: .revision)
        // An invalid optional hint cannot invalidate otherwise valid grants.
        canonicalPathHint = try? container.decode(String.self, forKey: .canonicalPathHint)
        directoryIdentityHint = try? container.decode(DirectoryIdentity.self, forKey: .directoryIdentityHint)
        persistentBookmarkData = try container.decodeIfPresent(
            Data.self,
            forKey: .persistentBookmarkData
        ) ?? container.decode(Data.self, forKey: .bookmarkData)
        transferBookmarkData = try container.decodeIfPresent(
            Data.self,
            forKey: .transferBookmarkData
        ) ?? Data()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(revision, forKey: .revision)
        try container.encode(persistentBookmarkData, forKey: .persistentBookmarkData)
        try container.encode(transferBookmarkData, forKey: .transferBookmarkData)
        try container.encodeIfPresent(canonicalPathHint, forKey: .canonicalPathHint)
        try container.encodeIfPresent(directoryIdentityHint, forKey: .directoryIdentityHint)
    }
}

// The lock file is never replaced: all processes lock the same inode while the JSON
// snapshot is atomically replaced. Every read goes to disk, including extension reads.
struct AuthorizedDirectoryRepository: @unchecked Sendable {
    struct Snapshot: Codable, Equatable, Sendable {
        let generation: UUID
        let authorizations: [StoredDirectoryAuthorization]
    }

    private let directory: URL?
    private let legacyData: () throws -> Data?
    private let decodedCache = OSAllocatedUnfairLock(initialState: DecodedCache())
    private let didDecodeSnapshot: (@Sendable () -> Void)?
    private struct DecodedCache: Sendable {
        var bytes: Data?
        var snapshot: Snapshot?
    }
    private static let maximumCachedBytes = 256 * 1024
    private static let authorizationsKey = "authorizedDirectories.v1"

    init(containerURL: URL?) {
        directory = containerURL
        didDecodeSnapshot = nil
        legacyData = {
            guard let containerURL else { return nil }
            let preferencesURL = containerURL
                .appendingPathComponent("Library/Preferences", isDirectory: true)
                .appendingPathComponent(QuickFileConfiguration.appGroupIdentifier + ".plist")
            let data: Data
            do {
                data = try Data(contentsOf: preferencesURL)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError {
                return nil
            }
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let values = plist as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            guard let value = values[Self.authorizationsKey] else { return nil }
            guard let data = value as? Data else { throw CocoaError(.propertyListReadCorrupt) }
            return data
        }
    }

    // Tests inject a private directory and legacy defaults; production migration reads
    // the on-disk App Group plist, never a process-local preferences cache.
    init(defaults: UserDefaults?, storageDirectory: URL?, didDecodeSnapshot: (@Sendable () -> Void)? = nil) {
        directory = defaults == nil ? nil : storageDirectory
        self.didDecodeSnapshot = didDecodeSnapshot
        legacyData = { defaults?.data(forKey: Self.authorizationsKey) }
    }

    var isAvailable: Bool { directory != nil }

    func load() throws -> [StoredDirectoryAuthorization] {
        try loadSnapshot().authorizations
    }

    func loadSnapshot() throws -> Snapshot {
        try withLock { try loadLocked() }
    }

    func contains(_ authorization: StoredDirectoryAuthorization) throws -> Bool {
        // Compare the complete record, including its revision, while holding the
        // same lock as revoke/authorize. Unrelated table changes remain valid.
        try withLock { try loadLocked().authorizations.contains(authorization) }
    }

    func update<Result>(
        expectedGeneration: UUID? = nil,
        _ operation: (inout [StoredDirectoryAuthorization]) throws -> Result
    ) throws -> Result {
        try withLock {
            let previous = try loadLocked()
            if let expectedGeneration, expectedGeneration != previous.generation {
                throw AuthorizedDirectoryStoreError.authorizationChanged
            }
            var authorizations = previous.authorizations
            let result = try operation(&authorizations)
            if authorizations != previous.authorizations {
                // The generation survives an empty table, so insert-then-revoke
                // cannot make a stale authorization snapshot current again.
                try saveLocked(Snapshot(generation: UUID(), authorizations: authorizations))
            }
            return result
        }
    }

    private func withLock<Result>(_ operation: () throws -> Result) throws -> Result {
        guard let directory else { throw AuthorizedDirectoryStoreError.sharedDefaultsUnavailable }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let descriptor = open(directory.appendingPathComponent("authorizedDirectories.lock").path,
                                  O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw posixError() }
            defer { close(descriptor) }
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else { throw posixError() }
            }
            defer { flock(descriptor, LOCK_UN) }
            return try operation()
        } catch let error as AuthorizedDirectoryStoreError {
            throw error
        } catch {
            throw AuthorizedDirectoryStoreError.persistenceFailed(error)
        }
    }

    private func loadLocked() throws -> Snapshot {
        let url = directory!.appendingPathComponent("authorizedDirectories.v2.json")
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            let marker = directory!.appendingPathComponent("authorizedDirectories.migrated")
            do {
                _ = try Data(contentsOf: marker)
                throw AuthorizedDirectoryStoreError.persistenceFailed(error)
            } catch let markerError as NSError where markerError.domain == NSCocoaErrorDomain
                && markerError.code == NSFileReadNoSuchFileError {
                // Only an absent marker permits the one-time legacy migration.
            }
            let authorizations = try legacyData().map {
                try JSONDecoder().decode([StoredDirectoryAuthorization].self, from: $0)
            } ?? []
            let migrated = Snapshot(generation: UUID(), authorizations: authorizations)
            // Persist even an empty migration. Later revocations must never fall back
            // to the legacy table, which older processes may still have cached.
            try saveLocked(migrated)
            try Data().write(to: marker, options: .atomic)
            return migrated
        }
        let snapshot: Snapshot
        let cached = decodedCache.withLock { cache -> Snapshot? in
            guard cache.bytes == data else { return nil }
            return cache.snapshot
        }
        if let cached {
            snapshot = cached
        } else {
            didDecodeSnapshot?()
            let decoder = JSONDecoder()
            if let legacy = try? decoder.decode([StoredDirectoryAuthorization].self, from: data) {
                // Never memoize a legacy array: every migration needs its own
                // persisted generation, and saveLocked changes the authoritative bytes.
                snapshot = Snapshot(generation: UUID(), authorizations: legacy)
                try saveLocked(snapshot)
                decodedCache.withLock { $0 = DecodedCache() }
            } else {
                snapshot = try decoder.decode(Snapshot.self, from: data)
                decodedCache.withLock { cache in
                    cache = data.count <= Self.maximumCachedBytes
                        ? DecodedCache(bytes: data, snapshot: snapshot) : DecodedCache()
                }
            }
        }
        // Recover a migration interrupted after the snapshot write. No successful
        // read or mutation may leave a snapshot eligible for legacy fallback.
        let marker = directory!.appendingPathComponent("authorizedDirectories.migrated")
        do {
            _ = try Data(contentsOf: marker)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            try Data().write(to: marker, options: .atomic)
        }
        return snapshot
    }

    private func saveLocked(_ snapshot: Snapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: directory!.appendingPathComponent("authorizedDirectories.v2.json"),
                       options: .atomic)
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
