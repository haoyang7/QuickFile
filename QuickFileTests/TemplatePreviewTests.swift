import XCTest
@testable import QuickFileCore

final class TemplatePreviewTests: XCTestCase {
    private let sampleClipboard = "示例剪贴板内容（预览不会读取系统剪贴板）"

    func testInputByteBudgetBelowAtAndAboveLimit() throws {
        XCTAssertEqual(TemplatePreview.maximumInputUTF8Bytes, 65_536)
        for count in [0, TemplatePreview.maximumInputUTF8Bytes - 1, TemplatePreview.maximumInputUTF8Bytes] {
            let content = String(repeating: "a", count: count)
            XCTAssertEqual(try preview(content).text, content)
        }
        assertRequestError(.inputTooLarge, content: String(repeating: "a", count: TemplatePreview.maximumInputUTF8Bytes + 1))
    }

    func testExtensionByteBudgetIsAppliedBeforeNormalization() throws {
        XCTAssertEqual(TemplatePreview.maximumExtensionUTF8Bytes, 255)
        for count in [0, 254, 255] {
            XCTAssertEqual(try preview("content", fileExtension: String(repeating: "a", count: count)).jsonStatus, .nonJSON)
        }
        assertRequestError(.fileExtensionTooLarge, content: "", fileExtension: String(repeating: "a", count: 256))
        assertRequestError(.fileExtensionTooLarge, content: "{}", fileExtension: String(repeating: " ", count: 252) + "json")
        XCTAssertEqual(try preview("{}", fileExtension: String(repeating: " ", count: 251) + "json").jsonStatus, .valid)
    }

    func testMultibyteInputAndExtensionUseByteCounts() throws {
        let content = String(repeating: "🧪", count: TemplatePreview.maximumInputUTF8Bytes / 4)
        XCTAssertEqual(try preview(content).text.utf8.count, TemplatePreview.maximumInputUTF8Bytes)
        assertRequestError(.inputTooLarge, content: content + "a")
        assertRequestError(.inputTooLarge, content: content + "🧪")
        let fileExtension = String(repeating: "界", count: 85)
        XCTAssertEqual(try preview("", fileExtension: fileExtension).jsonStatus, .nonJSON)
        assertRequestError(.fileExtensionTooLarge, content: "", fileExtension: fileExtension + "a")
        assertRequestError(.fileExtensionTooLarge, content: "", fileExtension: fileExtension + "界")
    }

    func testHugeSingleGraphemeClusterUsesByteBoundary() throws {
        let accepted = "é" + String(repeating: "\u{301}", count: (TemplatePreview.maximumInputUTF8Bytes - 2) / 2)
        XCTAssertEqual(accepted.utf8.count, TemplatePreview.maximumInputUTF8Bytes)
        XCTAssertEqual(Array(try preview(accepted).text.utf8), Array(accepted.utf8))
        let cluster = "e" + String(repeating: "\u{301}", count: TemplatePreview.maximumInputUTF8Bytes)
        assertRequestError(.inputTooLarge, content: cluster)
        assertRequestError(.fileExtensionTooLarge, content: "", fileExtension: cluster)
    }

    func testOversizedSourceIsRejectedEvenWhenRenderingWouldShrinkIt() {
        let content = String(repeating: "{{sequence}}", count: TemplatePreview.maximumInputUTF8Bytes / 12 + 1)
        XCTAssertGreaterThan(content.utf8.count, TemplatePreview.maximumInputUTF8Bytes)
        assertRequestError(.inputTooLarge, content: content)
    }

    func testExpandedOutputBelowAtAndAboveLimitIsCompleteOrRejected() throws {
        XCTAssertEqual(TemplatePreview.maximumOutputUTF8Bytes, 131_072)
        let repetitions = TemplatePreview.maximumOutputUTF8Bytes / sampleClipboard.utf8.count
        let expandedBytes = repetitions * sampleClipboard.utf8.count
        let body = String(repeating: "{{clipboard}}", count: repetitions)
        let expanded = String(repeating: sampleClipboard, count: repetitions)

        for outputBytes in [TemplatePreview.maximumOutputUTF8Bytes - 1, TemplatePreview.maximumOutputUTF8Bytes] {
            let suffix = String(repeating: "a", count: outputBytes - expandedBytes)
            let output = try preview(body + suffix)
            XCTAssertEqual(output.text.utf8.count, outputBytes)
            XCTAssertEqual(Array(output.text.utf8), Array((expanded + suffix).utf8))
        }
        let suffix = String(repeating: "a", count: TemplatePreview.maximumOutputUTF8Bytes + 1 - expandedBytes)
        let request = try TemplatePreviewRequest(content: body + suffix, fileExtension: "txt")
        XCTAssertEqual(TemplatePreview.render(request), .failure(.outputTooLarge))
    }

