import QuickFileCore
import Foundation

/// A separate preference; reading it never loads template bodies or directory grants.
/// Call only outside Finder menu callbacks and the main thread.
public struct FileCreationSettingsStore: Sendable {
    private let storage: LocalSharedStorage?

    public enum StoreError: LocalizedError {
        case unavailable
        case malformed

        public var errorDescription: String? {
            switch self {
            case .unavailable: return QuickFileLocalization.text(.init("无法访问 QuickFile 的创建设置。"))
            case .malformed: return QuickFileLocalization.text(.init("创建设置无效，自动打开已关闭。请重新保存设置。"))
            }
        }
    }

    private struct Document: Codable {
        let version: Int
        let automaticallyOpen: Bool
    }

    public init() { storage = QuickFileSharedStorage.local }
    init(storage: LocalSharedStorage?) { self.storage = storage }

    public func loadAutomaticallyOpen() throws -> Bool {
        guard let storage else { throw StoreError.unavailable }
        let url = storage.root.appendingPathComponent("file-creation-settings.v1.json")
        let data: Data
        do {
            data = try storage.read(url, maximumBytes: 4096)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return false
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else {
            throw StoreError.malformed
        }
        return document.automaticallyOpen
    }

    public func saveAutomaticallyOpen(_ value: Bool) throws {
        guard let storage else { throw StoreError.unavailable }
        let url = storage.root.appendingPathComponent("file-creation-settings.v1.json")
        try storage.write(JSONEncoder().encode(Document(version: 1, automaticallyOpen: value)), to: url)
    }
}
