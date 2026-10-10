import Foundation

/// The limits apply to a transfer file, not to historical on-disk configurations.
public struct TemplateTransferLimits: Equatable, Sendable {
    public let maximumFileBytes: Int
    public let maximumTemplates: Int
    public let maximumContentBytes: Int
    public let maximumNameBytes: Int
    public let maximumExtensionBytes: Int

    public init(
        maximumFileBytes: Int = 32 * 1024 * 1024,
        maximumTemplates: Int = 1_000,
        maximumContentBytes: Int = 16 * 1024 * 1024,
        maximumNameBytes: Int = 1_024,
        maximumExtensionBytes: Int = 255
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumTemplates = maximumTemplates
        self.maximumContentBytes = maximumContentBytes
        self.maximumNameBytes = maximumNameBytes
        self.maximumExtensionBytes = maximumExtensionBytes
    }

    public static let `default` = TemplateTransferLimits()

    public func validate() throws {
        guard maximumFileBytes >= 0, maximumFileBytes < Int.max,
              maximumTemplates >= 0, maximumContentBytes >= 0,
              maximumNameBytes >= 0, maximumExtensionBytes >= 0 else {
            throw TemplateTransferError.invalidLimits
        }
    }
}

public enum TemplateTransferError: LocalizedError, Equatable {
    case invalidLimits
    case invalidFormat
    case unsupportedVersion(Int)
    case malformedFile
    case fileTooLarge(maximumBytes: Int)
    case tooManyTemplates(maximum: Int)
    case invalidTemplate(index: Int, reason: String)
    case fieldTooLarge(index: Int, field: String, maximumBytes: Int)
    case nonLocalFile
    case protectedDestination

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: return "模板文件的大小限制无效。"
        case .invalidFormat: return "此文件不是 QuickFile 模板文件。"
        case let .unsupportedVersion(version): return "暂不支持模板文件版本 \(version)。"
        case .malformedFile: return "模板文件格式不完整或 JSON 无效，未导入任何模板。"
        case let .fileTooLarge(maximum): return "模板文件超过大小上限（\(maximum) 字节）。"
        case let .tooManyTemplates(maximum): return "模板文件最多包含 \(maximum) 个模板。"
        case let .invalidTemplate(index, reason): return "第 \(index + 1) 个模板无效：\(reason)"
        case let .fieldTooLarge(index, field, maximum):
            return "第 \(index + 1) 个模板的\(field)超过上限（\(maximum) 字节）。"
        case .nonLocalFile: return "请选择本地模板文件。"
        case .protectedDestination: return "不能用导出文件覆盖 QuickFile 的配置、锁文件或恢复备份，请选择其他位置。"
        }
    }
}

/// A portable template deliberately has no UUID, authorization, bookmark or history.
public struct TransferTemplate: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let fileExtension: String
    public let content: String
    public let defaultFilename: String
    public let isEnabled: Bool
    public let officeFormat: OfficeDocumentFormat?

    public init(name: String, fileExtension: String, content: String, isEnabled: Bool, defaultFilename: String = "", officeFormat: OfficeDocumentFormat? = nil) {
        self.defaultFilename = defaultFilename
        self.name = name
        self.fileExtension = fileExtension
        self.content = content
        self.isEnabled = isEnabled
        self.officeFormat = officeFormat
    }

    private enum CodingKeys: String, CodingKey {
        case name, fileExtension, content, isEnabled, defaultFilename, officeFormat
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        fileExtension = try values.decode(String.self, forKey: .fileExtension)
        content = try values.decode(String.self, forKey: .content)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        defaultFilename = values.contains(.defaultFilename) ? try values.decode(String.self, forKey: .defaultFilename) : ""
        officeFormat = values.contains(.officeFormat) ? try values.decode(OfficeDocumentFormat.self, forKey: .officeFormat) : nil
    }

    public init(_ template: FileTemplate) {
        self.init(name: template.name, fileExtension: template.fileExtension,
                  content: template.content, isEnabled: template.isEnabled, defaultFilename: template.defaultFilename,
                  officeFormat: template.officeFormat)
    }

    public var usesClipboard: Bool {
        // Detect the token only. Import/export never renders or reads the pasteboard.
        officeFormat == nil && TemplateRenderer.containsVariable("clipboard", in: content)
    }

    public func makeTemplate() -> FileTemplate {
        FileTemplate(name: name, fileExtension: fileExtension, content: content, isEnabled: isEnabled,
                     defaultFilename: defaultFilename, officeFormat: officeFormat)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isEnabled == rhs.isEnabled
            && lhs.officeFormat == rhs.officeFormat
            && TemplateByteOperations.areEqual(lhs.name.utf8, rhs.name.utf8)
            && TemplateByteOperations.areEqual(lhs.fileExtension.utf8, rhs.fileExtension.utf8)
            && TemplateByteOperations.areEqual(lhs.content.utf8, rhs.content.utf8)
            && TemplateByteOperations.areEqual(lhs.defaultFilename.utf8, rhs.defaultFilename.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        TemplateByteOperations.hash(name.utf8, into: &hasher)
        TemplateByteOperations.hash(fileExtension.utf8, into: &hasher)
        TemplateByteOperations.hash(content.utf8, into: &hasher)
        TemplateByteOperations.hash(defaultFilename.utf8, into: &hasher)
        hasher.combine(isEnabled)
        hasher.combine(officeFormat)
    }
}

