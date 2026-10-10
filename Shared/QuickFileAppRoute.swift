import Foundation

/// Navigation only. These URLs never carry a directory, template, authorization,
/// content, or a command to create a file. The receiving app must still obtain
/// user input and use its normal validation for every operation.
public enum QuickFileAppRoute: String, CaseIterable, Equatable, Sendable {
    case create, templates, diagnostics

    public static let scheme = "quickfile"
    public static let host = "open"
    public static let maximumURLBytes = 64
    public static var externalEventIdentifiers: Set<String> {
        Set(allCases.map { $0.url.absoluteString })
    }

    public var url: URL {
        // All components come from the fixed enum above, never external input.
        URL(string: "\(Self.scheme)://\(Self.host)/\(rawValue)")!
    }

    public init?(url: URL) {
        let text = url.absoluteString
        guard text.utf8.prefix(Self.maximumURLBytes + 1).count <= Self.maximumURLBytes,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.scheme,
              components.host == Self.host,
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let route = Self.allCases.first(where: { $0.url.absoluteString == text }) else {
            return nil
        }
        self = route
    }

    public var menuTitle: String {
        switch self {
        case .create: return "在 QuickFile 中创建…"
        case .templates: return "打开模板管理…"
        case .diagnostics: return "打开权限与诊断…"
        }
    }

    public var recoveryTitle: String {
        self == .create ? "打开 QuickFile…" : menuTitle
    }
}
