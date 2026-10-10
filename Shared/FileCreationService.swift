import Foundation
import Darwin

// FileManager is documented as safe to use from multiple threads. All other collaborators are
// immutable Sendable values or @Sendable providers.
public struct FileCreationService: @unchecked Sendable {
    typealias DateProvider = @Sendable () -> Date
    public typealias ClipboardProvider = @Sendable () -> String?

    private let fileManager: FileManager
    private let filenameNormalizer: FilenameNormalizer
    private let templateRenderer: TemplateRenderer
    private let dateProvider: DateProvider
    private let clipboardProvider: ClipboardProvider
    private let beforeCommit: (@Sendable (URL) throws -> Void)?

    public init(clipboardProvider: @escaping ClipboardProvider = { nil }) {
        fileManager = .default
        filenameNormalizer = FilenameNormalizer()
        templateRenderer = TemplateRenderer()
        dateProvider = { Date() }
        self.clipboardProvider = clipboardProvider
        beforeCommit = nil
    }

    init(
        fileManager: FileManager = .default,
        filenameNormalizer: FilenameNormalizer = FilenameNormalizer(),
        templateRenderer: TemplateRenderer = TemplateRenderer(),
        dateProvider: @escaping DateProvider = { Date() },
        clipboardProvider: @escaping ClipboardProvider = { nil },
        beforeCommit: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.filenameNormalizer = filenameNormalizer
        self.templateRenderer = templateRenderer
        self.dateProvider = dateProvider
        self.clipboardProvider = clipboardProvider
        self.beforeCommit = beforeCommit
    }

    public func createFile(for request: FileCreationRequest) throws -> FileCreationResult {
        if let clipboard = request.clipboard {
            return try createFile(for: request, clipboard: clipboard)
        }
        return try createFile(for: request, clipboardProvider: clipboardProvider)
    }

    public func createFile(
        for request: FileCreationRequest,
        clipboard: String
    ) throws -> FileCreationResult {
        try createFile(for: request, clipboardProvider: { clipboard })
    }

    private func createFile(
        for request: FileCreationRequest,
        clipboardProvider: ClipboardProvider
    ) throws -> FileCreationResult {
        let timing = request.timing
        var preflightCompleted = false
        defer {
            if !preflightCompleted {
                timing?.mark("writer.preflight.failed")
                timing?.mark("writer.preflight.end")
            }
            timing?.mark("writer.end")
        }
        timing?.mark("writer.preflight.begin")
        let destinationFolder = request.destinationFolder.standardizedFileURL
        guard destinationFolder.isFileURL else {
            throw FileCreationError.destinationIsNotFileURL
        }

        let requestedName = request.requestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveName = requestedName.flatMap { $0.isEmpty ? nil : $0 }
            ?? request.template.defaultFilename
        let normalizedFilename = try filenameNormalizer.normalize(
            effectiveName,
            requiredExtension: request.template.fileExtension
        )
        let isAccessingSecurityScopedResource = destinationFolder.startAccessingSecurityScopedResource()
        defer {
            if isAccessingSecurityScopedResource {
                destinationFolder.stopAccessingSecurityScopedResource()
            }
        }

        var destination = stat()
        guard stat(destinationFolder.path, &destination) == 0 else {
            throw destinationError(code: errno, at: destinationFolder)
        }
        guard destination.st_mode & S_IFMT == S_IFDIR else {
            throw FileCreationError.destinationIsNotDirectory(destinationFolder)
        }

        // Anchor every operation to the opened directory, including cleanup and commit.
        // O_SEARCH allows writable/searchable directories without listing permission.
        let directoryFD = open(destinationFolder.path, O_SEARCH | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw destinationError(code: errno, at: destinationFolder)
        }
        defer { close(directoryFD) }
        if let expectedIdentity = request.expectedDirectoryIdentity,
           try DirectoryIdentity(descriptor: directoryFD) != expectedIdentity {
            throw FileCreationError.destinationIdentityChanged
        }
        var volume = statfs()
        guard fstatfs(directoryFD, &volume) == 0 else {
            throw FileCreationError.writeFailed(destinationFolder, posixError())
        }
        try Self.validateCreationVolume(flags: volume.f_flags, folderURL: destinationFolder)
        errno = 0
        let nameLimit = fpathconf(directoryFD, _PC_NAME_MAX)
        guard nameLimit > 0 else {
            throw FileCreationError.writeFailed(destinationFolder, posixError(fallback: ENOTSUP))
        }
        var renderingInputs: (date: Date, clipboard: String)?
        preflightCompleted = true
        timing?.mark("writer.preflight.validated")
        timing?.mark("writer.preflight.end")

        for sequence in 1...10_000 {
            // NAME_MAX need not describe UTF-8 bytes (APFS accepts longer encoded
            // Unicode names). Preserve the original candidate unless the FS rejects it.
            var filename = try normalizedFilename.filename(sequence: sequence)
            var status = stat()
            var lookupResult = fstatat(directoryFD, filename, &status, AT_SYMLINK_NOFOLLOW)
            if lookupResult != 0 && errno == ENAMETOOLONG {
                filename = try normalizedFilename.filename(sequence: sequence, maximumUTF8Bytes: nameLimit)
                lookupResult = fstatat(directoryFD, filename, &status, AT_SYMLINK_NOFOLLOW)
            }
            let fileURL = destinationFolder.appendingPathComponent(filename, isDirectory: false)
            if lookupResult == 0 { continue }
            guard errno == ENOENT else {
                throw FileCreationError.writeFailed(fileURL, posixError())
            }

            let inputs: (date: Date, clipboard: String)
            if let renderingInputs {
                inputs = renderingInputs
            } else {
                let capturedInputs = (dateProvider(), request.template.usesClipboard ? clipboardProvider() ?? "" : "")
                renderingInputs = capturedInputs
                inputs = capturedInputs
            }
            let context = TemplateRenderingContext(
                date: inputs.date,
                folderName: destinationFolder.lastPathComponent,
                clipboard: inputs.clipboard,
                sequence: sequence
            )
            let data = Data(try templateRenderer.render(request.template.content, context: context).utf8)
            do {
                if let committedURL = try commit(data, named: filename, in: directoryFD, folderURL: destinationFolder, timing: timing) {
                    timing?.mark("writer.result.ready")
                    return FileCreationResult(fileURL: committedURL, didRenameForConflict: sequence > 1)
                }
            } catch let error as FileCreationError {
                throw error
            } catch {
                throw FileCreationError.writeFailed(fileURL, error)
            }
        }

        throw FileCreationError.conflictLimitReached
    }