public struct TemplateTransferBundle: Equatable, Sendable {
    public let templates: [TransferTemplate]

    public init(templates: [TransferTemplate]) { self.templates = templates }
    public init(templates: [FileTemplate]) { self.templates = templates.map(TransferTemplate.init) }
}

public struct TemplateImportPlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public let sourceIndex: Int
        public let originalName: String
        public let template: FileTemplate
        public var id: UUID { template.id }
        public var wasRenamed: Bool { originalName != template.name }
        public let usesClipboard: Bool
    }

    public let baseline: [FileTemplate]
    public let additions: [Item]
    public let skippedCount: Int
    public var templates: [FileTemplate] { baseline + additions.map(\.template) }
    public var addedCount: Int { additions.count }
    public var renamedCount: Int { additions.filter(\.wasRenamed).count }
    public var enabledCount: Int { additions.filter { $0.template.isEnabled }.count }
    public var clipboardCount: Int { additions.filter(\.usesClipboard).count }
}

public enum TemplateTransfer {
    public static let format = "quickfile.templates"
    public static let version = 3

    public static func decode(
        _ data: Data, limits: TemplateTransferLimits = .default
    ) throws -> TemplateTransferBundle {
        try limits.validate()
        guard data.count <= limits.maximumFileBytes else {
            throw TemplateTransferError.fileTooLarge(maximumBytes: limits.maximumFileBytes)
        }
        let decoder = JSONDecoder()
        decoder.userInfo[limitsKey] = limits
        do {
            return try decoder.decode(Envelope.self, from: data).bundle
        } catch let error as TemplateTransferError {
            throw error
        } catch {
            throw TemplateTransferError.malformedFile
        }
    }

    public static func validate(
        _ bundle: TemplateTransferBundle, limits: TemplateTransferLimits = .default
    ) throws {
        try limits.validate()
        guard bundle.templates.count <= limits.maximumTemplates else {
            throw TemplateTransferError.tooManyTemplates(maximum: limits.maximumTemplates)
        }
        for (index, template) in bundle.templates.enumerated() {
            try validate(template, index: index, limits: limits)
        }
    }

    /// Validates every transfer constraint, including JSON escape expansion and
    /// the complete envelope, without allocating an encoded copy of the bundle.
    @discardableResult
    public static func validateEncodedSize(
        _ bundle: TemplateTransferBundle, limits: TemplateTransferLimits = .default
    ) throws -> Int {
        try validate(bundle, limits: limits)
        return try encodedSizeWithoutValidation(bundle, maximumBytes: limits.maximumFileBytes)
    }

