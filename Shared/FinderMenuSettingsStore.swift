import Foundation
import notify
import QuickFileCore

/// Independent, atomically replaced settings file; never reads or rewrites templates.json.
/// Resolve the App Group URL inside load/save so callers can keep all I/O off the main thread.
public final class FinderMenuSettingsStore: @unchecked Sendable {
    public static let notificationName = "com.haoyoung.QuickFile.finder-menu-settings-did-change"
    public let changeNotificationName: String
    private let resolveStorageURL: @Sendable () -> URL?

    public enum StoreError: LocalizedError {
        case unavailable
        case malformed
        case readFailed(Error)
        case saveFailed(Error)
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "无法访问 Finder 菜单的共享设置。"
            case .malformed: return "Finder 菜单设置无效，已保留上次有效设置。请重新保存。"
            case let .readFailed(error): return "无法读取 Finder 菜单设置：\(error.localizedDescription)"
            case let .saveFailed(error): return "无法保存 Finder 菜单设置，原设置未更改：\(error.localizedDescription)"
            }
        }
    }

    private struct Document: Codable {
        let version: Int
        // Store an explicit null for all. A missing field is corruption, not a silent reset.
        let maximumCount: Int?
        enum CodingKeys: String, CodingKey { case version, maximumCount }
        init(_ limit: FinderMenuDisplayLimit) { version = 1; maximumCount = limit.maximumCount }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            guard values.contains(.maximumCount) else { throw StoreError.malformed }
            maximumCount = try values.decodeIfPresent(Int.self, forKey: .maximumCount)
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(version, forKey: .version)
            if let maximumCount { try values.encode(maximumCount, forKey: .maximumCount) }
            else { try values.encodeNil(forKey: .maximumCount) }
        }
    }

    public init() {
        resolveStorageURL = {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: QuickFileConfiguration.appGroupIdentifier
            )?.appendingPathComponent("finder-menu-settings.v1.json")
        }
        changeNotificationName = Self.notificationName
    }

    public init(storageURL: URL?, changeNotificationName: String = FinderMenuSettingsStore.notificationName) {
        resolveStorageURL = { storageURL }
        self.changeNotificationName = changeNotificationName
    }

    public func load() throws -> FinderMenuDisplayLimit {
        guard let url = resolveStorageURL() else { throw StoreError.unavailable }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .all
        } catch { throw StoreError.readFailed(error) }
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw StoreError.malformed }
            return try FinderMenuDisplayLimit(maximumCount: document.maximumCount)
        } catch { throw StoreError.malformed }
    }

    public func save(_ value: FinderMenuDisplayLimit) throws {
        guard let url = resolveStorageURL() else { throw StoreError.unavailable }
        do { try JSONEncoder().encode(Document(value)).write(to: url, options: .atomic) }
        catch { throw StoreError.saveFailed(error) }
        notify_post(changeNotificationName)
    }
}
