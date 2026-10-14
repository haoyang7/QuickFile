import Foundation
import notify
import QuickFileCore

/// A single preference with atomic last-writer-wins saves, independent of templates and grants.
public struct LanguageSettingsStore: Sendable {
    public static let notificationName = "com.haoyoung.QuickFile.language-settings-did-change"
    private let storage: LocalSharedStorage?
    private let changeNotificationName: String?
    private struct Document: Codable {
        let version: Int
        let language: QuickFileLanguage
    }

    public enum StoreError: LocalizedError {
        case unavailable, malformed

        public var errorDescription: String? {
            switch self {
            case .unavailable: return QuickFileLocalization.text(.init("无法访问 QuickFile 的语言设置。"))
            case .malformed: return QuickFileLocalization.text(.init("语言设置无效，已保留当前语言。请重新选择并保存。"))
            }
        }
    }

    public init() {
        storage = QuickFileSharedStorage.local
        changeNotificationName = Self.notificationName
    }

    init(storage: LocalSharedStorage?, changeNotificationName: String? = nil) {
        self.storage = storage
        self.changeNotificationName = changeNotificationName
    }

    public func load() throws -> QuickFileLanguage {
        guard let storage else { throw StoreError.unavailable }
        let url = storage.root.appendingPathComponent("language-settings.v1.json")
        let data: Data
        do {
            data = try storage.read(url, maximumBytes: 4096)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .system
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else {
            throw StoreError.malformed
        }
        return document.language
    }

    public func save(_ language: QuickFileLanguage) throws {
        guard let storage else { throw StoreError.unavailable }
        try storage.write(JSONEncoder().encode(Document(version: 1, language: language)),
                          to: storage.root.appendingPathComponent("language-settings.v1.json"))
        if let changeNotificationName { notify_post(changeNotificationName) }
    }
}