    /// Measures only whether a historical record's encoded size would grow.
    /// Invalid historical fields remain countable, and booleans participate in
    /// the exact byte count. This does not validate or authorize a replacement;
    /// callers must separately enforce field validity and collection limits.
    public static func isEncodedSizeNonIncreasing(
        _ candidate: TransferTemplate, comparedTo original: TransferTemplate
    ) throws -> Bool {
        // Both singleton envelopes have identical overhead. Keep arithmetic
        // bounded even when a historical record exceeds today's transfer limits.
        let candidateBytes = try encodedSizeWithoutValidation(
            TemplateTransferBundle(templates: [candidate]), maximumBytes: Int.max - 1
        )
        let originalBytes = try encodedSizeWithoutValidation(
            TemplateTransferBundle(templates: [original]), maximumBytes: Int.max - 1
        )
        return candidateBytes <= originalBytes
    }

    public static func encode(
        _ bundle: TemplateTransferBundle, limits: TemplateTransferLimits = .default
    ) throws -> Data {
        try validate(bundle, limits: limits)
        var sink = BoundedJSONDataSink(maximumBytes: limits.maximumFileBytes)
        try TemplateJSONEmission.write(bundle, to: &sink)
        return sink.finish()
    }

    public static func makeImportPlan(
        bundle: TemplateTransferBundle, existing: [FileTemplate],
        limits: TemplateTransferLimits = .default
    ) throws -> TemplateImportPlan {
        // Complete validation precedes any plan. A malformed final item cannot be
        // partially imported. The immutable plan has no persistence side effects.
        try validate(bundle, limits: limits)
        // Exact duplicates must share a source name. Avoid hashing unrelated
        // historical bodies; keep every existing name below for collision naming.
        let incomingNames = Set(bundle.templates.map(\.name))
        // Materialize the candidates so Set can size itself before hashing bodies.
        let candidates = existing.compactMap { incomingNames.contains($0.name) ? TransferTemplate($0) : nil }
        var seen = Set(candidates)
        var names = Set(existing.map(\.name))
        var additions: [TemplateImportPlan.Item] = []
        var skipped = 0
        for (index, source) in bundle.templates.enumerated() {
            guard seen.insert(source).inserted else { skipped += 1; continue }
            var name = source.name
            if names.contains(name) {
                var suffixNumber = 1
                repeat {
                    let suffix = suffixNumber == 1 ? "（导入）" : "（导入 \(suffixNumber)）"
                    // A long valid name must remain within the exported-name limit
                    // after suffixing. Shorten only the previewed imported name.
                    name = fittingName(source.name, suffix: suffix, maximumBytes: limits.maximumNameBytes)
                    guard !name.isEmpty else {
                        throw TemplateTransferError.fieldTooLarge(
                            index: index, field: "改名后的名称", maximumBytes: limits.maximumNameBytes
                        )
                    }
                    suffixNumber += 1
                } while names.contains(name)
            }
            names.insert(name)
            let template = FileTemplate(name: name, fileExtension: source.fileExtension,
                                        content: source.content, isEnabled: source.isEnabled,
                                        defaultFilename: source.defaultFilename, officeFormat: source.officeFormat)
            additions.append(.init(sourceIndex: index, originalName: source.name, template: template,
                                   usesClipboard: source.usesClipboard))
            // Also recognize an exact copy of a previous item's final, renamed form.
            seen.insert(TransferTemplate(template))
        }
        if !additions.isEmpty {
            // Do not create a newly unexportable collection. Historical over-limit
            // stores remain loadable; an all-skipped preview does not modify them.
            try validateEncodedSize(
                TemplateTransferBundle(templates: existing + additions.map(\.template)), limits: limits
            )
        }
        return TemplateImportPlan(baseline: existing, additions: additions, skippedCount: skipped)
    }

    private static func encodedSizeWithoutValidation(
        _ bundle: TemplateTransferBundle, maximumBytes: Int
    ) throws -> Int {
        var sink = CountingJSONSink(maximumBytes: maximumBytes)
        try TemplateJSONEmission.write(bundle, to: &sink)
        return sink.budget.count
    }

    private static func fittingName(_ name: String, suffix: String, maximumBytes: Int) -> String {
        let suffixBytes = suffix.utf8.count
        guard suffixBytes < maximumBytes else { return "" }
        let budget = maximumBytes - suffixBytes
        var prefix = ""
        var count = 0
        for character in name {
            let next = String(character)
            guard next.utf8.count <= budget - count else { break }
            prefix.append(character)
            count += next.utf8.count
        }
        return prefix.isEmpty ? "" : prefix + suffix
    }

