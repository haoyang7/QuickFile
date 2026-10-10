import Foundation

public enum DirectoryPathPolicy {
    public static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func directory(_ directoryURL: URL, contains candidateURL: URL) -> Bool {
        let directoryComponents = canonicalURL(directoryURL).pathComponents
        let candidateComponents = canonicalURL(candidateURL).pathComponents
        return candidateComponents.starts(with: directoryComponents)
    }
}
