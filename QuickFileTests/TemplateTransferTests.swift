import XCTest
import Darwin
@testable import QuickFileCore
@testable import QuickFileInfrastructure

final class TemplateTransferTests: XCTestCase {

    func testTransferRejectsRiskControlsInNamesAndDefaultFilenamesWithoutNormalizingThem() throws {
        let values = Array(0...31) + Array(127...159)
            + [0x061C, 0x200B, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069)
        for value in values {
            let control = String(UnicodeScalar(value)!)
            for field in ["name", "defaultFilename"] {
                let source = TransferTemplate(name: field == "name" ? "Word 文档" + control : "Word 文档",
                                              fileExtension: "txt", content: "body", isEnabled: true,
                                              defaultFilename: field == "defaultFilename" ? "invoice" + control : "")
                let bundle = TemplateTransferBundle(templates: [source])
                // Build external JSON without using the validating export path.
                let bytes = try JSONSerialization.data(withJSONObject: [
                    "format": "quickfile.templates", "version": 2,
                    "templates": [["name": source.name, "fileExtension": source.fileExtension,
                                   "content": source.content, "isEnabled": source.isEnabled,
                                   "defaultFilename": source.defaultFilename]]
                ])
                let error = field == "name" ? TemplateValidationError.invalidName : .invalidDefaultFilename
                let expected = TemplateTransferError.invalidTemplate(index: 0, reason: error.localizedDescription)
                XCTAssertThrowsError(try TemplateTransfer.decode(bytes)) {
                    XCTAssertEqual($0 as? TemplateTransferError, expected)
                }
                XCTAssertThrowsError(try TemplateTransfer.encode(bundle)) {
                    XCTAssertEqual($0 as? TemplateTransferError, expected)
                }
                XCTAssertThrowsError(try TemplateTransfer.makeImportPlan(bundle: bundle, existing: [])) {
                    XCTAssertEqual($0 as? TemplateTransferError, expected)
                }
            }
        }
    }

    func testTransferPreservesLegitimateNameBytesAndUnrestrictedBodyControls() throws {
        let name = "می\u{200C}خواهم-👩‍💻-✈\u{FE0F}-e\u{301}"
        let source = TransferTemplate(name: name, fileExtension: "txt", content: "\u{202E}\u{0}\n",
                                      isEnabled: true, defaultFilename: name)
        let bundle = TemplateTransferBundle(templates: [source])
        let decoded = try TemplateTransfer.decode(TemplateTransfer.encode(bundle))
        let imported = try XCTUnwrap(TemplateTransfer.makeImportPlan(bundle: decoded, existing: []).additions.first?.template)
        XCTAssertEqual(Array(imported.name.utf8), Array(name.utf8))
        XCTAssertEqual(Array(imported.defaultFilename.utf8), Array(name.utf8))
        XCTAssertEqual(Array(imported.content.utf8), Array(source.content.utf8))
    }

    func testDefaultFilenameUsesVersionTwoAndRoundTripsLiteralBytesAndBudget() throws {
        let source = FileTemplate(name: "A", fileExtension: "", content: "", defaultFilename: ".e\u{301}-👩‍💻-{{date}}-\"\\")
        let bundle = TemplateTransferBundle(templates: [source])
        let encoded = try TemplateTransfer.encode(bundle)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(try TemplateTransfer.validateEncodedSize(bundle), encoded.count)
        XCTAssertEqual(try TemplateTransfer.decode(encoded), bundle)
        XCTAssertEqual(try TemplateTransfer.makeImportPlan(bundle: bundle, existing: []).templates.first?.defaultFilename,
                       source.defaultFilename)
        XCTAssertEqual(try TemplateTransfer.encode(bundle, limits: .init(maximumFileBytes: encoded.count)), encoded)
        XCTAssertThrowsError(try TemplateTransfer.encode(bundle, limits: .init(maximumFileBytes: encoded.count - 1)))
        XCTAssertThrowsError(try TemplateTransfer.validateEncodedSize(bundle, limits: .init(maximumNameBytes: 1))) {
            XCTAssertEqual($0 as? TemplateTransferError, .fieldTooLarge(index: 0, field: "默认文件名", maximumBytes: 1))
        }
        var mislabeled = object
        mislabeled["version"] = 1
        XCTAssertThrowsError(try TemplateTransfer.decode(JSONSerialization.data(withJSONObject: mislabeled)))
    }

