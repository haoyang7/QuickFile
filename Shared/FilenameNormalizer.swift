import Foundation

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
    private let fallbackBaseName = "未命名"
    // C0/C1 controls only: Foundation's controlCharacters also includes format
    // characters such as the zero-width joiner needed by composed emoji.
    private let forbiddenCharacters = CharacterSet(charactersIn: "/:")
        .union(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(31)))
        .union(CharacterSet(charactersIn: Unicode.Scalar(127)...Unicode.Scalar(159)))

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
