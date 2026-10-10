import Foundation
import Darwin

/// Persisted identity for a directory selected before an asynchronous authorization step.
/// Birth time and generation also reject a recycled inode. Modification times are deliberately
/// excluded: creating unrelated entries must not invalidate an otherwise unchanged directory.
public struct DirectoryIdentity: Codable, Equatable, Sendable {
    private let device: Int32
    private let inode: UInt64
    private let generation: UInt32
    private let birthSeconds: Int64
    private let birthNanoseconds: Int64

    public static func capture(at url: URL) throws -> DirectoryIdentity {
        guard url.isFileURL else { throw FileCreationError.destinationIsNotFileURL }
        var attributes = stat()
        guard stat(url.path, &attributes) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return try DirectoryIdentity(attributes: attributes)
    }

    public init(descriptor: Int32) throws {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try self.init(attributes: attributes)
    }

    private init(attributes: stat) throws {
        guard attributes.st_mode & S_IFMT == S_IFDIR else {
            throw FileCreationError.destinationIdentityChanged
        }
        device = attributes.st_dev
        inode = UInt64(attributes.st_ino)
        generation = attributes.st_gen
        birthSeconds = Int64(attributes.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(attributes.st_birthtimespec.tv_nsec)
    }
}

public struct FileCreationRequest: Sendable {
    public let template: FileTemplate
    public let destinationFolder: URL
    public let requestedFilename: String?
    public let clipboard: String?
    public let expectedDirectoryIdentity: DirectoryIdentity?
    public let timing: CreationTiming?

    public init(
        template: FileTemplate,
        destinationFolder: URL,
        requestedFilename: String?,
        clipboard: String? = nil,
        expectedDirectoryIdentity: DirectoryIdentity? = nil,
        timing: CreationTiming? = nil
    ) {
        self.template = template
        self.destinationFolder = destinationFolder
        self.requestedFilename = requestedFilename
        self.clipboard = clipboard
        self.expectedDirectoryIdentity = expectedDirectoryIdentity
        self.timing = timing
    }
}

public struct FileCreationResult: Equatable, Sendable {
    public let fileURL: URL
    public let didRenameForConflict: Bool

    public init(fileURL: URL, didRenameForConflict: Bool) {
        self.fileURL = fileURL
        self.didRenameForConflict = didRenameForConflict
    }
}

public enum FileCreationError: LocalizedError {
    case destinationIsNotFileURL
    case destinationDoesNotExist(URL)
    case destinationIsNotDirectory(URL)
    case destinationIdentityChanged
    case invalidFilename
    case conflictLimitReached
    case writeFailed(URL, Error)
    /// The file was committed; callers must not retry creation automatically.
    case createdFileLocationUnavailable(filename: String, underlyingError: Error)
    case renderedContentTooLarge(maximumUTF8Bytes: Int)

    public var errorDescription: String? {
        switch self {
        case .destinationIsNotFileURL:
            return "目标位置不是本地文件夹。"
        case let .destinationDoesNotExist(url):
            return "目标文件夹不存在：\(url.path)"
        case let .destinationIsNotDirectory(url):
            return "目标位置不是文件夹：\(url.path)"
        case .destinationIdentityChanged:
            return "原目标文件夹已变化或无法确认身份，本次未创建文件。请从 Finder 重新发起创建。"
        case .invalidFilename:
            return "文件名无效，请换一个名称后重试。"
        case .conflictLimitReached:
            return "同名文件过多，无法生成可用文件名。"
        case let .renderedContentTooLarge(maximumUTF8Bytes):
            return "模板展开后的内容超过 \(maximumUTF8Bytes) 字节的 UTF-8 上限，本次未创建文件。请缩短模板内容或剪贴板文本。"
        case let .createdFileLocationUnavailable(filename, error):
            return "文件 \(filename) 已保存，但无法确认当前位置：\(error.localizedDescription)。请先检查目标文件夹，避免重复创建。"
        case let .writeFailed(url, error):
            return "无法写入 \(url.lastPathComponent)：\(error.localizedDescription)"
        }
    }
}
