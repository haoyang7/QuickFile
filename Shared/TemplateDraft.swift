import Foundation

public struct TemplateDraft: Equatable {
    public var id: FileTemplate.ID?
    public var name: String
    public var fileExtension: String
    public var defaultFilename: String
    public var content: String
    public var isEnabled: Bool
    public var officeFormat: OfficeDocumentFormat?

    public init(template: FileTemplate? = nil) {
        defaultFilename = template?.defaultFilename ?? ""
        id = template?.id
        name = template?.name ?? ""
        fileExtension = template?.fileExtension ?? ""
        content = template?.content ?? ""
        isEnabled = template?.isEnabled ?? true
        officeFormat = template?.officeFormat
    }

    public func makeTemplate() throws -> FileTemplate {
        guard name.rangeOfCharacter(from: TemplateNameCharacters.forbiddenControls) == nil else {
            throw TemplateValidationError.invalidName
        }
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

        guard defaultFilename.rangeOfCharacter(from: TemplateNameCharacters.forbiddenFilenameCharacters) == nil else {
            throw TemplateValidationError.invalidDefaultFilename
        }

        try officeFormat?.validate(content: content, fileExtension: fileExtension)

        return FileTemplate(
            id: id ?? UUID(),
            name: normalizedName,
            fileExtension: normalizedExtension,
            content: content,
            isEnabled: isEnabled,
            defaultFilename: defaultFilename.trimmingCharacters(in: .whitespacesAndNewlines),
            officeFormat: officeFormat
        )
    }
}

public enum TemplateValidationError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case emptyExtension
    case invalidDefaultFilename
    case invalidExtension
    case invalidOfficeTemplate

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return QuickFileLocalization.text(.init("模板名称不能为空。"))
        case .invalidName:
            return QuickFileLocalization.text(.init("模板名称不能包含控制字符。"))
        case .emptyExtension:
            return QuickFileLocalization.text(.init("文件扩展名不能为空。"))
        case .invalidDefaultFilename:
            return QuickFileLocalization.text(.init("默认文件名不能包含路径分隔符或控制字符。"))
        case .invalidExtension:
            return QuickFileLocalization.text(.init("文件扩展名不能包含路径分隔符或控制字符。"))
        case .invalidOfficeTemplate:
            return QuickFileLocalization.text(.init("Office 模板只能创建对应格式的空白文档，不能修改扩展名或预填文本。"))
        }
    }
}
