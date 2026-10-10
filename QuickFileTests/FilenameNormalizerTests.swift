import XCTest
@testable import QuickFileCore

final class FilenameNormalizerTests: XCTestCase {
    private let normalizer = FilenameNormalizer()

    func testAddsRequiredExtension() throws {
        let result = try normalizer.normalize("报告", requiredExtension: "md")

        XCTAssertEqual(try result.filename(sequence: 1), "报告.md")
    }

    func testDoesNotDuplicateExistingExtensionIgnoringCase() throws {
        let result = try normalizer.normalize("README.MD", requiredExtension: ".md")

        XCTAssertEqual(try result.filename(sequence: 1), "README.md")
    }

    func testUsesFallbackForBlankFilename() throws {
        let result = try normalizer.normalize("   \n", requiredExtension: "txt")

        XCTAssertEqual(try result.filename(sequence: 1), "未命名.txt")
    }

    func testReplacesPathSeparatorsAndControlCharacters() throws {
        let result = try normalizer.normalize("父/子:名称\n草稿", requiredExtension: "yaml")

        XCTAssertEqual(try result.filename(sequence: 1), "父-子-名称-草稿.yaml")
    }

    func testAddsConflictSequenceBeforeExtension() throws {
        let result = try normalizer.normalize("note", requiredExtension: "md")

        XCTAssertEqual(try result.filename(sequence: 3), "note 3.md")
    }

    func testBudgetsExtensionAndConflictSuffixAtFilesystemLimit() throws {
        let result = try normalizer.normalize(String(repeating: "a", count: 251), requiredExtension: "txt")
        XCTAssertEqual(try result.filename(sequence: 1, maximumUTF8Bytes: 255).utf8.count, 255)
        XCTAssertEqual(try result.filename(sequence: 2, maximumUTF8Bytes: 255), String(repeating: "a", count: 249) + " 2.txt")
        XCTAssertEqual(try result.filename(sequence: 10_000, maximumUTF8Bytes: 255).utf8.count, 255)
    }

    func testTruncationPreservesWholeUnicodeCharactersAndCustomLimit() throws {
        let result = try normalizer.normalize("👩🏽‍💻👩🏽‍💻报告", requiredExtension: "txt")
        XCTAssertEqual(try result.filename(sequence: 2, maximumUTF8Bytes: 22), "👩🏽‍💻 2.txt")
        XCTAssertThrowsError(try result.filename(sequence: 1, maximumUTF8Bytes: 5))
    }

    func testRejectsExtensionThatLeavesNoRoomForBaseName() throws {
        let result = try normalizer.normalize("a", requiredExtension: String(repeating: "x", count: 255))
        XCTAssertThrowsError(try result.filename(sequence: 1, maximumUTF8Bytes: 255))
    }

    func testPreservesUnicodeJoinersAndCombiningMarksWhileRemovingControls() throws {
        let name = "👩🏽‍💻e\u{301}می\u{200C}خواهم"
        let result = try normalizer.normalize(name + "\u{0}\u{7F}\u{85}end", requiredExtension: "t\u{0}x\u{7F}t")
        XCTAssertEqual(try result.filename(sequence: 1), name + "---end.txt")
        let emojiExtension = try normalizer.normalize("note", requiredExtension: "👩🏽‍💻")
        XCTAssertEqual(try emojiExtension.filename(sequence: 1), "note.👩🏽‍💻")
    }

}
