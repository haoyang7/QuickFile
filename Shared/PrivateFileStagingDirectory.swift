import Darwin
import Foundation

/// A private namespace for temporary files. Descriptors keep its contents anchored if a
/// containing directory is moved. Other users must not be able to access this namespace.
public final class PrivateFileStagingDirectory {
    public let descriptor: Int32
    public let url: URL
    private let parentDescriptor: Int32
    private let name: String
    private let identity: stat

    private init(parentDescriptor: Int32, name: String, url: URL) throws {
        let descriptor = openat(parentDescriptor, name, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.stagingError(at: url, underlying: Self.posixError()) }
        do {
            identity = try Self.privateDirectoryIdentity(descriptor)
        } catch {
            close(descriptor)
            throw Self.stagingError(at: url, underlying: error)
        }
        self.descriptor = descriptor
        self.parentDescriptor = parentDescriptor
        self.name = name
        self.url = url
    }

    deinit {
        close(descriptor)
        close(parentDescriptor)
    }

    /// FileManager chooses a replacement directory on the destination volume. Its
    /// parent must also be private: source names and final cleanup then stay protected.
    public static func replacementDirectory(
        for destination: URL,
        directoryDescriptor: Int32,
        fileManager: FileManager,
        inheritDestinationGroup: Bool = true
    ) throws -> PrivateFileStagingDirectory {
        let url = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination, create: true
        )
        let parent = open(url.deletingLastPathComponent().path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw posixError() }
        var ownsParent = true
        defer { if ownsParent { close(parent) } }
        do {
            _ = try privateDirectoryIdentity(parent)
        } catch {
            throw stagingError(at: url, underlying: error)
        }
        let staging = try PrivateFileStagingDirectory(
            parentDescriptor: parent, name: url.lastPathComponent, url: url
        )
        ownsParent = false
        var destinationIdentity = stat()
        guard fstat(directoryDescriptor, &destinationIdentity) == 0 else {
            let error = posixError()
            try? staging.remove()
            throw error
        }
        guard staging.identity.st_dev == destinationIdentity.st_dev else {
            try? staging.remove()
            throw posixError(code: EXDEV)
        }
        if inheritDestinationGroup, staging.identity.st_gid != destinationIdentity.st_gid,
           fchown(staging.descriptor, uid_t.max, destinationIdentity.st_gid) != 0 {
            let code = errno
            try staging.remove()
            guard code == EPERM else { throw posixError(code: code) }
            // Darwin lets a new entry inherit its parent's group even when the
            // creator cannot chown an existing inode to that group. Recreate the
            // private namespace under the destination to obtain that inheritance.
            // Its public name must be protected before mkdirat -> openat begins.
            return try destinationDirectory(
                in: directoryDescriptor, folderURL: destination,
                prefix: ".quickfile-staging-", allowRootOwnedStickyParent: true
            )
        }
        return staging
    }

    /// A probe must exercise the actual destination, not a system temporary folder.
    public static func probeDirectory(in directoryDescriptor: Int32, folderURL: URL) throws -> PrivateFileStagingDirectory {
        try destinationDirectory(in: directoryDescriptor, folderURL: folderURL, prefix: ".quickfile-write-probe-")
    }

    private static func destinationDirectory(
        in directoryDescriptor: Int32, folderURL: URL, prefix: String,
        allowRootOwnedStickyParent: Bool = false
    ) throws -> PrivateFileStagingDirectory {
        // mkdirat does not return a descriptor. Protect its new entry from other users
        // throughout mkdirat -> openat, rather than trusting the eventual entry's UID.
        try validateDestinationParent(directoryDescriptor, allowRootOwnedStickyParent: allowRootOwnedStickyParent)
        let name = prefix + UUID().uuidString
        let parent = fcntl(directoryDescriptor, F_DUPFD_CLOEXEC, 0)
        guard parent >= 0 else { throw posixError() }
        do {
            guard mkdirat(parent, name, 0o700) == 0 else { throw posixError() }
            return try PrivateFileStagingDirectory(
                parentDescriptor: parent, name: name,
                url: folderURL.appendingPathComponent(name, isDirectory: true)
            )
        } catch {
            // Do not delete a name whose opened identity/permissions were not verified.
            close(parent)
            throw error
        }
    }

    /// A rename preserves the staged inode's metadata; it does not perform the
    /// destination's normal group/ACL inheritance. Apply supported metadata before
    /// publication, and reject inherited ACLs rather than silently discarding them.
    public func applyDestinationPermissions(to fileDescriptor: Int32, in directoryDescriptor: Int32) throws {
        var directory = stat()
        guard fstat(directoryDescriptor, &directory) == 0 else { throw Self.posixError() }
        try Self.inspectACL(directoryDescriptor) { entry in
            if try Self.hasFlag(ACL_ENTRY_FILE_INHERIT, in: entry) {
                throw NSError(domain: "QuickFile.PrivateFileStaging", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "目标文件夹设置了文件继承 ACL，当前暂不支持安全创建，未发布文件。"
                ])
            }
        }
        var file = stat()
        guard fstat(fileDescriptor, &file) == 0 else { throw Self.posixError() }
        if file.st_gid != directory.st_gid {
            guard fchown(fileDescriptor, uid_t.max, directory.st_gid) == 0 else { throw Self.posixError() }
        }
    }

    /// Only known entries inside the private namespace may be unlinked. Never recurse.
    public func removeFile(named name: String) throws {
        guard unlinkat(descriptor, name, 0) == 0 else { throw Self.posixError() }
    }

    public func remove() throws {
        var current = stat()
        guard fstatat(parentDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Self.posixError()
        }
        guard current.st_dev == identity.st_dev, current.st_ino == identity.st_ino else {
            throw Self.posixError(code: ESTALE)
        }
        // Darwin has no compare-and-unlink-directory primitive. Parent permissions
        // protect our entry from other users; same-UID/root tampering is outside this boundary.
        // rmdir never removes files or nonempty directories, even after such tampering.
        guard unlinkat(parentDescriptor, name, AT_REMOVEDIR) == 0 else { throw Self.posixError() }
    }

    private static func privateDirectoryIdentity(_ descriptor: Int32) throws -> stat {
        var identity = stat()
        guard fstat(descriptor, &identity) == 0 else { throw posixError() }
        guard identity.st_uid == geteuid(), identity.st_mode & 0o777 == 0o700 else {
            throw posixError(code: EACCES)
        }
        var volume = statfs()
        guard fstatfs(descriptor, &volume) == 0 else { throw posixError() }
        guard volume.f_flags & UInt32(MNT_UNKNOWNPERMISSIONS) == 0 else {
            throw posixError(code: ENOTSUP)
        }
        // Mode 0700 alone does not exclude access granted by an inherited macOS ACL.
        try inspectACL(descriptor) { entry in
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { throw posixError() }
            guard tag != ACL_EXTENDED_ALLOW else { throw posixError(code: EACCES) }
        }
        return identity
    }

    static func validateDestinationParent(_ descriptor: Int32, allowRootOwnedStickyParent: Bool) throws {
        var directory = stat()
        guard fstat(descriptor, &directory) == 0 else { throw posixError() }
        let error = NSError(domain: "QuickFile.PrivateFileStaging", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "目标文件夹无法保护私有暂存目录免受其他用户替换，当前不能安全创建临时文件。"
        ])
        // A sticky root-owned directory also protects our name from other users.
        // Root is already outside the private-namespace boundary. A different
        // non-root owner can remove our entry despite sticky, so is never accepted.
        let trustedOwner = directory.st_uid == geteuid()
            || (allowRootOwnedStickyParent && directory.st_uid == 0 && directory.st_mode & S_ISVTX != 0)
        guard trustedOwner,
              directory.st_mode & 0o022 == 0 || directory.st_mode & S_ISVTX != 0 else {
            throw error
        }
        var volume = statfs()
        guard fstatfs(descriptor, &volume) == 0 else { throw posixError() }
        guard volume.f_flags & UInt32(MNT_UNKNOWNPERMISSIONS) == 0 else { throw error }
        try inspectACL(descriptor) { entry in
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { throw posixError() }
            guard tag == ACL_EXTENDED_ALLOW else { return }
            // An inherited grant could let another user delete or change the new
            // directory before openat verifies it, even when the parent grant is
            // inherit-only. Reject directory grants before creating that entry.
            guard try !hasFlag(ACL_ENTRY_DIRECTORY_INHERIT, in: entry) else { throw error }
            if try hasFlag(ACL_ENTRY_ONLY_INHERIT, in: entry) { return }
            var permissions: acl_permset_mask_t = 0
            guard acl_get_permset_mask_np(entry, &permissions) == 0 else { throw posixError() }
            let unsafePermissions = UInt64(ACL_DELETE_CHILD.rawValue | ACL_WRITE_SECURITY.rawValue | ACL_CHANGE_OWNER.rawValue)
            // Conservatively reject these grants even if the qualifier names our UID;
            // no group/ACL ordering interpreter is needed at this ownership boundary.
            guard permissions & unsafePermissions == 0 else { throw error }
        }
    }

    private static func hasFlag(_ flag: acl_flag_t, in entry: acl_entry_t) throws -> Bool {
        var flags: acl_flagset_t?
        guard acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0 else { throw posixError() }
        let result = acl_get_flag_np(flags!, flag)
        guard result >= 0 else { throw posixError() }
        return result != 0
    }

    private static func inspectACL(_ descriptor: Int32, entry inspect: (acl_entry_t) throws -> Void) throws {
        if let acl = acl_get_fd(descriptor) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            var entryID = Int32(ACL_FIRST_ENTRY.rawValue)
            while acl_get_entry(acl, entryID, &entry) == 0 {
                try inspect(entry!)
                entryID = Int32(ACL_NEXT_ENTRY.rawValue)
            }
        } else if errno != ENOENT && errno != ENOTSUP {
            throw posixError()
        }
    }

    private static func posixError(code: Int32? = nil) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code ?? (errno == 0 ? EIO : errno)))
    }

    private static func stagingError(at url: URL, underlying error: Error) -> NSError {
        NSError(domain: "QuickFile.PrivateFileStaging", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "无法安全使用临时目录：\(url.path)。若有残留请检查此位置。\(error.localizedDescription)",
            NSUnderlyingErrorKey: error
        ])
    }
}
