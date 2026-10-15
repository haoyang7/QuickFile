import QuickFileCore
import Foundation
import Darwin
import os

public enum QuickFileStorageMode: String, Sendable {
    case localShared = "local-shared"

    public static let current: Self = .localShared
    public var displayName: String { QuickFileLocalization.text(.init("本地共享存储")) }
}

/// Build metadata describes the channel; artifact checks verify the actual signature.
public enum QuickFileDistributionChannel: String, Sendable {
    case community
    case developerID = "developer-id"
    case development

    public static var current: Self? {
        (Bundle.main.infoDictionary?["QuickFileDistributionChannel"] as? String).flatMap(Self.init(rawValue:))
    }

    public var displayName: String {
        switch self {
        case .community: return "Community"
        case .developerID: return "Developer ID"
        case .development: return QuickFileLocalization.text(.init("开发构建"))
        }
    }
}

/// Both distribution channels share one stable location. Never probe old containers
/// or select another store when access fails. Tests inject private directories.
enum QuickFileSharedStorage {
    // Keep the original directory name: changing a channel must not move user data.
    static let directoryName = "QuickFileCommunity"

    static func configurationMatches(_ info: [String: Any]) -> Bool {
        info["QuickFileStorageMode"] as? String == QuickFileStorageMode.current.rawValue
    }

    static let local: LocalSharedStorage? = {
        guard configurationMatches(Bundle.main.infoDictionary ?? [:]),
              let home = try? userHomeDirectory() else { return nil }
        return LocalSharedStorage(root: home.appendingPathComponent(
            "Library/Application Support/" + directoryName, isDirectory: true
        ))
    }()

    static func directory() -> URL? { local?.root }

    // Legacy decoders remain available to isolated compatibility tests. Production
    // never opens a protected App Group preferences domain, in either channel.
    static func legacyDefaults() -> UserDefaults? { nil }

    private static func userHomeDirectory() throws -> URL {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16 * 1024)
        let code = getpwuid_r(getuid(), &entry, &buffer, buffer.count, &result)
        guard code == 0, result != nil, let path = entry.pw_dir, path.pointee == 47 else {
            throw POSIXError(.ENOENT)
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
}

/// Owner-private filesystem storage. Directory identities are protected by the lock;
/// payload operations use opened parent descriptors and never follow a leaf symlink.
/// This does not provide App Group's application-identity isolation from the same user.
final class LocalSharedStorage: @unchecked Sendable {
    let root: URL
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }
    private let directories = OSAllocatedUnfairLock(initialState: [String: Identity]())

    init(root: URL) { self.root = root.standardizedFileURL }

    func prepare(_ directory: URL) throws {
        try withDirectory(directory) { _ in }
    }

    private func withDirectory<T>(_ url: URL, forPermissionRepair: Bool = false,
                                  _ operation: (Int32) throws -> T) throws -> T {
        let components = url.standardizedFileURL.pathComponents
        let rootComponents = root.pathComponents
        guard components.starts(with: rootComponents),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw POSIXError(.EINVAL)
        }
        var descriptor = open("/", O_SEARCH | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        for index in 1..<components.count {
            let owned = index >= rootComponents.count - 1
            let name = components[index]
            if owned, !forPermissionRepair, mkdirat(descriptor, name, 0o700) != 0, errno != EEXIST { throw posixError() }
            let access = owned ? (forPermissionRepair ? O_EVTONLY : O_RDONLY) : O_SEARCH
            let child = openat(descriptor, name, access | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw posixError() }
            close(descriptor)
            descriptor = child
            if owned {
                var status = stat()
                guard fstat(descriptor, &status) == 0 else { throw posixError() }
                guard status.st_uid == geteuid(), forPermissionRepair || status.st_mode & 0o077 == 0 else {
                    throw POSIXError(.EACCES)
                }
                let path = "/" + components[1...index].joined(separator: "/")
                let identity = Identity(status)
                let valid = directories.withLock { entries in
                    if let existing = entries[path] { return existing == identity }
                    entries[path] = identity
                    return true
                }
                guard valid else { throw POSIXError(.ESTALE) }
            }
        }
        try validateDirectory(descriptor, at: url)
        return try operation(descriptor)
    }

