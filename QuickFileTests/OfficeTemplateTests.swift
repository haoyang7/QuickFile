import XCTest
@testable import QuickFile
@testable import QuickFileCore
@testable import QuickFileInfrastructure

final class OfficeTemplateTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var storageURL: URL { directory.appendingPathComponent("templates.json") }

    override func setUpWithError() throws {
        suite = "QuickFileTests.OfficeTemplates.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        directory = repository.appendingPathComponent(".build/Temporary/office-defaults/\(suite!)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let suite { defaults?.removePersistentDomain(forName: suite) }
        if let directory { try FileManager.default.removeItem(at: directory) }
        defaults = nil
        directory = nil
        suite = nil
    }

    private func office(_ format: OfficeDocumentFormat) -> FileTemplate {
        FileTemplate(name: "Office \(format.rawValue)", fileExtension: format.rawValue,
                     content: "", officeFormat: format)
    }

    private func store() -> TemplateStore {
        TemplateStore(defaults: defaults, storageURL: storageURL, cachesReads: false,
                      changeNotificationName: suite)
    }

    private func record(_ template: FileTemplate) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as? [String: Any])
    }

    private func library(_ records: [[String: Any]], version: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "format": "quickfile.template-library", "version": version, "templates": records
        ])
    }

    private func assertLibraryRejects(_ data: Data, selectedID: UUID,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        try data.write(to: storageURL, options: .atomic)
        let reader = store()
        XCTAssertThrowsError(try reader.reloadTemplates(), file: file, line: line)
        XCTAssertThrowsError(try reader.reloadMenuEntries(), file: file, line: line)
        XCTAssertThrowsError(try reader.reloadCreationSnapshot(templateID: selectedID), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: storageURL), data, file: file, line: line)
    }

    func testModelBackwardDecodeAndOfficeRoundTrip() throws {
        for format in OfficeDocumentFormat.allCases {
            let source = office(format)
            XCTAssertEqual(try JSONDecoder().decode(FileTemplate.self, from: JSONEncoder().encode(source)), source)
            var historical = try record(source)
            historical.removeValue(forKey: "officeFormat")
            historical.removeValue(forKey: "defaultFilename")
            historical["content"] = "historical text"
            let decoded = try JSONDecoder().decode(FileTemplate.self, from: JSONSerialization.data(withJSONObject: historical))
            XCTAssertNil(decoded.officeFormat)
            XCTAssertEqual(decoded.content, "historical text")
            XCTAssertEqual(decoded.defaultFilename, "")
            XCTAssertNil(TemplateDraft().officeFormat)
            XCTAssertEqual(try TemplateDraft(template: source).makeTemplate(), source)
        }
    }

    func testModelAndDraftRejectMalformedOfficeMarkersAndFields() throws {
        let source = office(.docx)
        let valid = try record(source)
        for marker in ["unknown", NSNull(), false, 1, ["docx"], ["format": "docx"]] as [Any] {
            var invalid = valid
            invalid["officeFormat"] = marker
            XCTAssertThrowsError(try JSONDecoder().decode(FileTemplate.self, from: JSONSerialization.data(withJSONObject: invalid)))
        }
        for (suffix, content) in [("xlsx", ""), ("DOCX", ""), (".docx", ""), (" docx ", ""), ("", ""), ("docx", " "), ("docx", "{{clipboard}}")] {
            var invalid = source
            invalid.fileExtension = suffix
            invalid.content = content
            XCTAssertThrowsError(try TemplateDraft(template: invalid).makeTemplate()) {
                XCTAssertEqual($0 as? TemplateValidationError, .invalidOfficeTemplate)
            }
            XCTAssertThrowsError(try JSONDecoder().decode(FileTemplate.self, from: JSONEncoder().encode(invalid)))
        }
    }

    func testBuiltInsPrependOfficeKeepTextIdentitiesAndFinderOrder() throws {
        let templates = BuiltInTemplates.all
        XCTAssertEqual(templates.map(\.fileExtension), ["docx", "xlsx", "pptx", "txt", "md", "json", "yaml", "sh"])
        XCTAssertEqual(templates.prefix(3).map(\.officeFormat), [.docx, .xlsx, .pptx])
        XCTAssertTrue(templates.prefix(3).allSatisfy { $0.content.isEmpty && $0.isEnabled })
        XCTAssertTrue(templates.dropFirst(3).allSatisfy { $0.officeFormat == nil })
        XCTAssertEqual(Set(templates.map(\.id)).count, templates.count)
        let textIDs = [
            "A8A680CC-CC64-4F71-8905-E5B350297A11", "B16CD640-23B1-4FF6-A365-816696091E1C",
            "42A8D1DB-D9DA-4D84-A698-505130282A67", "7537DDB2-C1B3-4597-B3B1-24ED056F4BD0",
            "020E1DD5-C50D-436C-A433-39250EE60B3B"
        ].map { UUID(uuidString: $0)! }
        XCTAssertEqual(templates.dropFirst(3).map(\.id), textIDs)
        XCTAssertEqual(try store().reloadTemplates(), templates)
        XCTAssertEqual(try store().reloadMenuEntries().map(\.id), templates.map(\.id))
        for template in templates.prefix(3) {
            XCTAssertEqual(try store().reloadCreationSnapshot(templateID: template.id).template, template)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path), "Reading defaults must not seed a user library")
    }

    func testOfficeLibraryUsesV4AndAllReadProjectionsPreserveMarker() throws {
        var selected = office(.xlsx)
        selected.defaultFilename = "工作簿.xlsx"
        var disabled = office(.pptx)
        disabled.isEnabled = false
        let text = FileTemplate(name: "Text DOCX", fileExtension: "docx", content: "literal text")
        let templates = [selected, disabled, text]
        try store().saveTemplates(templates)
        let bytes = try Data(contentsOf: storageURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 4)
        XCTAssertThrowsError(try JSONDecoder().decode([FileTemplate].self, from: bytes))
        let reader = store()
        XCTAssertEqual(try reader.reloadTemplates(), templates)
        XCTAssertEqual(try reader.reloadMenuEntries(), FinderMenuModelBuilder().entries(from: templates))
        let snapshot = try reader.reloadCreationSnapshot(templateID: selected.id)
        XCTAssertEqual(snapshot.template, selected)
        XCTAssertEqual(snapshot.menuEntries, FinderMenuModelBuilder().entries(from: templates))
        XCTAssertNil(try reader.reloadCreationSnapshot(templateID: disabled.id).template)
        XCTAssertEqual(try reader.reloadCreationSnapshot(templateID: text.id).template, text)
    }

    func testHistoricalTextLibraryDoesNotAcquireOfficeOrNewDefaults() throws {
        let text = FileTemplate(name: "Existing DOCX", fileExtension: "docx", content: "saved text")
        let records = [try record(text)]
        for data in [try JSONSerialization.data(withJSONObject: records), try library(records, version: 3)] {
            try data.write(to: storageURL, options: .atomic)
            let reader = store()
            XCTAssertEqual(try reader.reloadTemplates(), [text])
            XCTAssertEqual(try reader.reloadMenuEntries(), [FinderTemplateMenuEntry(template: text)])
            XCTAssertEqual(try reader.reloadCreationSnapshot(templateID: text.id).template, text)
            XCTAssertEqual(try Data(contentsOf: storageURL), data)
        }
        try store().saveTemplates([text])
        XCTAssertNoThrow(try JSONDecoder().decode([FileTemplate].self, from: Data(contentsOf: storageURL)))
        var named = text
        named.defaultFilename = "Document"
        try store().saveTemplates([named])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 3)
    }

    func testOldLibraryVersionsAndMalformedUnselectedOfficeRecordsAreRejected() throws {
        let selected = FileTemplate(name: "Selected", fileExtension: "txt", content: "keep")
        var disabled = office(.docx)
        disabled.isEnabled = false
        let selectedRecord = try record(selected)
        let officeRecord = try record(disabled)
        try assertLibraryRejects(JSONSerialization.data(withJSONObject: [selectedRecord, officeRecord]), selectedID: selected.id)
        try assertLibraryRejects(library([selectedRecord, officeRecord], version: 3), selectedID: selected.id)
        for marker in ["unknown", NSNull(), 3, false, ["docx"]] as [Any] {
            var invalid = officeRecord
            invalid["officeFormat"] = marker
            try assertLibraryRejects(library([selectedRecord, invalid], version: 4), selectedID: selected.id)
        }
        for (suffix, content) in [("DOCX", ""), (" .docx ", ""), ("xlsx", ""), ("docx", "body")] {
            var invalid = officeRecord
            invalid["fileExtension"] = suffix
            invalid["content"] = content
            try assertLibraryRejects(library([selectedRecord, invalid], version: 4), selectedID: selected.id)
        }
    }

    func testMarkerOnlyChangeParticipatesInCASAndHistoricalFieldMatching() throws {
        let original = office(.docx)
        try store().saveTemplates([original])
        var text = original
        text.officeFormat = nil
        XCTAssertNotEqual(original, text)
        try store().saveTemplates([text], expectedTemplates: [original])
        XCTAssertThrowsError(try store().saveTemplates([], expectedTemplates: [original])) {
            guard case TemplateStore.StoreError.configurationChanged = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try store().reloadTemplates(), [text])

        var historical = text
        historical.name = String(repeating: "x", count: TemplateTransferLimits.default.maximumNameBytes + 1)
        try JSONEncoder().encode([historical]).write(to: storageURL, options: .atomic)
        var changed = historical
        changed.isEnabled = false
        changed.officeFormat = .docx
        XCTAssertThrowsError(try store().saveTemplates([changed]))
        XCTAssertEqual(try store().reloadTemplates(), [historical])
        changed.officeFormat = nil
        try store().saveTemplates([changed])
        XCTAssertEqual(try store().reloadTemplates(), [changed])
    }

    func testOfficeTransferV3RoundTripDedupeAndExactSizeBoundary() throws {
        var originals = OfficeDocumentFormat.allCases.map(office)
        originals[0].defaultFilename = "文稿 \"📄\""
        originals[1].isEnabled = false
        let bundle = TemplateTransferBundle(templates: originals)
        let encoded = try TemplateTransfer.encode(bundle)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 3)
        XCTAssertEqual(try TemplateTransfer.decode(encoded), bundle)
        XCTAssertEqual(try TemplateTransfer.validateEncodedSize(bundle), encoded.count)
        let exact = TemplateTransferLimits(maximumFileBytes: encoded.count)
        XCTAssertEqual(try TemplateTransfer.encode(bundle, limits: exact), encoded)
        XCTAssertEqual(try TemplateTransfer.decode(encoded, limits: exact), bundle)
        let short = TemplateTransferLimits(maximumFileBytes: encoded.count - 1)
        XCTAssertThrowsError(try TemplateTransfer.encode(bundle, limits: short))
        XCTAssertThrowsError(try TemplateTransfer.validateEncodedSize(bundle, limits: short))
        XCTAssertThrowsError(try TemplateTransfer.decode(encoded, limits: short))
        let plan = try TemplateTransfer.makeImportPlan(bundle: TemplateTransfer.decode(encoded), existing: [])
        XCTAssertEqual(plan.templates.map(\.officeFormat), originals.map(\.officeFormat))
        XCTAssertTrue(Set(plan.templates.map(\.id)).isDisjoint(with: originals.map(\.id)))
        XCTAssertEqual(try TemplateTransfer.makeImportPlan(bundle: bundle, existing: plan.templates).addedCount, 0)

        let officeRecord = TransferTemplate(originals[0])
        let textRecord = TransferTemplate(name: officeRecord.name, fileExtension: officeRecord.fileExtension,
                                          content: "", isEnabled: officeRecord.isEnabled,
                                          defaultFilename: officeRecord.defaultFilename)
        XCTAssertNotEqual(officeRecord, textRecord)
        XCTAssertEqual(Set([officeRecord, textRecord]).count, 2)
        let mixed = try TemplateTransfer.makeImportPlan(
            bundle: TemplateTransferBundle(templates: [officeRecord, textRecord, officeRecord, textRecord]), existing: []
        )
        XCTAssertEqual(mixed.addedCount, 2)
        XCTAssertEqual(mixed.skippedCount, 2)
        XCTAssertEqual(mixed.templates.map(\.officeFormat), [.docx, nil])
    }

    func testTransferOldVersionsAndInvalidMarkersRejectWithoutReinterpretingText() throws {
        let portable = TransferTemplate(office(.docx))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: TemplateTransfer.encode(.init(templates: [portable]))) as? [String: Any])
        let records = try XCTUnwrap(object["templates"] as? [[String: Any]])
        for version in [1, 2] {
            object["version"] = version
            XCTAssertThrowsError(try TemplateTransfer.decode(JSONSerialization.data(withJSONObject: object)))
        }
        object["version"] = 3
        for marker in ["unknown", NSNull(), 0, false, ["docx"]] as [Any] {
            var invalid = records[0]
            invalid["officeFormat"] = marker
            object["templates"] = [invalid]
            XCTAssertThrowsError(try TemplateTransfer.decode(JSONSerialization.data(withJSONObject: object)))
            XCTAssertThrowsError(try JSONDecoder().decode(TransferTemplate.self, from: JSONSerialization.data(withJSONObject: invalid)))
        }
        for (suffix, content) in [("DOCX", ""), (".docx", ""), ("xlsx", ""), ("docx", "body")] {
            let invalid = TransferTemplate(name: "Invalid", fileExtension: suffix, content: content,
                                           isEnabled: true, officeFormat: .docx)
            XCTAssertThrowsError(try TemplateTransfer.encode(.init(templates: [invalid])))
            XCTAssertThrowsError(try TemplateTransfer.makeImportPlan(bundle: .init(templates: [invalid]), existing: []))
        }
        let text = TransferTemplate(name: "Text DOCX", fileExtension: "docx", content: "text", isEnabled: true)
        for filename in ["", "Default"] {
            let source = TransferTemplate(name: text.name, fileExtension: text.fileExtension, content: text.content,
                                          isEnabled: true, defaultFilename: filename)
            let bytes = try TemplateTransfer.encode(.init(templates: [source]))
            let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(legacy["version"] as? Int, filename.isEmpty ? 1 : 2)
            XCTAssertNil(try TemplateTransfer.decode(bytes).templates.first?.officeFormat)
        }
    }

    @MainActor
    func testEditorCopyAndSaveAsNewPreserveOfficeMarkerAndFreshIdentity() async throws {
        for format in OfficeDocumentFormat.allCases {
            var original = office(format)
            original.defaultFilename = "Document.\(format.rawValue)"
            original.isEnabled = false
            var state = TemplateEditorState(template: original, isCopy: true)
            let copy = try state.makeTemplate()
            XCTAssertNotEqual(copy.id, original.id)
            XCTAssertEqual(TransferTemplate(copy), TransferTemplate(original))
            XCTAssertFalse(state.isDirty)
            state.draft.officeFormat = nil
            XCTAssertTrue(state.isDirty)
            state.draft.officeFormat = format
            XCTAssertFalse(state.isDirty)
            try store().saveTemplates([original])
            let model = QuickFileViewModel(
                templateStore: store(), templates: [original],
                authorizedDirectoryStore: AuthorizedDirectoryStore(
                    defaults: defaults, storageDirectory: directory,
                    persistentBookmarkCreator: { Data($0.standardizedFileURL.path.utf8) },
                    transferBookmarkCreator: { Data($0.standardizedFileURL.path.utf8) },
                    persistentBookmarkResolver: { data in
                        let path = try XCTUnwrap(String(data: data, encoding: .utf8))
                        return ResolvedSecurityScopedBookmark(url: URL(fileURLWithPath: path, isDirectory: true), isStale: false)
                    },
                    transferBookmarkResolver: { data in
                        let path = try XCTUnwrap(String(data: data, encoding: .utf8))
                        return ResolvedSecurityScopedBookmark(url: URL(fileURLWithPath: path, isDirectory: true), isStale: false)
                    },
                    startAccessing: { _ in true },
                    stopAccessing: { _ in }
                )
            )
            let newID = try await model.saveTemplateAsNew(copy)
            let saved = try store().reloadTemplates()
            XCTAssertEqual(saved.first, original)
            XCTAssertEqual(saved.last?.id, newID)
            XCTAssertNotEqual(newID, original.id)
            XCTAssertNotEqual(newID, copy.id)
            XCTAssertEqual(saved.last.map(TransferTemplate.init), TransferTemplate(original))
        }
    }

    func testOfficeCreationWritesZIPAndNeverReadsClipboardOrClockOrOverwritesConflict() throws {
        let service = FileCreationService(dateProvider: {
            XCTFail("Office creation must not read the clock")
            return Date(timeIntervalSince1970: 0)
        }, clipboardProvider: {
            XCTFail("Office creation must not read the clipboard")
            return "clipboard"
        })
        for format in OfficeDocumentFormat.allCases {
            let template = office(format)
            let existing = directory.appendingPathComponent("Document.\(format.rawValue)")
            let previous = Data("existing content".utf8)
            try previous.write(to: existing)
            let result = try service.createFile(for: .init(template: template, destinationFolder: directory,
                                                          requestedFilename: "Document"))
            XCTAssertTrue(result.didRenameForConflict)
            XCTAssertEqual(result.fileURL.lastPathComponent, "Document 2.\(format.rawValue)")
            XCTAssertEqual(try Data(contentsOf: existing), previous)
            let data = try Data(contentsOf: result.fileURL)
            XCTAssertGreaterThan(data.count, 4)
            XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
            XCTAssertEqual(data, format.data)
            let edited = Data("user-edited document".utf8)
            try edited.write(to: result.fileURL)
            let next = try service.createFile(for: .init(template: template, destinationFolder: directory,
                                                        requestedFilename: "Document"))
            XCTAssertEqual(next.fileURL.lastPathComponent, "Document 3.\(format.rawValue)")
            XCTAssertTrue(next.didRenameForConflict)
            XCTAssertEqual(try Data(contentsOf: next.fileURL), format.data)
            XCTAssertEqual(try Data(contentsOf: result.fileURL), edited)
            XCTAssertEqual(try Data(contentsOf: existing), previous)
        }
        let expectedNames = OfficeDocumentFormat.allCases.flatMap {
            ["Document.\($0.rawValue)", "Document 2.\($0.rawValue)", "Document 3.\($0.rawValue)"]
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), Set(expectedNames))
    }

    func testSameOfficeExtensionWithoutMarkerStillWritesUTF8Text() throws {
        for format in OfficeDocumentFormat.allCases {
            let template = FileTemplate(name: "Historical", fileExtension: format.rawValue, content: "正文 {{clipboard}}")
            let result = try FileCreationService(clipboardProvider: { "text" }).createFile(
                for: .init(template: template, destinationFolder: directory, requestedFilename: "Text")
            )
            XCTAssertEqual(try Data(contentsOf: result.fileURL), Data("正文 text".utf8))
        }
    }

    func testInvalidOfficeCreationRejectsBeforeWritingAnyFile() throws {
        for (suffix, content) in [("xlsx", ""), ("DOCX", ""), (".docx", ""), (" docx ", ""), ("", ""), ("docx", "{{clipboard}}")] {
            let invalid = FileTemplate(name: "Invalid", fileExtension: suffix, content: content, officeFormat: .docx)
            XCTAssertThrowsError(try FileCreationService().createFile(
                for: .init(template: invalid, destinationFolder: directory, requestedFilename: "Invalid")
            )) {
                XCTAssertEqual($0 as? TemplateValidationError, .invalidOfficeTemplate)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }
}
