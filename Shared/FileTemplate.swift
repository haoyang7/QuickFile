import Foundation

public struct FileTemplate: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var fileExtension: String
    public var content: String
    public var defaultFilename: String
    public var isEnabled: Bool

    public var usesClipboard: Bool {
        TemplateRenderer.containsVariable("clipboard", in: content)
    }

    public init(
        id: UUID = UUID(),
        name: String,
        fileExtension: String,
        content: String,
        isEnabled: Bool = true,
        defaultFilename: String = ""
    ) {
        self.defaultFilename = defaultFilename
        self.id = id
        self.name = name
        self.fileExtension = fileExtension
        self.content = content
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, fileExtension, content, isEnabled, defaultFilename
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        fileExtension = try values.decode(String.self, forKey: .fileExtension)
        content = try values.decode(String.self, forKey: .content)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        defaultFilename = values.contains(.defaultFilename) ? try values.decode(String.self, forKey: .defaultFilename) : ""
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(fileExtension, forKey: .fileExtension)
        try values.encode(content, forKey: .content)
        try values.encode(isEnabled, forKey: .isEnabled)
        if !defaultFilename.isEmpty { try values.encode(defaultFilename, forKey: .defaultFilename) }
    }
}

public enum BuiltInTemplates {
    public static let all: [FileTemplate] = [
        FileTemplate(
            id: UUID(uuidString: "A8A680CC-CC64-4F71-8905-E5B350297A11")!,
            name: "文本文档",
            fileExtension: "txt",
            content: ""
        ),
        FileTemplate(
            id: UUID(uuidString: "B16CD640-23B1-4FF6-A365-816696091E1C")!,
            name: "Markdown",
            fileExtension: "md",
            content: ""
        ),
        FileTemplate(
            id: UUID(uuidString: "42A8D1DB-D9DA-4D84-A698-505130282A67")!,
            name: "JSON",
            fileExtension: "json",
            content: "{}\n"
        ),
        FileTemplate(
            id: UUID(uuidString: "7537DDB2-C1B3-4597-B3B1-24ED056F4BD0")!,
            name: "YAML",
            fileExtension: "yaml",
            content: ""
        ),
        FileTemplate(
            id: UUID(uuidString: "020E1DD5-C50D-436C-A433-39250EE60B3B")!,
            name: "Shell",
            fileExtension: "sh",
            content: "#!/bin/bash\n\n"
        )
    ]
}