    private static func validate(_ template: TransferTemplate, index: Int, limits: TemplateTransferLimits) throws {
        for (value, field, maximum) in [
            (template.name, "名称", limits.maximumNameBytes),
            (template.defaultFilename, "默认文件名", limits.maximumNameBytes),
            (template.fileExtension, "扩展名", limits.maximumExtensionBytes),
            (template.content, "正文", limits.maximumContentBytes)
        ] {
            guard value.utf8.count <= maximum else {
                throw TemplateTransferError.fieldTooLarge(index: index, field: field, maximumBytes: maximum)
            }
        }
        var draft = TemplateDraft()
        draft.defaultFilename = template.defaultFilename
        draft.name = template.name
        draft.fileExtension = template.fileExtension
        draft.content = template.content
        draft.isEnabled = template.isEnabled
        draft.officeFormat = template.officeFormat
        do { _ = try draft.makeTemplate() }
        catch {
            throw TemplateTransferError.invalidTemplate(index: index, reason: error.localizedDescription)
        }
        // Validate the literal extension too: transfer never silently normalizes it.
        let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        guard template.fileExtension.rangeOfCharacter(from: forbidden) == nil else {
            throw TemplateTransferError.invalidTemplate(
                index: index, reason: TemplateValidationError.invalidExtension.localizedDescription
            )
        }
    }

    private static let limitsKey = CodingUserInfoKey(rawValue: "quickfile.template-transfer-limits")!

    private struct Envelope: Decodable {
        let bundle: TemplateTransferBundle
        enum CodingKeys: String, CodingKey { case format, version, templates }
        init(from decoder: Decoder) throws {
            let limits = decoder.userInfo[TemplateTransfer.limitsKey] as? TemplateTransferLimits ?? .default
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decode(String.self, forKey: .format) == TemplateTransfer.format else {
                throw TemplateTransferError.invalidFormat
            }
            let version = try container.decode(Int.self, forKey: .version)
            guard (1...TemplateTransfer.version).contains(version) else { throw TemplateTransferError.unsupportedVersion(version) }
            var values = try container.nestedUnkeyedContainer(forKey: .templates)
            var templates: [TransferTemplate] = []
            while !values.isAtEnd {
                // Never instantiate more than the allowed number of template values.
                guard templates.count < limits.maximumTemplates else {
                    throw TemplateTransferError.tooManyTemplates(maximum: limits.maximumTemplates)
                }
                let template = try values.decode(TransferTemplate.self)
                guard version != 1 || template.defaultFilename.isEmpty else {
                    throw TemplateTransferError.invalidTemplate(
                        index: templates.count, reason: "默认文件名需要模板文件版本 2。"
                    )
                }
                guard version >= 3 || template.officeFormat == nil else {
                    throw TemplateTransferError.invalidTemplate(
                        index: templates.count, reason: "Office 模板需要模板文件版本 3。"
                    )
                }
                try TemplateTransfer.validate(template, index: templates.count, limits: limits)
                templates.append(template)
            }
            bundle = TemplateTransferBundle(templates: templates)
        }
    }
}

/// Both sinks consume the same emission, so size validation cannot drift from
/// the exported envelope, punctuation, booleans or string escaping.
private protocol TemplateJSONSink {
    mutating func append<Bytes: Collection>(_ bytes: Bytes) throws where Bytes.Element == UInt8
}

private struct JSONByteBudget {
    let maximumBytes: Int
    private(set) var count = 0

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    mutating func consume(_ byteCount: Int) throws {
        // Limits are validated before either sink is created. Subtraction avoids
        // overflowing Int even when callers select a limit close to Int.max.
        guard byteCount <= maximumBytes - count else {
            throw TemplateTransferError.fileTooLarge(maximumBytes: maximumBytes)
        }
        count += byteCount
    }
}

private struct CountingJSONSink: TemplateJSONSink {
    private(set) var budget: JSONByteBudget

    init(maximumBytes: Int) { budget = JSONByteBudget(maximumBytes: maximumBytes) }

    mutating func append<Bytes: Collection>(_ bytes: Bytes) throws where Bytes.Element == UInt8 {
        try budget.consume(bytes.count)
    }
}

