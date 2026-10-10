import Foundation
import Darwin
import QuickFileCore

public struct DirectoryDiagnosticReport: Equatable, Sendable {
    public let folderURL: URL
    /// False means metadata could not be read; `exists` is then not a known result.
    public let existenceKnown: Bool
    public let exists: Bool
    public let isDirectory: Bool
    public let metadataErrorCode: Int32?
    public let metadataErrorDescription: String?
    public let isWritableByFileManager: Bool
    public let writeProbeSucceeded: Bool?
    public let writeProbeErrorDescription: String?
    public let volumeName: String?
    public let volumeIsReadOnly: Bool?
    public let volumeIsRemovable: Bool?
    public let volumeIsLocal: Bool?
    public let isLikelyICloud: Bool

    public var storageDescription: String {
        if isLikelyICloud {
            return "iCloud Drive"
        }
        if volumeIsRemovable == true {
            return "外接或可移除卷"
        }
        if volumeIsLocal == false {
            return "网络或非本地卷"
        }
        return "本地卷"
    }

    public var issues: [String] {
        var messages: [String] = []
        if !existenceKnown {
            messages.append(metadataErrorDescription ?? "无法确定目标路径是否存在。")
        } else if !exists {
            messages.append("目标路径不存在。")
        } else if !isDirectory {
            messages.append("目标路径不是文件夹。")
        }
        if volumeIsReadOnly == true {
            messages.append("所在卷为只读卷。")
        }
        if isDirectory && !isWritableByFileManager {
            messages.append("FileManager 报告该目录不可写。")
        }
        if writeProbeSucceeded == false {
            messages.append(writeProbeErrorDescription ?? "实际写入探针失败。")
        }
        return messages
    }
}

// FileManager supports concurrent access and each inspection keeps all mutable state local.
public struct DirectoryDiagnosticsService: @unchecked Sendable {
    private let fileManager: FileManager
    private let beforeProbeWrite: (@Sendable (URL) throws -> Void)?
    private let beforeProbeCleanup: (@Sendable (URL) throws -> Void)?

    public init() {
        fileManager = .default
        beforeProbeWrite = nil
        beforeProbeCleanup = nil
    }

    init(
        fileManager: FileManager = .default,
        beforeProbeWrite: (@Sendable (URL) throws -> Void)? = nil,
        beforeProbeCleanup: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.beforeProbeWrite = beforeProbeWrite
        self.beforeProbeCleanup = beforeProbeCleanup
    }

    public func inspect(folderURL: URL, performWriteProbe: Bool = true) -> DirectoryDiagnosticReport {
        let folderURL = folderURL.standardizedFileURL
        let isAccessingSecurityScopedResource = folderURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessingSecurityScopedResource {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        var metadata = stat()
        let exists = stat(folderURL.path, &metadata) == 0
        let metadataErrorCode: Int32? = exists ? nil : errno
        let existenceKnown = exists || metadataErrorCode == ENOENT || metadataErrorCode == ENOTDIR
        let isDirectory = exists && metadata.st_mode & S_IFMT == S_IFDIR
        let metadataErrorDescription: String?
        if !existenceKnown, let code = metadataErrorCode {
            let reason = code == EACCES || code == EPERM ? "权限不足，无法读取目标路径信息" : "无法读取目标路径信息"
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            metadataErrorDescription = "\(reason)，无法确定路径是否存在：\(error.localizedDescription)"
        } else {
            metadataErrorDescription = nil
        }
        let resourceValues = try? folderURL.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .volumeNameKey,
            .volumeIsReadOnlyKey,
            .volumeIsRemovableKey,
            .volumeIsLocalKey
        ])
        let isWritable = isDirectory && fileManager.isWritableFile(atPath: folderURL.path)

        var writeProbeSucceeded: Bool?
        var writeProbeErrorDescription: String?
        if performWriteProbe && isDirectory {
            do {
                try writeProbe(in: folderURL)
                writeProbeSucceeded = true
            } catch {
                writeProbeSucceeded = false
                writeProbeErrorDescription = "无法在目标目录完成临时写入探针：\(error.localizedDescription)"
            }
        }

        return DirectoryDiagnosticReport(
            folderURL: folderURL,
            existenceKnown: existenceKnown,
            exists: exists,
            isDirectory: isDirectory,
            metadataErrorCode: metadataErrorCode,
            metadataErrorDescription: metadataErrorDescription,
            isWritableByFileManager: isWritable,
            writeProbeSucceeded: writeProbeSucceeded,
            writeProbeErrorDescription: writeProbeErrorDescription,
            volumeName: resourceValues?.volumeName,
            volumeIsReadOnly: resourceValues?.volumeIsReadOnly,
            volumeIsRemovable: resourceValues?.volumeIsRemovable,
            volumeIsLocal: resourceValues?.volumeIsLocal,
            isLikelyICloud: isLikelyICloudURL(
                folderURL,
                resourceFlag: resourceValues?.isUbiquitousItem ?? false
            )
        )
    }

    private func writeProbe(in folderURL: URL) throws {
        let directoryFD = open(folderURL.path, O_SEARCH | O_CLOEXEC)
        guard directoryFD >= 0 else { throw posixError() }
        defer { close(directoryFD) }
        let staging = try PrivateFileStagingDirectory.probeDirectory(in: directoryFD, folderURL: folderURL)
        var fileCreated = false
        var directoryRemoved = false
        defer {
            if fileCreated { try? staging.removeFile(named: "payload") }
            if !directoryRemoved { try? staging.remove() }
        }
        do {
            try beforeProbeWrite?(staging.url)
            let descriptor = openat(staging.descriptor, "payload", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw posixError() }
            fileCreated = true
            var isOpen = true
            defer { if isOpen { close(descriptor) } }
            try Data("QuickFile write probe".utf8).withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw posixError() }
                    offset += written
                }
            }
            let closeResult = close(descriptor)
            isOpen = false
            guard closeResult == 0 else { throw posixError() }
            try beforeProbeCleanup?(staging.url)
            try staging.removeFile(named: "payload")
            fileCreated = false
            try staging.remove()
            directoryRemoved = true
        } catch {
            throw NSError(
                domain: "QuickFile.DirectoryWriteProbe", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "探针位置：\(staging.url.path)。写入或清理未完成，若有残留请检查此位置。\(error.localizedDescription)"]
            )
        }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EIO : errno))
    }

    public func isLikelyICloudURL(_ url: URL, resourceFlag: Bool) -> Bool {
        resourceFlag
            || url.path.contains("/Library/Mobile Documents/")
            || url.path.contains("/Mobile Documents/com~apple~CloudDocs/")
    }
}
