import XCTest
import Darwin
@testable import QuickFileCore
@testable import QuickFileInfrastructure

final class TemplateStoreTests: XCTestCase {

    func testHistoricalStateOnlyExceptionCannotHideDefaultFilenameChanges() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let original = FileTemplate(name: String(repeating: "x", count: 1025), fileExtension: "", content: "")
        try JSONEncoder().encode([original]).write(to: url)
        let store = TemplateStore(defaults: defaults, storageURL: url)
        var changed = original
        changed.isEnabled = false
        changed.defaultFilename = "new"
        XCTAssertThrowsError(try store.saveTemplates([changed]))
        XCTAssertEqual(try store.reloadTemplates(), [original])
        changed.defaultFilename = ""
        try store.saveTemplates([changed])
        XCTAssertEqual(try store.reloadTemplates(), [changed])
    }


    func testDefaultFilenameEnvelopeRejectsOldReaderAndProtectsDefaultOnlyCAS() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        let original = FileTemplate(name: "A", fileExtension: "", content: "", defaultFilename: "é")
        try store.saveTemplates([original])
        let bytes = try Data(contentsOf: url)
        // The previous version used exactly this array-only decoding boundary.
        XCTAssertThrowsError(try JSONDecoder().decode([FileTemplate].self, from: bytes))
        let fresh = TemplateStore(defaults: defaults, storageURL: url, cachesReads: false)
        XCTAssertEqual(try fresh.reloadTemplates(), [original])
        XCTAssertThrowsError(try fresh.prepareRecovery()) {
            guard case TemplateStore.RecoveryError.notRecoverable = $0 else { return XCTFail("\($0)") }
        }
        var changed = original
        changed.defaultFilename = "e\u{301}"
        try fresh.saveTemplates([changed], expectedTemplates: [original])
        XCTAssertThrowsError(try store.saveTemplates([original], expectedTemplates: [original])) {
            guard case TemplateStore.StoreError.configurationChanged = $0 else { return XCTFail("\($0)") }
        }
        changed.defaultFilename = ""
        try fresh.saveTemplates([changed])
        let legacy = try JSONDecoder().decode([FileTemplate].self, from: Data(contentsOf: url))
        XCTAssertEqual(legacy[0].defaultFilename, "")
    }

    func testDefaultFilenameBudgetAndHistoricalRepair() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        let oversized = FileTemplate(name: "A", fileExtension: "", content: "",
                                     defaultFilename: String(repeating: "x", count: 1025))
        XCTAssertThrowsError(try store.saveTemplates([oversized]))
        // Historical arrays remain readable without applying today's save limits.
        try JSONEncoder().encode([oversized]).write(to: url)
        XCTAssertEqual(try store.reloadTemplates(), [oversized])
        var repaired = oversized
        repaired.defaultFilename = ".env"
        try store.saveTemplates([repaired], expectedTemplates: [oversized])
        XCTAssertEqual(try store.reloadTemplates(), [repaired])
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        suiteName = "QuickFileTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickFileTemplateStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let temporaryDirectory {
            if let entries = FileManager.default.enumerator(at: temporaryDirectory, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let url as URL in entries {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                    }
                }
            }
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        defaults = nil
        suiteName = nil
    }

    func testUsesBuiltInTemplatesWhenNoSharedConfigurationExists() throws {
        let templates = try TemplateStore(defaults: defaults).loadTemplates()

        XCTAssertEqual(templates, BuiltInTemplates.all)
    }

    func testSavesAndLoadsSharedTemplates() throws {
        let templates = [
            FileTemplate(name: "自定义", fileExtension: "qf", content: "{{date}}"),
            FileTemplate(name: "停用", fileExtension: "off", content: "", isEnabled: false)
        ]
        let store = TemplateStore(defaults: defaults)

        try store.saveTemplates(templates)

        XCTAssertEqual(try store.loadTemplates(), templates)
    }

    func testCorruptLegacyDataIsReportedAndCannotBeOverwritten() {
        let data = Data("not-json".utf8)
        defaults.set(data, forKey: "templates.v1")
        let store = TemplateStore(defaults: defaults)

        XCTAssertThrowsError(try store.loadTemplates())
        XCTAssertThrowsError(try store.saveTemplates(BuiltInTemplates.all))
        XCTAssertEqual(defaults.data(forKey: "templates.v1"), data)
    }

    func testSavedEmptyTemplateListDoesNotFallBackToBuiltIns() throws {
        let store = TemplateStore(defaults: defaults)

        try store.saveTemplates([])

        XCTAssertEqual(try store.loadTemplates(), [])
    }

    func testFileStorageMigratesLegacyTemplatesAndRemovesDefaultsPayload() throws {
        let templates = [
            FileTemplate(name: "迁移模板", fileExtension: "txt", content: "legacy")
        ]
        defaults.set(try JSONEncoder().encode(templates), forKey: "templates.v1")
        let storageURL = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)

        XCTAssertEqual(try store.loadTemplates(), templates)
        XCTAssertNil(defaults.data(forKey: "templates.v1"))
        XCTAssertNotNil(defaults.string(forKey: "templates.revision.v2"))
        XCTAssertEqual(
            try JSONDecoder().decode([FileTemplate].self, from: Data(contentsOf: storageURL)),
            templates
        )
    }

    func testLateLegacyMigrationDoesNotOverwriteConcurrentSave() throws {
        let legacyTemplates = [
            FileTemplate(name: "Legacy", fileExtension: "txt", content: "old")
        ]
        let savedTemplates = [
            FileTemplate(name: "Saved", fileExtension: "md", content: "new")
        ]
        defaults.set(try JSONEncoder().encode(legacyTemplates), forKey: "templates.v1")
        let storageURL = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let pausingFileManager = PausingTemplateFileManager()
        let migratingStore = TemplateStore(
            defaults: defaults,
            storageURL: storageURL,
            fileManager: pausingFileManager
        )
        let savingStore = TemplateStore(defaults: defaults, storageURL: storageURL)
        let migrationFinished = expectation(description: "Migration finished")
        let result = LockedTemplateLoadResult()

        DispatchQueue.global().async {
            result.set(Result { try migratingStore.loadTemplates() })
            migrationFinished.fulfill()
        }
        XCTAssertEqual(pausingFileManager.didEnterCreateDirectory.wait(timeout: .now() + 5), .success)

        try savingStore.saveTemplates(savedTemplates)
        pausingFileManager.resumeCreateDirectory.signal()
        wait(for: [migrationFinished], timeout: 5)

        XCTAssertEqual(try result.get().get(), savedTemplates)
        XCTAssertEqual(try savingStore.reloadTemplates(), savedTemplates)
    }

    func testFileStorageCacheInvalidatesWhenAnotherStoreSaves() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let writer = TemplateStore(defaults: defaults, storageURL: storageURL)
        let reader = TemplateStore(defaults: defaults, storageURL: storageURL)
        let initialTemplates = [
            FileTemplate(name: "初始", fileExtension: "one", content: "1")
        ]
        let updatedTemplates = [
            FileTemplate(name: "更新", fileExtension: "two", content: "2")
        ]

        try writer.saveTemplates(initialTemplates)
        XCTAssertEqual(try reader.loadTemplates(), initialTemplates)

        try writer.saveTemplates(updatedTemplates)
        XCTAssertEqual(try reader.loadTemplates(), updatedTemplates)
    }

    func testLateMigrationKeepsLockedRevisionWhenAnotherSavePrecedesCachePublication() throws {
        let legacy = [FileTemplate(name: "Legacy", fileExtension: "txt", content: "legacy")]
        let firstSave = [FileTemplate(name: "First save", fileExtension: "txt", content: "first")]
        let latestSave = [FileTemplate(name: "Latest save", fileExtension: "md", content: "latest")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "templates.v1")
        let storageURL = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let writer = TemplateStore(defaults: defaults, storageURL: storageURL)
        let reader = TemplateStore(defaults: defaults, storageURL: storageURL, migrationCheckpoint: { stage in
            switch stage {
            case .beforeStorageLock:
                // The reader has observed legacy data, but the v2 writer wins the lock.
                try writer.saveTemplates(firstSave)
            case .beforeCachePublication:
                // The reader has released the lock with firstSave. Publish a new revision
                // before it caches that snapshot, without a sleep or thread scheduling race.
                try writer.saveTemplates(latestSave)
            }
        })

        XCTAssertEqual(try reader.loadTemplates(), firstSave)
        // Both calls must use the current revision. Caching firstSave with the latest
        // revision would keep returning firstSave indefinitely, including on this retry.
        XCTAssertEqual(try reader.loadTemplates(), latestSave)
        XCTAssertEqual(try reader.loadTemplates(), latestSave)
        XCTAssertThrowsError(try reader.saveTemplates([], expectedTemplates: firstSave)) { error in
            guard case TemplateStore.StoreError.configurationChanged = error else {
                return XCTFail("Expected a configuration conflict, got \(error)")
            }
        }
        XCTAssertEqual(try writer.reloadTemplates(), latestSave)
        XCTAssertNil(defaults.data(forKey: "templates.v1"))
    }

    func testMigrationWriteKeepsItsRevisionWhenAnotherSavePrecedesCachePublication() throws {
        let legacy = [FileTemplate(name: "Legacy", fileExtension: "txt", content: "legacy")]
        let latestSave = [FileTemplate(name: "Latest save", fileExtension: "md", content: "latest")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "templates.v1")
        let storageURL = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let writer = TemplateStore(defaults: defaults, storageURL: storageURL)
        let reader = TemplateStore(defaults: defaults, storageURL: storageURL, migrationCheckpoint: { stage in
            if case .beforeCachePublication = stage {
                try writer.saveTemplates(latestSave)
            }
        })

        XCTAssertEqual(try reader.loadTemplates(), legacy)
        XCTAssertEqual(try reader.loadTemplates(), latestSave)
        XCTAssertEqual(try reader.loadTemplates(), latestSave)
        XCTAssertEqual(try writer.reloadTemplates(), latestSave)
        XCTAssertNil(defaults.data(forKey: "templates.v1"))
    }

    func testFailedMigrationPreservesLegacyDataAndDoesNotCacheSuccess() throws {
        let legacy = [FileTemplate(name: "Legacy", fileExtension: "txt", content: "keep")]
        let legacyData = try JSONEncoder().encode(legacy)
        defaults.set(legacyData, forKey: "templates.v1")
        let storageURL = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let reader = TemplateStore(defaults: defaults, storageURL: storageURL, writeTemplatesData: { _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        }, migrationCheckpoint: { stage in
            if case .beforeCachePublication = stage {
                XCTFail("A failed migration must not publish a cache snapshot")
            }
        })

        for _ in 0..<2 {
            XCTAssertThrowsError(try reader.loadTemplates()) { error in
                guard case TemplateStore.StoreError.persistenceFailed = error else {
                    return XCTFail("Expected a persistence failure, got \(error)")
                }
            }
        }
        XCTAssertEqual(defaults.data(forKey: "templates.v1"), legacyData)
        XCTAssertNil(defaults.object(forKey: "templates.revision.v2"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))

        let healthyStore = TemplateStore(defaults: defaults, storageURL: storageURL)
        XCTAssertEqual(try healthyStore.loadTemplates(), legacy)
        XCTAssertEqual(try reader.loadTemplates(), legacy)
    }

    func testExecutionReloadReadsFileBeforeRevisionNotificationArrives() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
        try store.saveTemplates([original])
        var updated = original
        updated.isEnabled = false
        try JSONEncoder().encode([updated]).write(to: storageURL, options: .atomic)

        XCTAssertEqual(try store.loadTemplates(), [original])
        XCTAssertEqual(try store.reloadTemplates(), [updated])
    }

    func testOrdinarySavesRejectNewUnexportableLibrariesWithoutChangingStoredData() throws {
        let url = temporaryDirectory.appendingPathComponent("bounded-saves.json")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        let original = [FileTemplate(name: "Original", fileExtension: "txt", content: "keep")]
        try store.saveTemplates(original)
        let originalData = try Data(contentsOf: url)
        let revision = defaults.string(forKey: "templates.revision.v2")
        let invalidLibraries: [[FileTemplate]] = [
            [FileTemplate(name: String(repeating: "n", count: 1_025), fileExtension: "txt", content: "")],
            [FileTemplate(name: "Extension", fileExtension: String(repeating: "x", count: 256), content: "")],
            [FileTemplate(name: "Content", fileExtension: "txt", content: String(repeating: "x", count: 16 * 1024 * 1024 + 1))],
            (0...1_000).map { FileTemplate(name: "Item \($0)", fileExtension: "txt", content: "") },
            [FileTemplate(name: "Escapes", fileExtension: "txt", content: String(repeating: "\u{0000}", count: 6 * 1024 * 1024))]
        ]
        for invalid in invalidLibraries {
            XCTAssertThrowsError(try store.saveTemplates(invalid, expectedTemplates: original))
            XCTAssertEqual(try Data(contentsOf: url), originalData)
            XCTAssertEqual(defaults.string(forKey: "templates.revision.v2"), revision)
            XCTAssertEqual(try store.reloadTemplates(), original)
        }
    }

    func testHistoricalOversizedLibrariesRemainLoadableAndAllowDeletionAndIncrementalRepair() throws {
        let url = temporaryDirectory.appendingPathComponent("historical.json")
        let first = FileTemplate(name: String(repeating: "a", count: 1_025), fileExtension: "txt", content: "old")
        let second = FileTemplate(name: String(repeating: "b", count: 1_026), fileExtension: "txt", content: "old")
        let third = FileTemplate(name: "Third", fileExtension: "txt", content: "old")
        let historical = [first, second, third]
        try JSONEncoder().encode(historical).write(to: url)
        let store = TemplateStore(defaults: defaults, storageURL: url)
        XCTAssertEqual(try store.reloadTemplates(), historical)
        try store.saveTemplates([third, second, first], expectedTemplates: historical)
        try store.saveTemplates([second, first], expectedTemplates: [third, second, first])
        var repaired = first
        repaired.name = "Repaired"
        try store.saveTemplates([second, repaired], expectedTemplates: [second, first])
        XCTAssertEqual(try store.reloadTemplates(), [second, repaired])
        var enlarged = second
        enlarged.name += "more"
        XCTAssertThrowsError(try store.saveTemplates([enlarged, repaired]))
        XCTAssertThrowsError(try store.saveTemplates([second, repaired, third]))
        try store.saveTemplates([repaired])
        XCTAssertEqual(try store.reloadTemplates(), [repaired])
    }

    func testLegacyMigrationPreservesOversizedHistoricalTemplate() throws {
        let historical = [FileTemplate(name: String(repeating: "n", count: 1_025), fileExtension: "txt", content: "keep")]
        defaults.set(try JSONEncoder().encode(historical), forKey: "templates.v1")
        let url = temporaryDirectory.appendingPathComponent("legacy-large.json")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        XCTAssertEqual(try store.loadTemplates(), historical)
        XCTAssertEqual(try JSONDecoder().decode([FileTemplate].self, from: Data(contentsOf: url)), historical)
        XCTAssertNil(defaults.data(forKey: "templates.v1"))
        try store.saveTemplates([])
        XCTAssertEqual(try store.reloadTemplates(), [])
    }

    func testHistoricalReductionRejectsNewJSONEscapeAmplification() throws {
        let url = temporaryDirectory.appendingPathComponent("legacy-escapes.json")
        let oversized = FileTemplate(name: String(repeating: "n", count: 1_025), fileExtension: "txt", content: "")
        let original = FileTemplate(name: "Other", fileExtension: "txt", content: "a")
        try JSONEncoder().encode([oversized, original]).write(to: url)
        let store = TemplateStore(defaults: defaults, storageURL: url)
        var changed = original
        changed.content = "\u{0000}"
        XCTAssertEqual(changed.content.utf8.count, original.content.utf8.count)
        XCTAssertThrowsError(try store.saveTemplates([oversized, changed]))
        XCTAssertEqual(try store.reloadTemplates(), [oversized, original])
    }

    func testHistoricalInvalidTemplateCanBeDisabledAndReenabledWithoutChangingItsFields() throws {
        let url = temporaryDirectory.appendingPathComponent("historical-toggle.json")
        let historical = FileTemplate(name: String(repeating: "n", count: 1_025), fileExtension: "txt", content: "e\u{0301}")
        try JSONEncoder().encode([historical]).write(to: url)
        let store = TemplateStore(defaults: defaults, storageURL: url)
        var disabled = historical
        disabled.isEnabled = false
        try store.saveTemplates([disabled], expectedTemplates: [historical])
        XCTAssertEqual(try store.reloadTemplates(), [disabled])
        try store.saveTemplates([historical], expectedTemplates: [disabled])
        let restored = try XCTUnwrap(store.reloadTemplates().first)
        XCTAssertEqual(restored.id, historical.id)
        XCTAssertEqual(TransferTemplate(restored), TransferTemplate(historical))
        var changedBytes = disabled
        changedBytes.content = "é"
        XCTAssertThrowsError(try store.saveTemplates([changedBytes]), "Canonical equivalence is not an unchanged historical body")
    }

    func testHistoricalOversizedBodyToggleDoesNotPermitSameIDBodyGrowth() throws {
        let url = temporaryDirectory.appendingPathComponent("historical-body-toggle.json")
        let historical = FileTemplate(name: "Historical", fileExtension: "txt",
            content: String(repeating: "x", count: TemplateTransferLimits.default.maximumContentBytes + 1))
        try JSONEncoder().encode([historical]).write(to: url)
        let store = TemplateStore(defaults: defaults, storageURL: url)
        var disabled = historical
        disabled.isEnabled = false
        try store.saveTemplates([disabled])
        var enlarged = disabled
        enlarged.content += "x"
        XCTAssertEqual(enlarged.id, historical.id)
        XCTAssertThrowsError(try store.saveTemplates([enlarged]))
        try store.saveTemplates([historical])
        let restored = try XCTUnwrap(store.reloadTemplates().first)
        XCTAssertEqual(restored.id, historical.id)
        XCTAssertEqual(TransferTemplate(restored), TransferTemplate(historical))
    }

    func testBooleanChangeCannotMakePreviouslyExportableLibraryExceedEncodedLimit() throws {
        let limit = TemplateTransferLimits.default.maximumFileBytes
        var templates = [
            FileTemplate(name: "First", fileExtension: "txt", content: ""),
            FileTemplate(name: "Second", fileExtension: "txt", content: "")
        ]
        let overhead = try TemplateTransfer.validateEncodedSize(TemplateTransferBundle(templates: templates))
        templates[0].content = String(repeating: "x", count: limit / 2)
        templates[1].content = String(repeating: "x", count: limit / 2 - overhead)
        XCTAssertEqual(try TemplateTransfer.validateEncodedSize(TemplateTransferBundle(templates: templates)), limit)
        let url = temporaryDirectory.appendingPathComponent("boolean-size-boundary.json")
        try JSONEncoder().encode(templates).write(to: url)
        let store = TemplateStore(defaults: defaults, storageURL: url)
        var disabled = templates
        disabled[0].isEnabled = false
        XCTAssertThrowsError(try store.saveTemplates(disabled))
        XCTAssertEqual(try store.reloadTemplates(), templates)
    }

    func testAuthoritativeReloadAlwaysReadsBytesButDecodesUnchangedSmallFileOnce() throws {
        let url = temporaryDirectory.appendingPathComponent("decode-cache.json")
        let template = FileTemplate(name: "Template", fileExtension: "txt", content: "aaa")
        try JSONEncoder().encode([template]).write(to: url)
        let probe = TemplateStoreIOProbe()
        let store = TemplateStore(defaults: defaults, storageURL: url,
            readTemplatesData: { try probe.read($0) }, decodeTemplatesData: { try probe.decode($0) })
        XCTAssertEqual(try store.reloadTemplates(), [template])
        XCTAssertEqual(try store.reloadTemplates(), [template])
        XCTAssertEqual(probe.counts().reads, 2)
        XCTAssertEqual(probe.counts().decodes, 1)

        var changed = template
        changed.content = "bbb"
        let oldDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
        try JSONEncoder().encode([changed]).write(to: url)
        if let oldDate { try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path) }
        XCTAssertEqual(try store.reloadTemplates(), [changed], "Equal size/mtime cannot establish freshness")
        XCTAssertEqual(probe.counts().reads, 3)
        XCTAssertEqual(probe.counts().decodes, 2)
    }

    func testUncachedReadsRetainNoDecodeSnapshotAndStillSeeEditsAndCorruption() throws {
        let url = temporaryDirectory.appendingPathComponent("uncached.json")
        let probe = TemplateStoreIOProbe()
        let store = TemplateStore(defaults: defaults, storageURL: url, cachesReads: false,
            readTemplatesData: { try probe.read($0) }, decodeTemplatesData: { try probe.decode($0) })
        for size in [8, TemplateStore.maximumDecodedFileCacheBytes + 1] {
            let template = FileTemplate(name: "Uncached", fileExtension: "txt", content: String(repeating: "x", count: size))
            try JSONEncoder().encode([template]).write(to: url, options: .atomic)
            XCTAssertEqual(try store.loadTemplates(), [template])
            XCTAssertEqual(try store.reloadTemplates(), [template])
            XCTAssertEqual(store.decodedFileCacheRetainedRawByteCount, 0)
        }
        XCTAssertEqual(probe.counts().reads, 4)
        XCTAssertEqual(probe.counts().decodes, 4)
        try JSONEncoder().encode([FileTemplate]()).write(to: url, options: .atomic)
        XCTAssertEqual(try store.loadTemplates(), [], "Unchanged defaults revision cannot hide a file edit")
        try Data("corrupt".utf8).write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.loadTemplates())
    }

    func testUncachedLegacyMigrationStillPersistsAndDoesNotMaskLaterFileEdits() throws {
        let url = temporaryDirectory.appendingPathComponent("migrated-uncached.json")
        let template = FileTemplate(name: "Legacy", fileExtension: "txt", content: "literal")
        defaults.set(try JSONEncoder().encode([template]), forKey: "templates.v1")
        let store = TemplateStore(defaults: defaults, storageURL: url, cachesReads: false)
        XCTAssertEqual(try store.loadTemplates(), [template])
        XCTAssertEqual(try JSONDecoder().decode([FileTemplate].self, from: Data(contentsOf: url)), [template])
        try JSONEncoder().encode([FileTemplate]()).write(to: url, options: .atomic)
        XCTAssertEqual(try store.loadTemplates(), [])
        XCTAssertEqual(store.decodedFileCacheRetainedRawByteCount, 0)
    }

    func testDecodedFileCacheSwitchesToFingerprintBeyondItsRawByteBudget() throws {
        let url = temporaryDirectory.appendingPathComponent("cache-boundary.json")
        let empty = FileTemplate(name: "Boundary", fileExtension: "txt", content: "")
        let overhead = try JSONEncoder().encode([empty]).count
        var template = empty
        let probe = TemplateStoreIOProbe()
        let store = TemplateStore(defaults: defaults, storageURL: url,
            readTemplatesData: { try probe.read($0) }, decodeTemplatesData: { try probe.decode($0) })
        for extra in [0, 1] {
            template.content = String(repeating: "x", count: TemplateStore.maximumDecodedFileCacheBytes - overhead + extra)
            let data = try JSONEncoder().encode([template])
            XCTAssertEqual(data.count, TemplateStore.maximumDecodedFileCacheBytes + extra)
            try data.write(to: url, options: .atomic)
            XCTAssertEqual(try store.reloadTemplates(), [template])
            XCTAssertEqual(try store.reloadTemplates(), [template])
            XCTAssertEqual(store.decodedFileCacheRetainedRawByteCount,
                           extra == 0 ? data.count : 0)
        }
        XCTAssertEqual(probe.counts().reads, 4)
        XCTAssertEqual(probe.counts().decodes, 2, "Both key types reuse unchanged decoded templates")
        // Returning to the earlier small bytes also decodes: there is only one
        // cache entry, so the fingerprint replaced the previous exact-byte key.
        template.content.removeLast()
        try JSONEncoder().encode([template]).write(to: url, options: .atomic)
        _ = try store.reloadTemplates()
        XCTAssertEqual(probe.counts().decodes, 3)
        XCTAssertEqual(store.decodedFileCacheRetainedRawByteCount,
                       TemplateStore.maximumDecodedFileCacheBytes)
    }

    func testFingerprintCacheEligibilityIsBoundedWithoutRetainingLargeRawData() throws {
        let limit = TemplateStore.maximumFingerprintedFileCacheBytes
        XCTAssertEqual(limit, TemplateStore.maximumRecoveryFileBytes)
        var data = Data(repeating: 0x20, count: limit)
        let key = try XCTUnwrap(TemplateStore.decodedFileCacheKey(for: data))
        guard case let .fingerprint(byteCount, digest) = key else {
            return XCTFail("The inclusive upper boundary must use a fingerprint")
        }
        XCTAssertEqual(byteCount, limit)
        XCTAssertEqual(Array(digest).count, 32)
        XCTAssertEqual(key.retainedRawByteCount, 0)
        data.append(0x20)
        XCTAssertNil(TemplateStore.decodedFileCacheKey(for: data),
                     "Historical larger files skip hashing/cache; they are not rejected by loading")
        // Large legal JSON padding exercises the actual historical loading path
        // without allocating a second huge decoded model or writing a large file.
        data.append(contentsOf: [0x5b, 0x5d])
        let historicalData = data
        let probe = TemplateStoreIOProbe()
        let store = TemplateStore(defaults: defaults,
            storageURL: temporaryDirectory.appendingPathComponent("historical-injected.json"),
            readTemplatesData: { _ in historicalData }, decodeTemplatesData: { try probe.decode($0) })
        XCTAssertEqual(try store.reloadTemplates(), [])
        XCTAssertEqual(try store.reloadTemplates(), [])
        XCTAssertEqual(probe.counts().decodes, 2, "Over-budget historical JSON still loads, without caching")
        XCTAssertEqual(store.decodedFileCacheRetainedRawByteCount, 0)
    }

    func testLargeLegalLibraryUsesFreshBytesAndNeverFallsBackAfterReadOrDecodeFailure() throws {
        let url = temporaryDirectory.appendingPathComponent("large-fingerprint.json")
        var template = FileTemplate(name: "Large", fileExtension: "txt",
                                    content: String(repeating: "a", count: 2 * 1024 * 1024))
        XCTAssertNoThrow(try TemplateTransfer.validateEncodedSize(TemplateTransferBundle(templates: [template])))
        try JSONEncoder().encode([template]).write(to: url)
        defaults.set("saved", forKey: "templates.revision.v2")
        let probe = TemplateStoreIOProbe()
        let store = TemplateStore(defaults: defaults, storageURL: url,
            readTemplatesData: { try probe.read($0) }, decodeTemplatesData: { try probe.decode($0) })
        for _ in 0..<2 { XCTAssertEqual(try store.reloadTemplates(), [template]) }
        XCTAssertEqual(probe.counts().reads, 2)
        XCTAssertEqual(probe.counts().decodes, 1)
        XCTAssertEqual(store.decodedFileCacheRetainedRawByteCount, 0)

        let originalSize = try Data(contentsOf: url).count
        let oldDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
        template.content = String(repeating: "b", count: 2 * 1024 * 1024)
        let changed = try JSONEncoder().encode([template])
        XCTAssertEqual(changed.count, originalSize)
        try changed.write(to: url)
        if let oldDate { try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path) }
        for _ in 0..<2 { XCTAssertEqual(try store.reloadTemplates(), [template]) }
        XCTAssertEqual(probe.counts().reads, 4)
        XCTAssertEqual(probe.counts().decodes, 2, "Size, revision and mtime are not freshness evidence")

        let corrupt = Data(repeating: 0x78, count: changed.count)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try store.reloadTemplates())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        try changed.write(to: url)
        XCTAssertEqual(try store.reloadTemplates(), [template])
        XCTAssertEqual(probe.counts().decodes, 4, "Decode failure must clear the previous fingerprint")

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.reloadTemplates(), "Unreadable file must never reuse cached templates")
        try FileManager.default.removeItem(at: url)
        try changed.write(to: url)
        XCTAssertEqual(try store.reloadTemplates(), [template])
        XCTAssertEqual(probe.counts().decodes, 5, "Read failure must clear the previous fingerprint")
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try store.reloadTemplates(), "Missing saved configuration must remain a failure")
        try changed.write(to: url)
        XCTAssertEqual(try store.reloadTemplates(), [template])
        XCTAssertEqual(probe.counts().decodes, 6, "Missing file must clear the previous fingerprint")
        XCTAssertEqual(store.decodedFileCacheRetainedRawByteCount, 0)
    }

    func testOlderReadCompletionCannotReplaceNewerDecodedFileCache() throws {
        for paddingSize in [0, 2 * 1024 * 1024] {
            let url = temporaryDirectory.appendingPathComponent("cache-interleaving-\(paddingSize).json")
            let padding = String(repeating: "x", count: paddingSize)
            let first = FileTemplate(name: "A", fileExtension: "txt", content: "old" + padding)
            let second = FileTemplate(name: "B", fileExtension: "txt", content: "new" + padding)
            try JSONEncoder().encode([first]).write(to: url)
            let probe = TemplateStoreIOProbe(pauseFirstRead: true)
            let store = TemplateStore(defaults: defaults, storageURL: url,
                readTemplatesData: { try probe.read($0) }, decodeTemplatesData: { try probe.decode($0) })
            defer { probe.resumeRead.signal() }
            let result = LockedTemplateLoadResult()
            let finished = expectation(description: "Older A read finished")
            DispatchQueue.global().async {
                result.set(Result { try store.reloadTemplates() })
                finished.fulfill()
            }
            XCTAssertEqual(probe.didRead.wait(timeout: .now() + 5), .success)
            try JSONEncoder().encode([second]).write(to: url, options: .atomic)
            XCTAssertEqual(try store.reloadTemplates(), [second])
            probe.resumeRead.signal()
            wait(for: [finished], timeout: 5)
            XCTAssertEqual(try result.get().get(), [first])
            XCTAssertEqual(try store.loadTemplates(), [second], "Late A must not roll back the revision cache either")
            XCTAssertEqual(try store.reloadTemplates(), [second])
            XCTAssertEqual(probe.counts().reads, 3)
            XCTAssertEqual(probe.counts().decodes, 2, "Late A must not evict B's decode cache for either key type")
        }
    }

    func testReadFailureDoesNotUseDecodedFileCacheAsAuthority() throws {
        let url = temporaryDirectory.appendingPathComponent("cached-then-missing.json")
        let templates = [FileTemplate(name: "Original", fileExtension: "txt", content: "keep")]
        try JSONEncoder().encode(templates).write(to: url)
        defaults.set("saved", forKey: "templates.revision.v2")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        XCTAssertEqual(try store.reloadTemplates(), templates)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try store.reloadTemplates())
        try Data("broken-json".utf8).write(to: url)
        XCTAssertThrowsError(try store.reloadTemplates())
    }

    func testCorruptFileIsReportedAndPreservedEvenWithCachedTemplates() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        try store.saveTemplates([FileTemplate(name: "Custom", fileExtension: "txt", content: "keep")])
        let corruptData = Data("broken-json".utf8)
        try corruptData.write(to: storageURL)

        XCTAssertThrowsError(try store.reloadTemplates())
        XCTAssertThrowsError(try store.saveTemplates(BuiltInTemplates.all))
        XCTAssertEqual(try Data(contentsOf: storageURL), corruptData)
    }

    func testTemporarilyUnreadableFileRecoversWithoutReplacingCustomTemplates() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let templates = [FileTemplate(name: "Custom", fileExtension: "txt", content: "keep")]
        let originalData = try JSONEncoder().encode(templates)
        try originalData.write(to: storageURL)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: storageURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path) }
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)

        XCTAssertThrowsError(try store.loadTemplates())
        XCTAssertThrowsError(try store.saveTemplates(BuiltInTemplates.all))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        XCTAssertEqual(try store.reloadTemplates(), templates)
        XCTAssertEqual(try Data(contentsOf: storageURL), originalData)
    }

    func testMissingPreviouslySavedFileIsNotTreatedAsFirstLaunch() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        try store.saveTemplates([])
        try FileManager.default.removeItem(at: storageURL)

        XCTAssertThrowsError(try store.reloadTemplates())
        XCTAssertThrowsError(try store.saveTemplates(BuiltInTemplates.all))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
    }

    func testCompareAndSwapRejectsStaleBaselineAcrossIndependentStores() throws {
        for url in [nil, temporaryDirectory.appendingPathComponent("cas.json")] as [URL?] {
            let first = TemplateStore(defaults: defaults, storageURL: url)
            let second = TemplateStore(defaults: defaults, storageURL: url)
            let original = FileTemplate(name: "Original", fileExtension: "txt", content: "old")
            try first.saveTemplates([original])
            let baseline = try second.reloadTemplates()
            var edited = original
            edited.content = "new"
            try first.saveTemplates([edited], expectedTemplates: baseline)
            XCTAssertThrowsError(try second.saveTemplates([], expectedTemplates: baseline)) { error in
                guard case TemplateStore.StoreError.configurationChanged = error else {
                    return XCTFail("Expected a configuration conflict, got \(error)")
                }
            }
            XCTAssertEqual(try second.reloadTemplates(), [edited])
            try second.saveTemplates([], expectedTemplates: [edited])
            XCTAssertEqual(try first.reloadTemplates(), [])
        }
    }

    func testCompareAndSwapDistinguishesCanonicallyEquivalentLiteralBytes() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        let before = FileTemplate(name: "A", fileExtension: "txt", content: "é")
        try store.saveTemplates([before])
        var changed = before
        changed.content = "e\u{301}"
        try store.saveTemplates([changed])
        XCTAssertThrowsError(try store.saveTemplates([], expectedTemplates: [before])) { error in
            guard case TemplateStore.StoreError.configurationChanged = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(Array(try XCTUnwrap(store.reloadTemplates().first).content.utf8), Array(changed.content.utf8))
    }

    func testExportCannotClobberStoreLockOrFilesystemAliases() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        try store.saveTemplates([])
        XCTAssertThrowsError(try store.validateExportDestination(url))
        XCTAssertThrowsError(try store.validateExportDestination(url.appendingPathExtension("lock")))
        let symlinkURL = temporaryDirectory.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: url)
        XCTAssertThrowsError(try store.validateExportDestination(symlinkURL))
        let hardlinkURL = temporaryDirectory.appendingPathComponent("hardlink.json")
        try FileManager.default.linkItem(at: url, to: hardlinkURL)
        XCTAssertThrowsError(try store.validateExportDestination(hardlinkURL))
        XCTAssertNoThrow(try store.validateExportDestination(temporaryDirectory.appendingPathComponent("export.json")))
    }

    func testMissingStoreExportProtectionIncludesCaseVariants() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        XCTAssertThrowsError(try store.validateExportDestination(temporaryDirectory.appendingPathComponent("TEMPLATES.V2.JSON")))
        XCTAssertThrowsError(try store.validateExportDestination(temporaryDirectory.appendingPathComponent("TEMPLATES.V2.JSON.LOCK")))
        XCTAssertNoThrow(try store.validateExportDestination(temporaryDirectory.appendingPathComponent("My templates.json")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMissingStoreBehindParentAliasCannotBeExportedOver() throws {
        let directory = temporaryDirectory.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let alias = temporaryDirectory.appendingPathComponent("store-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let url = directory.appendingPathComponent("templates.v2.json")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        XCTAssertThrowsError(try store.validateExportDestination(alias.appendingPathComponent("templates.v2.json")))
        XCTAssertThrowsError(try store.validateExportDestination(alias.appendingPathComponent("TEMPLATES.V2.JSON")))
        XCTAssertThrowsError(try store.validateExportDestination(alias.appendingPathComponent("templates.v2.json.lock")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // Canonicalize the configured store too, not just the destination.
        let aliasedStore = TemplateStore(defaults: defaults, storageURL: alias.appendingPathComponent("templates.v2.json"))
        XCTAssertThrowsError(try aliasedStore.validateExportDestination(url))
    }

    func testMissingExportOutsideProtectedPathsRemainsAllowedThroughParentAlias() throws {
        let directory = temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let alias = temporaryDirectory.appendingPathComponent("exports-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let store = TemplateStore(defaults: defaults, storageURL: temporaryDirectory.appendingPathComponent("templates.v2.json"))
        XCTAssertNoThrow(try store.validateExportDestination(directory.appendingPathComponent("new-export.json")))
        XCTAssertNoThrow(try store.validateExportDestination(alias.appendingPathComponent("new-export.json")))
        XCTAssertNoThrow(try store.validateExportDestination(alias.appendingPathComponent("missing/subdirectory/new-export.json")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new-export.json").path))
    }

    func testExportRejectsExplicitTraversalThroughDirectoryAlias() throws {
        let storeDirectory = temporaryDirectory.appendingPathComponent("store", isDirectory: true)
        let child = storeDirectory.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let alias = temporaryDirectory.appendingPathComponent("child-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        let store = TemplateStore(defaults: defaults, storageURL: storeDirectory.appendingPathComponent("templates.v2.json"))
        let traversal = try XCTUnwrap(URL(string: alias.absoluteString + "/../templates.v2.json"))
        XCTAssertTrue(traversal.path.split(separator: "/").contains(".."))
        XCTAssertThrowsError(try store.validateExportDestination(traversal))
        let explicitDot = try XCTUnwrap(URL(string: storeDirectory.absoluteString + "/./templates.v2.json"))
        XCTAssertTrue(explicitDot.path.split(separator: "/").contains("."))
        XCTAssertThrowsError(try store.validateExportDestination(explicitDot))
        XCTAssertNoThrow(try store.validateExportDestination(temporaryDirectory.appendingPathComponent("ordinary-export.json")))
    }

    func testExportFailsClosedForDanglingSymlinkOrItsMissingChild() throws {
        let dangling = temporaryDirectory.appendingPathComponent("dangling-link")
        let target = temporaryDirectory.appendingPathComponent("missing-target")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: target)
        let store = TemplateStore(defaults: defaults, storageURL: temporaryDirectory.appendingPathComponent("templates.v2.json"))
        XCTAssertThrowsError(try store.validateExportDestination(dangling))
        XCTAssertThrowsError(try store.validateExportDestination(dangling.appendingPathComponent("new-export.json")))
        XCTAssertNoThrow(try store.validateExportDestination(temporaryDirectory.appendingPathComponent("ordinary-export.json")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testExportRejectsParentAliasRetargetedAfterEncodingToProtectedConfigOrLock() throws {
        let directory = try makeExportDirectory("store")
        let storageURL = directory.appendingPathComponent("templates.v2.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        try store.saveTemplates(BuiltInTemplates.all)
        let original = try Data(contentsOf: storageURL)
        let lockURL = storageURL.appendingPathExtension("lock")
        let originalLock = try Data(contentsOf: lockURL)
        for (index, name) in [storageURL.lastPathComponent, lockURL.lastPathComponent].enumerated() {
            let safe = try makeExportDirectory("safe-\(index)")
            let alias = temporaryDirectory.appendingPathComponent("selected-\(index)")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: safe)
            let exporting = TemplateStore(defaults: defaults, storageURL: storageURL, exportCheckpoint: { stage in
                if case .afterEncoding = stage {
                    try FileManager.default.removeItem(at: alias)
                    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
                }
            })
            XCTAssertThrowsError(try exporting.exportTemplates(exportBundle(), to: alias.appendingPathComponent(name)))
            XCTAssertEqual(try Data(contentsOf: storageURL), original)
            XCTAssertEqual(try Data(contentsOf: lockURL), originalLock)
            XCTAssertFalse(FileManager.default.fileExists(atPath: safe.appendingPathComponent(name).path))
        }
        XCTAssertEqual(try store.reloadTemplates(), BuiltInTemplates.all)
    }

    func testExportRejectsParentAliasRetargetAfterPinningAndBeforePublication() throws {
        let directory = try makeExportDirectory("store")
        let storageURL = directory.appendingPathComponent("templates.v2.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        try store.saveTemplates(BuiltInTemplates.all)
        let original = try Data(contentsOf: storageURL)
        for stageIndex in 0..<2 {
            let safe = try makeExportDirectory("safe-\(stageIndex)")
            let safeFile = safe.appendingPathComponent("templates.v2.json")
            let previousExport = Data("previous export".utf8)
            try previousExport.write(to: safeFile)
            let alias = temporaryDirectory.appendingPathComponent("selected-\(stageIndex)")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: safe)
            let exporting = TemplateStore(defaults: defaults, storageURL: storageURL, exportCheckpoint: { stage in
                let mutate: Bool
                switch stage {
                case .afterOpeningDirectory: mutate = stageIndex == 0
                case .beforePublication: mutate = stageIndex == 1
                case .afterEncoding: mutate = false
                }
                if mutate {
                    try FileManager.default.removeItem(at: alias)
                    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
                }
            })
            XCTAssertThrowsError(try exporting.exportTemplates(exportBundle(), to: alias.appendingPathComponent("templates.v2.json")))
            XCTAssertEqual(try Data(contentsOf: safeFile), previousExport)
            XCTAssertEqual(try Data(contentsOf: storageURL), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: safe.path), ["templates.v2.json"])
        }
    }

    func testExportRejectsPinnedDirectoryRenameAndReplacementAlias() throws {
        let directory = try makeExportDirectory("store")
        let storageURL = directory.appendingPathComponent("templates.v2.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        try store.saveTemplates(BuiltInTemplates.all)
        let original = try Data(contentsOf: storageURL)
        let safe = try makeExportDirectory("safe")
        let moved = temporaryDirectory.appendingPathComponent("moved-safe")
        let previous = Data("previous export".utf8)
        try previous.write(to: safe.appendingPathComponent("templates.v2.json"))
        let exporting = TemplateStore(defaults: defaults, storageURL: storageURL, exportCheckpoint: { stage in
            if case .beforePublication = stage {
                try FileManager.default.moveItem(at: safe, to: moved)
                try FileManager.default.createSymbolicLink(at: safe, withDestinationURL: directory)
            }
        })
        XCTAssertThrowsError(try exporting.exportTemplates(exportBundle(), to: safe.appendingPathComponent("templates.v2.json")))
        XCTAssertEqual(try Data(contentsOf: storageURL), original)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("templates.v2.json")), previous)
    }

    func testExportRejectsPinnedDirectoryRelocatedIntoBackupSubtree() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        try store.saveTemplates(BuiltInTemplates.all)
        let original = try Data(contentsOf: storageURL)
        let safe = try makeExportDirectory("safe")
        let backup = try makeExportDirectory("QuickFile-template-backup-race-fixture")
        let moved = backup.appendingPathComponent("relocated")
        let alias = temporaryDirectory.appendingPathComponent("selected")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: safe)
        let previous = Data("previous export".utf8)
        try previous.write(to: safe.appendingPathComponent("export.json"))
        let exporting = TemplateStore(defaults: defaults, storageURL: storageURL, exportCheckpoint: { stage in
            if case .beforePublication = stage {
                try FileManager.default.moveItem(at: safe, to: moved)
                try FileManager.default.removeItem(at: alias)
                // The selected pathname still names the pinned inode. Only the
                // descriptor's current protected ancestry check rejects this case.
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: moved)
            }
        })
        XCTAssertThrowsError(try exporting.exportTemplates(exportBundle(), to: alias.appendingPathComponent("export.json")))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("export.json")), previous)
        XCTAssertEqual(try Data(contentsOf: storageURL), original)
    }

    func testDescriptorBoundExportOverwritesConfirmedOrdinaryFileAndKeepsStore() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        try store.saveTemplates(BuiltInTemplates.all)
        let original = try Data(contentsOf: storageURL)
        let directory = try makeExportDirectory("exports")
        let alias = temporaryDirectory.appendingPathComponent("selected")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let destination = alias.appendingPathComponent("export.json")
        try Data("previous contents".utf8).write(to: destination)
        let bundle = exportBundle()
        try store.exportTemplates(bundle, to: destination)
        XCTAssertEqual(try TemplateTransferFile.read(from: destination), bundle)
        XCTAssertEqual(try Data(contentsOf: storageURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["export.json"])
        XCTAssertThrowsError(try store.exportTemplates(bundle, to: destination, limits: .init(maximumFileBytes: 1)))
        XCTAssertEqual(try TemplateTransferFile.read(from: destination), bundle)
    }

    func testExportFailureBeforePublicationPreservesDestinationAndCleansStaging() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let directory = try makeExportDirectory("exports")
        let destination = directory.appendingPathComponent("export.json")
        let previous = Data("keep this export".utf8)
        try previous.write(to: destination)
        let store = TemplateStore(defaults: defaults, storageURL: storageURL, exportCheckpoint: { stage in
            if case .beforePublication = stage { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        })
        XCTAssertThrowsError(try store.exportTemplates(exportBundle(), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["export.json"])
    }

    func testExportRejectsProtectedHardlinkIntroducedBeforePublication() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let initial = TemplateStore(defaults: defaults, storageURL: storageURL)
        try initial.saveTemplates(BuiltInTemplates.all)
        let original = try Data(contentsOf: storageURL)
        let directory = try makeExportDirectory("exports")
        let destination = directory.appendingPathComponent("export.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL, exportCheckpoint: { stage in
            if case .beforePublication = stage {
                try FileManager.default.linkItem(at: storageURL, to: destination)
            }
        })
        XCTAssertThrowsError(try store.exportTemplates(exportBundle(), to: destination))
        XCTAssertEqual(try Data(contentsOf: storageURL), original)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testExportRejectsFinalSymlinkAndSpecialFileWithoutChangingTargets() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("templates.v2.json")
        let store = TemplateStore(defaults: defaults, storageURL: storageURL)
        let directory = try makeExportDirectory("exports")
        let target = directory.appendingPathComponent("target.json")
        let original = Data("target contents".utf8)
        try original.write(to: target)
        let alias = directory.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        XCTAssertThrowsError(try store.exportTemplates(exportBundle(), to: alias))
        XCTAssertEqual(try Data(contentsOf: target), original)
        let fifo = directory.appendingPathComponent("fifo.json")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertThrowsError(try store.exportTemplates(exportBundle(), to: fifo))
    }

    private func makeExportDirectory(_ name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func exportBundle() -> TemplateTransferBundle {
        TemplateTransferBundle(templates: [
            TransferTemplate(name: "Export", fileExtension: "txt", content: "{{clipboard}}\nexport", isEnabled: false)
        ])
    }

    func testUnexpectedLegacyTypeIsPreservedByOrdinaryLoadAndSave() throws {
        defaults.set("unexpected string", forKey: "templates.v1")
        let store = TemplateStore(defaults: defaults, storageURL: temporaryDirectory.appendingPathComponent("templates.json"))
        XCTAssertThrowsError(try store.reloadTemplates())
        XCTAssertThrowsError(try store.saveTemplates([]))
        XCTAssertEqual(defaults.string(forKey: "templates.v1"), "unexpected string")
        let snapshot = try store.prepareRecovery()
        XCTAssertEqual(snapshot.reason, .corruptLegacyData)
        let result = try store.recoverTemplates([], expectedRecoveryState: snapshot)
        let metadata = try recoveryMetadata(result.backupURL)
        let rawValue = try XCTUnwrap(metadata["legacyValuePropertyList"] as? Data)
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: rawValue, format: nil) as? [String], ["unexpected string"])
    }

    func testRecoveryDefaultsBudgetChargesEscapingAndExactBoundary() throws {
        // This is an allocation budget, deliberately more conservative than XML length.
        let value = String(repeating: "&", count: 100)
        let required = 1024 + 264 + 6 * value.utf8.count
        var exact = required
        let encoded = try XCTUnwrap(TemplateStore.serializedDefaultsValue(value, remainingBytes: &exact))
        XCTAssertEqual(exact, 0)
        XCTAssertLessThanOrEqual(encoded.count, required)
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String], [value])
        var insufficient = required - 1
        XCTAssertThrowsError(try TemplateStore.serializedDefaultsValue(value, remainingBytes: &insufficient))
        var emptyBudget = 0
        XCTAssertNil(try TemplateStore.serializedDefaultsValue(nil, remainingBytes: &emptyBudget))
        XCTAssertThrowsError(try TemplateStore.serializedDefaultsValue("", remainingBytes: &emptyBudget))
    }

    func testRecoveryDefaultsBudgetBoundsNestedDataNodeCountAndDepth() throws {
        let values: [Any] = [
            ["nested": [Data(repeating: 0, count: 1024)]],
            Array(repeating: false, count: 32),
            [String(repeating: "&", count: 600): true]
        ]
        for value in values {
            var budget = 4096
            XCTAssertThrowsError(try TemplateStore.serializedDefaultsValue(value, remainingBytes: &budget))
        }
        var nested: Any = false
        for _ in 0..<33 { nested = [nested] }
        var budget = 1024 * 1024
        XCTAssertThrowsError(try TemplateStore.serializedDefaultsValue(nested, remainingBytes: &budget))
    }

    func testRecoveryDefaultsBudgetFailurePreservesFileAndBothDefaults() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let original = Data("broken".utf8)
        try original.write(to: url)
        let values: [(Any, Any)] = [
            (String(repeating: "&", count: 600), "revision"),
            (["nested": [Data(repeating: 0, count: 1024)]], "revision"),
            ("legacy", String(repeating: "&", count: 600)),
            // Each fits alone, but the two snapshots must share one budget.
            (String(repeating: "a", count: 200), String(repeating: "b", count: 200))
        ]
        let store = TemplateStore(defaults: defaults, storageURL: url, recoveryDefaultsMaximumBytes: 4096)
        for (legacy, revision) in values {
            defaults.set(legacy, forKey: "templates.v1")
            defaults.set(revision, forKey: "templates.revision.v2")
            let before = try PropertyListSerialization.data(
                fromPropertyList: [defaults.object(forKey: "templates.v1")!, defaults.object(forKey: "templates.revision.v2")!],
                format: .binary, options: 0
            )
            XCTAssertThrowsError(try store.prepareRecovery()) { error in
                guard case let TemplateStore.StoreError.readFailed(underlying) = error,
                      case TemplateTransferError.fileTooLarge = underlying else { return XCTFail("\(error)") }
            }
            let after = try PropertyListSerialization.data(
                fromPropertyList: [defaults.object(forKey: "templates.v1")!, defaults.object(forKey: "templates.revision.v2")!],
                format: .binary, options: 0
            )
            XCTAssertEqual(before, after)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertTrue(try recoveryBackupURLs().isEmpty)
        }
    }

    func testRecoveryPreservesSmallNestedUnexpectedDefaultsAndTheirCAS() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let legacy: [String: Any] = ["values": [Data([0, 255]), "<&", true, 42, 1.5, Date(timeIntervalSince1970: 0)]]
        defaults.set(legacy, forKey: "templates.v1")
        defaults.set(["unexpected": 7], forKey: "templates.revision.v2")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        let stale = try store.prepareRecovery()
        defaults.set(["unexpected": 8], forKey: "templates.revision.v2")
        XCTAssertThrowsError(try store.recoverTemplates([], expectedRecoveryState: stale)) { error in
            guard case TemplateStore.RecoveryError.configurationChanged = error else { return XCTFail("\(error)") }
        }
        let snapshot = try store.prepareRecovery()
        let result = try store.recoverTemplates([], expectedRecoveryState: snapshot)
        let metadata = try recoveryMetadata(result.backupURL)
        let legacyBytes = try XCTUnwrap(metadata["legacyValuePropertyList"] as? Data)
        let restored = try XCTUnwrap(try PropertyListSerialization.propertyList(from: legacyBytes, format: nil) as? [NSDictionary])
        XCTAssertEqual(restored, [legacy as NSDictionary])
        let revisionBytes = try XCTUnwrap(metadata["revisionValuePropertyList"] as? Data)
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: revisionBytes, format: nil) as? [[String: Int]], [["unexpected": 8]])
    }

    func testPrepareRecoveryDoesNotMutateCorruptionOrDefaults() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let raw = Data(" { broken json \n".utf8)
        try raw.write(to: url)
        defaults.set("old-revision", forKey: "templates.revision.v2")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        let snapshot = try store.prepareRecovery()
        XCTAssertEqual(snapshot.reason, .corruptFile)
        XCTAssertEqual(try Data(contentsOf: url), raw)
        XCTAssertEqual(defaults.string(forKey: "templates.revision.v2"), "old-revision")
        XCTAssertTrue(try recoveryBackupURLs().isEmpty)
        XCTAssertThrowsError(try store.saveTemplates(BuiltInTemplates.all))
        XCTAssertThrowsError(try store.reloadTemplates())
    }

    func testRecoveryBacksUpExactOriginalBytesAndLegacyMetadataBeforeReset() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let raw = Data([0, 0xff, 10, 0x7b, 0x20])
        let legacy = Data("also broken legacy".utf8)
        try raw.write(to: url)
        defaults.set(legacy, forKey: "templates.v1")
        defaults.set("original-revision", forKey: "templates.revision.v2")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        let snapshot = try store.prepareRecovery()
        let result = try store.recoverTemplates(BuiltInTemplates.all, expectedRecoveryState: snapshot)
        XCTAssertEqual(result.templates, BuiltInTemplates.all)
        XCTAssertThrowsError(try store.validateExportDestination(result.backupURL.appendingPathComponent("templates.original.json")))
        XCTAssertThrowsError(try store.validateExportDestination(result.backupURL.appendingPathComponent("new-export.json")))
        let backupAlias = temporaryDirectory.appendingPathComponent("backup-alias")
        try FileManager.default.createSymbolicLink(at: backupAlias, withDestinationURL: result.backupURL)
        XCTAssertThrowsError(try store.validateExportDestination(backupAlias.appendingPathComponent("new-export.json")))
        XCTAssertThrowsError(try store.validateExportDestination(backupAlias.appendingPathComponent("missing/subdirectory/new-export.json")))
        XCTAssertEqual(try store.reloadTemplates(), BuiltInTemplates.all)
        XCTAssertEqual(try Data(contentsOf: result.backupURL.appendingPathComponent("templates.original.json")), raw)
        XCTAssertEqual(try Data(contentsOf: result.backupURL.appendingPathComponent("legacy.original.data")), legacy)
        let metadata = try recoveryMetadata(result.backupURL)
        XCTAssertEqual(metadata["fileWasMissing"] as? Bool, false)
        let encodedRevision = try XCTUnwrap(metadata["revisionValuePropertyList"] as? Data)
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: encodedRevision, format: nil) as? [String], ["original-revision"])
        XCTAssertNil(defaults.data(forKey: "templates.v1"))
        XCTAssertNotEqual(defaults.string(forKey: "templates.revision.v2"), "original-revision")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: result.backupURL.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o500)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: result.backupURL.appendingPathComponent("templates.original.json").path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
        XCTAssertThrowsError(try store.recoverTemplates([], expectedRecoveryState: snapshot))
        XCTAssertEqual(try recoveryBackupURLs().count, 1)
    }

    func testMissingSavedConfigurationRecoveryHasMetadataBackup() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        defaults.set("previously-saved", forKey: "templates.revision.v2")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        let snapshot = try store.prepareRecovery()
        XCTAssertEqual(snapshot.reason, .missingSavedConfiguration)
        let result = try store.recoverTemplates([], expectedRecoveryState: snapshot)
        XCTAssertEqual(try store.reloadTemplates(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.backupURL.appendingPathComponent("templates.original.json").path))
        let metadata = try recoveryMetadata(result.backupURL)
        XCTAssertEqual(metadata["fileWasMissing"] as? Bool, true)
        XCTAssertEqual(metadata["revisionWasPresent"] as? Bool, true)
        XCTAssertEqual(metadata["reason"] as? String, "missingSavedConfiguration")
    }

    func testCorruptLegacyRecoveryPreservesPayloadAndUsesValidatedReplacement() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let raw = Data("broken legacy".utf8)
        defaults.set(raw, forKey: "templates.v1")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        let snapshot = try store.prepareRecovery()
        XCTAssertEqual(snapshot.reason, .corruptLegacyData)
        let bundle = TemplateTransferBundle(templates: [TransferTemplate(name: "restored", fileExtension: "", content: "{{clipboard}}", isEnabled: false)])
        let validated = try TemplateTransfer.decode(TemplateTransfer.encode(bundle))
        let replacements = validated.templates.map { $0.makeTemplate() }
        let result = try store.recoverTemplates(replacements, expectedRecoveryState: snapshot)
        XCTAssertEqual(try store.reloadTemplates(), replacements)
        XCTAssertEqual(try Data(contentsOf: result.backupURL.appendingPathComponent("legacy.original.data")), raw)
        XCTAssertNil(defaults.data(forKey: "templates.v1"))
    }

    func testRecoveryRejectsHealthyAndFirstLaunchStores() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        XCTAssertThrowsError(try store.prepareRecovery()) { error in
            guard case TemplateStore.RecoveryError.notRecoverable = error else { return XCTFail("\(error)") }
        }
        try store.saveTemplates([])
        XCTAssertThrowsError(try store.prepareRecovery())
        XCTAssertTrue(try recoveryBackupURLs().isEmpty)
        XCTAssertThrowsError(try TemplateStore(defaults: nil).prepareRecovery())
    }

    func testRecoveryRejectsPermissionFailureSymlinkDirectoryAndFIFO() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let store = TemplateStore(defaults: defaults, storageURL: url)
        let raw = Data("broken".utf8)
        try raw.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        XCTAssertThrowsError(try store.prepareRecovery())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let target = temporaryDirectory.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: url, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try store.prepareRecovery())
        XCTAssertEqual(try Data(contentsOf: target), raw)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.prepareRecovery())
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(mkfifo(url.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertThrowsError(try store.prepareRecovery())
        XCTAssertTrue(try recoveryBackupURLs().isEmpty)
    }

    func testRecoveryRejectsChangedFileLegacyAndRevisionSnapshots() throws {
        for field in ["file", "legacy", "revision", "sameBytesNewFile"] {
            let url = temporaryDirectory.appendingPathComponent("\(field).json")
            let original = Data("broken".utf8)
            try original.write(to: url)
            defaults.set(Data("legacy".utf8), forKey: "templates.v1")
            defaults.set("initial", forKey: "templates.revision.v2")
            let store = TemplateStore(defaults: defaults, storageURL: url)
            let snapshot = try store.prepareRecovery()
            switch field {
            case "file": try Data("different corruption".utf8).write(to: url, options: .atomic)
            case "legacy": defaults.set(Data("different legacy".utf8), forKey: "templates.v1")
            case "revision": defaults.set("different revision", forKey: "templates.revision.v2")
            default: try original.write(to: url, options: .atomic)
            }
            let current = try Data(contentsOf: url)
            XCTAssertThrowsError(try store.recoverTemplates(BuiltInTemplates.all, expectedRecoveryState: snapshot)) { error in
                guard case TemplateStore.RecoveryError.configurationChanged = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: url), current)
        }
        XCTAssertTrue(try recoveryBackupURLs().isEmpty)
    }

    func testSnapshotCannotBeUsedWithAnotherStoreInstance() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        try Data("broken".utf8).write(to: url)
        let first = TemplateStore(defaults: defaults, storageURL: url)
        let second = TemplateStore(defaults: defaults, storageURL: url)
        let snapshot = try first.prepareRecovery()
        XCTAssertThrowsError(try second.recoverTemplates([], expectedRecoveryState: snapshot))
        XCTAssertTrue(try recoveryBackupURLs().isEmpty)
    }

    func testConcurrentRecoveriesAllowOnlyOneReplacementAndBackup() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let raw = Data("broken".utf8)
        try raw.write(to: url)
        let first = TemplateStore(defaults: defaults, storageURL: url)
        let second = TemplateStore(defaults: defaults, storageURL: url)
        let firstSnapshot = try first.prepareRecovery()
        let secondSnapshot = try second.prepareRecovery()
        let results = LockedRecoveryResults()
        let done = expectation(description: "Both repair attempts finish")
        done.expectedFulfillmentCount = 2
        DispatchQueue.global().async {
            results.append(Result { try first.recoverTemplates(BuiltInTemplates.all, expectedRecoveryState: firstSnapshot) })
            done.fulfill()
        }
        DispatchQueue.global().async {
            results.append(Result { try second.recoverTemplates([], expectedRecoveryState: secondSnapshot) })
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let successful = results.values().compactMap { try? $0.get() }
        XCTAssertEqual(successful.count, 1)
        XCTAssertEqual(try recoveryBackupURLs().count, 1)
        XCTAssertEqual(try first.reloadTemplates(), try XCTUnwrap(successful.first).templates)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(successful.first).backupURL.appendingPathComponent("templates.original.json")), raw)
    }

    func testBackupFailureAndPartialBackupFailureAbortBeforeReplacement() throws {
        for failurePosition in [1, 2] {
            let url = temporaryDirectory.appendingPathComponent("templates-\(failurePosition).json")
            let raw = Data("broken original".utf8)
            try raw.write(to: url)
            defaults.set("original-revision", forKey: "templates.revision.v2")
            let writes = FailingBackupWrites(failurePosition: failurePosition)
            let store = TemplateStore(defaults: defaults, storageURL: url, backupWriteOverride: { try writes.write($0, to: $1) })
            let snapshot = try store.prepareRecovery()
            XCTAssertThrowsError(try store.recoverTemplates([], expectedRecoveryState: snapshot)) { error in
                guard case TemplateStore.RecoveryError.backupFailed = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: url), raw)
            XCTAssertEqual(defaults.string(forKey: "templates.revision.v2"), "original-revision")
        }
    }

    func testFailedReplacementPreservesOriginalAndKeepsUniqueReadOnlyBackup() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let raw = Data("broken original".utf8)
        try raw.write(to: url)
        defaults.set("old", forKey: "templates.revision.v2")
        let store = TemplateStore(defaults: defaults, storageURL: url, writeTemplatesData: { _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        })
        let snapshot = try store.prepareRecovery()
        var backups: [URL] = []
        for _ in 0..<2 {
            do {
                _ = try store.recoverTemplates([], expectedRecoveryState: snapshot)
                XCTFail("Expected write failure")
            } catch let TemplateStore.RecoveryError.replacementFailed(backupURL, _) {
                backups.append(backupURL)
            }
        }
        XCTAssertEqual(Set(backups).count, 2)
        for backup in backups {
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("templates.original.json")), raw)
        }
        XCTAssertEqual(try Data(contentsOf: url), raw)
        XCTAssertEqual(defaults.string(forKey: "templates.revision.v2"), "old")
        XCTAssertThrowsError(try store.reloadTemplates())
    }

    func testExternalFileEditDuringBackupIsNotOverwritten() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        try Data("initial corruption".utf8).write(to: url)
        let edited = Data("edited during backup".utf8)
        let store = TemplateStore(defaults: defaults, storageURL: url, backupWriteOverride: { data, backupURL in
            try data.write(to: backupURL, options: .withoutOverwriting)
            try edited.write(to: url, options: .atomic)
        })
        let snapshot = try store.prepareRecovery()
        XCTAssertThrowsError(try store.recoverTemplates([], expectedRecoveryState: snapshot)) { error in
            guard case TemplateStore.RecoveryError.configurationChanged = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), edited)
        XCTAssertNil(defaults.string(forKey: "templates.revision.v2"))
    }

    func testLegacyAndRevisionEditDuringBackupIsNotOverwritten() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let raw = Data("initial corruption".utf8)
        try raw.write(to: url)
        defaults.set(try JSONEncoder().encode([FileTemplate]()), forKey: "templates.v1")
        defaults.set("before", forKey: "templates.revision.v2")
        let concurrentWriter = TemplateStore(defaults: defaults)
        let changed = [FileTemplate(name: "Concurrent", fileExtension: "txt", content: "keep")]
        let store = TemplateStore(defaults: defaults, storageURL: url, backupWriteOverride: { data, backupURL in
            try data.write(to: backupURL, options: .withoutOverwriting)
            try concurrentWriter.saveTemplates(changed)
        })
        let snapshot = try store.prepareRecovery()
        XCTAssertThrowsError(try store.recoverTemplates([], expectedRecoveryState: snapshot)) { error in
            guard case TemplateStore.RecoveryError.configurationChanged = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), raw)
        XCTAssertEqual(try concurrentWriter.reloadTemplates(), changed)
        XCTAssertNotEqual(defaults.string(forKey: "templates.revision.v2"), "before")
    }

    func testOversizedHistoricalFileIsNotClassifiedAsCorruption() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        try Data("broken".utf8).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        let oversized = UInt64(TemplateStore.maximumRecoveryFileBytes + 1)
        try handle.truncate(atOffset: oversized)
        try handle.close()
        let store = TemplateStore(defaults: defaults, storageURL: url)
        XCTAssertThrowsError(try store.prepareRecovery()) { error in
            guard case TemplateStore.StoreError.readFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(try recoveryBackupURLs().isEmpty)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value, oversized)
    }

    func testRecoveryBudgetAcceptsInternalJSONLargerThanValidPortableEnvelope() throws {
        let limit = TemplateTransferLimits.default.maximumFileBytes
        let first = FileTemplate(name: "First", fileExtension: "txt", content: "")
        let second = FileTemplate(name: "Second", fileExtension: "txt", content: "")
        let overhead = try TemplateTransfer.validateEncodedSize(TemplateTransferBundle(templates: [first, second]))
        var templates = [first, second]
        templates[0].content = String(repeating: "/", count: limit / 2)
        templates[1].content = String(repeating: "/", count: limit / 2 - overhead)
        XCTAssertEqual(try TemplateTransfer.validateEncodedSize(TemplateTransferBundle(templates: templates)), limit)
        // JSONEncoder's internal UUID fields alone exceed the portable envelope;
        // slash escaping can amplify this further. The recovery budget covers both.
        let internalData = try JSONEncoder().encode(templates)
        XCTAssertGreaterThan(internalData.count, limit)
        XCTAssertLessThanOrEqual(internalData.count, TemplateStore.maximumRecoveryFileBytes)
        let url = temporaryDirectory.appendingPathComponent("large-internal-json.json")
        try internalData.write(to: url)
        let store = TemplateStore(defaults: defaults, storageURL: url)
        XCTAssertThrowsError(try store.prepareRecovery()) { error in
            guard case TemplateStore.RecoveryError.notRecoverable = error else {
                return XCTFail("A valid internal configuration must be recognized, not rejected by portable size: \(error)")
            }
        }
    }

    func testInvalidReplacementCannotCreateBackupOrReplaceCorruption() throws {
        let url = temporaryDirectory.appendingPathComponent("templates.json")
        let raw = Data("broken".utf8)
        try raw.write(to: url)
        let store = TemplateStore(defaults: defaults, storageURL: url)
        let snapshot = try store.prepareRecovery()
        XCTAssertThrowsError(try store.recoverTemplates([FileTemplate(name: "", fileExtension: "txt", content: "")], expectedRecoveryState: snapshot))
        XCTAssertEqual(try Data(contentsOf: url), raw)
        XCTAssertTrue(try recoveryBackupURLs().isEmpty)
    }

    private func recoveryBackupURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("QuickFile-template-backup-") }
    }

    private func recoveryMetadata(_ backupURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: backupURL.appendingPathComponent("metadata.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testUnavailableStoreDoesNotSupplyDefaults() {
        XCTAssertThrowsError(try TemplateStore(defaults: nil).loadTemplates())
    }
}

