import Foundation

public struct TemplateDraft: Equatable {
    public var id: FileTemplate.ID?
    public var name: String
    public var fileExtension: String
    public var defaultFilename: String
    public var content: String
    public var isEnabled: Bool

    public init(template: FileTemplate? = nil) {
        defaultFilename = template?.defaultFilename ?? ""
        id = template?.id
        name = template?.name ?? ""
        fileExtension = template?.fileExtension ?? ""
        content = template?.content ?? ""
        isEnabled = template?.isEnabled ?? true
    }

    public func makeTemplate() throws -> FileTemplate {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw TemplateValidationError.emptyName
        }

        let normalizedExtension = fileExtension.trimmingCharacters(
            in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines)
        )
        let forbiddenCharacters = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        guard normalizedExtension.rangeOfCharacter(from: forbiddenCharacters) == nil else {
            throw TemplateValidationError.invalidExtension
        }

        // Match filename normalization's C0/C1 rule while allowing emoji ZWJ.
        let forbiddenFilename = CharacterSet(charactersIn: "/:")
            .union(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(31)))
            .union(CharacterSet(charactersIn: Unicode.Scalar(127)...Unicode.Scalar(159)))
        guard defaultFilename.rangeOfCharacter(from: forbiddenFilename) == nil else {
            throw TemplateValidationError.invalidDefaultFilename
        }

        return FileTemplate(
            id: id ?? UUID(),
            name: normalizedName,
            fileExtension: normalizedExtension,
            content: content,
            isEnabled: isEnabled,
            defaultFilename: defaultFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public enum TemplateValidationError: LocalizedError, Equatable {
    case emptyName
    case emptyExtension
    case invalidDefaultFilename
    case invalidExtension

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "模板名称不能为空。"
        case .emptyExtension:
            return "文件扩展名不能为空。"
        case .invalidDefaultFilename:
            return "默认文件名不能包含路径分隔符或控制字符。"
        case .invalidExtension:
            return "文件扩展名不能包含路径分隔符或控制字符。"
        }
    }
}
