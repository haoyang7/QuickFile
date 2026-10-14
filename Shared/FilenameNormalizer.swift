import Foundation

// Reject display-direction controls and invisible separators, while retaining
// joiners, variation selectors and combining marks used by legitimate names.
enum TemplateNameCharacters {
    static let forbiddenControls = CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(31))
        .union(CharacterSet(charactersIn: Unicode.Scalar(127)...Unicode.Scalar(159)))
        .union(CharacterSet(charactersIn: "\u{061C}\u{200B}\u{200E}\u{200F}"))
        .union(CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"))
        .union(CharacterSet(charactersIn: "\u{2066}\u{2067}\u{2068}\u{2069}"))

    static let forbiddenFilenameCharacters = CharacterSet(charactersIn: "/:")
        .union(forbiddenControls)
}

struct NormalizedFilename: Equatable, Sendable {
    let baseName: String
    let fileExtension: String

    func filename(sequence: Int, maximumUTF8Bytes: Int = .max) throws -> String {
        let suffix = (sequence > 1 ? " \(sequence)" : "")
            + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        let budget = maximumUTF8Bytes - suffix.utf8.count
        guard budget > 0 else { throw FileCreationError.invalidFilename }
        var prefix = ""
        var byteCount = 0
        // Keep whole grapheme clusters, including composed accents and emoji.
        for character in baseName {
            let size = String(character).utf8.count
            guard byteCount + size <= budget else { break }
            prefix.append(character)
            byteCount += size
        }
        guard !prefix.isEmpty else { throw FileCreationError.invalidFilename }
        return prefix + suffix
    }
}

struct FilenameNormalizer: Sendable {
    private var fallbackBaseName: String { QuickFileLocalization.text(.init("未命名")) }
    private let forbiddenCharacters = TemplateNameCharacters.forbiddenFilenameCharacters

    func normalize(_ requestedFilename: String?, requiredExtension: String) throws -> NormalizedFilename {
        let normalizedExtension = sanitizeExtension(requiredExtension)
        var baseName = sanitizeBaseName(requestedFilename ?? "")

        if !normalizedExtension.isEmpty {
            let suffix = ".\(normalizedExtension)"
            if baseName.lowercased().hasSuffix(suffix.lowercased()) {
                baseName.removeLast(suffix.count)
                baseName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if baseName.isEmpty || baseName == "." || baseName == ".." {
            baseName = fallbackBaseName
        }

        guard !baseName.isEmpty else {
            throw FileCreationError.invalidFilename
        }

        return NormalizedFilename(baseName: baseName, fileExtension: normalizedExtension)
    }

    private func sanitizeBaseName(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return ""
        }

        return trimmedValue
            .components(separatedBy: forbiddenCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizeExtension(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return trimmed
            .components(separatedBy: forbiddenCharacters)
            .joined()
    }
}
