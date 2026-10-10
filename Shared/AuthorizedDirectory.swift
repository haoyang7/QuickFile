import Foundation

public struct AuthorizedDirectory: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let isBookmarkStale: Bool

    public init(id: UUID, url: URL, isBookmarkStale: Bool) {
        self.id = id
        self.url = url
        self.isBookmarkStale = isBookmarkStale
    }
}

public struct UnavailableAuthorizedDirectory: Identifiable, Equatable, Sendable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}

public struct AuthorizedDirectoryInventory: Equatable, Sendable {
    public let availableDirectories: [AuthorizedDirectory]
    public let unavailableDirectories: [UnavailableAuthorizedDirectory]

    public init(
        availableDirectories: [AuthorizedDirectory],
        unavailableDirectories: [UnavailableAuthorizedDirectory]
    ) {
        self.availableDirectories = availableDirectories
        self.unavailableDirectories = unavailableDirectories
    }
}

public struct ResolvedSecurityScopedBookmark: Sendable {
    public let url: URL
    public let isStale: Bool

    public init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }
}

public enum AuthorizedDirectoryStoreError: LocalizedError {
    case sharedDefaultsUnavailable
    case directoryIsNotFileURL
    case directoryDoesNotExist
    case directoryIsNotDirectory
    case bookmarkCreationFailed(Error)
    case bookmarkResolutionFailed(Error)
    case authorizationResolutionFailed(unresolvedCount: Int)
    case bookmarkRefreshFailed(failedAuthorizationIDs: [UUID], underlyingError: Error)
    case authorizationChanged
    case persistenceFailed(Error)
    case directoryNotAuthorized
    case securityScopeUnavailable

    public var errorDescription: String? {
        switch self {
        case .sharedDefaultsUnavailable:
            return "无法访问 QuickFile 的共享目录授权存储。"
        case .directoryIsNotFileURL:
            return "只能授权本地文件夹。"
        case .directoryDoesNotExist:
            return "要授权的文件夹不存在。"
        case .directoryIsNotDirectory:
            return "所选位置不是文件夹。"
        case .bookmarkCreationFailed:
            return "无法保存文件夹授权，请重新选择该文件夹。"
        case .bookmarkResolutionFailed:
            return "已保存的文件夹授权已失效，请在 QuickFile 中重新授权。"
        case let .authorizationResolutionFailed(unresolvedCount):
            return "有 \(unresolvedCount) 个文件夹授权已失效，请在诊断页移除后重新授权。"
        case let .bookmarkRefreshFailed(failedAuthorizationIDs, _):
            return "有 \(failedAuthorizationIDs.count) 个 Finder 文件夹授权无法刷新，请重新确认这些授权。"
        case .authorizationChanged:
            return "文件夹授权已被其他操作更新，请重新选择该文件夹。"
        case .persistenceFailed:
            return "无法读取或保存 QuickFile 的共享目录授权。"
        case .directoryNotAuthorized:
            return "此 Finder 位置尚未授权。请打开 QuickFile，在“诊断”中添加该文件夹或其上级文件夹。"
        case .securityScopeUnavailable:
            return "无法启用已保存的文件夹授权，请在 QuickFile 中重新授权。"
        }
    }

    public var underlyingError: Error? {
        switch self {
        case let .bookmarkCreationFailed(error),
             let .bookmarkResolutionFailed(error),
             let .bookmarkRefreshFailed(_, error),
             let .persistenceFailed(error):
            return error
        case .sharedDefaultsUnavailable,
             .directoryIsNotFileURL,
             .directoryDoesNotExist,
             .directoryIsNotDirectory,
             .authorizationResolutionFailed,
             .authorizationChanged,
             .directoryNotAuthorized,
             .securityScopeUnavailable:
            return nil
        }
    }
}