private final class PausingTemplateFileManager: FileManager, @unchecked Sendable {
    let didEnterCreateDirectory = DispatchSemaphore(value: 0)
    let resumeCreateDirectory = DispatchSemaphore(value: 0)

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        didEnterCreateDirectory.signal()
        guard resumeCreateDirectory.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "TemplateStoreTests", code: 1)
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }
}

// Every mutable counter is lock-protected; the semaphores only coordinate test
// checkpoints, and file/JSON operations run outside that lock.
private final class TemplateStoreIOProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0
    private var decodeCount = 0
    private let pauseFirstRead: Bool
    let didRead = DispatchSemaphore(value: 0)
    let resumeRead = DispatchSemaphore(value: 0)

    init(pauseFirstRead: Bool = false) { self.pauseFirstRead = pauseFirstRead }

    func read(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        lock.lock()
        readCount += 1
        let pause = pauseFirstRead && readCount == 1
        lock.unlock()
        if pause {
            didRead.signal()
            guard resumeRead.wait(timeout: .now() + 5) == .success else {
                throw NSError(domain: "TemplateStoreIOProbe", code: 1)
            }
        }
        return data
    }

    func decode(_ data: Data) throws -> [FileTemplate] {
        lock.lock()
        decodeCount += 1
        lock.unlock()
        return try JSONDecoder().decode([FileTemplate].self, from: data)
    }

    func counts() -> (reads: Int, decodes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (readCount, decodeCount)
    }
}

private final class LockedTemplateLoadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[FileTemplate], Error>?

    func set(_ result: Result<[FileTemplate], Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() throws -> Result<[FileTemplate], Error> {
        lock.lock()
        defer { lock.unlock() }
        return try XCTUnwrap(result)
    }
}

private final class LockedRecoveryResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<TemplateStore.RecoveryResult, Error>] = []

    func append(_ result: Result<TemplateStore.RecoveryResult, Error>) {
        lock.lock()
        results.append(result)
        lock.unlock()
    }

    func values() -> [Result<TemplateStore.RecoveryResult, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}

private final class FailingBackupWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failurePosition: Int

    init(failurePosition: Int) { self.failurePosition = failurePosition }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        count += 1
        let shouldFail = count == failurePosition
        lock.unlock()
        if shouldFail { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        try data.write(to: url, options: .withoutOverwriting)
    }
}
