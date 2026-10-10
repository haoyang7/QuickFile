import Foundation
import Darwin
import QuickFileCore

/// Only local, user-selected file I/O lives here; UI owns panels and confirmation.
public enum TemplateTransferFile {
    public static func read(
        from url: URL, limits: TemplateTransferLimits = .default
    ) throws -> TemplateTransferBundle {
        try limits.validate()
        guard url.isFileURL else { throw TemplateTransferError.nonLocalFile }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError() }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        var data = Data()
        // Read at most max + 1, including on a file that grows after it is opened.
        // Do not trust metadata or mmap an arbitrary user-selected file.
        let readLimit = limits.maximumFileBytes + 1
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < readLimit {
            let request = min(buffer.count, readLimit - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, request) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= limits.maximumFileBytes else {
            throw TemplateTransferError.fileTooLarge(maximumBytes: limits.maximumFileBytes)
        }
        return try TemplateTransfer.decode(data, limits: limits)
    }

    enum ExportCheckpoint: Sendable {
        case afterEncoding
        case afterOpeningDirectory
        case beforePublication
    }

    public enum ExportError: LocalizedError {
        case destinationChanged
        case unsupportedDestination

        public var errorDescription: String? {
            switch self {
            case .destinationChanged:
                return "导出文件夹在操作期间发生变化，未发布模板文件。请重新选择位置。"
            case .unsupportedDestination:
                return "导出位置不是可安全替换的普通文件，请选择其他位置。"
            }
        }
    }

    /// Infrastructure-only publication primitive. The app uses TemplateStore's
    /// exportTemplates so protected-store checks and publication share this FD.
    static func write(
        _ bundle: TemplateTransferBundle, to url: URL, limits: TemplateTransferLimits = .default,
        validateDestination: (Int32, String) throws -> Void = { _, _ in },
        checkpoint: ((ExportCheckpoint) throws -> Void)? = nil
    ) throws {
        guard url.isFileURL else { throw TemplateTransferError.nonLocalFile }
        guard !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" else {
            throw ExportError.unsupportedDestination
        }
        // Finish all bounded encoding before creating a staging file. Parent paths
        // may change during encoding; only the subsequently opened FD is authority.
        let data = try TemplateTransfer.encode(bundle, limits: limits)
        try checkpoint?(.afterEncoding)
        let parentURL = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let parent = open(parentURL.path, O_SEARCH | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw posixError() }
        defer { close(parent) }
        try validateNamedParent(parent, at: parentURL)
        try validateFinalEntry(in: parent, named: name)
        try validateDestination(parent, name)
        try checkpoint?(.afterOpeningDirectory)

        let staging = try PrivateFileStagingDirectory.replacementDirectory(
            for: directoryURL(for: parent), directoryDescriptor: parent, fileManager: .default,
            inheritDestinationGroup: false
        )
        defer { try? staging.remove() }
        let temporaryName = "payload"
        let descriptor = openat(staging.descriptor, temporaryName,
                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var published = false
        defer { if !published { try? staging.removeFile(named: temporaryName) } }
        var isOpen = true
        defer { if isOpen { close(descriptor) } }
        // Exported template bodies remain owner-only (0600). A Save panel grants
        // access to the selected file, not permission to create sibling staging
        // directories or change their group. Creation's group/ACL inheritance is
        // deliberately separate from this private transfer-file publication.
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError() }
        let closeResult = close(descriptor)
        isOpen = false
        guard closeResult == 0 else { throw posixError() }
        try checkpoint?(.beforePublication)
        try validateNamedParent(parent, at: parentURL)
        try validateFinalEntry(in: parent, named: name)
        // Re-evaluate the actual pinned parent's location too: a rename can move
        // the same directory inode into a protected backup subtree.
        try validateDestination(parent, name)
        // Unlike new-file creation, Save-panel export explicitly permits replacing
        // this filename. Both staging and destination are descriptor-relative; a
        // retargeted parent symlink can never redirect this rename to another inode.
        guard renameat(staging.descriptor, temporaryName, parent, name) == 0 else { throw posixError() }
        published = true
    }

    static func directoryURL(for descriptor: Int32) throws -> URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { throw posixError() }
        let url = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        try validateNamedParent(descriptor, at: url)
        return url
    }

    private static func validateNamedParent(_ descriptor: Int32, at url: URL) throws {
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0 else { throw posixError() }
        guard stat(url.path, &named) == 0, opened.st_mode & S_IFMT == S_IFDIR,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            throw ExportError.destinationChanged
        }
    }

    private static func validateFinalEntry(in parent: Int32, named name: String) throws {
        var entry = stat()
        if fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 {
            guard entry.st_mode & S_IFMT == S_IFREG else { throw ExportError.unsupportedDestination }
        } else if errno != ENOENT {
            throw posixError()
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
