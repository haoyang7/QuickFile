import XCTest
@testable import QuickFileCore

final class TemplateDraftTests: XCTestCase {

    func testDefaultFilenameRoundTripsNormalizesWhitespaceAndPreservesLiteralUnicode() throws {
        let original = FileTemplate(name: "模板", fileExtension: "", content: "", defaultFilename: "  .👩‍💻-e\u{301}-{{date}}  ")
        let draft = TemplateDraft(template: original)
        XCTAssertEqual(draft.defaultFilename, original.defaultFilename)
        XCTAssertEqual(try draft.makeTemplate().defaultFilename, ".👩‍💻-e\u{301}-{{date}}")
        XCTAssertEqual(TemplateDraft().defaultFilename, "")
    }

    func testDefaultFilenameRejectsSeparatorsAndC0C1Controls() {
        for value in ["a/b", "a:b", "a\n", "a\u{0}", "a\u{7f}", "a\u{85}"] {
            var draft = TemplateDraft()
            draft.name = "模板"
            draft.defaultFilename = value
            XCTAssertThrowsError(try draft.makeTemplate()) {
                XCTAssertEqual($0 as? TemplateValidationError, .invalidDefaultFilename)
            }
        }
    }

    func testNormalizesNameAndExtension() throws {
        var draft = TemplateDraft()
        draft.name = "  自定义模板  "
        draft.fileExtension = " .note "
        draft.content = "{{date}}"

        let template = try draft.makeTemplate()

        XCTAssertEqual(template.name, "自定义模板")
        XCTAssertEqual(template.fileExtension, "note")
        XCTAssertEqual(template.content, "{{date}}")
    }

    func testEditingPreservesTemplateIdentifier() throws {
        let original = FileTemplate(name: "Markdown", fileExtension: "md", content: "")
        var draft = TemplateDraft(template: original)
        draft.name = "Markdown 文档"

        let template = try draft.makeTemplate()

        XCTAssertEqual(template.id, original.id)
        XCTAssertEqual(template.name, "Markdown 文档")
    }

    func testAllowsEmptyExtensionWithoutAddingASuffix() throws {
        var draft = TemplateDraft()
        draft.name = "精确文件名"
        draft.fileExtension = " . "

        let template = try draft.makeTemplate()

        XCTAssertEqual(template.fileExtension, "")
    }

    func testRejectsEmptyName() {
        var draft = TemplateDraft()
        draft.name = "  "
        draft.fileExtension = "txt"

        XCTAssertThrowsError(try draft.makeTemplate()) { error in
            XCTAssertEqual(error as? TemplateValidationError, .emptyName)
        }
    }

    func testRejectsInvalidExtension() {
        var draft = TemplateDraft()
        draft.name = "模板"
        draft.fileExtension = "bad/path"

        XCTAssertThrowsError(try draft.makeTemplate()) { error in
            XCTAssertEqual(error as? TemplateValidationError, .invalidExtension)
        }
    }
}