    func testAllVariablesUseFixedExamplesAcrossRepeatedPreviews() throws {
        let content = "{{date}}|{{time}}|{{year}}|{{folderName}}|{{clipboard}}|{{sequence}}"
        let expected = "2026-01-01|12:00:00|2026|示例文件夹|\(sampleClipboard)|1"
        for _ in 0..<3 {
            let output = try preview(content)
            XCTAssertEqual(output.text, expected)
            XCTAssertEqual(output.jsonStatus, .nonJSON)
        }
    }

    func testUnknownUnclosedAndNestedTokensRemainLiteral() throws {
        for content in ["{{unknown}}", "prefix {{date", "{{unknown {{date}}}}", "{{{date}}}", "{{ date }}"] {
            XCTAssertEqual(Array(try preview(content).text.utf8), Array(content.utf8), content)
        }
        XCTAssertEqual(try preview("{{unknown {{date}}}}|{{year}}").text, "{{unknown {{date}}}}|2026")
    }

    func testOriginalBodyBytesArePreservedWithoutNormalizationOrTrimming() throws {
        for content in ["  e\u{301}\r\n", "é", "\u{FEFF}界\u{0}\t", "e\u{301}|{{unknown}}|é"] {
            XCTAssertEqual(Array(try preview(content).text.utf8), Array(content.utf8))
        }
    }

    func testJSONObjectsArraysAndScalarsValidateCompleteRenderedText() throws {
        for content in ["{\"year\":{{year}}}", "[1,\"{{date}}\",null]", "\"{{folderName}}\"", "123", "true", "false", "null"] {
            XCTAssertEqual(try preview(content, fileExtension: " \t.JSoN.\n").jsonStatus, .valid, content)
        }
        let output = try preview(" {\"date\":\"{{date}}\"} \n", fileExtension: "json")
        XCTAssertEqual(output.text, " {\"date\":\"2026-01-01\"} \n")
        XCTAssertEqual(output.jsonStatus, .valid)
    }

    func testInvalidJSONReportsStatusAndPreservesCompleteOutput() throws {
        for content in ["", "{", "[1", "{\"year\":{{unknown}}}", "{} trailing", "true false"] {
            let output = try preview(content, fileExtension: "json")
            XCTAssertEqual(output.jsonStatus, .invalid, content)
            XCTAssertEqual(Array(output.text.utf8), Array(content.utf8))
        }
    }

    func testNonJSONContentIsOnlyRenderedAsText() throws {
        let content = "<script>fetch('https://example.invalid');</script><p>{{date}}</p>"
        let output = try preview(content, fileExtension: "html")
        XCTAssertEqual(output.text, "<script>fetch('https://example.invalid');</script><p>2026-01-01</p>")
        XCTAssertEqual(output.jsonStatus, .nonJSON)
        for fileExtension in ["", "txt", "jsonx", "xjson"] {
            XCTAssertEqual(try preview("{}", fileExtension: fileExtension).jsonStatus, .nonJSON)
        }
    }

    private func preview(_ content: String, fileExtension: String = "txt") throws -> TemplatePreviewOutput {
        try TemplatePreview.render(TemplatePreviewRequest(content: content, fileExtension: fileExtension)).get()
    }

    private func assertRequestError(
        _ expected: TemplatePreviewError,
        content: String,
        fileExtension: String = "txt",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try TemplatePreviewRequest(content: content, fileExtension: fileExtension), file: file, line: line) {
            XCTAssertEqual($0 as? TemplatePreviewError, expected, file: file, line: line)
        }
    }
}
