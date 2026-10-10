import Foundation
import QuickFileCore

// FileManager supports concurrent access and this policy has no mutable state of its own.
struct AuthorizedDirectoryPolicy: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func validate(_ directoryURL: URL) throws {
        guard directoryURL.isFileURL else {
            throw AuthorizedDirectoryStoreError.directoryIsNotFileURL
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            throw AuthorizedDirectoryStoreError.directoryDoesNotExist
        }
        guard isDirectory.boolValue else {
            throw AuthorizedDirectoryStoreError.directoryIsNotDirectory
        }
    }

    static func canonicalURL(_ url: URL) -> URL {
        DirectoryPathPolicy.canonicalURL(url)
    }

    static func directory(_ directoryURL: URL, contains candidateURL: URL) -> Bool {
        DirectoryPathPolicy.directory(directoryURL, contains: candidateURL)
    }
}