    func testDefaultFilenameParticipatesInExactDeduplicationAndHash() throws {
        let composed = TransferTemplate(name: "A", fileExtension: "", content: "", isEnabled: true, defaultFilename: "é")
        let decomposed = TransferTemplate(name: "A", fileExtension: "", content: "", isEnabled: true, defaultFilename: "e\u{301}")
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(Set([composed, decomposed, composed]).count, 2)
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: .init(templates: [decomposed]), existing: [composed.makeTemplate()]
        )
        XCTAssertEqual(plan.addedCount, 1)
        XCTAssertEqual(Array(plan.additions[0].template.defaultFilename.utf8), Array(decomposed.defaultFilename.utf8))
    }

    private func record(
        _ name: String = "模板", extension suffix: String = "txt", body: String = "body", enabled: Bool = true
    ) -> TransferTemplate {
        TransferTemplate(name: name, fileExtension: suffix, content: body, isEnabled: enabled)
    }

    private func data(_ records: [TransferTemplate]) throws -> Data {
        try TemplateTransfer.encode(TemplateTransferBundle(templates: records))
    }

    func testRoundTripPreservesOrderAllFieldsAndLiteralVariablesWithoutIDs() throws {
        let originals = [
            FileTemplate(name: "停用 📄", fileExtension: "", content: "  \n{{clipboard}}\r\n{{unknown}}\t", isEnabled: false),
            FileTemplate(name: "Unicode", fileExtension: "文本", content: "e\u{301} ≠ é\u{0000} / \\\" \u{2028}")
        ]
        let encoded = try TemplateTransfer.encode(TemplateTransferBundle(templates: originals))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["format", "version", "templates"])
        XCTAssertEqual(object["format"] as? String, "quickfile.templates")
        XCTAssertEqual(object["version"] as? Int, 1)
        for item in try XCTUnwrap(object["templates"] as? [[String: Any]]) {
            XCTAssertEqual(Set(item.keys), ["name", "fileExtension", "content", "isEnabled"])
        }
        let decoded = try TemplateTransfer.decode(encoded)
        XCTAssertEqual(decoded.templates, originals.map(TransferTemplate.init))
        XCTAssertEqual(Array(decoded.templates[1].content.utf8), Array(originals[1].content.utf8))
        XCTAssertTrue(decoded.templates[0].usesClipboard)
        XCTAssertFalse(decoded.templates[1].usesClipboard)
        let plan = try TemplateTransfer.makeImportPlan(bundle: decoded, existing: [])
        XCTAssertEqual(plan.addedCount, 2)
        XCTAssertEqual(plan.enabledCount, 1)
        XCTAssertEqual(plan.clipboardCount, 1)
        XCTAssertTrue(Set(plan.templates.map(\.id)).isDisjoint(with: originals.map(\.id)))
    }

    func testExistingLargeBodyRoundTripsAtDefaultLimit() throws {
        let body = String(repeating: "abc ", count: 1_150_000)
        let original = record(body: body)
        XCTAssertEqual(body.utf8.count, 4_600_000)
        XCTAssertEqual(try TemplateTransfer.decode(data([original])).templates, [original])
    }

    func testDeduplicatesExistingAndEarlierOriginalAndRenamedItems() throws {
        let existing = record("报告", body: "old").makeTemplate()
        let changed = record("报告", body: "new")
        let renamedCopy = record("报告（导入）", body: "new")
        let bundle = TemplateTransferBundle(templates: [TransferTemplate(existing), changed, changed, renamedCopy])
        let plan = try TemplateTransfer.makeImportPlan(bundle: bundle, existing: [existing])
        XCTAssertEqual(plan.baseline, [existing])
        XCTAssertEqual(plan.addedCount, 1)
        XCTAssertEqual(plan.skippedCount, 3)
        XCTAssertEqual(plan.renamedCount, 1)
        XCTAssertEqual(plan.additions[0].sourceIndex, 1)
        XCTAssertEqual(plan.additions[0].originalName, "报告")
        XCTAssertEqual(plan.templates.map(\.name), ["报告", "报告（导入）"])
        XCTAssertEqual(plan.templates.first, existing)
    }

    func testDisabledDifferenceIsNotDuplicateAndRenameSkipsCollisions() throws {
        let originals = [record("A"), record("A（导入）"), record("A（导入 2）")].map { $0.makeTemplate() }
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: TemplateTransferBundle(templates: [record("A", enabled: false), record("A", body: "different")]),
            existing: originals
        )
        XCTAssertEqual(plan.templates.suffix(2).map(\.name), ["A（导入 3）", "A（导入 4）"])
        XCTAssertEqual(plan.enabledCount, 1)
        XCTAssertEqual(plan.skippedCount, 0)
        XCTAssertEqual(Set(plan.templates.map(\.id)).count, 5)
    }

    func testReimportOfRenamedSourceDoesNotGuessProvenanceOrDropDistinctNames() throws {
        let original = record("A", body: "existing").makeTemplate()
        let bundle = TemplateTransferBundle(templates: [record("A", body: "import")])
        let first = try TemplateTransfer.makeImportPlan(bundle: bundle, existing: [original])
        let second = try TemplateTransfer.makeImportPlan(bundle: bundle, existing: first.templates)
        XCTAssertEqual(second.addedCount, 1)
        XCTAssertEqual(second.skippedCount, 0)
        XCTAssertEqual(second.additions[0].template.name, "A（导入 2）")
        let intentional = try TemplateTransfer.makeImportPlan(
            bundle: TemplateTransferBundle(templates: [record("Different name", body: "import")]),
            existing: first.templates
        )
        XCTAssertEqual(intentional.addedCount, 1)
        XCTAssertEqual(intentional.templates.last?.name, "Different name")
    }

    func testNonemptyAppendCannotExceedCombinedExportLimits() throws {
        let existing = [record("existing").makeTemplate()]
        XCTAssertThrowsError(try TemplateTransfer.makeImportPlan(
            bundle: TemplateTransferBundle(templates: [record("new")]), existing: existing,
            limits: .init(maximumTemplates: 1)
        ))
        let historical = existing + [record("other").makeTemplate()]
        XCTAssertNoThrow(try TemplateTransfer.makeImportPlan(
            bundle: TemplateTransferBundle(templates: [TransferTemplate(existing[0])]), existing: historical,
            limits: .init(maximumTemplates: 1)
        ))
        let limits = TemplateTransferLimits(maximumFileBytes: try data([record("new")]).count)
        XCTAssertThrowsError(try TemplateTransfer.makeImportPlan(
            bundle: TemplateTransferBundle(templates: [record("new")]), existing: existing, limits: limits
        ))
    }

    func testByteDifferentUnicodeBodiesAreNotSilentlyDeduplicated() throws {
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: TemplateTransferBundle(templates: [record(body: "é"), record(body: "e\u{301}")]), existing: []
        )
        XCTAssertEqual(plan.addedCount, 2)
        XCTAssertEqual(plan.renamedCount, 1)
        XCTAssertNotEqual(Array(plan.templates[0].content.utf8), Array(plan.templates[1].content.utf8))
    }

    func testExistingCanonicallyEquivalentNamesStillUseByteExactDeduplication() throws {
        let composed = record("é")
        let decomposed = record("e\u{301}")
        let reserved = record("e\u{301}（导入）", body: "reserved")
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: .init(templates: [composed, decomposed, decomposed]),
            existing: [composed.makeTemplate(), reserved.makeTemplate()]
        )
        XCTAssertEqual(plan.skippedCount, 2)
        XCTAssertEqual(plan.addedCount, 1)
        XCTAssertEqual(plan.additions[0].sourceIndex, 1)
        XCTAssertEqual(Array(plan.additions[0].template.name.utf8), Array("e\u{301}（导入 2）".utf8))
    }

    func testEmptyAndAllSkippedImportsPreserveUnrelatedOverLimitHistory() throws {
        let duplicate = record("small")
        let existing = [record("historical", body: String(repeating: "x", count: 128)).makeTemplate(),
                        duplicate.makeTemplate()]
        let limits = TemplateTransferLimits(maximumTemplates: 1, maximumContentBytes: 8)
        for sources in [[], [duplicate]] {
            let plan = try TemplateTransfer.makeImportPlan(
                bundle: .init(templates: sources), existing: existing, limits: limits
            )
            XCTAssertEqual(plan.baseline, existing)
            XCTAssertEqual(plan.templates, existing)
            XCTAssertEqual(plan.addedCount, 0)
            XCTAssertEqual(plan.skippedCount, sources.count)
        }
    }

    func testNameAndBodyAreNotSilentlyTrimmed() throws {
        let source = record(" name ", extension: ".txt", body: "\n  body  \r\n")
        XCTAssertEqual(try TemplateTransfer.decode(data([source])).templates, [source])
    }

    func testCanonicalUnicodePopulationDoesNotCollapseIntoOneHashBucket() throws {
        func permutations(_ remaining: [String]) -> [String] {
            guard !remaining.isEmpty else { return [""] }
            return remaining.indices.flatMap { index -> [String] in
                var rest = remaining
                let first = rest.remove(at: index)
                return permutations(rest).map { first + $0 }
            }
        }
        let marks = ["\u{0334}", "\u{0321}", "\u{031B}", "\u{0323}", "\u{0300}", "\u{0315}"]
        let prefix = String(repeating: "x", count: 8_192) + "a"
        let templates = permutations(marks).prefix(64).map { record(body: prefix + $0) }
        XCTAssertTrue(templates.allSatisfy { $0.content == templates[0].content })
        XCTAssertEqual(Set(templates.map { Data($0.content.utf8) }).count, templates.count)
        // Ordinary random collisions remain legal. Reject systematic collapse of
        // the population without asserting that every pair must have a unique hash.
        XCTAssertGreaterThan(Set(templates.map(\.hashValue)).count, templates.count / 2)
        let encoded = try TemplateTransfer.encode(TemplateTransferBundle(templates: templates))
        let plan = try TemplateTransfer.makeImportPlan(bundle: TemplateTransfer.decode(encoded), existing: [])
        XCTAssertEqual(plan.addedCount, templates.count)
        XCTAssertEqual(plan.skippedCount, 0)
        XCTAssertEqual(plan.renamedCount, templates.count - 1)
        XCTAssertEqual(plan.additions.map { Data($0.template.content.utf8) }, templates.map { Data($0.content.utf8) })
    }

    func testLongCollisionNameIsVisiblyRenamedWithinUTF8Limit() throws {
        let source = record(String(repeating: "名", count: 341))
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: TemplateTransferBundle(templates: [source]),
            existing: [record(source.name, body: "existing").makeTemplate()]
        )
        XCTAssertTrue(plan.additions[0].wasRenamed)
        XCTAssertTrue(plan.templates[1].name.hasSuffix("（导入）"))
        XCTAssertLessThanOrEqual(plan.templates[1].name.utf8.count, 1_024)
        XCTAssertNoThrow(try TemplateTransfer.encode(TemplateTransferBundle(templates: plan.templates)))
    }

    func testRepeatedLongNameGeneratesOnlyOneCandidatePerRenameAndPreservesBudget() throws {
        let name = String(repeating: "A", count: 1_024)
        let sources = (0..<256).map { record(name, body: "body \($0)") }
        let bundle = TemplateTransferBundle(templates: sources)
        var candidateCount = 0
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: bundle, existing: [], didGenerateNameCandidate: { candidateCount += 1 }
        )
        XCTAssertEqual(candidateCount, 255)
        XCTAssertEqual(plan.addedCount, 256)
        XCTAssertEqual(plan.skippedCount, 0)
        XCTAssertEqual(plan.renamedCount, 255)
        XCTAssertEqual(plan.additions.map(\.sourceIndex), Array(0..<256))
        XCTAssertEqual(plan.additions.map(\.originalName), Array(repeating: name, count: 256))
        XCTAssertEqual(plan.templates.map(\.content), sources.map(\.content))
        for index in 1..<256 {
            let suffix = index == 1 ? "（导入）" : "（导入 \(index)）"
            XCTAssertEqual(plan.templates[index].name,
                           String(repeating: "A", count: 1_024 - suffix.utf8.count) + suffix)
        }
        let bytes = try TemplateTransfer.encode(.init(templates: plan.templates)).count
        XCTAssertNoThrow(try TemplateTransfer.makeImportPlan(
            bundle: bundle, existing: [], limits: .init(maximumFileBytes: bytes)
        ))
        XCTAssertThrowsError(try TemplateTransfer.makeImportPlan(
            bundle: bundle, existing: [], limits: .init(maximumFileBytes: bytes - 1)
        )) {
            XCTAssertEqual($0 as? TemplateTransferError, .fileTooLarge(maximumBytes: bytes - 1))
        }
    }

    func testDistinctLongNamesShareRenameSearchWithoutChangingNamesOrBudget() throws {
        let originalLanguage = try XCTUnwrap(QuickFileLanguage(rawValue: QuickFileLocalization.identifier))
        defer { QuickFileLocalization.apply(originalLanguage) }
        for language in [QuickFileLanguage.simplifiedChinese, .english] {
            QuickFileLocalization.apply(language)
            let names = (0..<256).map { String(repeating: "Q", count: 1_020) + String(format: "%04d", $0) }
            let existing = names.map { record($0, body: "old").makeTemplate() }
            let sources = names.enumerated().map { record($0.element, body: "new \($0.offset)") }
            let bundle = TemplateTransferBundle(templates: sources)
            var candidateCount = 0
            let plan = try TemplateTransfer.makeImportPlan(
                bundle: bundle, existing: existing, didGenerateNameCandidate: { candidateCount += 1 }
            )
            XCTAssertEqual(candidateCount, 256)
            XCTAssertEqual(plan.addedCount, 256)
            XCTAssertEqual(plan.skippedCount, 0)
            XCTAssertEqual(plan.renamedCount, 256)
            XCTAssertEqual(plan.additions.map(\.sourceIndex), Array(0..<256))
            XCTAssertEqual(plan.additions.map(\.originalName), names)
            XCTAssertEqual(plan.additions.map(\.template.content), sources.map(\.content))
            for (index, addition) in plan.additions.enumerated() {
                let suffix: String
                if language == .simplifiedChinese {
                    suffix = index == 0 ? "（导入）" : "（导入 \(index + 1)）"
                } else {
                    suffix = index == 0 ? " (Imported)" : " (Imported \(index + 1))"
                }
                let expected = String(repeating: "Q", count: 1_024 - suffix.utf8.count) + suffix
                XCTAssertEqual(Data(addition.template.name.utf8), Data(expected.utf8))
                XCTAssertEqual(addition.template.name.utf8.count, 1_024)
            }
            let bytes = try TemplateTransfer.encode(.init(templates: plan.templates)).count
            XCTAssertNoThrow(try TemplateTransfer.makeImportPlan(
                bundle: bundle, existing: existing, limits: .init(maximumFileBytes: bytes)
            ))
            XCTAssertThrowsError(try TemplateTransfer.makeImportPlan(
                bundle: bundle, existing: existing, limits: .init(maximumFileBytes: bytes - 1)
            )) {
                XCTAssertEqual($0 as? TemplateTransferError, .fileTooLarge(maximumBytes: bytes - 1))
            }
        }
    }

    func testCanonicallyEquivalentTruncatedPrefixesShareSearchAndPreserveSourceBytes() throws {
        func permutations(_ remaining: [String]) -> [String] {
            guard !remaining.isEmpty else { return [""] }
            return remaining.indices.flatMap { index -> [String] in
                var rest = remaining
                let first = rest.remove(at: index)
                return permutations(rest).map { first + $0 }
            }
        }
        let marks = ["\u{0334}", "\u{0321}", "\u{031B}", "\u{0323}", "\u{0300}", "\u{0315}"]
        let prefixes = permutations(marks).prefix(256).map { "a" + $0 }
        XCTAssertEqual(Set(prefixes).count, 1)
        XCTAssertEqual(Set(prefixes.map { Data($0.utf8) }).count, 256)
        let names = prefixes.enumerated().map {
            $0.element + String(repeating: "Q", count: 1_007) + String(format: "%04d", $0.offset)
        }
        XCTAssertEqual(Set(names).count, 256)
        XCTAssertTrue(names.allSatisfy { $0.utf8.count == 1_024 })
        let existing = names.map { record($0, body: "old").makeTemplate() }
        let sources = names.enumerated().map { record($0.element, body: "new \($0.offset)") }
        let originalLanguage = try XCTUnwrap(QuickFileLanguage(rawValue: QuickFileLocalization.identifier))
        defer { QuickFileLocalization.apply(originalLanguage) }
        for language in [QuickFileLanguage.simplifiedChinese, .english] {
            QuickFileLocalization.apply(language)
            var candidateCount = 0
            let plan = try TemplateTransfer.makeImportPlan(
                bundle: .init(templates: sources), existing: existing,
                didGenerateNameCandidate: { candidateCount += 1 }
            )
            XCTAssertEqual(candidateCount, 256)
            XCTAssertEqual(plan.addedCount, 256)
            XCTAssertEqual(plan.skippedCount, 0)
            XCTAssertEqual(plan.renamedCount, 256)
            XCTAssertEqual(plan.additions.map(\.sourceIndex), Array(0..<256))
            XCTAssertEqual(plan.additions.map { Data($0.originalName.utf8) }, names.map { Data($0.utf8) })
            XCTAssertEqual(plan.additions.map(\.template.content), sources.map(\.content))
            for (index, addition) in plan.additions.enumerated() {
                let suffix: String
                if language == .simplifiedChinese {
                    suffix = index == 0 ? "（导入）" : "（导入 \(index + 1)）"
                } else {
                    suffix = index == 0 ? " (Imported)" : " (Imported \(index + 1))"
                }
                let prefix = prefixes[index]
                let expected = prefix + String(repeating: "Q", count: 1_024 - prefix.utf8.count - suffix.utf8.count) + suffix
                XCTAssertEqual(Data(addition.template.name.utf8), Data(expected.utf8))
                XCTAssertEqual(addition.template.name.utf8.count, 1_024)
            }
        }
    }

    func testRenameFamiliesKeepCanonicalEquivalentFirstCandidatesByteDistinct() throws {
        let composed = String(repeating: "é", count: 4)
        let decomposed = String(repeating: "e\u{301}", count: 4)
        let sources = [record(composed, body: "first"), record(decomposed, body: "second"),
                       record(composed, body: "third")]
        var candidateCount = 0
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: .init(templates: sources), existing: [record(composed).makeTemplate()],
            limits: .init(maximumNameBytes: 24), didGenerateNameCandidate: { candidateCount += 1 }
        )
        let expected = [composed + "（导入）", String(repeating: "e\u{301}", count: 3) + "（导入 2）",
                        composed + "（导入 2）"]
        XCTAssertEqual(plan.additions.map { Data($0.template.name.utf8) }, expected.map { Data($0.utf8) })
        XCTAssertEqual(plan.additions.map { Data($0.originalName.utf8) }, sources.map { Data($0.name.utf8) })
        XCTAssertEqual(plan.additions.map(\.template.content), sources.map(\.content))
        XCTAssertEqual(candidateCount, 3)
        XCTAssertEqual(plan.skippedCount, 0)
    }

    func testInterleavedTruncatedFamiliesFillTheirOwnFirstNumberingHoles() throws {
        let left = String(repeating: "A", count: 1_023)
        let right = String(repeating: "B", count: 1_023)
        let originalNames = [left + "X", left + "Y", right + "X", right + "Y"]
        func renamed(_ prefix: String, _ number: Int) -> String {
            let suffix = number == 1 ? "（导入）" : "（导入 \(number)）"
            return String(prefix.prefix(1_024 - suffix.utf8.count)) + suffix
        }
        let occupied = [renamed(left, 2), renamed(left, 4), renamed(right, 1), renamed(right, 3)]
        let existing = (originalNames + occupied).map { record($0).makeTemplate() }
        let sourceNames = [originalNames[0], originalNames[2], originalNames[1], originalNames[3],
                           originalNames[0], originalNames[2]]
        let sources = sourceNames.enumerated().map { record($0.element, body: "new \($0.offset)") }
        var candidateCount = 0
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: .init(templates: sources), existing: existing,
            didGenerateNameCandidate: { candidateCount += 1 }
        )
        let expected = [renamed(left, 1), renamed(right, 2), renamed(left, 3),
                        renamed(right, 4), renamed(left, 5), renamed(right, 5)]
        XCTAssertEqual(plan.additions.map(\.template.name), expected)
        XCTAssertEqual(plan.additions.map(\.originalName), sourceNames)
        XCTAssertEqual(plan.additions.map(\.template.content), sources.map(\.content))
        XCTAssertEqual(candidateCount, 10)
        XCTAssertEqual(plan.skippedCount, 0)
    }

    func testRenameSearchSharesPrefixesThatOnlyConvergeWithNumberedSuffixes() throws {
        let originalLanguage = try XCTUnwrap(QuickFileLanguage(rawValue: QuickFileLocalization.identifier))
        defer { QuickFileLocalization.apply(originalLanguage) }
        for language in [QuickFileLanguage.simplifiedChinese, .english] {
            QuickFileLocalization.apply(language)
            let firstSuffix = language == .simplifiedChinese ? "（导入）" : " (Imported)"
            let numberedSuffix = language == .simplifiedChinese ? "（导入 2）" : " (Imported 2)"
            let commonPrefix = String(repeating: "Q", count: 1_024 - numberedSuffix.utf8.count)
            let codes = (0..<64).map { String(format: "%02X", $0) }
            let names = codes.map { commonPrefix + $0 + String(repeating: "R", count: numberedSuffix.utf8.count - 2) }
            let occupied = codes.map { commonPrefix + $0 + firstSuffix }
            let existing = (names + occupied).map { record($0, body: "old").makeTemplate() }
            let sources = names.enumerated().map { record($0.element, body: "new \($0.offset)") }
            var candidateCount = 0
            let plan = try TemplateTransfer.makeImportPlan(
                bundle: .init(templates: sources), existing: existing,
                didGenerateNameCandidate: { candidateCount += 1 }
            )
            XCTAssertEqual(candidateCount, 128)
            XCTAssertEqual(plan.addedCount, 64)
            XCTAssertEqual(plan.skippedCount, 0)
            XCTAssertEqual(plan.additions.map(\.originalName), names)
            for (index, addition) in plan.additions.enumerated() {
                let suffix = language == .simplifiedChinese ? "（导入 \(index + 2)）" : " (Imported \(index + 2))"
                XCTAssertEqual(addition.template.name,
                               String(repeating: "Q", count: 1_024 - suffix.utf8.count) + suffix)
            }
        }
    }

    func testSharedRenameSearchChecksHolesAcrossSuffixWidthBoundaries() throws {
        let prefix = String(repeating: "A", count: 1_023)
        let originals = [prefix + "X", prefix + "Y"]
        func renamed(_ number: Int) -> String {
            let suffix = number == 1 ? "（导入）" : "（导入 \(number)）"
            return String(repeating: "A", count: 1_024 - suffix.utf8.count) + suffix
        }
        let occupiedNumbers = Array(1...8) + [10, 12] + Array(14...98) + [100, 102]
        let existing = (originals + occupiedNumbers.map(renamed)).map { record($0).makeTemplate() }
        let sources = (0..<6).map { record(originals[$0 % 2], body: "new \($0)") }
        var candidateCount = 0
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: .init(templates: sources), existing: existing,
            didGenerateNameCandidate: { candidateCount += 1 }
        )
        XCTAssertEqual(plan.additions.map(\.template.name), [9, 11, 13, 99, 101, 103].map(renamed))
        XCTAssertEqual(plan.additions.map(\.originalName), sources.map(\.name))
        XCTAssertEqual(candidateCount, 103)
        XCTAssertEqual(plan.skippedCount, 0)
    }

    func testRenameSearchRejectsSuffixWhenNoWholeFirstGraphemeFits() throws {
        let name = "a" + String(repeating: "\u{20D0}", count: 337)
        XCTAssertEqual(name.count, 1)
        let sources = [record(name, body: "first"), record(name, body: "second")]
        var candidateCount = 0
        XCTAssertThrowsError(try TemplateTransfer.makeImportPlan(
            bundle: .init(templates: sources), existing: [record(name).makeTemplate()],
            didGenerateNameCandidate: { candidateCount += 1 }
        )) {
            XCTAssertEqual($0 as? TemplateTransferError, .fieldTooLarge(
                index: 1, field: QuickFileLocalization.text(.init("改名后的名称")), maximumBytes: 1_024
            ))
        }
        XCTAssertEqual(candidateCount, 2)
    }

    func testRenameCursorRestartsWhenLanguageChangesBetweenSourceNames() throws {
        let originalLanguage = try XCTUnwrap(QuickFileLanguage(rawValue: QuickFileLocalization.identifier))
        defer { QuickFileLocalization.apply(originalLanguage) }
        let singleGrapheme = "a" + String(repeating: "\u{20D0}", count: 337)
        XCTAssertEqual(singleGrapheme.count, 1)
        XCTAssertEqual(singleGrapheme.utf8.count, 1_012)
        for name in ["A", singleGrapheme] {
            QuickFileLocalization.apply(.simplifiedChinese)
            let sources = [record(name, body: "first"), record(name, body: "second")]
            var candidateCount = 0
            let plan = try TemplateTransfer.makeImportPlan(
                bundle: .init(templates: sources), existing: [record(name).makeTemplate()],
                didGenerateNameCandidate: {
                    candidateCount += 1
                    if candidateCount == 1 { QuickFileLocalization.apply(.english) }
                }
            )
            XCTAssertEqual(candidateCount, 2)
            XCTAssertEqual(plan.additions.map(\.template.name), [name + "（导入）", name + " (Imported)"])
            XCTAssertEqual(plan.additions.map(\.template.content), ["first", "second"])
            XCTAssertEqual(plan.additions.map(\.originalName), [name, name])
            XCTAssertEqual(plan.skippedCount, 0)
        }
    }

    func testRenameCollisionSearchKeepsItsLanguageSnapshot() throws {
        let originalLanguage = try XCTUnwrap(QuickFileLanguage(rawValue: QuickFileLocalization.identifier))
        defer { QuickFileLocalization.apply(originalLanguage) }
        QuickFileLocalization.apply(.simplifiedChinese)
        var candidateCount = 0
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: .init(templates: [record("A", body: "new")]),
            existing: [record("A").makeTemplate(), record("A（导入）").makeTemplate()],
            didGenerateNameCandidate: {
                candidateCount += 1
                if candidateCount == 1 { QuickFileLocalization.apply(.english) }
            }
        )
        XCTAssertEqual(candidateCount, 2)
        XCTAssertEqual(plan.additions.map(\.template.name), ["A（导入 2）"])
    }

    func testRenameCursorFillsNumberingHolesAndChecksLaterOccupiedNames() throws {
        let existing = ["A", "A（导入 2）", "A（导入 4）"].map { record($0).makeTemplate() }
        let sources = (0..<3).map { record("A", body: "new \($0)") }
        var candidateCount = 0
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: .init(templates: sources), existing: existing,
            didGenerateNameCandidate: { candidateCount += 1 }
        )
        XCTAssertEqual(plan.additions.map(\.template.name), ["A（导入）", "A（导入 3）", "A（导入 5）"])
        XCTAssertEqual(candidateCount, 5)
    }

    func testRenameCursorsUseOriginalUTF8BytesForEquivalentNamesThatTruncateDifferently() throws {
        let composed = String(repeating: "é", count: 8)
        let decomposed = String(repeating: "e\u{301}", count: 8)
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        let sources = [record(composed, body: "first"), record(decomposed, body: "second"),
                       record(composed, body: "third")]
        var candidateCount = 0
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: .init(templates: sources), existing: [record(composed).makeTemplate()],
            limits: .init(maximumNameBytes: 24), didGenerateNameCandidate: { candidateCount += 1 }
        )
        let expected = [String(repeating: "é", count: 6) + "（导入）",
                        String(repeating: "e\u{301}", count: 4) + "（导入）",
                        String(repeating: "é", count: 5) + "（导入 2）"]
        XCTAssertEqual(plan.additions.map { Data($0.template.name.utf8) }, expected.map { Data($0.utf8) })
        XCTAssertEqual(plan.additions.map { Data($0.originalName.utf8) }, sources.map { Data($0.name.utf8) })
        XCTAssertEqual(candidateCount, 3)
        XCTAssertEqual(plan.skippedCount, 0)
    }

    func testRenameCursorRechecksNamesOccupiedByAnotherTruncatedOriginal() throws {
        let prefix = String(repeating: "A", count: 1_023)
        let left = prefix + "X"
        let right = prefix + "Y"
        let sources = [record(left, body: "first"), record(right, body: "second"), record(left, body: "third")]
        var candidateCount = 0
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: .init(templates: sources), existing: [record(left).makeTemplate(), record(right).makeTemplate()],
            didGenerateNameCandidate: { candidateCount += 1 }
        )
        let expected = ["（导入）", "（导入 2）", "（导入 3）"].map {
            String(repeating: "A", count: 1_024 - $0.utf8.count) + $0
        }
        XCTAssertEqual(plan.additions.map(\.template.name), expected)
        XCTAssertEqual(plan.additions.map(\.originalName), [left, right, left])
        XCTAssertEqual(candidateCount, 3)
        XCTAssertEqual(plan.skippedCount, 0)
    }

    func testDifferentLongOriginalNamesCannotBeSkippedAfterTruncationCollision() throws {
        let prefix = String(repeating: "A", count: 1_023)
        let left = record(prefix + "X", body: "old").makeTemplate()
        let right = record(prefix + "Y", body: "old").makeTemplate()
        let bundle = TemplateTransferBundle(templates: [record(left.name, body: "new"), record(right.name, body: "new")])
        let plan = try TemplateTransfer.makeImportPlan(bundle: bundle, existing: [left, right])
        XCTAssertEqual(plan.addedCount, 2)
        XCTAssertEqual(plan.skippedCount, 0)
        XCTAssertNotEqual(plan.additions[0].template.name, plan.additions[1].template.name)
        XCTAssertEqual(plan.additions.map(\.originalName), [left.name, right.name])
    }

    func testCancelingPlanCannotMutateStoreOrBaseline() throws {
        let suite = "QuickFileTransferTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TemplateStore(defaults: defaults)
        let existing = [record("before").makeTemplate()]
        try store.saveTemplates(existing)
        let revision = defaults.string(forKey: "templates.revision.v2")
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: TemplateTransferBundle(templates: [record("after")]), existing: try store.reloadTemplates()
        )
        XCTAssertEqual(plan.addedCount, 1)
        XCTAssertEqual(plan.baseline, existing)
        XCTAssertEqual(try store.reloadTemplates(), existing)
        XCTAssertEqual(defaults.string(forKey: "templates.revision.v2"), revision)
    }

    func testImportCASRejectsChangeAfterPreviewWithoutMerging() throws {
        let suite = "QuickFileTransferTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TemplateStore(defaults: defaults)
        let existing = [record("before").makeTemplate()]
        try store.saveTemplates(existing)
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: TemplateTransferBundle(templates: [record("import")]), existing: existing
        )
        let concurrent = [record("concurrent").makeTemplate()]
        try store.saveTemplates(concurrent)
        XCTAssertThrowsError(try store.saveTemplates(plan.templates, expectedTemplates: plan.baseline)) { error in
            guard case TemplateStore.StoreError.configurationChanged = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try store.reloadTemplates(), concurrent)
    }

    func testRejectsFormatFutureVersionMalformedAndMissingRequiredFields() throws {
        let files = [
            "{}", "[]", "not-json", "{\"format\":\"other\",\"version\":1,\"templates\":[]}",
            "{\"format\":\"quickfile.templates\",\"version\":99,\"templates\":[]}",
            "{\"format\":\"quickfile.templates\",\"version\":1,\"templates\":[{\"name\":\"a\",\"fileExtension\":\"txt\",\"content\":\"\"}]}"
        ]
        for file in files { XCTAssertThrowsError(try TemplateTransfer.decode(Data(file.utf8))) }
        XCTAssertThrowsError(try TemplateTransfer.decode(Data(files[4].utf8))) { error in
            XCTAssertEqual(error as? TemplateTransferError, .unsupportedVersion(99))
        }
    }

    func testInvalidLastRecordRejectsWholeBundle() throws {
        let valid = try data([record()])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        let first = try XCTUnwrap(object["templates"] as? [[String: Any]])
        object["templates"] = first + [["name": "last", "fileExtension": "bad/ext", "content": "", "isEnabled": true]]
        XCTAssertThrowsError(try TemplateTransfer.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try TemplateTransfer.makeImportPlan(
            bundle: TemplateTransferBundle(templates: [record(), record("bad", extension: "bad/ext")]), existing: []
        ))
    }

    func testFieldValidationAndUTF8Budgets() throws {
        for invalid in [record(" \n"), record(extension: "/"), record(extension: ":"), record(extension: "txt\n")] {
            XCTAssertThrowsError(try data([invalid]))
        }
        let limits = TemplateTransferLimits(maximumContentBytes: 3, maximumNameBytes: 3, maximumExtensionBytes: 3)
        XCTAssertNoThrow(try TemplateTransfer.encode(TemplateTransferBundle(templates: [record("名", extension: "", body: "文")]), limits: limits))
        for oversized in [record("名字", extension: "", body: ""), record("A", extension: "扩展", body: ""), record("A", extension: "", body: "正文")] {
            XCTAssertThrowsError(try TemplateTransfer.encode(TemplateTransferBundle(templates: [oversized]), limits: limits))
        }
        let bodyLimits = TemplateTransferLimits(maximumContentBytes: 3)
        XCTAssertThrowsError(try TemplateTransfer.decode(data([record(body: "1234")]), limits: bodyLimits))
    }

    func testCountBoundStopsBeforeDecodingOverflowRecord() throws {
        let json = "{\"format\":\"quickfile.templates\",\"version\":1,\"templates\":[{\"name\":\"a\",\"fileExtension\":\"\",\"content\":\"\",\"isEnabled\":true},false]}"
        XCTAssertThrowsError(try TemplateTransfer.decode(Data(json.utf8), limits: .init(maximumTemplates: 1))) { error in
            XCTAssertEqual(error as? TemplateTransferError, .tooManyTemplates(maximum: 1))
        }
        XCTAssertThrowsError(try TemplateTransfer.encode(TemplateTransferBundle(templates: [record(), record()]), limits: .init(maximumTemplates: 1)))
    }

    func testEncodedByteBudgetAccountsForEscapesAndExactBoundary() throws {
        let bundle = TemplateTransferBundle(templates: [record(body: "\u{0}\u{1}\n\t\"\\/📄")])
        let encoded = try TemplateTransfer.encode(bundle)
        XCTAssertEqual(try TemplateTransfer.decode(encoded), bundle)
        let exact = TemplateTransferLimits(maximumFileBytes: encoded.count)
        XCTAssertEqual(try TemplateTransfer.encode(bundle, limits: exact), encoded)
        XCTAssertThrowsError(try TemplateTransfer.encode(bundle, limits: .init(maximumFileBytes: encoded.count - 1)))
        XCTAssertThrowsError(try TemplateTransfer.decode(encoded, limits: .init(maximumFileBytes: encoded.count - 1)))
        let amplified = TemplateTransferBundle(templates: [record(body: String(repeating: "\u{0}", count: 1_000))])
        XCTAssertThrowsError(try TemplateTransfer.encode(amplified, limits: .init(maximumFileBytes: 2_000)))
    }

    func testCountOnlyValidationIncludesEnvelopeCommasAndBooleanLengths() throws {
        let empty = TemplateTransferBundle(templates: [TransferTemplate]())
        let emptyJSON = Data("{\"format\":\"quickfile.templates\",\"version\":1,\"templates\":[]}".utf8)
        XCTAssertEqual(try TemplateTransfer.encode(empty), emptyJSON)
        XCTAssertEqual(try TemplateTransfer.validateEncodedSize(empty), emptyJSON.count)
        let enabled = TemplateTransferBundle(templates: [record(enabled: true)])
        let disabled = TemplateTransferBundle(templates: [record(enabled: false)])
        let both = TemplateTransferBundle(templates: enabled.templates + disabled.templates)
        let enabledCount = try TemplateTransfer.validateEncodedSize(enabled)
        let disabledCount = try TemplateTransfer.validateEncodedSize(disabled)
        XCTAssertEqual(disabledCount, enabledCount + 1)
        XCTAssertEqual(try TemplateTransfer.validateEncodedSize(both), enabledCount + disabledCount - emptyJSON.count + 1)
        for bundle in [empty, enabled, disabled, both] {
            let encoded = try TemplateTransfer.encode(bundle)
            XCTAssertEqual(try TemplateTransfer.validateEncodedSize(bundle), encoded.count)
            XCTAssertThrowsError(try TemplateTransfer.validateEncodedSize(bundle, limits: .init(maximumFileBytes: 0))) {
                XCTAssertEqual($0 as? TemplateTransferError, .fileTooLarge(maximumBytes: 0))
            }
        }
    }

    func testCountAndEncodingPreserveAllControlEscapesAndRawUnicodeBytes() throws {
        let controls = (0..<32).map { String(UnicodeScalar($0)!) }.joined()
        let escapedControls = (0..<32).map { String(format: "\\u%04x", $0) }.joined()
        let body = controls + "\"\\/📄 é e\u{301} \u{2028}\u{2029}"
        let bundle = TemplateTransferBundle(templates: [record("A", extension: "", body: body)])
        let expected = "{\"format\":\"quickfile.templates\",\"version\":1,\"templates\":[{\"name\":\"A\",\"fileExtension\":\"\",\"content\":\""
            + escapedControls + "\\\"\\\\/📄 é e\u{301} \u{2028}\u{2029}\",\"isEnabled\":true}]}"
        let encoded = try TemplateTransfer.encode(bundle)
        // Every control, including newline and tab, keeps the existing six-byte
        // spelling. Quotes/backslashes use two bytes; slash and UTF-8 stay raw.
        XCTAssertEqual(encoded, Data(expected.utf8))
        XCTAssertEqual(try TemplateTransfer.validateEncodedSize(bundle), expected.utf8.count)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let values = try XCTUnwrap(object["templates"] as? [[String: Any]])
        XCTAssertEqual(Array(try XCTUnwrap(values[0]["content"] as? String).utf8), Array(body.utf8))
        XCTAssertEqual(try TemplateTransfer.decode(encoded), bundle)
    }

    func testCountingAndDataSinksAgreeAcrossChunkBoundariesAndBudgets() throws {
        let controls = (0..<32).map { String(UnicodeScalar($0)!) }.joined()
        let bodies = ["", "é", "e\u{301}", String(repeating: controls, count: 700)]
            + [16_383, 16_384, 16_385, 32_767].map {
                String(repeating: "a", count: $0) + "📄\u{0}\"\\/é e\u{301}" + String(repeating: "z", count: 16_385)
            }
        for body in bodies {
            let bundle = TemplateTransferBundle(templates: [
                record("name\"\\/é", extension: "文\\\"", body: body, enabled: false),
                record("e\u{301}", extension: "", body: "\n\t")
            ])
            let encoded = try TemplateTransfer.encode(bundle)
            for budget in [encoded.count, encoded.count + 1, Int.max - 1] {
                let limits = TemplateTransferLimits(maximumFileBytes: budget)
                XCTAssertEqual(try TemplateTransfer.validateEncodedSize(bundle, limits: limits), encoded.count)
                XCTAssertEqual(try TemplateTransfer.encode(bundle, limits: limits), encoded)
            }
            let short = TemplateTransferLimits(maximumFileBytes: encoded.count - 1)
            XCTAssertThrowsError(try TemplateTransfer.validateEncodedSize(bundle, limits: short)) {
                XCTAssertEqual($0 as? TemplateTransferError, .fileTooLarge(maximumBytes: encoded.count - 1))
            }
            XCTAssertThrowsError(try TemplateTransfer.encode(bundle, limits: short)) {
                XCTAssertEqual($0 as? TemplateTransferError, .fileTooLarge(maximumBytes: encoded.count - 1))
            }
            XCTAssertEqual(try TemplateTransfer.decode(encoded), bundle)
        }
    }

    func testCountOnlyValidationRejectsTheSameInvalidFieldsAndTemplateCount() throws {
        let cases: [(TemplateTransferBundle, TemplateTransferLimits)] = [
            (.init(templates: [record(), record(" \n")]), .default),
            (.init(templates: [record(extension: "bad/ext")]), .default),
            (.init(templates: [record(body: "正文")]), .init(maximumContentBytes: 3)),
            (.init(templates: [record(), record()]), .init(maximumTemplates: 1))
        ]
        for (bundle, limits) in cases {
            var encodingError: TemplateTransferError?
            XCTAssertThrowsError(try TemplateTransfer.encode(bundle, limits: limits)) {
                encodingError = $0 as? TemplateTransferError
            }
            XCTAssertNotNil(encodingError)
            XCTAssertThrowsError(try TemplateTransfer.validateEncodedSize(bundle, limits: limits)) {
                XCTAssertEqual($0 as? TemplateTransferError, encodingError)
            }
        }
    }

    func testEncodedSizeComparisonMatchesEncodingForControlsBooleansAndUnicode() throws {
        let controls = (0..<32).map { String(UnicodeScalar($0)!) }.joined()
        let records = [
            record("A", extension: "", body: "", enabled: true),
            record("A", extension: "", body: "", enabled: false),
            record("A", extension: "", body: "/"),
            record("A", extension: "", body: "\\"),
            record("A", extension: "", body: "\""),
            record("A", extension: "", body: "é"),
            record("A", extension: "", body: "e\u{301}"),
            record("A\"\\é", extension: "文\\\"", body: controls + "/📄")
        ]
        let encodedCounts = try records.map { try TemplateTransfer.encode(.init(templates: [$0])).count }
        for (candidateIndex, candidate) in records.enumerated() {
            for (originalIndex, original) in records.enumerated() {
                XCTAssertEqual(
                    try TemplateTransfer.isEncodedSizeNonIncreasing(candidate, comparedTo: original),
                    encodedCounts[candidateIndex] <= encodedCounts[originalIndex]
                )
            }
        }
        XCTAssertFalse(try TemplateTransfer.isEncodedSizeNonIncreasing(records[1], comparedTo: records[0]))
        XCTAssertTrue(try TemplateTransfer.isEncodedSizeNonIncreasing(records[0], comparedTo: records[1]))
        XCTAssertFalse(try TemplateTransfer.isEncodedSizeNonIncreasing(records[6], comparedTo: records[5]))
    }

    func testEncodedSizeComparisonCountsInvalidHistoricalFieldsWithoutValidatingThem() throws {
        let controls = (0..<32).map { String(UnicodeScalar($0)!) }.joined()
        let historical = [
            record("", extension: "", body: "", enabled: false),
            record(" \n", extension: "/:\n", body: "\"\\/é e\u{301}", enabled: true),
            record("historical", extension: controls, body: "📄", enabled: false),
            record(String(repeating: "n", count: 1_025), extension: "txt", body: "")
        ]
        let encodedCounts = try historical.map { value in
            // Moving all literal fields into a valid body preserves their total
            // escaped size. Only this reference's one-byte name adds overhead.
            let reference = record("A", extension: "", body: value.name + value.fileExtension + value.content,
                                   enabled: value.isEnabled)
            return try TemplateTransfer.encode(.init(templates: [reference])).count - 1
        }
        for (candidateIndex, candidate) in historical.enumerated() {
            XCTAssertThrowsError(try TemplateTransfer.validateEncodedSize(.init(templates: [candidate])))
            for (originalIndex, original) in historical.enumerated() {
                XCTAssertEqual(
                    try TemplateTransfer.isEncodedSizeNonIncreasing(candidate, comparedTo: original),
                    encodedCounts[candidateIndex] <= encodedCounts[originalIndex]
                )
            }
        }
    }

    func testImportPlanCountsCombinedRenamedOutputAndPreservesAllSkippedExemption() throws {
        let existing = record("A", body: "old").makeTemplate()
        let source = TemplateTransferBundle(templates: [record("A", body: "new")])
        let expected = TemplateTransferBundle(templates: [TransferTemplate(existing), record("A（导入）", body: "new")])
        let expectedCount = try TemplateTransfer.encode(expected).count
        let plan = try TemplateTransfer.makeImportPlan(
            bundle: source, existing: [existing], limits: .init(maximumFileBytes: expectedCount)
        )
        XCTAssertEqual(plan.addedCount, 1)
        XCTAssertEqual(plan.renamedCount, 1)
        XCTAssertEqual(try TemplateTransfer.validateEncodedSize(.init(templates: plan.templates)), expectedCount)
        XCTAssertThrowsError(try TemplateTransfer.makeImportPlan(
            bundle: source, existing: [existing], limits: .init(maximumFileBytes: expectedCount - 1)
        )) {
            XCTAssertEqual($0 as? TemplateTransferError, .fileTooLarge(maximumBytes: expectedCount - 1))
        }
        let historical = [existing, record("historical", body: String(repeating: "x", count: 20)).makeTemplate()]
        let skipped = try TemplateTransfer.makeImportPlan(
            bundle: .init(templates: [TransferTemplate(existing)]), existing: historical,
            limits: .init(maximumFileBytes: 1, maximumTemplates: 1, maximumContentBytes: 3)
        )
        XCTAssertEqual(skipped.templates, historical)
        XCTAssertEqual(skipped.addedCount, 0)
        XCTAssertEqual(skipped.skippedCount, 1)
    }

    func testInvalidAndOverflowingLimitsAreRejected() throws {
        let empty = TemplateTransferBundle(templates: [TransferTemplate]())
        for limits in [
            TemplateTransferLimits(maximumFileBytes: -1), .init(maximumFileBytes: Int.max),
            .init(maximumTemplates: -1), .init(maximumContentBytes: -1),
            .init(maximumNameBytes: -1), .init(maximumExtensionBytes: -1)
        ] {
            XCTAssertThrowsError(try TemplateTransfer.encode(empty, limits: limits))
            XCTAssertThrowsError(try TemplateTransfer.validateEncodedSize(empty, limits: limits))
            XCTAssertThrowsError(try TemplateTransfer.decode(Data(), limits: limits))
        }
    }

    func testLocalFileRoundTripAndOverLimitExportPreserveDestination() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuickFile-transfer-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = TemplateTransferBundle(templates: [record("停用", enabled: false)])
        try TemplateTransferFile.write(bundle, to: url)
        XCTAssertEqual(try TemplateTransferFile.read(from: url), bundle)
        let saved = try Data(contentsOf: url)
        XCTAssertThrowsError(try TemplateTransferFile.write(bundle, to: url, limits: .init(maximumFileBytes: 1)))
        XCTAssertEqual(try Data(contentsOf: url), saved)
        XCTAssertThrowsError(try TemplateTransferFile.read(from: url, limits: .init(maximumFileBytes: saved.count - 1)))
        XCTAssertEqual(try TemplateTransferFile.read(from: url, limits: .init(maximumFileBytes: saved.count)), bundle)
    }

    func testRejectsNonLocalURLsAndNonRegularFilesWithoutReading() throws {
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/templates.json"))
        XCTAssertThrowsError(try TemplateTransferFile.read(from: remote))
        XCTAssertThrowsError(try TemplateTransferFile.write(TemplateTransferBundle(templates: [TransferTemplate]()), to: remote))
        let fifo = FileManager.default.temporaryDirectory.appendingPathComponent("QuickFile-transfer-\(UUID().uuidString).fifo")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        defer { try? FileManager.default.removeItem(at: fifo) }
        XCTAssertThrowsError(try TemplateTransferFile.read(from: fifo))
        XCTAssertThrowsError(try TemplateTransferFile.read(from: FileManager.default.temporaryDirectory))
    }

    func testExportInSystemTemporaryTreeKeepsBodiesPrivateAndReplacesOnlySelectedFile() throws {
        // /private/tmp commonly inherits wheel, which the current user cannot
        // chown to. Export must not require a grant for sibling staging entries.
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("QuickFile-transfer-private-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("export.json")
        let sentinel = directory.appendingPathComponent("keep.txt")
        let original = Data("keep this sibling".utf8)
        try original.write(to: sentinel)
        let bundle = TemplateTransferBundle(templates: [record("私有正文", body: "{{clipboard}}", enabled: false)])
        for _ in 0..<2 {
            try TemplateTransferFile.write(bundle, to: destination)
            XCTAssertEqual(try TemplateTransferFile.read(from: destination), bundle)
            var metadata = stat()
            XCTAssertEqual(lstat(destination.path, &metadata), 0)
            XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
            XCTAssertEqual(metadata.st_uid, geteuid())
            XCTAssertEqual(try Data(contentsOf: sentinel), original)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                           ["export.json", "keep.txt"])
        }
    }
}
