import Foundation

public struct FinderAuthorizationRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let templateID: UUID
    public let destinationFolderPath: String
    /// Nil only for legacy requests or when the original target could not be inspected.
    /// Such requests must not be resumed by adopting the current object at the same path.
    public let destinationIdentity: DirectoryIdentity?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        templateID: UUID,
        destinationFolder: URL,
        createdAt: Date = Date(),
        destinationIdentity: DirectoryIdentity? = nil
    ) {
        self.id = id
        self.templateID = templateID
        destinationFolderPath = destinationFolder.standardizedFileURL.path
        self.destinationIdentity = destinationIdentity ?? (try? DirectoryIdentity.capture(at: destinationFolder))
        self.createdAt = createdAt
    }

    public var destinationFolder: URL {
        URL(fileURLWithPath: destinationFolderPath, isDirectory: true)
    }
}
