import XCTest
@testable import QuickFileCore

final class TemplateRendererTests: XCTestCase {
    func testRendersAllSupportedVariables() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = timeZone
        components.year = 2026
        components.month = 8
        components.day = 6
        components.hour = 9
        components.minute = 7
        components.second = 5

        let context = TemplateRenderingContext(
            date: try XCTUnwrap(components.date),
            folderName: "项目 📁",
            clipboard: "复制内容",
            sequence: 4
        )
        let renderer = TemplateRenderer(timeZone: timeZone)

        let rendered = try renderer.render(
            "{{date}}|{{time}}|{{year}}|{{folderName}}|{{clipboard}}|{{sequence}}",
            context: context
        )

        XCTAssertEqual(rendered, "2026-08-06|09:07:05|2026|项目 📁|复制内容|4")
    }

    func testRefreshesTimeZoneForEachRenderAcrossDayAndYearBoundary() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let west = try XCTUnwrap(TimeZone(secondsFromGMT: -8 * 60 * 60))
        let provider = TestTimeZoneProvider(utc)
        let renderer = TemplateRenderer(timeZoneProvider: { provider.current() })
        let context = TemplateRenderingContext(
            date: Date(timeIntervalSince1970: 0),
            folderName: "Folder",
            clipboard: "",
            sequence: 1
        )
        let template = "{{date}}|{{time}}|{{year}}|{{date}}"

        XCTAssertEqual(provider.readCount, 0, "Do not capture the zone at initialization")
        XCTAssertEqual(try renderer.render(template, context: context), "1970-01-01|00:00:00|1970|1970-01-01")
        XCTAssertEqual(provider.readCount, 1, "Capture one zone for all variables in a render")

        provider.setTimeZone(west)
        XCTAssertEqual(try renderer.render(template, context: context), "1969-12-31|16:00:00|1969|1969-12-31")
        XCTAssertEqual(provider.readCount, 2)

        provider.setTimeZone(utc)
        XCTAssertEqual(try renderer.render(template, context: context), "1970-01-01|00:00:00|1970|1970-01-01")
        XCTAssertEqual(provider.readCount, 3)
    }

    func testExplicitTimeZonesRemainDeterministicAcrossRepeatedRenders() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let east = try XCTUnwrap(TimeZone(secondsFromGMT: 5 * 60 * 60 + 30 * 60))
        let west = try XCTUnwrap(TimeZone(secondsFromGMT: -8 * 60 * 60))
        let cases = [
            (utc, "1970-01-01|00:00:00|1970"),
            (east, "1970-01-01|05:30:00|1970"),
            (west, "1969-12-31|16:00:00|1969")
        ]
        let context = TemplateRenderingContext(
            date: Date(timeIntervalSince1970: 0),
            folderName: "Folder",
            clipboard: "",
            sequence: 1
        )

        for (timeZone, expected) in cases {
            let renderer = TemplateRenderer(timeZone: timeZone)
            for _ in 0..<3 {
                XCTAssertEqual(try renderer.render("{{date}}|{{time}}|{{year}}", context: context), expected)
            }
        }
    }

    func testLeavesUnknownVariablesUntouched() throws {
        let context = TemplateRenderingContext(
            date: Date(timeIntervalSince1970: 0),
            folderName: "Folder",
            clipboard: "",
            sequence: 1
        )

        let rendered = try TemplateRenderer().render("{{unknown}}", context: context)

        XCTAssertEqual(rendered, "{{unknown}}")
    }

    func testDoesNotInterpretVariablesInsideReplacementValues() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let context = TemplateRenderingContext(
            date: Date(timeIntervalSince1970: 0),
            folderName: "{{year}}",
            clipboard: "{{date}}",
            sequence: 1
        )

        let rendered = try TemplateRenderer(timeZone: timeZone).render(
            "{{clipboard}}|{{folderName}}|{{date}}",
            context: context
        )

        XCTAssertEqual(rendered, "{{date}}|{{year}}|1970-01-01")
    }

    func testLeavesUnclosedVariableUntouched() throws {
        let context = TemplateRenderingContext(
            date: Date(timeIntervalSince1970: 0),
            folderName: "Folder",
            clipboard: "",
            sequence: 1
        )

        let rendered = try TemplateRenderer().render("prefix {{date", context: context)

        XCTAssertEqual(rendered, "prefix {{date")
    }

    func testClipboardDetectionMatchesExactRendererTokens() throws {
        let context = TemplateRenderingContext(date: Date(), folderName: "folder", clipboard: "CAPTURED", sequence: 1)
        let examples: [(String, Bool)] = [
            ("{{clipboard}}", true), ("{{ clipboard }}", false),
            ("{{Clipboard}}", false), ("{{clipboard", false),
            ("{{unknown {{clipboard}}", false), ("{{{clipboard}}}", false),
            ("{{unknown}} {{clipboard}}", true), ("{{unknown {{clipboard}} {{clipboard}}", true)
        ]
        for (content, expected) in examples {
            let template = FileTemplate(name: "test", fileExtension: "txt", content: content)
            XCTAssertEqual(template.usesClipboard, expected, content)
            XCTAssertEqual(try TemplateRenderer().render(content, context: context).contains("CAPTURED"), expected, content)
        }
    }

    func testLiteralOutputRespectsBudgetBelowAtAndAboveLimit() throws {
        let renderer = TemplateRenderer(maximumOutputUTF8Bytes: 8)
        let context = budgetContext()
        for count in [7, 8] {
            let content = String(repeating: "a", count: count)
            XCTAssertEqual(try renderer.render(content, context: context), content)
        }
        assertOutputTooLarge(maximumUTF8Bytes: 8) {
            try renderer.render(String(repeating: "a", count: 9), context: context)
        }
    }

    func testExpandedOutputRespectsBudgetBelowAtAndAboveLimit() throws {
        let renderer = TemplateRenderer(maximumOutputUTF8Bytes: 8)
        let context = budgetContext(clipboard: "data")
        XCTAssertEqual(try renderer.render("{{clipboard}}abc", context: context), "dataabc")
        XCTAssertEqual(try renderer.render("{{clipboard}}{{clipboard}}", context: context), "datadata")
        assertOutputTooLarge(maximumUTF8Bytes: 8) {
            try renderer.render("{{clipboard}}{{clipboard}}x", context: context)
        }
    }

    func testMultibyteLiteralAndReplacementBudgetsCountUTF8Bytes() throws {
        // Canonically equivalent strings can occupy different UTF-8 byte counts.
        for value in ["é", "e\u{301}", "🧪", "🇨🇳"] {
            let byteCount = value.utf8.count
            let context = budgetContext(clipboard: value)
            for content in [value, "{{clipboard}}"] {
                for limit in [byteCount, byteCount + 1] {
                    let rendered = try TemplateRenderer(maximumOutputUTF8Bytes: limit).render(content, context: context)
                    XCTAssertEqual(Array(rendered.utf8), Array(value.utf8))
                }
                assertOutputTooLarge(maximumUTF8Bytes: byteCount - 1) {
                    try TemplateRenderer(maximumOutputUTF8Bytes: byteCount - 1).render(content, context: context)
                }
            }
        }
    }

    func testRepeatedClipboardCountsEveryOccurrence() throws {
        let renderer = TemplateRenderer(maximumOutputUTF8Bytes: 8)
        let context = budgetContext(clipboard: "界")
        XCTAssertEqual(try renderer.render("{{clipboard}}{{clipboard}}", context: context), "界界")
        assertOutputTooLarge(maximumUTF8Bytes: 8) {
            try renderer.render("{{clipboard}}{{clipboard}}{{clipboard}}", context: context)
        }
    }

    func testUnknownAndUnclosedTokensRetainLiteralContentWithinBudget() throws {
        let context = budgetContext(clipboard: "must not expand")
        for content in ["前{{unknown}}后", "{{unknown {{clipboard}}", "prefix {{date", "{{{clipboard}}}"] {
            let byteCount = content.utf8.count
            let renderer = TemplateRenderer(maximumOutputUTF8Bytes: byteCount)
            XCTAssertEqual(try renderer.render(content, context: context), content)
            assertOutputTooLarge(maximumUTF8Bytes: byteCount - 1) {
                try TemplateRenderer(maximumOutputUTF8Bytes: byteCount - 1).render(content, context: context)
            }
        }
    }

    func testEverySupportedReplacementCountsAgainstBudget() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let context = budgetContext(clipboard: "{{date}}")
        let replacements = [
            ("{{date}}", "1970-01-01"), ("{{time}}", "00:00:00"), ("{{year}}", "1970"),
            ("{{folderName}}", "Folder"), ("{{clipboard}}", "{{date}}"), ("{{sequence}}", "1")
        ]
        for (content, expected) in replacements {
            let byteCount = expected.utf8.count
            XCTAssertEqual(
                try TemplateRenderer(timeZone: timeZone, maximumOutputUTF8Bytes: byteCount).render(content, context: context),
                expected
            )
            assertOutputTooLarge(maximumUTF8Bytes: byteCount - 1) {
                try TemplateRenderer(timeZone: timeZone, maximumOutputUTF8Bytes: byteCount - 1).render(content, context: context)
            }
        }
    }

    func testLargeUnknownTokenIsRejectedByOutputBudget() {
        let content = "{{" + String(repeating: "x", count: 100_000) + "}}"
        assertOutputTooLarge(maximumUTF8Bytes: 8) {
            try TemplateRenderer(maximumOutputUTF8Bytes: 8).render(content, context: budgetContext())
        }
    }

    func testZeroBudgetAllowsEmptyOutputAndLargeSourceThatExpandsToEmpty() throws {
        let renderer = TemplateRenderer(maximumOutputUTF8Bytes: 0)
        let context = budgetContext()
        XCTAssertEqual(try renderer.render("", context: context), "")
        XCTAssertEqual(try renderer.render(String(repeating: "{{clipboard}}", count: 1000), context: context), "")
        assertOutputTooLarge(maximumUTF8Bytes: 0) {
            try renderer.render("{{clipboard}}x", context: context)
        }
    }

    func testLiteralFastPathDoesNotCaptureTimeZone() throws {
        let renderer = TemplateRenderer(maximumOutputUTF8Bytes: 8, timeZoneProvider: {
            XCTFail("Literal content must not capture a time zone")
            return .current
        })
        XCTAssertEqual(try renderer.render("literal", context: budgetContext()), "literal")
        assertOutputTooLarge(maximumUTF8Bytes: 8) {
            try renderer.render("over limit", context: budgetContext())
        }
    }

    func testMaximumIntegerBudgetDoesNotOverflowForSmallOutput() throws {
        let renderer = TemplateRenderer(maximumOutputUTF8Bytes: Int.max)
        XCTAssertEqual(try renderer.render("a{{clipboard}}z", context: budgetContext(clipboard: "界")), "a界z")
    }

    func testDefaultBudgetAllowsExistingLargeBodyAndRejectsOversizedExpansion() throws {
        XCTAssertEqual(TemplateRenderer.defaultMaximumOutputUTF8Bytes, 16 * 1024 * 1024)
        let body = String(repeating: "a", count: 4_600_000)
        let context = budgetContext(clipboard: body)
        let renderer = TemplateRenderer()
        XCTAssertEqual(try renderer.render(body, context: context), body)
        XCTAssertEqual(try renderer.render("{{clipboard}}", context: context), body)
        assertOutputTooLarge(maximumUTF8Bytes: 16 * 1024 * 1024) {
            try renderer.render(String(repeating: "{{clipboard}}", count: 4), context: context)
        }
    }

    private func budgetContext(clipboard: String = "") -> TemplateRenderingContext {
        TemplateRenderingContext(date: Date(timeIntervalSince1970: 0), folderName: "Folder", clipboard: clipboard, sequence: 1)
    }

    private func assertOutputTooLarge(
        maximumUTF8Bytes: Int,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ render: () throws -> String
    ) {
        XCTAssertThrowsError(try render(), file: file, line: line) { error in
            guard case let FileCreationError.renderedContentTooLarge(limit) = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertEqual(limit, maximumUTF8Bytes, file: file, line: line)
        }
    }

}

// Shared by renderer and file-creation tests; never changes the process or OS time zone.
final class TestTimeZoneProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var timeZone: TimeZone
    private var reads = 0

    init(_ timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    func current() -> TimeZone {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return timeZone
    }

    func setTimeZone(_ timeZone: TimeZone) {
        lock.lock()
        defer { lock.unlock() }
        self.timeZone = timeZone
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}
