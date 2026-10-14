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

    private func withDirectory<T>(_ url: URL, _ operation: (Int32) throws -> T) throws -> T {
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
            if owned, mkdirat(descriptor, name, 0o700) != 0, errno != EEXIST { throw posixError() }
            let child = openat(descriptor, name, (owned ? O_RDONLY : O_SEARCH) | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw posixError() }
            close(descriptor)
            descriptor = child
            if owned {
                var status = stat()
                guard fstat(descriptor, &status) == 0 else { throw posixError() }
                guard status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
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
            let temporary = ".quickfile-write-" + UUID().uuidString
            let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
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