    static func validateCreationVolume(flags: UInt32, folderURL: URL) throws {
        // FileManager can choose another volume for a read-only destination's replacement
        // directory. Reject before staging so that failure remains a read-only error.
        let code: Int32
        let description: String
        if flags & UInt32(MNT_RDONLY) != 0 {
            code = EROFS
            description = "目标卷为只读，无法创建文件。"
        } else if flags & UInt32(MNT_UNKNOWNPERMISSIONS) != 0 {
            code = ENOTSUP
            description = "目标卷忽略文件所有权，无法保护私有暂存目录，当前不能安全创建文件。"
        } else {
            return
        }
        throw FileCreationError.writeFailed(folderURL, NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: description]
        ))
    }

    // An exclusive rename publishes only a fully written file after closing its write handle. Unsupported
    // filesystems fail safely; never fall back to an overwriting rename or a final-path write.
    private func commit(_ data: Data, named filename: String, in directoryFD: Int32, folderURL: URL, timing: CreationTiming?) throws -> URL? {
        timing?.mark("staging.begin")
        let staging = try PrivateFileStagingDirectory.replacementDirectory(
            for: folderURL, directoryDescriptor: directoryFD, fileManager: fileManager
        )
        timing?.mark("staging.ready")
        defer {
            timing?.mark("staging.cleanup.attempt.begin")
            try? staging.remove()
            timing?.mark("staging.cleanup.attempt.end")
        }
        let temporaryName = "payload"
        let descriptor = openat(staging.descriptor, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { throw posixError() }
        var committed = false
        defer { if !committed { try? staging.removeFile(named: temporaryName) } }
        var isOpen = true
        defer { if isOpen { close(descriptor) } }
        try staging.applyDestinationPermissions(to: descriptor, in: directoryFD)
        timing?.mark("payload.permissions.ready")
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw posixError(fallback: EIO) }
                offset += written
            }
        }
        // Capture identity before the final writer close. A duplicated descriptor
        // would postpone that close and could hide a writeback failure until publication.
        var identity = stat()
        guard fstat(descriptor, &identity) == 0 else { throw posixError() }
        let closeResult = close(descriptor)
        isOpen = false
        guard closeResult == 0 else { throw posixError() }
        timing?.mark("payload.closed")
        try beforeCommit?(staging.url)
        // The closed writer's source name is in an owner-only namespace, not the
        // shared destination. Replacing a public destination name cannot swap it.
        if renameatx_np(staging.descriptor, temporaryName, directoryFD, filename, UInt32(RENAME_EXCL)) == 0 {
            committed = true
            timing?.mark("file.published")
            do {
                let url = try committedURL(named: filename, in: directoryFD, identity: identity)
                timing?.mark("file.location.verified")
                return url
            } catch {
                // Publication succeeded. Never remove a committed file or report
                // this as a failed write that callers could safely retry.
                throw FileCreationError.createdFileLocationUnavailable(filename: filename, underlyingError: error)
            }
        }
        if errno == EEXIST { return nil }
        throw posixError()
    }

    private func committedURL(named filename: String, in directoryFD: Int32, identity: stat) throws -> URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(directoryFD, F_GETPATH, &path) == 0 else { throw posixError() }
        let url = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
        var current = stat()
        guard lstat(url.path, &current) == 0 else { throw posixError() }
        guard current.st_dev == identity.st_dev, current.st_ino == identity.st_ino else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE))
        }
        return url
    }

    private func posixError(fallback: Int32 = EIO) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? fallback : errno))
    }

    private func destinationError(code: Int32, at url: URL) -> FileCreationError {
        switch code {
        case ENOENT:
            return .destinationDoesNotExist(url)
        case ENOTDIR:
            return .destinationIsNotDirectory(url)
        default:
            return .writeFailed(url, NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
        }
    }

}
