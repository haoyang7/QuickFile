import Foundation
import QuickFileCore

public enum FinderAuthorizationCompletionError: LocalizedError, Equatable {
    case authorizedDirectoryDoesNotContainDestination
    case templateUnavailable

    public var errorDescription: String? {
        switch self {
        case .authorizedDirectoryDoesNotContainDestination:
            return "所选授权范围不包含 Finder 请求的目标文件夹，请重新发起创建。"
        case .templateUnavailable:
            return "Finder 请求使用的模板已不可用，请重新打开 Finder 菜单。"
        }
    }
}

public struct FinderAuthorizationCompletion: Equatable, Sendable {
    public let templates: [FileTemplate]
    public let selectedTemplateID: FileTemplate.ID
    public let destinationFolder: URL
    /// The exact newly persisted grant, even when it authorizes an ancestor of the target.
    public let authorizationID: UUID
    /// The target identity checked before authorizing and again within admitted access.
    public let destinationIdentity: DirectoryIdentity
    public let creationResult: FileCreationResult

    public init(
        templates: [FileTemplate],
        selectedTemplateID: FileTemplate.ID,
        destinationFolder: URL,
        authorizationID: UUID,
        destinationIdentity: DirectoryIdentity,
        creationResult: FileCreationResult
    ) {
        self.templates = templates
        self.selectedTemplateID = selectedTemplateID
        self.destinationFolder = destinationFolder
        self.authorizationID = authorizationID
        self.destinationIdentity = destinationIdentity
        self.creationResult = creationResult
    }
}

// Dependencies may be called from background work. Sendable callbacks make their
// capture safety part of the contract; execution and access lifetimes stay synchronous.
public struct FinderAuthorizationCoordinator: Sendable {
    public typealias TemplateLoader = @Sendable () throws -> [FileTemplate]
    public typealias DirectoryAuthorizer = @Sendable (URL) throws -> UUID
    public typealias AccessOperation = @Sendable () throws -> FileCreationResult
    public typealias AccessPerformer = @Sendable (
        URL,
        UUID,
        AccessOperation
    ) throws -> FileCreationResult
    public typealias FileCreator = @Sendable (FileCreationRequest) throws -> FileCreationResult
    public typealias SecurityScopeStarter = @Sendable (URL) -> Bool
    public typealias SecurityScopeStopper = @Sendable (URL) -> Void

    private let loadTemplates: TemplateLoader
    private let authorizeDirectory: DirectoryAuthorizer
    private let performWithAccess: AccessPerformer
    private let createFile: FileCreator
    private let startAccessing: SecurityScopeStarter
    private let stopAccessing: SecurityScopeStopper

    public init(
        loadTemplates: @escaping TemplateLoader,
        authorizeDirectory: @escaping DirectoryAuthorizer,
        performWithAccess: @escaping AccessPerformer,
        createFile: @escaping FileCreator,
        startAccessing: @escaping SecurityScopeStarter = { $0.startAccessingSecurityScopedResource() },
        stopAccessing: @escaping SecurityScopeStopper = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.loadTemplates = loadTemplates
        self.authorizeDirectory = authorizeDirectory
        self.performWithAccess = performWithAccess
        self.createFile = createFile
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
    }

    public func complete(
        _ request: FinderAuthorizationRequest,
        authorizedDirectory: URL,
        clipboard: String? = nil
    ) throws -> FinderAuthorizationCompletion {
        // Keep the original panel URL when starting access; reconstructing it from a path
        // can lose its security scope. NSOpenPanel may already provide implicit access,
        // so a false start is not by itself a failure. Validation below must still succeed.
        let selectedDirectoryURL = authorizedDirectory
        let didStartAccessing = startAccessing(selectedDirectoryURL)
        defer {
            if didStartAccessing { stopAccessing(selectedDirectoryURL) }
        }

        let destinationFolder = request.destinationFolder.standardizedFileURL
        let authorizedDirectory = selectedDirectoryURL.standardizedFileURL
        guard DirectoryPathPolicy.directory(authorizedDirectory, contains: destinationFolder) else {
            throw FinderAuthorizationCompletionError.authorizedDirectoryDoesNotContainDestination
        }

        let templates = try loadTemplates()
        guard let template = templates.first(where: {
            $0.id == request.templateID && $0.isEnabled
        }) else {
            throw FinderAuthorizationCompletionError.templateUnavailable
        }

        // A legacy path-only request cannot establish which directory the user originally chose.
        guard let expectedIdentity = request.destinationIdentity else {
            throw FileCreationError.destinationIdentityChanged
        }

        // Check under the panel's temporary access before committing a persistent grant.
        // A target already replaced/missing at this preflight must not create/refresh a grant.
        // This is not atomic with persistence; retain the later check for changes while authorizing.
        guard (try? DirectoryIdentity.capture(at: destinationFolder)) == expectedIdentity else {
            throw FileCreationError.destinationIdentityChanged
        }

        let authorizationID = try authorizeDirectory(authorizedDirectory)
        let result = try performWithAccess(destinationFolder, authorizationID) {
            guard (try? DirectoryIdentity.capture(at: destinationFolder)) == expectedIdentity else {
                throw FileCreationError.destinationIdentityChanged
            }
            return try createFile(
                FileCreationRequest(
                    template: template,
                    destinationFolder: destinationFolder,
                    requestedFilename: nil,
                    clipboard: clipboard,
                    expectedDirectoryIdentity: expectedIdentity
                )
            )
        }

        return FinderAuthorizationCompletion(
            templates: templates,
            selectedTemplateID: template.id,
            destinationFolder: destinationFolder,
            authorizationID: authorizationID,
            destinationIdentity: expectedIdentity,
            creationResult: result
        )
    }
}
