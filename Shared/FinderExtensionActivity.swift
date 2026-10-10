import Foundation

public enum FinderExtensionActivityKind: String, Codable, Equatable, Sendable {
    case launched
    case menuPrepared
    case fileCreated
    case fileCreationFailed

    public var displayName: String {
        switch self {
        case .launched:
            return "扩展已启动"
        case .menuPrepared:
            return "Finder 菜单已生成"
        case .fileCreated:
            return "扩展已创建文件"
        case .fileCreationFailed:
            return "扩展创建文件失败"
        }
    }
}

public enum FinderExtensionFailureReason: String, Codable, Equatable, Sendable {
    case menuContextUnavailable
    case templateUnavailable
    case templateReadFailed
    case templateStorageUnavailable
    case templateWriteFailed
    case destinationUnavailable
    case operationInProgress
    case destinationMissing
    case invalidFilename
    case conflictLimitReached
    case renderedContentTooLarge
    case directoryNotAuthorized
    case authorizationUnavailable
    case permissionDenied
    case readOnlyVolume
    case writeFailed
    case createdFileLocationUnavailable

    public var displayName: String {
        switch self {
        case .menuContextUnavailable:
            return "Finder 菜单上下文不可用"
        case .templateUnavailable:
            return "模板不可用"
        case .templateReadFailed:
            return "模板配置读取失败"
        case .templateStorageUnavailable:
            return "模板共享存储不可用"
        case .templateWriteFailed:
            return "模板配置保存失败"
        case .destinationUnavailable:
            return "目标文件夹不可用"
        case .operationInProgress:
            return "已有文件请求正在处理"
        case .destinationMissing:
            return "目标文件夹不存在"
        case .invalidFilename:
            return "文件名无效"
        case .conflictLimitReached:
            return "重名数量超过限制"
        case .renderedContentTooLarge:
            return "模板展开后的内容过大，未创建文件"
        case .directoryNotAuthorized:
            return "目标文件夹尚未授权"
        case .authorizationUnavailable:
            return "已保存的目录授权不可用"
        case .permissionDenied:
            return "沙箱或文件权限拒绝写入"
        case .readOnlyVolume:
            return "目标卷只读"
        case .writeFailed:
            return "文件写入失败"
        case .createdFileLocationUnavailable:
            return "文件已创建，当前位置无法确认"
        }
    }
}

public struct FinderExtensionActivityFailure: Codable, Equatable, Sendable {
    public let reason: FinderExtensionFailureReason
    public let errorDomain: String?
    public let errorCode: Int?

    public init(reason: FinderExtensionFailureReason, errorDomain: String?, errorCode: Int?) {
        self.reason = reason
        self.errorDomain = errorDomain
        self.errorCode = errorCode
    }
}

public struct FinderExtensionActivity: Codable, Equatable, Sendable {
    public let kind: FinderExtensionActivityKind
    public let timestamp: Date
    public let failure: FinderExtensionActivityFailure?

    public init(
        kind: FinderExtensionActivityKind,
        timestamp: Date,
        failure: FinderExtensionActivityFailure? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.failure = failure
    }
}
