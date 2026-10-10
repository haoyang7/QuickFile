import Foundation
import QuickFileCore

public enum FinderFileCreationError: LocalizedError, Equatable {
    case menuContextUnavailable
    case templateUnavailable
    case destinationUnavailable
    case operationInProgress
    case directoryAuthorizationRequired(templateID: UUID, destinationFolder: URL, destinationIdentity: DirectoryIdentity? = nil)

    public var errorDescription: String? {
        switch self {
        case .menuContextUnavailable:
            return "Finder 菜单状态已失效，请重新打开 Finder 菜单后再试。"
        case .templateUnavailable:
            return "所选模板已不可用，请重新打开 Finder 菜单后再试。"
        case .destinationUnavailable:
            return "无法确定创建目录：所选项目可能来自不同文件夹，或目标已经失效。请重新选择后再试。"
        case .operationInProgress:
            return "已有文件请求正在处理，本次请求未执行。请等待处理完成或检查目标卷后再试。"
        case .directoryAuthorizationRequired:
            return "此 Finder 位置尚未授权。"
        }
    }
}

// Dependencies may be called from background work. Sendable callbacks make their
// capture safety part of the contract; execution and access lifetimes stay synchronous.
public struct FinderFileCreationCoordinator: Sendable {
    public typealias TemplateLoader = @Sendable (UUID) throws -> FileTemplate?
    public typealias AccessOperation = @Sendable () throws -> FileCreationResult
    public typealias AccessPerformer = @Sendable (
        URL,
        AccessOperation
    ) throws -> FileCreationResult
    public typealias FileCreator = @Sendable (FileCreationRequest) throws -> FileCreationResult
    public typealias AuthorizationRequirementEvaluator = @Sendable (Error) -> Bool
    public typealias SelectionResolver = @Sendable (FinderMenuContext, URL?, [URL]) -> URL?

    private let loadTemplate: TemplateLoader
    private let performWithAccess: AccessPerformer
    private let createFile: FileCreator
    private let requiresAuthorization: AuthorizationRequirementEvaluator
    private let resolveSelection: SelectionResolver

    public init(
        loadTemplate: @escaping TemplateLoader,
        performWithAccess: @escaping AccessPerformer,
        createFile: @escaping FileCreator,
        requiresAuthorization: @escaping AuthorizationRequirementEvaluator,
        resolveSelection: @escaping SelectionResolver = { context, targetedURL, selectedItemURLs in
            FinderContextResolver().destinationFolder(
                for: context, targetedURL: targetedURL, selectedItemURLs: selectedItemURLs
            )
        }
    ) {
        self.loadTemplate = loadTemplate
        self.performWithAccess = performWithAccess
        self.createFile = createFile
        self.requiresAuthorization = requiresAuthorization
        self.resolveSelection = resolveSelection
    }

    public func createFile(for action: FinderMenuAction, timing: CreationTiming? = nil) throws -> FileCreationResult {
        let (prepared, destinationFolder) = try {
            timing?.mark("destination.validation.begin")
            defer { timing?.mark("destination.validation.end") }
            do {
                guard let prepared = action.preparedDestination else {
                    throw FinderFileCreationError.destinationUnavailable
                }
                let destinationFolder: URL
                switch action.target {
                case let .directory(directory):
                    destinationFolder = directory.standardizedFileURL
                case let .selection(targetedURL, selectedItemURLs):
                    // Invoked on the creation queue, never while Finder is asking for its menu.
                    guard let resolved = resolveSelection(action.context, targetedURL, selectedItemURLs) else {
                        throw FinderFileCreationError.destinationUnavailable
                    }
                    destinationFolder = resolved.standardizedFileURL
                }

                // Revalidation cannot establish a new identity: the immutable menu snapshot is
                // authoritative, even if this path now resolves to another directory or symlink.
                guard destinationFolder == prepared.folder,
                      try DirectoryIdentity.capture(at: destinationFolder) == prepared.identity else {
                    throw FileCreationError.destinationIdentityChanged
                }
                timing?.mark("destination.validation.validated")
                return (prepared, destinationFolder)
            } catch {
                timing?.mark("destination.validation.failed")
                throw error
            }
        }()
        let destinationIdentity = prepared.identity
        let template = try {
            timing?.mark("templates.load.begin")
            defer { timing?.mark("templates.load.end") }
            do {
                guard let template = try loadTemplate(action.templateID),
                      template.id == action.templateID, template.isEnabled else {
                    throw FinderFileCreationError.templateUnavailable
                }
                timing?.mark("templates.load.loaded")
                return template
            } catch {
                timing?.mark("templates.load.failed")
                throw error
            }
        }()

        do {
            return try performWithAccess(destinationFolder) {
                try createFile(
                    FileCreationRequest(
                        template: template,
                        destinationFolder: destinationFolder,
                        requestedFilename: nil,
                        expectedDirectoryIdentity: destinationIdentity,
                        timing: timing
                    )
                )
            }
        } catch {
            guard requiresAuthorization(error) else {
                throw error
            }
            throw FinderFileCreationError.directoryAuthorizationRequired(
                templateID: template.id,
                destinationFolder: destinationFolder,
                destinationIdentity: destinationIdentity
            )
        }
    }
}
