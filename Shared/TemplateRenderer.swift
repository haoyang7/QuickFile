import Foundation
import Darwin

struct TemplateRenderingContext: Sendable {
    let date: Date
    let folderName: String
    let clipboard: String
    let sequence: Int
}

struct TemplateRenderer: Sendable {
    typealias TimeZoneProvider = @Sendable () -> TimeZone

    static let defaultMaximumOutputUTF8Bytes = 16 * 1024 * 1024

    private let calendar: Calendar
    private let timeZoneProvider: TimeZoneProvider
    private let maximumOutputUTF8Bytes: Int

    init(
        maximumOutputUTF8Bytes: Int = TemplateRenderer.defaultMaximumOutputUTF8Bytes,
        timeZoneProvider: @escaping TimeZoneProvider = { .current }
    ) {
        precondition(maximumOutputUTF8Bytes >= 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar
        self.timeZoneProvider = timeZoneProvider
        self.maximumOutputUTF8Bytes = maximumOutputUTF8Bytes
    }

    init(timeZone: TimeZone, maximumOutputUTF8Bytes: Int = TemplateRenderer.defaultMaximumOutputUTF8Bytes) {
        self.init(maximumOutputUTF8Bytes: maximumOutputUTF8Bytes, timeZoneProvider: { timeZone })
    }

    static func containsVariable(_ name: String, in content: String) -> Bool {
        // An ASCII opening brace is required even when the surrounding text is Unicode.
        guard containsOpeningBrace(in: content) else { return false }
        let scanner = DelimiterScanner(content)
        var cursor = content.startIndex
        while let opening = scanner.range(of: 0x7B, from: cursor) {
            guard let closing = scanner.range(of: 0x7D, from: opening.upperBound) else {
                return false
            }
            if content[opening.upperBound..<closing.lowerBound] == name { return true }
            cursor = closing.upperBound
        }
        return false
    }

    func render(_ content: String, context: TemplateRenderingContext) throws -> String {
        let scanner = Self.containsOpeningBrace(in: content) ? DelimiterScanner(content) : nil
        guard let scanner, scanner.range(of: 0x7B, from: content.startIndex) != nil else {
            guard content.utf8.count <= maximumOutputUTF8Bytes else {
                throw FileCreationError.renderedContentTooLarge(maximumUTF8Bytes: maximumOutputUTF8Bytes)
            }
            return content
        }

        // Long-lived services must see system time-zone changes. Capture one
        // zone per render so all date/time variables use the same snapshot.
        var calendar = self.calendar
        calendar.timeZone = timeZoneProvider()
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: context.date
        )
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let replacements: [Substring: String] = [
            "date": String(format: "%04d-%02d-%02d", year, month, day),
            "time": String(format: "%02d:%02d:%02d", hour, minute, second),
            "year": String(format: "%04d", year),
            "folderName": context.folderName,
            "clipboard": context.clipboard,
            "sequence": String(context.sequence)
        ]

        // Validate the complete expanded UTF-8 size before allocating output. The
        // source can exceed the budget while expanding to less (e.g. empty clipboard).
        // Both passes share immutable replacements, so providers are captured once.
        var outputUTF8Bytes = 0
        try forEachSegment(in: content, scanner: scanner, replacements: replacements) { segment in
            let byteCount = segment.utf8.count
            guard byteCount <= maximumOutputUTF8Bytes - outputUTF8Bytes else {
                throw FileCreationError.renderedContentTooLarge(maximumUTF8Bytes: maximumOutputUTF8Bytes)
            }
            outputUTF8Bytes += byteCount
        }

        var rendered = ""
        rendered.reserveCapacity(outputUTF8Bytes)
        forEachSegment(in: content, scanner: scanner, replacements: replacements) { rendered.append(contentsOf: $0) }
        return rendered
    }

    private func forEachSegment(
        in content: String,
        scanner: DelimiterScanner,
        replacements: [Substring: String],
        _ consume: (Substring) throws -> Void
    ) rethrows {
        var cursor = content.startIndex

        while let openingRange = scanner.range(of: 0x7B, from: cursor) {
            try consume(content[cursor..<openingRange.lowerBound])
            guard let closingRange = scanner.range(of: 0x7D, from: openingRange.upperBound) else {
                try consume(content[openingRange.lowerBound...])
                return
            }

            // Keep unknown token names as slices, not potentially huge String copies.
            let variable = content[openingRange.upperBound..<closingRange.lowerBound]
            if let replacement = replacements[variable] {
                try consume(replacement[...])
            } else {
                try consume(content[openingRange.lowerBound..<closingRange.upperBound])
            }
            cursor = closingRange.upperBound
        }

        try consume(content[cursor...])
    }

    private static func containsOpeningBrace(in content: String) -> Bool {
        // Borrow contiguous UTF-8 without materializing Data or bridging the string.
        // Keep the collection path for strings that cannot expose such storage.
        content.utf8.withContiguousStorageIfAvailable { bytes in
            guard let base = bytes.baseAddress else { return false }
            return memchr(base, 0x7B, bytes.count) != nil
        } ?? content.utf8.contains(0x7B)
    }

    private struct DelimiterScanner {
        let content: String
        let isASCII: Bool

        init(_ content: String) {
            self.content = content
            isASCII = content.utf8.allSatisfy { $0 < 0x80 }
        }

        func range(of brace: UInt8, from start: String.Index) -> Range<String.Index>? {
            guard isASCII else {
                // Foundation's default search observes Unicode character boundaries.
                // Literal byte matches next to combining marks are not equivalent.
                return content.range(of: brace == 0x7B ? "{{" : "}}", range: start..<content.endIndex)
            }
            let bytes = content.utf8
            var cursor = start
            while let first = bytes[cursor...].firstIndex(of: brace) {
                let next = bytes.index(after: first)
                if next != bytes.endIndex, bytes[next] == brace {
                    return first..<bytes.index(after: next)
                }
                cursor = next
            }
            return nil
        }
    }
}
