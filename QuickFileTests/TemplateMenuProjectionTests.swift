import XCTest
@testable import QuickFileCore
@testable import QuickFileInfrastructure

final class TemplateMenuProjectionTests: XCTestCase {

    func testDefaultFilenameEnvelopeProjectsAllRecordsAndRejectsMalformedLaterField() throws {
        let selected = FileTemplate(name: "Selected", fileExtension: "", content: "body", defaultFilename: ".env")
        let disabled = FileTemplate(name: "Disabled", fileExtension: "", content: "", isEnabled: false)
        try store().saveTemplates([selected, disabled])
        let reader = store()
        XCTAssertEqual(try reader.reloadMenuEntries(), [FinderTemplateMenuEntry(template: selected)])
        XCTAssertEqual(try reader.reloadCreationSnapshot(templateID: selected.id).template?.defaultFilename, ".env")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var records = try XCTUnwrap(object["templates"] as? [[String: Any]])
        records[1]["defaultFilename"] = false
        object["templates"] = records
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try reader.reloadMenuEntries())
        XCTAssertThrowsError(try reader.reloadCreationSnapshot(templateID: selected.id))
        XCTAssertThrowsError(try reader.reloadTemplates())
        object["templates"] = []
        object["version"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try reader.reloadMenuEntries())
        XCTAssertThrowsError(try reader.reloadCreationSnapshot(templateID: selected.id))
    }

    private var suite: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("templates.v2.json") }

    override func setUpWithError() throws {
        suite = "QuickFileTests.MenuProjection.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suite)
        if let directory { try FileManager.default.removeItem(at: directory) }
        defaults = nil
    }

    private func store() -> TemplateStore {
        TemplateStore(defaults: defaults, storageURL: url, cachesReads: false,
                      changeNotificationName: suite)
    }

    private func write(_ templates: [FileTemplate]) throws {
        try JSONEncoder().encode(templates).write(to: url, options: .atomic)
    }

    func testMenuProjectionPreservesOrderIdentityLabelsAndEnabledFiltering() throws {
        let id = UUID()
        let templates = [
            FileTemplate(id: id, name: "模板 📝", fileExtension: " .md ", content: "正文\n\"\\"),
            FileTemplate(name: "Disabled", fileExtension: "txt", content: "hidden", isEnabled: false),
            FileTemplate(id: id, name: " \n", fileExtension: " . ", content: "historical duplicate"),
            FileTemplate(name: "Large", fileExtension: "txt", content: String(repeating: "正文", count: 8192))
        ]
        try write(templates)
        XCTAssertEqual(try store().reloadMenuEntries(), FinderMenuModelBuilder().entries(from: templates))
        try write([])
        XCTAssertEqual(try store().reloadMenuEntries(), [])
    }

    func testCreationSnapshotSelectsFirstEnabledMatchAndKeepsAllMenuMetadata() throws {
        let id = UUID()
        let selected = FileTemplate(id: id, name: "Selected", fileExtension: "md", content: "正文 📝\n\"\\\u{0000}")
        let templates = [
            FileTemplate(id: id, name: "Disabled duplicate", fileExtension: "txt", content: "disabled", isEnabled: false),
            FileTemplate(name: "Other", fileExtension: "txt", content: String(repeating: "x", count: 16_384)),
            selected,
            FileTemplate(id: id, name: "Later duplicate", fileExtension: "txt", content: "must not win")
        ]
        try write(templates)
        let reader = store()
        let snapshot = try reader.reloadCreationSnapshot(templateID: id)
        XCTAssertEqual(snapshot.template, selected)
        XCTAssertEqual(snapshot.menuEntries, FinderMenuModelBuilder().entries(from: templates))
        let missing = try reader.reloadCreationSnapshot(templateID: UUID())
        XCTAssertNil(missing.template)
        XCTAssertEqual(missing.menuEntries, snapshot.menuEntries)
    }

    func testCreationReadsOnceAndDoesNotUseTheWholeLibraryDecoderOrCachedBodies() throws {
        let first = FileTemplate(name: "First", fileExtension: "txt", content: "old")
        let second = FileTemplate(name: "Second", fileExtension: "md", content: "second")
        let reads = LockedTestValue(0)
        let reader = TemplateStore(defaults: defaults, storageURL: url, cachesReads: true,
                                   cachesMenuReads: true, changeNotificationName: suite,
                                   readTemplatesData: { url in reads.update { $0 += 1 }; return try Data(contentsOf: url) },
                                   decodeTemplatesData: { _ in
            XCTFail("Ordinary creation reads must not materialize the whole template array")
            return []
        })
        try write([first, second])
        XCTAssertEqual(try reader.reloadCreationSnapshot(templateID: first.id).template, first)
        XCTAssertEqual(try reader.reloadCreationSnapshot(templateID: second.id).template, second)
        var changed = first
        changed.content = "new"
        try write([changed, second])
        XCTAssertEqual(try reader.reloadCreationSnapshot(templateID: first.id).template, changed)
        changed.isEnabled = false
        try write([changed, second])
        let disabled = try reader.reloadCreationSnapshot(templateID: first.id)
        XCTAssertNil(disabled.template)
        XCTAssertEqual(disabled.menuEntries, [FinderTemplateMenuEntry(template: second)])
        try write([])
        let empty = try reader.reloadCreationSnapshot(templateID: first.id)
        XCTAssertNil(empty.template)
        XCTAssertEqual(empty.menuEntries, [])
        XCTAssertEqual(reads.value, 5, "Selection and metadata must come from the same single read")
        XCTAssertEqual(reader.decodedFileCacheRetainedRawByteCount, 0)
    }

    func testCreationSnapshotRetainsFirstUseMigrationAndMissingSavedConfigurationRules() throws {
        let builtIn = BuiltInTemplates.all[0]
        XCTAssertEqual(try store().reloadCreationSnapshot(templateID: builtIn.id).template, builtIn)
        let legacy = FileTemplate(name: "Legacy", fileExtension: "txt", content: "legacy body")
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "templates.v1")
        let migrated = try store().reloadCreationSnapshot(templateID: legacy.id)
        XCTAssertEqual(migrated.template, legacy)
        XCTAssertEqual(migrated.menuEntries, [FinderTemplateMenuEntry(template: legacy)])
        XCTAssertEqual(try store().reloadTemplates(), [legacy])
        XCTAssertNil(defaults.object(forKey: "templates.v1"))
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try store().reloadCreationSnapshot(templateID: legacy.id)) {
            guard case TemplateStore.StoreError.savedConfigurationMissing = $0 else {
                return XCTFail("Unexpected missing-file result: \($0)")
            }
        }
    }

    func testCreationMigrationSelectsConcurrentV2SaveInsteadOfLegacy() throws {
        let legacy = FileTemplate(name: "Legacy", fileExtension: "txt", content: "old")
        var edited = legacy
        edited.content = "concurrently saved"
        let current = edited
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "templates.v1")
        let writer = store()
        let reader = TemplateStore(defaults: defaults, storageURL: url, cachesReads: false,
                                   changeNotificationName: suite, migrationCheckpoint: { checkpoint in
            if case .beforeStorageLock = checkpoint { try writer.saveTemplates([current]) }
        })
        let snapshot = try reader.reloadCreationSnapshot(templateID: legacy.id)
        XCTAssertEqual(snapshot.template, current)
        XCTAssertEqual(snapshot.menuEntries, [FinderTemplateMenuEntry(template: current)])
    }

    func testCreationReadFailureDoesNotFallBackToLegacyOrBuiltIns() throws {
        let selected = BuiltInTemplates.all[0]
        defaults.set(try JSONEncoder().encode([selected]), forKey: "templates.v1")
        let reader = TemplateStore(defaults: defaults, storageURL: url, changeNotificationName: suite,
                                   readTemplatesData: { _ in throw CocoaError(.fileReadNoPermission) })
        XCTAssertThrowsError(try reader.reloadCreationSnapshot(templateID: selected.id)) {
            guard case TemplateStore.StoreError.readFailed = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertNotNil(defaults.object(forKey: "templates.v1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try TemplateStore(defaults: nil, storageURL: url).reloadCreationSnapshot(templateID: selected.id)) {
            guard case TemplateStore.StoreError.sharedDefaultsUnavailable = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testMenuProjectionAlwaysReadsCurrentFileBeforeRevisionNotification() throws {
        let reader = store()
        let first = FileTemplate(name: "First", fileExtension: "txt", content: "old")
        try write([first])
        XCTAssertEqual(try reader.reloadMenuEntries(), [FinderTemplateMenuEntry(template: first)])
        var changed = first
        changed.name = "Changed"
        changed.content = "new"
        try write([changed])
        XCTAssertEqual(try reader.reloadMenuEntries(), [FinderTemplateMenuEntry(template: changed)])
        changed.isEnabled = false
        try write([changed])
        XCTAssertEqual(try reader.reloadMenuEntries(), [])
        XCTAssertNil(defaults.object(forKey: "templates.revision.v2"))
    }

    func testMenuProjectionRejectsInvalidRecordsIncludingDisabledBodiesWithoutFallback() throws {
        let valid = FileTemplate(name: "Valid", fileExtension: "txt", content: "body")
        let validRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        var disabled = validRecord
        disabled["isEnabled"] = false
        let mutations: [(String, Any?)] = [
            ("content", 123), ("content", NSNull()), ("content", nil),
            ("id", "invalid-uuid"), ("name", false), ("fileExtension", []), ("isEnabled", "true")
        ]
        defaults.set(try JSONEncoder().encode([valid]), forKey: "templates.v1")
        for (key, value) in mutations {
            var invalid = disabled
            invalid[key] = value
            let data = try JSONSerialization.data(withJSONObject: [validRecord, invalid])
            try data.write(to: url, options: .atomic)
            XCTAssertThrowsError(try store().reloadMenuEntries(), "Invalid \(key)") { error in
                guard case TemplateStore.StoreError.readFailed = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertThrowsError(try store().reloadCreationSnapshot(templateID: valid.id),
                                 "A selected first row must not hide the invalid later \(key)")
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        for json in ["null", "{}", "[", "[null]"] {
            try Data(json.utf8).write(to: url, options: .atomic)
            XCTAssertThrowsError(try store().reloadMenuEntries())
            XCTAssertThrowsError(try store().reloadCreationSnapshot(templateID: valid.id))
        }
        try write([valid])
        XCTAssertEqual(try store().reloadMenuEntries(), [FinderTemplateMenuEntry(template: valid)])
    }

    func testMenuProjectionRetainsFirstUseMigrationAndMissingSavedConfigurationSemantics() throws {
        XCTAssertEqual(try store().reloadMenuEntries(), FinderMenuModelBuilder().entries(from: BuiltInTemplates.all))
        let legacy = [FileTemplate(name: "Legacy", fileExtension: "txt", content: "keep body")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "templates.v1")
        XCTAssertEqual(try store().reloadMenuEntries(), FinderMenuModelBuilder().entries(from: legacy))
        XCTAssertEqual(try store().reloadTemplates(), legacy)
        XCTAssertNil(defaults.object(forKey: "templates.v1"))
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try store().reloadMenuEntries()) { error in
            guard case TemplateStore.StoreError.savedConfigurationMissing = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMenuProjectionLegacyFallbackUsesConcurrentV2Save() throws {
        let legacy = [FileTemplate(name: "Legacy", fileExtension: "txt", content: "old")]
        let current = [FileTemplate(name: "Current", fileExtension: "md", content: "new")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "templates.v1")
        let writer = store()
        let reader = TemplateStore(defaults: defaults, storageURL: url, cachesReads: false,
                                   changeNotificationName: suite, migrationCheckpoint: { checkpoint in
            if case .beforeStorageLock = checkpoint { try writer.saveTemplates(current) }
        })
        XCTAssertEqual(try reader.reloadMenuEntries(), FinderMenuModelBuilder().entries(from: current))
        XCTAssertEqual(try writer.reloadTemplates(), current)
    }

    func testMenuProjectionRejectsUnavailableDefaultsAndReadErrors() throws {
        XCTAssertThrowsError(try TemplateStore(defaults: nil, storageURL: url).reloadMenuEntries()) { error in
            guard case TemplateStore.StoreError.sharedDefaultsUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        defaults.set(try JSONEncoder().encode(BuiltInTemplates.all), forKey: "templates.v1")
        let reader = TemplateStore(defaults: defaults, storageURL: url, readTemplatesData: { _ in
            throw CocoaError(.fileReadNoPermission)
        })
        XCTAssertThrowsError(try reader.reloadMenuEntries()) { error in
            guard case TemplateStore.StoreError.readFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMenuReuseReadsEveryTimeAndDetectsEqualSizeEqualMtimeEdits() throws {
        let template = FileTemplate(name: "First", fileExtension: "txt", content: "old")
        try write([template])
        let originalSize = try Data(contentsOf: url).count
        let originalDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let probe = MenuReadProbe()
        let reader = cachedStore(probe)
        for _ in 0..<3 {
            XCTAssertEqual(try reader.reloadMenuEntries(), [FinderTemplateMenuEntry(template: template)])
        }
        XCTAssertEqual(probe.counts().reads, 3)
        XCTAssertEqual(probe.counts().decodes, 1)

        var changed = template
        changed.content = "new"
        try write([changed])
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url).count, originalSize)
        XCTAssertEqual(try reader.reloadMenuEntries(), [FinderTemplateMenuEntry(template: template)])
        XCTAssertEqual(probe.counts().decodes, 2, "Even a body-only edit must be validated again")
        XCTAssertEqual(try reader.reloadTemplates(), [changed], "Menu reuse cannot supply an execution body")

        changed.isEnabled = false
        try write([changed])
        XCTAssertEqual(try reader.reloadMenuEntries(), [])
        try write([])
        XCTAssertEqual(try reader.reloadMenuEntries(), [])
        XCTAssertEqual(try reader.reloadMenuEntries(), [])
        XCTAssertEqual(probe.counts().decodes, 4)
    }

    func testMenuReadAndDecodeFailuresInvalidateReuseWithoutHidingSavedFileLoss() throws {
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "body")
        try store().saveTemplates([template])
        let original = try Data(contentsOf: url)
        let expected = [FinderTemplateMenuEntry(template: template)]
        let probe = MenuReadProbe()
        let reader = cachedStore(probe)
        XCTAssertEqual(try reader.reloadMenuEntries(), expected)
        probe.setReadFailure(true)
        XCTAssertThrowsError(try reader.reloadMenuEntries())
        probe.setReadFailure(false)
        XCTAssertEqual(try reader.reloadMenuEntries(), expected)
        XCTAssertEqual(probe.counts().decodes, 2)

        try Data("invalid".utf8).write(to: url, options: .atomic)
        XCTAssertThrowsError(try reader.reloadMenuEntries())
        try original.write(to: url, options: .atomic)
        XCTAssertEqual(try reader.reloadMenuEntries(), expected)
        XCTAssertEqual(probe.counts().decodes, 4)

        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try reader.reloadMenuEntries()) { error in
            guard case TemplateStore.StoreError.savedConfigurationMissing = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        try original.write(to: url, options: .atomic)
        XCTAssertEqual(try reader.reloadMenuEntries(), expected)
        XCTAssertEqual(probe.counts().decodes, 5)
    }

    func testOlderMenuReadOrFailureCannotEvictNewerReuseEntry() throws {
        for failOlderRead in [false, true] {
            let first = FileTemplate(name: "Old", fileExtension: "txt", content: "old")
            let latest = FileTemplate(name: "New", fileExtension: "txt", content: "new")
            try write([first])
            let probe = MenuReadProbe(pauseFirstRead: true, failFirstAfterPause: failOlderRead)
            let reader = cachedStore(probe)
            let finished = expectation(description: "Older read finished")
            defer { probe.resumeRead.signal() }
            DispatchQueue.global().async {
                do {
                    let entries = try reader.reloadMenuEntries()
                    XCTAssertFalse(failOlderRead)
                    XCTAssertEqual(entries, [FinderTemplateMenuEntry(template: first)])
                } catch {
                    XCTAssertTrue(failOlderRead, "Unexpected read error: \(error)")
                }
                finished.fulfill()
            }
            XCTAssertEqual(probe.didRead.wait(timeout: .now() + 5), .success)
            try write([latest])
            XCTAssertEqual(try reader.reloadMenuEntries(), [FinderTemplateMenuEntry(template: latest)])
            probe.resumeRead.signal()
            wait(for: [finished], timeout: 5)
            XCTAssertEqual(try reader.reloadMenuEntries(), [FinderTemplateMenuEntry(template: latest)])
            XCTAssertEqual(probe.counts().decodes, failOlderRead ? 1 : 2)
        }
    }

    func testMenuReuseCanBeDisabledAndNeverRetainsOversizedHistoricalInput() throws {
        try write([])
        let uncachedProbe = MenuReadProbe()
        let uncached = TemplateStore(defaults: defaults, storageURL: url, cachesReads: false,
                                    decodeMenuEntriesData: { try uncachedProbe.decode($0) })
        XCTAssertEqual(try uncached.reloadMenuEntries(), [])
        XCTAssertEqual(try uncached.reloadMenuEntries(), [])
        XCTAssertEqual(uncachedProbe.counts().decodes, 2)

        let probe = MenuReadProbe()
        let reader = cachedStore(probe)
        XCTAssertEqual(try reader.reloadMenuEntries(), [])
        var large = Data("[]".utf8)
        large.append(Data(repeating: 0x20, count: TemplateStore.maximumFingerprintedFileCacheBytes))
        try large.write(to: url, options: .atomic)
        for _ in 0..<2 { XCTAssertEqual(try reader.reloadMenuEntries(), []) }
        XCTAssertEqual(probe.counts().decodes, 3, "Historical files above the hash budget still load normally")
        try write([])
        XCTAssertEqual(try reader.reloadMenuEntries(), [])
        XCTAssertEqual(probe.counts().decodes, 4, "The skipped input must evict the previous reuse entry")
    }

    private func cachedStore(_ probe: MenuReadProbe) -> TemplateStore {
        TemplateStore(defaults: defaults, storageURL: url, cachesReads: false, cachesMenuReads: true,
                      changeNotificationName: suite,
                      readTemplatesData: { try probe.read($0) },
                      decodeMenuEntriesData: { try probe.decode($0) })
    }
}

private final class MenuReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var decodes = 0
    private var readFailure = false
    private let pauseFirstRead: Bool
    private let failFirstAfterPause: Bool
    let didRead = DispatchSemaphore(value: 0)
    let resumeRead = DispatchSemaphore(value: 0)

    init(pauseFirstRead: Bool = false, failFirstAfterPause: Bool = false) {
        self.pauseFirstRead = pauseFirstRead
        self.failFirstAfterPause = failFirstAfterPause
    }

    func setReadFailure(_ failure: Bool) {
        lock.lock(); defer { lock.unlock() }
        readFailure = failure
    }

    func counts() -> (reads: Int, decodes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (reads, decodes)
    }

    func read(_ url: URL) throws -> Data {
        lock.lock()
        reads += 1
        let count = reads
        let failure = readFailure
        lock.unlock()
        if failure { throw CocoaError(.fileReadNoPermission) }
        let data = try Data(contentsOf: url)
        if pauseFirstRead, count == 1 {
            didRead.signal()
            guard resumeRead.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
            if failFirstAfterPause { throw CocoaError(.fileReadNoPermission) }
        }
        return data
    }

    func decode(_ data: Data) throws -> [FinderTemplateMenuEntry] {
        lock.lock(); decodes += 1; lock.unlock()
        return FinderMenuModelBuilder().entries(from: try JSONDecoder().decode([FileTemplate].self, from: data))
    }
}
