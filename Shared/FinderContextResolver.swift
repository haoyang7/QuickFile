import Foundation
import Darwin

public enum FinderMenuContext: Equatable, Sendable {
    case items
    case container
    case sidebar
    case toolbar
}

public struct FinderContextResolver {
    private let directoryExists: (URL) -> Bool
    private let selectionEntryExists: (URL) -> Bool

    public init() {
        self.init(fileManager: .default)
    }

    init(fileManager: FileManager) {
        self.init(isDirectory: { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }, entryExists: { url in
            var metadata = stat()
            return lstat(url.path, &metadata) == 0
        })
    }

    // Keep explicit metadata dependencies observable without replacing URL normalization.
    init(isDirectory: @escaping (URL) -> Bool, entryExists: @escaping (URL) -> Bool) {
        directoryExists = isDirectory
        selectionEntryExists = entryExists
    }

    public func destinationFolder(
        for context: FinderMenuContext,
        targetedURL: URL?,
        selectedItemURLs: [URL]
    ) -> URL? {
        switch context {
        case .container:
            guard let targetedURL, isDirectory(targetedURL) else { return nil }
            return targetedURL.standardizedFileURL
        case .items:
            return selectedItemURLs.isEmpty
                ? directoryRepresented(by: targetedURL)
                : destinationForSelection(selectedItemURLs)
        case .sidebar:
            // In a sidebar callback Finder supplies the clicked item as its selection;
            // targetedURL can still point at the front window's directory. Never use
            // that window target (or a selected file's parent) as a sidebar fallback.
            guard selectedItemURLs.count == 1,
                  let sidebarURL = selectedItemURLs.first,
                  isDirectory(sidebarURL) else { return nil }
            return sidebarURL.standardizedFileURL
        case .toolbar:
            return targetedURL == nil
                ? destinationForSelection(selectedItemURLs)
                : directoryRepresented(by: targetedURL)
        }
    }

    private func destinationForSelection(_ selectedItemURLs: [URL]) -> URL? {
        guard let firstURL = selectedItemURLs.first else {
            return nil
        }

        if selectedItemURLs.count == 1 {
            return directoryRepresented(by: firstURL)
        }

        let commonParent = firstURL.deletingLastPathComponent().standardizedFileURL
        // Reject the full mixed-parent selection before explicit parent/item metadata
        // reads. standardizedFileURL itself may consult the filesystem on some paths.
        guard selectedItemURLs.dropFirst().allSatisfy({
            $0.deletingLastPathComponent().standardizedFileURL == commonParent
        }) else { return nil }
        guard isDirectory(commonParent), selectedItemURLs.allSatisfy({ entryExists($0) }) else {
            return nil
        }
        return commonParent
    }

    private func directoryRepresented(by url: URL?) -> URL? {
        guard let url, url.isFileURL else {
            return nil
        }

        let standardizedURL = url.standardizedFileURL
        var metadata = stat()
        guard lstat(standardizedURL.path, &metadata) == 0 else {
            return nil
        }
        if metadata.st_mode & S_IFMT == S_IFLNK {
            var target = stat()
            if stat(standardizedURL.path, &target) == 0 {
                metadata = target
            } else if errno != ENOENT && errno != ENOTDIR {
                // An inaccessible directory link is not a file in its parent directory.
                return nil
            }
        }
        if metadata.st_mode & S_IFMT == S_IFDIR {
            return standardizedURL
        }

        let parentURL = standardizedURL.deletingLastPathComponent()
        return isDirectory(parentURL) ? parentURL : nil
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return directoryExists(url)
    }

    private func entryExists(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return selectionEntryExists(url)
    }
}