    private func validateDirectory(_ descriptor: Int32, at url: URL) throws {
        var opened = stat(), named = stat()
        guard fstat(descriptor, &opened) == 0, lstat(url.path, &named) == 0 else { throw posixError() }
        guard named.st_mode & S_IFMT == S_IFDIR, Identity(opened) == Identity(named) else {
            throw POSIXError(.ESTALE)
        }
        // A rename of an ancestor must not make the pinned directory publish elsewhere.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { throw posixError() }
        guard String(cString: path) == url.standardizedFileURL.path else { throw POSIXError(.ESTALE) }
    }

    func validateFile(_ status: stat) throws {
        guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(),
              status.st_nlink == 1, status.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
    }

    func validateFile(descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError() }
        try validateFile(status)
    }

    func containsFile(at url: URL) throws -> Bool {
        try withDirectory(url.deletingLastPathComponent()) { parent in
            var status = stat()
            guard fstatat(parent, url.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return false }
                throw posixError()
            }
            try validateFile(status)
            return true
        }
    }

    /// Explicit user action only. Restores owner-only modes without reading or replacing data.
    /// Never follows links, changes ownership, traverses children or repairs a replaced root.
    func repairTemplatePermissions() throws {
        try repairPermissions(in: root, lockName: "templates.v2.json.lock") { _ in
            ["templates.v2.json", "templates.persistence.v1.json"]
        }
    }

    func repairAuthorizationPermissions() throws {
        try repairPermissions(in: root, lockName: "authorizedDirectories.lock") { _ in
            ["authorizedDirectories.v2.json", "authorizedDirectories.migrated"]
        }
    }

    func repairRequestPermissions() throws {
        // Restore traversal first, then inspect only the fixed queue child. Do not
        // create a missing queue or traverse archived contents and arbitrary subdirectories.
        let exists = try withDirectory(root, forPermissionRepair: true) { parent in
            guard fchmod(parent, 0o700) == 0 else { throw posixError() }
            try validateDirectory(parent, at: root)
            var entry = stat()
            if fstatat(parent, "finder-authorization-requests", &entry, AT_SYMLINK_NOFOLLOW) == 0 { return true }
            guard errno == ENOENT else { throw posixError() }
            return false
        }
        guard exists else { return }
        let queue = root.appendingPathComponent("finder-authorization-requests", isDirectory: true)
        try repairPermissions(in: queue, lockName: ".queue.lock", repairArchive: true) { parent in
            // O_EVTONLY cannot enumerate; reopen the same pinned directory.
            let descriptor = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw self.posixError() }
            guard let stream = fdopendir(descriptor) else {
                let error = self.posixError(); close(descriptor); throw error
            }
            defer { closedir(stream) }
            var names = [".legacy-v1-migrated"]
            var count = 0
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw self.posixError() }
                    break
                }
                count += 1
                guard count <= 1024 else { throw POSIXError(.EFBIG) }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil {
                    names.append(name)
                    guard names.count <= 257 else { throw POSIXError(.EFBIG) }
                }
            }
            return names
        }
    }

    private func repairPermissions(in directory: URL, lockName: String, repairArchive: Bool = false,
                                   names: (Int32) throws -> [String]) throws {
        try withDirectory(directory, forPermissionRepair: true) { parent in
            // An openable directory must regain owner search access before its entries
            // can be inspected. A later refusal can leave this verified root changed.
            guard fchmod(parent, 0o700) == 0 else { throw posixError() }
            try validateDirectory(parent, at: directory)
            var descriptors: [(name: String, fd: Int32)] = []
            defer { for entry in descriptors { close(entry.fd) } }

            func inspect(_ name: String, _ descriptor: Int32) throws {
                var opened = stat(), named = stat()
                guard fstat(descriptor, &opened) == 0,
                      fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
                guard opened.st_mode & S_IFMT == S_IFREG, opened.st_uid == geteuid(),
                      opened.st_nlink == 1, named.st_mode & S_IFMT == S_IFREG,
                      Identity(opened) == Identity(named) else { throw POSIXError(.EACCES) }
            }
            func openEntry(_ name: String, create: Bool = false) throws -> Int32? {
                var descriptor = openat(parent, name, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                if descriptor < 0, errno == ENOENT, create {
                    descriptor = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                }
                guard descriptor >= 0 else {
                    if errno == ENOENT, !create { return nil }
                    throw posixError()
                }
                descriptors.append((name, descriptor))
                try inspect(name, descriptor)
                return descriptor
            }
            guard let lock = try openEntry(lockName, create: true) else { throw POSIXError(.ENOENT) }
            while flock(lock, LOCK_EX) != 0 {
                guard errno == EINTR else { throw posixError() }
            }
            defer { flock(lock, LOCK_UN) }
            for name in try names(parent) { _ = try openEntry(name) }
            // Validate every leaf before changing any leaf mode. A symlink or hard
            // link keeps its target untouched; data is never reset on repair failure.
            for entry in descriptors { try inspect(entry.name, entry.fd) }
            for entry in descriptors {
                try validateDirectory(parent, at: directory)
                try inspect(entry.name, entry.fd)
                guard fchmod(entry.fd, 0o600) == 0 else { throw posixError() }
                try inspect(entry.name, entry.fd)
            }
            if repairArchive { try repairRecoveryArchive(in: directory, parent: parent) }
            try validateDirectory(parent, at: directory)
        }
    }

    /// The queue lock is held by the caller. Repair only this fixed directory, never its evidence files.
    private func repairRecoveryArchive(in queue: URL, parent: Int32) throws {
        var named = stat(), parentStatus = stat()
        guard fstatat(parent, ".recovery-archive", &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw posixError()
        }
        guard fstat(parent, &parentStatus) == 0 else { throw posixError() }
        guard named.st_mode & S_IFMT == S_IFDIR, named.st_uid == geteuid(),
              named.st_dev == parentStatus.st_dev else { throw POSIXError(.EACCES) }
        let archive = queue.appendingPathComponent(".recovery-archive", isDirectory: true)
        try withDirectory(archive, forPermissionRepair: true) { descriptor in
            var opened = stat(), volume = statfs()
            guard fstat(descriptor, &opened) == 0, Identity(opened) == Identity(named),
                  fstatfs(descriptor, &volume) == 0,
                  volume.f_flags & UInt32(MNT_UNKNOWNPERMISSIONS) == 0 else { throw POSIXError(.EACCES) }
            // chmod does not remove an extended allow ACL. Do not report that boundary as repaired.
            if let acl = acl_get_fd(descriptor) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                var entryID = Int32(ACL_FIRST_ENTRY.rawValue)
                while acl_get_entry(acl, entryID, &entry) == 0 {
                    guard let entry else { throw POSIXError(.EACCES) }
                    var tag = ACL_UNDEFINED_TAG
                    guard acl_get_tag_type(entry, &tag) == 0, tag != ACL_EXTENDED_ALLOW else { throw POSIXError(.EACCES) }
                    entryID = Int32(ACL_NEXT_ENTRY.rawValue)
                }
            } else if errno != ENOENT && errno != ENOTSUP { throw posixError() }
            try validateDirectory(parent, at: queue)
            guard fchmod(descriptor, 0o700) == 0 else { throw posixError() }
            try validateDirectory(descriptor, at: archive)
        }
    }

    func read(_ url: URL, maximumBytes: Int = 64 * 1024 * 1024) throws -> Data {
        try withDirectory(url.deletingLastPathComponent()) { parent in
            let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno == ENOENT { throw CocoaError(.fileReadNoSuchFile) }
                throw posixError()
            }
            defer { close(descriptor) }
            var before = stat()
            guard fstat(descriptor, &before) == 0 else { throw posixError() }
            try validateFile(before)
            guard before.st_size >= 0, before.st_size <= maximumBytes else { throw POSIXError(.EFBIG) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumBytes + 1))
            while data.count <= maximumBytes {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, min($0.count, maximumBytes + 1 - data.count))
                }
                if count == 0 { break }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                data.append(contentsOf: buffer.prefix(count))
            }
            guard data.count <= maximumBytes else { throw POSIXError(.EFBIG) }
            try validateDirectory(parent, at: url.deletingLastPathComponent())
            return data
        }
    }

    func write(_ data: Data, to url: URL, durable: Bool = false) throws {
        try withDirectory(url.deletingLastPathComponent()) { parent in
            func validateTarget() throws {
                var target = stat()
                if fstatat(parent, url.lastPathComponent, &target, AT_SYMLINK_NOFOLLOW) == 0 {
                    try validateFile(target)
                } else if errno != ENOENT { throw posixError() }
            }
            try validateTarget()
            try removeAbandonedWrites(in: url.deletingLastPathComponent(), parent: parent)
            let temporary = ".quickfile-write-" + UUID().uuidString
            // O_EXLOCK establishes ownership atomically with creation, including the window
            // before the first write. Cleanup cannot acquire a live writer's lock.
            let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw posixError() }
            defer { close(descriptor); unlinkat(parent, temporary, 0) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw posixError() }
                    offset += count
                }
            }
            if durable, fsync(descriptor) != 0 { throw posixError() }
            try validateDirectory(parent, at: url.deletingLastPathComponent())
            try validateTarget()
            guard renameat(parent, temporary, parent, url.lastPathComponent) == 0 else { throw posixError() }
            if durable, fsync(parent) != 0 { throw posixError() }
        }
    }

    /// Opportunistic, bounded reclamation of private unpublished files. Fresh files,
    /// active writers, links and unknown entries are left untouched.
    private func removeAbandonedWrites(in directory: URL, parent: Int32) throws {
        let descriptor = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        guard let stream = fdopendir(descriptor) else {
            let error = posixError(); close(descriptor); throw error
        }
        defer { closedir(stream) }
        let cutoff = Date().timeIntervalSince1970 - 24 * 60 * 60
        for _ in 0..<1024 {
            guard let entry = readdir(stream) else { break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            let prefix = ".quickfile-write-"
            guard name.hasPrefix(prefix),
                  let id = UUID(uuidString: String(name.dropFirst(prefix.count))), name == prefix + id.uuidString else { continue }
            let candidate = openat(parent, name, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard candidate >= 0 else { continue }
            defer { close(candidate) }
            guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else { continue }
            defer { flock(candidate, LOCK_UN) }
            var opened = stat(), named = stat()
            guard fstat(candidate, &opened) == 0,
                  opened.st_mode & S_IFMT == S_IFREG, opened.st_mode & 0o7777 == 0o600,
                  opened.st_uid == geteuid(), opened.st_nlink == 1,
                  Double(opened.st_mtimespec.tv_sec) < cutoff,
                  fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  Identity(opened) == Identity(named) else { continue }
            try validateDirectory(parent, at: directory)
            // Cleanup failure must not prevent a normal save; another write can retry.
            _ = unlinkat(parent, name, 0)
        }
    }

    func remove(_ url: URL) throws {
        try withDirectory(url.deletingLastPathComponent()) { parent in
            var status = stat()
            guard fstatat(parent, url.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
            try validateFile(status)
            try validateDirectory(parent, at: url.deletingLastPathComponent())
            guard unlinkat(parent, url.lastPathComponent, 0) == 0 else { throw posixError() }
        }
    }

    func withLock<T>(at url: URL, _ operation: () throws -> T) throws -> T {
        try withDirectory(url.deletingLastPathComponent()) { parent in
            let descriptor = openat(parent, url.lastPathComponent,
                                    O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw posixError() }
            defer { close(descriptor) }
            var opened = stat(), named = stat()
            guard fstat(descriptor, &opened) == 0 else { throw posixError() }
            try validateFile(opened)
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else { throw posixError() }
            }
            defer { flock(descriptor, LOCK_UN) }
            try validateDirectory(parent, at: url.deletingLastPathComponent())
            guard fstatat(parent, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  Identity(opened) == Identity(named) else { throw POSIXError(.ESTALE) }
            return try operation()
        }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
