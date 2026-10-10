import Foundation

public struct TemplatePreviewRequest: Sendable {
    fileprivate let content: String
    fileprivate let fileExtension: String

    public init(content: String, fileExtension: String) throws {
        // Copy only the bounded UTF-8 prefix before inspecting its size. Character
        // traversal can scan an arbitrarily large single grapheme cluster.
        let contentBytes = Array(content.utf8.prefix(TemplatePreview.maximumInputUTF8Bytes + 1))
        guard contentBytes.count <= TemplatePreview.maximumInputUTF8Bytes else {
            throw TemplatePreviewError.inputTooLarge
        }
        let extensionBytes = Array(fileExtension.utf8.prefix(TemplatePreview.maximumExtensionUTF8Bytes + 1))
        guard extensionBytes.count <= TemplatePreview.maximumExtensionUTF8Bytes else {
            throw TemplatePreviewError.fileExtensionTooLarge
        }
        self.content = String(decoding: contentBytes, as: UTF8.self)
        self.fileExtension = String(decoding: extensionBytes, as: UTF8.self)
    }
}

public struct TemplatePreviewOutput: Sendable, Equatable {
    public let text: String
    public let jsonStatus: TemplatePreviewJSONStatus
}

public enum TemplatePreviewJSONStatus: Sendable, Equatable {
    case nonJSON
    case valid
    case invalid
}

public enum TemplatePreviewError: Error, Sendable, Equatable {
    case inputTooLarge
    case fileExtensionTooLarge
    case outputTooLarge
    case renderingFailed
}

public enum TemplatePreview {
    public static let maximumInputUTF8Bytes = 65_536
    public static let maximumOutputUTF8Bytes = 131_072
    public static let maximumExtensionUTF8Bytes = 255

    public static func render(_ request: TemplatePreviewRequest) -> Result<TemplatePreviewOutput, TemplatePreviewError> {
        let renderer = TemplateRenderer(
            timeZone: TimeZone(secondsFromGMT: 0)!,
            maximumOutputUTF8Bytes: maximumOutputUTF8Bytes
        )
        let context = TemplateRenderingContext(
            // 2026-01-01 12:00:00 UTC.
            date: Date(timeIntervalSince1970: 1_767_268_800),
            folderName: "示例文件夹",
            clipboard: "示例剪贴板内容（预览不会读取系统剪贴板）",
            sequence: 1
        )

        let text: String
        do {
            text = try renderer.render(request.content, context: context)
        } catch FileCreationError.renderedContentTooLarge {
            return .failure(.outputTooLarge)
        } catch {
            return .failure(.renderingFailed)
        }

        let normalizedExtension = request.fileExtension.trimmingCharacters(
            in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)
        )
        let jsonStatus: TemplatePreviewJSONStatus
        if normalizedExtension.caseInsensitiveCompare("json") == .orderedSame {
            do {
                _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
                jsonStatus = .valid
            } catch {
                jsonStatus = .invalid
            }
        } else {
            jsonStatus = .nonJSON
        }
        return .success(TemplatePreviewOutput(text: text, jsonStatus: jsonStatus))
    }
}
