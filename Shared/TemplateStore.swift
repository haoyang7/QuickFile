import Foundation
import Darwin
import CoreFoundation
import CryptoKit
import QuickFileCore

public enum QuickFileConfiguration {
    public static let appBundleIdentifier = "com.haoyoung.QuickFile"
    public static let finderExtensionBundleIdentifier = "com.haoyoung.QuickFile.FinderExtension"
    public static let appGroupIdentifier = "group.com.haoyoung.QuickFile"
    public static let templatesDidChangeDarwinNotification =
        "com.haoyoung.QuickFile.templates-did-change"

    public static var usesPlaceholderIdentifiers: Bool {
        appBundleIdentifier.hasPrefix("com.example")
            || appGroupIdentifier.contains("com.example")
            || finderExtensionBundleIdentifier.hasPrefix("com.example")
    }
}

// UserDefaults and FileManager are thread-safe; the only mutable in-memory state is protected
// by cacheLock. File writes are atomic so concurrent readers observe a complete old or new value.
public final class TemplateStore: @unchecked Sendable {
    public enum StoreError: LocalizedError {
        case configurationChanged
        case sharedDefaultsUnavailable
        case readFailed(Error)
        case savedConfigurationMissing
        case persistenceFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .configurationChanged:
                return "模板已在其他实例修改。当前修改未保存，请重新加载模板后重试。"
            case .sharedDefaultsUnavailable:
                return "无法访问 QuickFile 的共享模板存储。"
            case let .readFailed(error):
                return "无法读取 QuickFile 模板，原配置未被替换：\(error.localizedDescription)"
            case .savedConfigurationMissing:
                return "已保存的模板配置文件不可用。请恢复文件后重新加载模板。"
            case let .persistenceFailed(error):
                return "无法保存 QuickFile 模板：\(error.localizedDescription)"
            }
        }
    }

    public enum RecoveryReason: String, Sendable {
        case corruptFile
        case corruptLegacyData
        case missingSavedConfiguration
    }

    /// Opaque compare-and-swap evidence. Preparing it never resets configuration.
    public struct RecoverySnapshot: Equatable, Sendable {
        public let reason: RecoveryReason
        fileprivate let storeIdentity: UUID
        fileprivate let state: RecoveryRawState
    }

    public struct RecoveryResult: Sendable {
        public let templates: [FileTemplate]
        /// A private local directory containing exact original bytes and metadata.
        public let backupURL: URL
    }

    public enum RecoveryError: LocalizedError {
        case notRecoverable
        case configurationChanged
        case backupFailed(Error)
        case replacementFailed(backupURL: URL, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .notRecoverable:
                return "当前配置未确认损坏，不能执行恢复。请先重新加载。"
            case .configurationChanged:
                return "配置已在恢复预览后发生变化。未替换任何配置，请重新加载。"
            case let .backupFailed(error):
                return "无法备份原配置，恢复已停止，原配置未被替换：\(error.localizedDescription)"
            case let .replacementFailed(_, error):
                return "原配置已备份，但恢复写入失败：\(error.localizedDescription)"
            }
        }
    }

    fileprivate struct RecoveryRawState: Equatable, Sendable {
        let fileData: Data?
        let fileIdentity: RecoveryFileIdentity?
        let legacyData: Data?
        // Preserve all property-list values, including unexpected historical types.
        let legacyValue: Data?
        let revisionValue: Data?
    }

    fileprivate struct RecoveryFileIdentity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
            size = status.st_size
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = status.st_mtimespec.tv_nsec
            changedSeconds = status.st_ctimespec.tv_sec
            changedNanoseconds = status.st_ctimespec.tv_nsec
        }
    }

    private let defaults: UserDefaults?
    private let storageURL: URL?
    private let fileManager: FileManager
    private let cachesReads: Bool
    private let cachesMenuReads: Bool
    private let recoveryIdentity = UUID()
    private let writeTemplatesData: @Sendable (Data, URL) throws -> Void
    private let readTemplatesData: @Sendable (URL) throws -> Data
    private let decodeTemplatesData: @Sendable (Data) throws -> [FileTemplate]
    private let decodeMenuEntriesData: @Sendable (Data) throws -> [FinderTemplateMenuEntry]
    private let backupWriteOverride: (@Sendable (Data, URL) throws -> Void)?
    private let exportCheckpoint: (@Sendable (TemplateTransferFile.ExportCheckpoint) throws -> Void)?
    private let migrationCheckpoint: (@Sendable (MigrationCheckpoint) throws -> Void)?
    public let changeNotificationName: String
    private let legacyTemplatesKey = "templates.v1"
    private let revisionKey = "templates.revision.v2"
    private static let defaultsMutationLock = NSLock()
    private let cacheLock = NSLock()
    private var cachedRevision: String?
    private var cachedTemplates: [FileTemplate]?
    private var templateLoadGeneration: UInt64 = 0
    // This is a decode cache, not authority: every execution reload still reads
    // the complete file. Small keys retain at most 1 MiB of exact raw bytes.
    // Larger keys rely on SHA256 collision resistance, not literal byte equality,
    // and retain only a digest and byte count, never another large raw payload.
    static let maximumDecodedFileCacheBytes = 1024 * 1024
    // Bound added hashing work by the existing internal-format recovery budget.
    // This is cache eligibility only; larger historical files still load normally.
    static let maximumFingerprintedFileCacheBytes = maximumRecoveryFileBytes
    enum DecodedFileCacheKey: Equatable {
        case exactBytes(Data)
        case fingerprint(byteCount: Int, digest: SHA256.Digest)

        var retainedRawByteCount: Int {
            if case let .exactBytes(data) = self { return data.count }
            return 0
        }
    }
    private var decodedFileCache: (key: DecodedFileCacheKey, templates: [FileTemplate])?

    static func decodedFileCacheKey(for data: Data) -> DecodedFileCacheKey? {
        if data.count <= maximumDecodedFileCacheBytes { return .exactBytes(data) }
        guard data.count <= maximumFingerprintedFileCacheBytes else { return nil }
        return .fingerprint(byteCount: data.count, digest: SHA256.hash(data: data))
    }

    // Internal, payload-free accounting for deterministic cache budget tests.
    var decodedFileCacheRetainedRawByteCount: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return decodedFileCache?.key.retainedRawByteCount ?? 0
    }
    private var fileReadGeneration: UInt64 = 0

    // Menu reuse never retains source bytes or decoded bodies, even for small files.
    // Like the large-file decode cache, identity relies on SHA256 collision resistance.
    private struct MenuFileCacheKey: Equatable {
        let byteCount: Int
        let digest: SHA256.Digest
    }
    private var menuFileCache: (key: MenuFileCacheKey, entries: [FinderTemplateMenuEntry])?
    private var menuReadGeneration: UInt64 = 0

    // Internal JSON has UUIDs and JSONEncoder may escape slashes. It is not the
    // portable 32 MiB envelope. Recovery has its own bounded 64 MiB read budget;
    // ordinary historical loads intentionally retain their compatibility policy.
    static let maximumRecoveryFileBytes = 64 * 1024 * 1024

    /// Internal checkpoints keep migration/cache interleaving tests deterministic.
    enum MigrationCheckpoint: Sendable {
        case beforeStorageLock
        case beforeCachePublication
    }

    /// Operation-scoped readers can skip cache keys and retained snapshots while
    /// keeping the same authoritative reads, migration and failure semantics.
    /// A reusable menu reader can independently retain only a digest and menu metadata.
    public init(cachesReads: Bool = true, cachesMenuReads: Bool = false) {
        self.cachesReads = cachesReads
        self.cachesMenuReads = cachesMenuReads
        fileManager = .default
        writeTemplatesData = { try $0.write(to: $1, options: .atomic) }
        readTemplatesData = { try Data(contentsOf: $0) }
        decodeTemplatesData = { try JSONDecoder().decode(StoredTemplates.self, from: $0).templates }
        decodeMenuEntriesData = { try JSONDecoder().decode(MenuEntries.self, from: $0).entries }
        backupWriteOverride = nil
        exportCheckpoint = nil
        migrationCheckpoint = nil
        storageURL = FileManager.default
            .containerURL(
                forSecurityApplicationGroupIdentifier: QuickFileConfiguration.appGroupIdentifier
            )?
            .appendingPathComponent("templates.v2.json", isDirectory: false)
        defaults = storageURL == nil ? nil : UserDefaults(suiteName: QuickFileConfiguration.appGroupIdentifier)
        changeNotificationName = QuickFileConfiguration.templatesDidChangeDarwinNotification
    }

    init(
        defaults: UserDefaults?,
        storageURL: URL? = nil,
        fileManager: FileManager = .default,
        cachesReads: Bool = true,
        cachesMenuReads: Bool = false,
        changeNotificationName: String = QuickFileConfiguration.templatesDidChangeDarwinNotification,
        writeTemplatesData: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        },
        readTemplatesData: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
        decodeTemplatesData: @escaping @Sendable (Data) throws -> [FileTemplate] = {
            try JSONDecoder().decode(StoredTemplates.self, from: $0).templates
        },
        decodeMenuEntriesData: (@Sendable (Data) throws -> [FinderTemplateMenuEntry])? = nil,
        backupWriteOverride: (@Sendable (Data, URL) throws -> Void)? = nil,
        exportCheckpoint: (@Sendable (TemplateTransferFile.ExportCheckpoint) throws -> Void)? = nil,
        migrationCheckpoint: (@Sendable (MigrationCheckpoint) throws -> Void)? = nil
    ) {
        self.defaults = defaults
        self.storageURL = storageURL
        self.fileManager = fileManager
        self.cachesReads = cachesReads
        self.cachesMenuReads = cachesMenuReads
        self.writeTemplatesData = writeTemplatesData
        self.readTemplatesData = readTemplatesData
        self.decodeTemplatesData = decodeTemplatesData
        self.decodeMenuEntriesData = decodeMenuEntriesData ?? {
            try JSONDecoder().decode(MenuEntries.self, from: $0).entries
        }
        self.backupWriteOverride = backupWriteOverride
        self.exportCheckpoint = exportCheckpoint
        self.migrationCheckpoint = migrationCheckpoint
        self.changeNotificationName = changeNotificationName
    }

    /// A cheap UI invalidation hint only. Execution and CAS must still read authority.
    public struct ChangeToken: Equatable, Sendable {
        fileprivate let revision: String?
        fileprivate let fileIdentity: RecoveryFileIdentity?
    }

    public func changeToken() throws -> ChangeToken {
        guard let defaults else { throw StoreError.sharedDefaultsUnavailable }
        var identity: RecoveryFileIdentity?
        if let storageURL {
            var status = stat()
            // Normal template reads follow symbolic links; inspect the same target.
            if stat(storageURL.path, &status) == 0 {
                identity = RecoveryFileIdentity(status)
            } else if errno != ENOENT {
                throw StoreError.readFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
            }
        }
        return ChangeToken(revision: defaults.string(forKey: revisionKey), fileIdentity: identity)
    }

    public func loadTemplates() throws -> [FileTemplate] {
        try loadTemplates(allowCached: true)
    }

    /// Execution paths read the file even when the cross-process revision has not propagated yet.
    public func reloadTemplates() throws -> [FileTemplate] {
        try loadTemplates(allowCached: false)
    }

    /// Reads the authoritative menu configuration without retaining all decoded bodies.
    /// Every record still passes FileTemplate's decoder, including disabled records.
    public func reloadMenuEntries() throws -> [FinderTemplateMenuEntry] {
        guard defaults != nil else { throw StoreError.sharedDefaultsUnavailable }
        cacheLock.lock()
        menuReadGeneration &+= 1
        let generation = menuReadGeneration
        cacheLock.unlock()
        if let storageURL {
            do {
                let data = try readTemplatesData(storageURL)
                let key = cachesMenuReads && data.count <= Self.maximumFingerprintedFileCacheBytes
                    ? MenuFileCacheKey(byteCount: data.count, digest: SHA256.hash(data: data)) : nil
                cacheLock.lock()
                let cached = key.flatMap { key in
                    menuFileCache.flatMap { $0.key == key ? $0.entries : nil }
                }
                cacheLock.unlock()
                if let cached { return cached }
                let entries = try decodeMenuEntriesData(data)
                cacheLock.lock()
                if generation == menuReadGeneration {
                    menuFileCache = key.map { (key: $0, entries: entries) }
                }
                cacheLock.unlock()
                return entries
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
                invalidateMenuFileCache(expectedGeneration: generation)
                // The normal loader owns first use, missing saved configuration and
                // locked legacy migration. It also rechecks a concurrently created v2 file.
            } catch {
                invalidateMenuFileCache(expectedGeneration: generation)
                throw StoreError.readFailed(error)
            }
        }
        return FinderMenuModelBuilder().entries(from: try reloadTemplates())
    }

    private func invalidateMenuFileCache(expectedGeneration: UInt64) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard expectedGeneration == menuReadGeneration else { return }
        menuReadGeneration &+= 1
        menuFileCache = nil
    }

    /// One authoritative read supplies both the requested enabled template and
    /// fresh menu metadata. Unselected bodies do not escape the decoder loop.
    public struct CreationSnapshot: Sendable {
        public let template: FileTemplate?
        public let menuEntries: [FinderTemplateMenuEntry]

        public init(template: FileTemplate?, menuEntries: [FinderTemplateMenuEntry]) {
            self.template = template
            self.menuEntries = menuEntries
        }
    }

    public func reloadCreationSnapshot(templateID: UUID) throws -> CreationSnapshot {
        guard defaults != nil else { throw StoreError.sharedDefaultsUnavailable }
        if let storageURL {
            do {
                let data = try readTemplatesData(storageURL)
                let decoder = JSONDecoder()
                decoder.userInfo[MenuEntries.selectedTemplateIDKey] = templateID
                let decoded = try decoder.decode(MenuEntries.self, from: data)
                return CreationSnapshot(template: decoded.template, menuEntries: decoded.entries)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
                // Preserve first use, missing saved configuration, and locked
                // legacy migration, including a concurrent v2 save winning.
            } catch {
                throw StoreError.readFailed(error)
            }
        }
        let templates = try reloadTemplates()
        return CreationSnapshot(
            template: templates.first { $0.id == templateID && $0.isEnabled },
            menuEntries: FinderMenuModelBuilder().entries(from: templates)
        )
    }

    // A keyed envelope makes old array-only readers fail before they can save
    // a library after silently dropping fields they do not understand.
    private enum StorageKeys: String, CodingKey { case format, version, templates }

    private struct TemplateContainer {
        var values: UnkeyedDecodingContainer
        let supportsOfficeDocuments: Bool

        var isAtEnd: Bool { values.isAtEnd }

        mutating func decodeTemplate() throws -> FileTemplate {
            let template = try values.decode(FileTemplate.self)
            guard supportsOfficeDocuments || template.officeFormat == nil else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: values.codingPath, debugDescription: "Office templates require library version 4."
                ))
            }
            return template
        }
    }

    private static func templateContainer(from decoder: Decoder) throws -> TemplateContainer {
        if let array = try? decoder.unkeyedContainer() {
            return TemplateContainer(values: array, supportsOfficeDocuments: false)
        }
        let envelope = try decoder.container(keyedBy: StorageKeys.self)
        let version = try envelope.decode(Int.self, forKey: .version)
        guard try envelope.decode(String.self, forKey: .format) == "quickfile.template-library",
              version == 3 || version == 4 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Unsupported template library format."
            ))
        }
        return TemplateContainer(values: try envelope.nestedUnkeyedContainer(forKey: .templates),
                                 supportsOfficeDocuments: version == 4)
    }

    private struct StoredTemplates: Codable {
        let templates: [FileTemplate]

        init(templates: [FileTemplate]) { self.templates = templates }

        init(from decoder: Decoder) throws {
            var values = try TemplateStore.templateContainer(from: decoder)
            var templates: [FileTemplate] = []
            while !values.isAtEnd { templates.append(try values.decodeTemplate()) }
            self.templates = templates
        }

        func encode(to encoder: Encoder) throws {
            let hasOfficeDocuments = templates.contains { $0.officeFormat != nil }
            if hasOfficeDocuments || templates.contains(where: { !$0.defaultFilename.isEmpty }) {
                var values = encoder.container(keyedBy: StorageKeys.self)
                try values.encode("quickfile.template-library", forKey: .format)
                try values.encode(hasOfficeDocuments ? 4 : 3, forKey: .version)
                try values.encode(templates, forKey: .templates)
            } else {
                var values = encoder.unkeyedContainer()
                for template in templates { try values.encode(template) }
            }
        }
    }

    private struct MenuEntries: Decodable {
        static let selectedTemplateIDKey = CodingUserInfoKey(rawValue: "QuickFile.selectedTemplateID")!
        let entries: [FinderTemplateMenuEntry]
        let template: FileTemplate?

        init(from decoder: Decoder) throws {
            let selectedID = decoder.userInfo[Self.selectedTemplateIDKey] as? UUID
            var container = try TemplateStore.templateContainer(from: decoder)
            var entries: [FinderTemplateMenuEntry] = []
            var selected: FileTemplate?
            while !container.isAtEnd {
                let template = try container.decodeTemplate()
                if template.isEnabled {
                    entries.append(FinderTemplateMenuEntry(template: template))
                    if selected == nil, template.id == selectedID { selected = template }
                }
            }
            // Do not stop at the selected row: malformed later or disabled
            // records must still reject the entire configuration before writing.
            self.entries = entries
            self.template = selected
        }
    }

    private func loadTemplates(allowCached: Bool) throws -> [FileTemplate] {
        guard defaults != nil else { throw StoreError.sharedDefaultsUnavailable }
        let revision = defaults?.string(forKey: revisionKey)
        if allowCached, let cachedTemplates = cachedTemplates(for: revision) {
            return cachedTemplates
        }
        cacheLock.lock()
        templateLoadGeneration &+= 1
        let generation = templateLoadGeneration
        cacheLock.unlock()

        if let templates = try loadTemplatesFromFile() {
            updateCache(templates, revision: revision, expectedLoadGeneration: generation)
            return templates
        }

        if let templates = try loadLegacyTemplates() {
            if storageURL != nil {
                return try migrateLegacyTemplates(templates, loadGeneration: generation)
            } else {
                updateCache(templates, revision: revision, expectedLoadGeneration: generation)
            }
            return templates
        }

        guard defaults?.object(forKey: revisionKey) == nil else { throw StoreError.savedConfigurationMissing }
        let templates = BuiltInTemplates.all
        updateCache(templates, revision: revision, expectedLoadGeneration: generation)
        return templates
    }

    public func saveTemplates(_ templates: [FileTemplate]) throws {
        try saveTemplates(templates, expectedTemplates: nil)
    }

    /// Compares the authoritative configuration while holding the same lock as the write.
    public func saveTemplates(_ templates: [FileTemplate], expectedTemplates: [FileTemplate]?) throws {
        guard let defaults else {
            throw StoreError.sharedDefaultsUnavailable
        }

        let revision = try withStorageMutationLock {
            // Atomic replacement must never hide unreadable or corrupt existing configuration.
            let current = try loadTemplatesFromFile() ?? loadLegacyTemplates()
            if current == nil, defaults.object(forKey: revisionKey) != nil {
                throw StoreError.savedConfigurationMissing
            }
            if let expectedTemplates,
               !Self.templatesMatchExactly(current ?? BuiltInTemplates.all, expectedTemplates) {
                throw StoreError.configurationChanged
            }
            try Self.validateOrdinarySave(templates, replacing: current ?? BuiltInTemplates.all)
            return try persistTemplates(templates, defaults: defaults)
        }

        updateCache(templates, revision: revision)
        postTemplatesDidChangeNotification()
    }

    private static func templatesMatchExactly(_ lhs: [FileTemplate], _ rhs: [FileTemplate]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
            pair.0.id == pair.1.id && TransferTemplate(pair.0) == TransferTemplate(pair.1)
        }
    }

    private static func validateOrdinarySave(
        _ templates: [FileTemplate], replacing originals: [FileTemplate]
    ) throws {
        do {
            try TemplateTransfer.validateEncodedSize(TemplateTransferBundle(templates: templates))
        } catch {
            // Never lock a historical library out of deletion/reordering or
            // incremental repair. While the result remains over-limit, retain
            // only existing IDs; changed fields must become valid and must not
            // increase the record's JSON payload. An enable/disable-only edit of
            // an already-invalid library may preserve all historical field bytes.
            // This gate deliberately does not run in persistTemplates: migration
            // must continue preserving historical data without applying new limits.
            let originalError = error
            guard templates.count <= originals.count else { throw originalError }
            let byID = Dictionary(grouping: originals, by: \.id)
            var seen = Set<FileTemplate.ID>()
            var originalWasUnexportable: Bool?
            for template in templates {
                guard seen.insert(template.id).inserted,
                      let candidates = byID[template.id] else { throw originalError }
                if candidates.contains(where: { TransferTemplate($0) == TransferTemplate(template) }) {
                    continue
                }
                if candidates.contains(where: { fieldsMatchExactly(template, $0) }) {
                    if originalWasUnexportable == nil {
                        // false is one byte longer than true. Permit that bounded
                        // historical state change only when it cannot turn a
                        // previously exportable collection into an invalid one.
                        originalWasUnexportable = (try? TemplateTransfer.validateEncodedSize(
                            TemplateTransferBundle(templates: originals)
                        )) == nil
                    }
                    if originalWasUnexportable == true { continue }
                }
                do {
                    try TemplateTransfer.validateEncodedSize(TemplateTransferBundle(templates: [template]))
                } catch { throw originalError }
                guard candidates.contains(where: { doesNotGrow(template, comparedTo: $0) }) else {
                    throw originalError
                }
            }
        }
    }

    private static func fieldsMatchExactly(_ lhs: FileTemplate, _ rhs: FileTemplate) -> Bool {
        lhs.officeFormat == rhs.officeFormat
            && TemplateByteOperations.areEqual(lhs.name.utf8, rhs.name.utf8)
            && TemplateByteOperations.areEqual(lhs.fileExtension.utf8, rhs.fileExtension.utf8)
            && TemplateByteOperations.areEqual(lhs.content.utf8, rhs.content.utf8)
            && TemplateByteOperations.areEqual(lhs.defaultFilename.utf8, rhs.defaultFilename.utf8)
    }

    private static func doesNotGrow(_ template: FileTemplate, comparedTo original: FileTemplate) -> Bool {
        // Measurement shares the export emitter even for invalid historical fields.
        // The caller separately validates changed records before applying this check.
        (try? TemplateTransfer.isEncodedSizeNonIncreasing(
            TransferTemplate(template), comparedTo: TransferTemplate(original)
        )) == true
    }

    /// A user-selected export must not replace the store's authoritative file,
    /// coordination lock or immutable backups with the portable transfer envelope.
    public func validateExportDestination(_ url: URL) throws {
        guard url.isFileURL else { throw TemplateTransferError.nonLocalFile }
        // Panels supply ordinary absolute paths. Reject explicit traversal rather
        // than risk checking a lexically normalized path with different symlink
        // semantics from the original URL passed to the atomic file writer.
        guard !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw TemplateTransferError.protectedDestination
        }
        let destination = try canonicalExportURL(url)
        let backupParent = try canonicalExportURL(
            storageURL?.deletingLastPathComponent() ?? fileManager.temporaryDirectory
        ).pathComponents
        let destinationParts = destination.pathComponents
        if destinationParts.count > backupParent.count,
           zip(backupParent, destinationParts).allSatisfy({ pair in
               pair.0.caseInsensitiveCompare(pair.1) == .orderedSame
           }),
           destinationParts[backupParent.count].lowercased().hasPrefix("quickfile-template-backup-") {
            throw TemplateTransferError.protectedDestination
        }
        guard let storageURL else { return }
        for protected in [storageURL, storageURL.appendingPathExtension("lock")] {
            let canonical = try canonicalExportURL(protected)
            // Missing files have no inode to compare. Conservatively protect case
            // variants too, including on the common case-insensitive APFS volume.
            if destination.path.compare(canonical.path, options: [.caseInsensitive]) == .orderedSame {
                throw TemplateTransferError.protectedDestination
            }
            var candidate = stat()
            var original = stat()
            if lstat(destination.path, &candidate) == 0, lstat(canonical.path, &original) == 0,
               candidate.st_dev == original.st_dev, candidate.st_ino == original.st_ino {
                throw TemplateTransferError.protectedDestination
            }
        }
    }

    /// Call only after the export warning and Save-panel replacement confirmation.
    /// Path preflight is advisory; actual protection and atomic publication share a
    /// pinned parent descriptor inside the infrastructure writer.
    public func exportTemplates(
        _ bundle: TemplateTransferBundle, to url: URL, limits: TemplateTransferLimits = .default
    ) throws {
        try validateExportDestination(url)
        try TemplateTransferFile.write(bundle, to: url, limits: limits, validateDestination: { parent, name in
            try self.validateExportDestination(in: parent, named: name)
        }, checkpoint: exportCheckpoint)
    }

    private func validateExportDestination(in parent: Int32, named name: String) throws {
        let actualParent = try TemplateTransferFile.directoryURL(for: parent)
        try validateExportDestination(actualParent.appendingPathComponent(name))
        guard let storageURL else { return }
        var openedParent = stat()
        guard fstat(parent, &openedParent) == 0 else { throw currentPOSIXError() }
        var protectedParent = stat()
        if stat(storageURL.deletingLastPathComponent().path, &protectedParent) == 0 {
            if openedParent.st_dev == protectedParent.st_dev, openedParent.st_ino == protectedParent.st_ino,
               [storageURL.lastPathComponent, storageURL.appendingPathExtension("lock").lastPathComponent]
                .contains(where: { name.caseInsensitiveCompare($0) == .orderedSame }) {
                throw TemplateTransferError.protectedDestination
            }
        } else if errno != ENOENT { throw currentPOSIXError() }

        // Check hardlink identity against the entry in the opened destination, not
        // a fresh lookup through the user's possibly retargeted parent pathname.
        var candidate = stat()
        if fstatat(parent, name, &candidate, AT_SYMLINK_NOFOLLOW) == 0 {
            for protected in [storageURL, storageURL.appendingPathExtension("lock")] {
                var original = stat()
                if stat(protected.path, &original) == 0 {
                    if candidate.st_dev == original.st_dev, candidate.st_ino == original.st_ino {
                        throw TemplateTransferError.protectedDestination
                    }
                } else if errno != ENOENT { throw currentPOSIXError() }
            }
        } else if errno != ENOENT { throw currentPOSIXError() }
    }

    private func canonicalExportURL(_ url: URL) throws -> URL {
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while true {
            // Resolving the entire URL can leave a parent symlink unresolved when
            // its leaf does not exist. Resolve a real ancestor first, then append
            // the missing suffix without asking Foundation to resolve it again.
            if let resolvedPath = realpath(ancestor.path, nil) {
                defer { free(resolvedPath) }
                let resolved = URL(fileURLWithPath: String(cString: resolvedPath))
                return missingComponents.reversed().reduce(resolved) { $0.appendingPathComponent($1) }
            }
            let resolutionError = errno
            guard resolutionError == ENOENT else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(resolutionError))
            }
            var status = stat()
            // A dangling symlink exists even though realpath cannot resolve it.
            // It is not a missing suffix: fail closed instead of guessing where
            // a future write through that entry would land.
            guard lstat(ancestor.path, &status) != 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(resolutionError))
            }
            guard errno == ENOENT else { throw currentPOSIXError() }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { throw currentPOSIXError() }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
        }
    }

    /// Only proven decoding corruption or a previously saved missing configuration
    /// is recoverable. Permission, directory and other I/O errors are propagated.
    public func prepareRecovery() throws -> RecoverySnapshot {
        guard defaults != nil else { throw StoreError.sharedDefaultsUnavailable }
        return try withStorageMutationLock {
            let state = try captureRecoveryState()
            guard let reason = recoveryReason(for: state) else { throw RecoveryError.notRecoverable }
            return RecoverySnapshot(reason: reason, storeIdentity: recoveryIdentity, state: state)
        }
    }

    /// UI must obtain explicit confirmation of the replacement and original backup.
    /// Ordinary saves never use this escape hatch and keep their read-failure guard.
    public func recoverTemplates(
        _ templates: [FileTemplate], expectedRecoveryState snapshot: RecoverySnapshot
    ) throws -> RecoveryResult {
        guard let defaults else { throw StoreError.sharedDefaultsUnavailable }
        // Validation also bounds total encoded transfer bytes before backup/write.
        try TemplateTransfer.validateEncodedSize(TemplateTransferBundle(templates: templates))
        guard snapshot.storeIdentity == recoveryIdentity else { throw RecoveryError.configurationChanged }
        var revision: String?
        let backupURL = try withStorageMutationLock {
            let current = try captureRecoveryState()
            guard current == snapshot.state, recoveryReason(for: current) == snapshot.reason else {
                throw RecoveryError.configurationChanged
            }
            let backupURL: URL
            do { backupURL = try writeRecoveryBackup(current, reason: snapshot.reason) }
            catch { throw RecoveryError.backupFailed(error) }
            // A non-cooperating filesystem edit during backup must not be hidden.
            guard try captureRecoveryState() == current else { throw RecoveryError.configurationChanged }
            do { revision = try persistTemplates(templates, defaults: defaults) }
            catch { throw RecoveryError.replacementFailed(backupURL: backupURL, underlying: error) }
            return backupURL
        }
        updateCache(templates, revision: revision)
        postTemplatesDidChangeNotification()
        return RecoveryResult(templates: templates, backupURL: backupURL)
    }

    private func captureRecoveryState() throws -> RecoveryRawState {
        guard let defaults else { throw StoreError.sharedDefaultsUnavailable }
        let file: (data: Data, identity: RecoveryFileIdentity)?
        do { file = try readRecoveryFile() }
        catch { throw StoreError.readFailed(error) }
        let legacy = defaults.object(forKey: legacyTemplatesKey)
        if let data = legacy as? Data, data.count > Self.maximumRecoveryFileBytes {
            throw StoreError.readFailed(TemplateTransferError.fileTooLarge(
                maximumBytes: Self.maximumRecoveryFileBytes
            ))
        }
        let revision = defaults.object(forKey: revisionKey)
        do {
            return RecoveryRawState(
                fileData: file?.data,
                fileIdentity: file?.identity,
                legacyData: legacy as? Data,
                legacyValue: try serializedDefaultsValue(legacy),
                revisionValue: try serializedDefaultsValue(revision)
            )
        } catch { throw StoreError.readFailed(error) }
    }

    private func readRecoveryFile() throws -> (data: Data, identity: RecoveryFileIdentity)? {
        guard let storageURL else { return nil }
        // Never follow the current-file symlink or block on a FIFO/device. Such
        // states are I/O failures, not evidence that JSON is corrupt.
        let descriptor = open(storageURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw currentPOSIXError()
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw currentPOSIXError() }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        // Recovery is optional. Oversized historical data must be handled manually,
        // never classified as corruption or loaded without a memory bound.
        let maximum = Self.maximumRecoveryFileBytes
        guard before.st_size >= 0, before.st_size <= Int64(maximum) else {
            throw TemplateTransferError.fileTooLarge(maximumBytes: maximum)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maximum {
            let request = min(buffer.count, maximum + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, request) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw currentPOSIXError() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximum else { throw TemplateTransferError.fileTooLarge(maximumBytes: maximum) }
        var after = stat()
        var named = stat()
        guard fstat(descriptor, &after) == 0, lstat(storageURL.path, &named) == 0 else {
            throw currentPOSIXError()
        }
        let identity = RecoveryFileIdentity(before)
        guard identity == RecoveryFileIdentity(after), identity == RecoveryFileIdentity(named),
              named.st_mode & S_IFMT == S_IFREG, data.count == Int(before.st_size) else {
            throw RecoveryError.configurationChanged
        }
        return (data, identity)
    }

    private func serializedDefaultsValue(_ value: Any?) throws -> Data? {
        guard let value else { return nil }
        // A one-element array permits scalar defaults without guessing their type.
        return try PropertyListSerialization.data(fromPropertyList: [value], format: .xml, options: 0)
    }

    private func recoveryReason(for state: RecoveryRawState) -> RecoveryReason? {
        if let fileData = state.fileData {
            return (try? JSONDecoder().decode(StoredTemplates.self, from: fileData).templates) == nil ? .corruptFile : nil
        }
        if state.legacyValue != nil {
            guard let data = state.legacyData else { return .corruptLegacyData }
            return (try? JSONDecoder().decode(StoredTemplates.self, from: data).templates) == nil ? .corruptLegacyData : nil
        }
        return state.revisionValue == nil ? nil : .missingSavedConfiguration
    }

    private func writeRecoveryBackup(_ state: RecoveryRawState, reason: RecoveryReason) throws -> URL {
        let parent = storageURL?.deletingLastPathComponent() ?? fileManager.temporaryDirectory
        let directory = parent.appendingPathComponent("QuickFile-template-backup-\(UUID().uuidString)", isDirectory: true)
        // Never reuse or overwrite a prior backup, even after a failed replacement.
        guard mkdir(directory.path, S_IRWXU) == 0 else { throw currentPOSIXError() }
        if let data = state.fileData {
            try writeExclusiveBackup(data, to: directory.appendingPathComponent("templates.original.json"))
        }
        if let data = state.legacyData {
            try writeExclusiveBackup(data, to: directory.appendingPathComponent("legacy.original.data"))
        }
        var metadata: [String: Any] = [
            "format": "quickfile.template-recovery", "version": 1,
            "reason": reason.rawValue, "fileWasMissing": state.fileData == nil,
            "legacyWasPresent": state.legacyValue != nil,
            "revisionWasPresent": state.revisionValue != nil
        ]
        if let value = state.legacyValue { metadata["legacyValuePropertyList"] = value }
        if let value = state.revisionValue { metadata["revisionValuePropertyList"] = value }
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try writeExclusiveBackup(data, to: directory.appendingPathComponent("metadata.plist"))
        // Keep saved evidence read-only. No backup is deleted on any failure path.
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        try syncBackupDirectory(directory)
        try syncBackupDirectory(parent)
        return directory
    }

    private func syncBackupDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
    }

    private func writeExclusiveBackup(_ data: Data, to url: URL) throws {
        if let backupWriteOverride { try backupWriteOverride(data, url); return }
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { close(descriptor) }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw currentPOSIXError() }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
        guard fchmod(descriptor, S_IRUSR) == 0 else { throw currentPOSIXError() }
    }

    private func currentPOSIXError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func migrateLegacyTemplates(
        _ initiallyLoadedTemplates: [FileTemplate], loadGeneration: UInt64
    ) throws -> [FileTemplate] {
        guard let defaults else { throw StoreError.sharedDefaultsUnavailable }
        try migrationCheckpoint?(.beforeStorageLock)
        let snapshot: (templates: [FileTemplate], revision: String?, didMigrate: Bool) = try withStorageMutationLock {
            // A save may have completed after the unlocked legacy read. Its v2 file wins.
            if let existingTemplates = try loadTemplatesFromFile() {
                // Pair the revision with these bytes before another writer can publish.
                return (existingTemplates, defaults.string(forKey: revisionKey), false)
            }

            let legacyTemplates = try loadLegacyTemplates() ?? initiallyLoadedTemplates
            let revision = try persistTemplates(legacyTemplates, defaults: defaults)
            return (legacyTemplates, revision, true)
        }

        try migrationCheckpoint?(.beforeCachePublication)
        updateCache(snapshot.templates, revision: snapshot.revision, expectedLoadGeneration: loadGeneration)
        if snapshot.didMigrate {
            postTemplatesDidChangeNotification()
        }
        return snapshot.templates
    }

    private func persistTemplates(_ templates: [FileTemplate], defaults: UserDefaults) throws -> String {
        do {
            let data = try JSONEncoder().encode(StoredTemplates(templates: templates))
            let revision = UUID().uuidString

            if let storageURL {
                try writeTemplatesData(data, storageURL)
                invalidateDecodedFileCache()
                defaults.set(revision, forKey: revisionKey)
                defaults.removeObject(forKey: legacyTemplatesKey)
            } else {
                defaults.set(data, forKey: legacyTemplatesKey)
                defaults.set(revision, forKey: revisionKey)
            }
            return revision
        } catch {
            throw StoreError.persistenceFailed(error)
        }
    }

    private func withStorageMutationLock<Result>(_ operation: () throws -> Result) throws -> Result {
        guard let storageURL else {
            Self.defaultsMutationLock.lock()
            defer { Self.defaultsMutationLock.unlock() }
            return try operation()
        }
        let directoryURL = storageURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw StoreError.persistenceFailed(error)
        }

        let lockURL = storageURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw StoreError.persistenceFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        defer { close(descriptor) }
        var lockStatus = stat()
        guard fstat(descriptor, &lockStatus) == 0, lockStatus.st_mode & S_IFMT == S_IFREG else {
            throw StoreError.persistenceFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
        }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw StoreError.persistenceFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
            }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func postTemplatesDidChangeNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(changeNotificationName as CFString),
            nil,
            nil,
            true
        )
    }

    private func loadTemplatesFromFile() throws -> [FileTemplate]? {
        guard let storageURL else { return nil }
        cacheLock.lock()
        fileReadGeneration &+= 1
        let generation = fileReadGeneration
        cacheLock.unlock()
        do {
            let data = try readTemplatesData(storageURL)
            guard cachesReads else { return try decodeTemplatesData(data) }
            // Fingerprinting is bounded and outside the shared cache lock. Every
            // key is derived from this request's authoritative read, not metadata.
            let key = Self.decodedFileCacheKey(for: data)
            cacheLock.lock()
            let cached = key.flatMap { key in
                decodedFileCache.flatMap { $0.key == key ? $0.templates : nil }
            }
            cacheLock.unlock()
            if let cached { return cached }
            let templates = try decodeTemplatesData(data)
            cacheLock.lock()
            // A slow A read cannot replace a newer B read's decode cache.
            if generation == fileReadGeneration {
                decodedFileCache = key.map { (key: $0, templates: templates) }
            }
            cacheLock.unlock()
            return templates
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            invalidateDecodedFileCache(expectedGeneration: generation)
            return nil
        } catch {
            invalidateDecodedFileCache(expectedGeneration: generation)
            throw StoreError.readFailed(error)
        }
    }

    private func invalidateDecodedFileCache(expectedGeneration: UInt64? = nil) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let expectedGeneration, expectedGeneration != fileReadGeneration { return }
        fileReadGeneration &+= 1
        decodedFileCache = nil
    }

    private func loadLegacyTemplates() throws -> [FileTemplate]? {
        guard let value = defaults?.object(forKey: legacyTemplatesKey) else { return nil }
        guard let data = value as? Data else {
            throw StoreError.readFailed(DecodingError.typeMismatch(Data.self, .init(
                codingPath: [], debugDescription: "Legacy template payload is not data."
            )))
        }
        do {
            return try JSONDecoder().decode(StoredTemplates.self, from: data).templates
        } catch {
            throw StoreError.readFailed(error)
        }
    }

    private func cachedTemplates(for revision: String?) -> [FileTemplate]? {
        guard cachesReads else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard cachedRevision == revision else {
            return nil
        }
        return cachedTemplates
    }

    private func updateCache(
        _ templates: [FileTemplate], revision: String?, expectedLoadGeneration: UInt64? = nil
    ) {
        guard cachesReads else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let expectedLoadGeneration {
            guard expectedLoadGeneration == templateLoadGeneration else { return }
        } else {
            // A completed save/recovery supersedes in-flight load publications.
            templateLoadGeneration &+= 1
        }
        cachedRevision = revision
        cachedTemplates = templates
    }
}
