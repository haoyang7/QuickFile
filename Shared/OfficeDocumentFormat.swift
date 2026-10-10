import Foundation

/// A fixed blank document, not a filename-based inference or user-supplied archive.
public enum OfficeDocumentFormat: String, Codable, CaseIterable, Sendable {
    case docx, xlsx, pptx

    public var blankDocumentDescription: String {
        switch self {
        case .docx: return "空白 Word 文档"
        case .xlsx: return "空白 Excel 工作簿"
        case .pptx: return "空白 PowerPoint 演示文稿"
        }
    }

    func validate(content: String, fileExtension: String) throws {
        guard content.isEmpty, fileExtension == rawValue else {
            throw TemplateValidationError.invalidOfficeTemplate
        }
    }

    var data: Data {
        switch self {
        case .docx: return OfficeDocumentData.docx
        case .xlsx: return OfficeDocumentData.xlsx
        case .pptx: return OfficeDocumentData.pptx
        }
    }
}