/// Only encoded output already accepted by the budget is retained. Small writes
/// share a fixed-size staging buffer, while full runs append directly to Data.
/// In particular, neither plain text nor control-heavy content appends Data once
/// per source byte, and a tiny export never reserves the entire file-size limit.
private struct BoundedJSONDataSink: TemplateJSONSink {
    private var budget: JSONByteBudget
    private var data = Data()
    private var pending: [UInt8] = []

    init(maximumBytes: Int) { budget = JSONByteBudget(maximumBytes: maximumBytes) }

    mutating func append<Bytes: Collection>(_ bytes: Bytes) throws where Bytes.Element == UInt8 {
        let count = bytes.count
        try budget.consume(count)
        if count >= TemplateJSONEmission.maximumRunBytes {
            flush()
            data.append(contentsOf: bytes)
        } else {
            if count > TemplateJSONEmission.maximumRunBytes - pending.count { flush() }
            pending.append(contentsOf: bytes)
        }
    }

    mutating func finish() -> Data {
        flush()
        return data
    }

    private mutating func flush() {
        guard !pending.isEmpty else { return }
        data.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }
}

private enum TemplateJSONEmission {
    static let maximumRunBytes = 16 * 1024
    private static let escapedQuote: [UInt8] = [0x5c, 0x22]
    private static let escapedBackslash: [UInt8] = [0x5c, 0x5c]
    private static let escapedControls: [[UInt8]] = {
        let hex = Array("0123456789abcdef".utf8)
        return (0..<32).map { byte in
            [0x5c, 0x75, 0x30, 0x30, hex[byte >> 4], hex[byte & 0x0f]]
        }
    }()

    static func write<Sink: TemplateJSONSink>(_ bundle: TemplateTransferBundle, to sink: inout Sink) throws {
        let version = bundle.templates.contains { $0.officeFormat != nil } ? TemplateTransfer.version
            : (bundle.templates.contains { !$0.defaultFilename.isEmpty } ? 2 : 1)
        try sink.append("{\"format\":\"quickfile.templates\",\"version\":\(version),\"templates\":[".utf8)
        for (index, template) in bundle.templates.enumerated() {
            if index != 0 { try sink.append(",".utf8) }
            try sink.append("{\"name\":".utf8)
            try appendString(template.name, to: &sink)
            try sink.append(",\"fileExtension\":".utf8)
            try appendString(template.fileExtension, to: &sink)
            try sink.append(",\"content\":".utf8)
            try appendString(template.content, to: &sink)
            if let format = template.officeFormat {
                try sink.append(",\"officeFormat\":".utf8)
                try appendString(format.rawValue, to: &sink)
            }
            if !template.defaultFilename.isEmpty {
                try sink.append(",\"defaultFilename\":".utf8)
                try appendString(template.defaultFilename, to: &sink)
            }
            try sink.append(",\"isEnabled\":".utf8)
            try sink.append((template.isEnabled ? "true}" : "false}").utf8)
        }
        try sink.append("]}".utf8)
    }

    private static func appendString<Sink: TemplateJSONSink>(_ value: String, to sink: inout Sink) throws {
        try sink.append("\"".utf8)
        let bytes = value.utf8
        var runStart = bytes.startIndex
        var index = runStart
        var runCount = 0
        while index != bytes.endIndex {
            let byte = bytes[index]
            if byte < 0x20 || byte == 0x22 || byte == 0x5c {
                if runCount != 0 { try sink.append(bytes[runStart..<index]) }
                switch byte {
                case 0x22: try sink.append(escapedQuote)
                case 0x5c: try sink.append(escapedBackslash)
                default: try sink.append(escapedControls[Int(byte)])
                }
                bytes.formIndex(after: &index)
                runStart = index
                runCount = 0
            } else {
                bytes.formIndex(after: &index)
                runCount += 1
                if runCount == maximumRunBytes {
                    try sink.append(bytes[runStart..<index])
                    runStart = index
                    runCount = 0
                }
            }
        }
        if runCount != 0 { try sink.append(bytes[runStart..<index]) }
        try sink.append("\"".utf8)
    }
}
