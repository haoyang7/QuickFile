import Foundation

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
        var cursor = content.startIndex
        while let opening = content.range(of: "{{", range: cursor..<content.endIndex) {
            guard let closing = content.range(of: "}}", range: opening.upperBound..<content.endIndex) else {
                return false
            }
            if content[opening.upperBound..<closing.lowerBound] == name { return true }
            cursor = closing.upperBound
        }
        return false
    }

    func render(_ content: String, context: TemplateRenderingContext) throws -> String {
        guard content.contains("{{") else {
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
        try forEachSegment(in: content, replacements: replacements) { segment in
            let byteCount = segment.utf8.count
            guard byteCount <= maximumOutputUTF8Bytes - outputUTF8Bytes else {
                throw FileCreationError.renderedContentTooLarge(maximumUTF8Bytes: maximumOutputUTF8Bytes)
            }
            outputUTF8Bytes += byteCount
        }

        var rendered = ""
        rendered.reserveCapacity(outputUTF8Bytes)
        forEachSegment(in: content, replacements: replacements) { rendered.append(contentsOf: $0) }
        return rendered
    }

    private func forEachSegment(
        in content: String,
        replacements: [Substring: String],
        _ consume: (Substring) throws -> Void
    ) rethrows {
        var cursor = content.startIndex

        while let openingRange = content.range(of: "{{", range: cursor..<content.endIndex) {
            try consume(content[cursor..<openingRange.lowerBound])
            guard let closingRange = content.range(of: "}}", range: openingRange.upperBound..<content.endIndex) else {
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
}
