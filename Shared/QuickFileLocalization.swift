import Foundation
import os

/// Available choices come from the host's shipped .lproj resources. Adding a
/// translation does not require another enum case, picker item or Finder cache.
public struct QuickFileLanguage: RawRepresentable, Codable, Hashable, CaseIterable, Sendable {
    public let rawValue: String
    public static let system = Self(unchecked: "system")
    public static let simplifiedChinese = Self(unchecked: "zh-Hans")
    public static let english = Self(unchecked: "en")
    public static let supportedIdentifiers = Bundle.main.localizations.filter { $0 != "Base" }.sorted()
    public static var allCases: [Self] { [.system] + supportedIdentifiers.map { Self(unchecked: $0) } }

    private init(unchecked: String) { rawValue = unchecked }

    public init?(rawValue: String) {
        guard rawValue == "system" || Self.supportedIdentifiers.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let identifier = try container.decode(String.self)
        guard let language = Self(rawValue: identifier) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported language")
        }
        self = language
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Autonyms stay recognizable even if the user cannot read the selected language.
    public var nativeName: String {
        Locale(identifier: rawValue).localizedString(forIdentifier: rawValue) ?? rawValue
    }

    public func resolvedIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if self != .system { return rawValue }
        return Bundle.preferredLocalizations(from: Self.supportedIdentifiers, forPreferences: preferredLanguages).first
            ?? Bundle.main.developmentLocalization ?? "zh-Hans"
    }
}

/// The hosts publish a language after a background settings read. Text lookup
/// reads only this in-memory snapshot, never the shared settings file.
public enum QuickFileLocalization {
    private static let bundles = Dictionary(uniqueKeysWithValues: QuickFileLanguage.supportedIdentifiers.map {
        ($0, resourceBundle(for: $0))
    })
    private struct Selection {
        let identifier: String
        let bundle: Bundle
        let locale: Locale
    }
    private static let selection = OSAllocatedUnfairLock(initialState: Selection(
        identifier: QuickFileLanguage.system.resolvedIdentifier(),
        bundle: bundles[QuickFileLanguage.system.resolvedIdentifier()]!,
        locale: Locale(identifier: QuickFileLanguage.system.resolvedIdentifier())
    ))

    public static var identifier: String { selection.withLock { $0.identifier } }
    public static var bundle: Bundle { selection.withLock { $0.bundle } }
    public static var locale: Locale { selection.withLock { $0.locale } }

    /// Resolve a native resource at display time. Its arguments remain values;
    /// no caller has to cache a translated String or supply a bundle/locale pair.
    /// Use `.init("…", comment: "…")` at the call site for Xcode extraction.
    public static func text(_ resource: LocalizedStringResource) -> String {
        var localized = resource
        localized.locale = locale
        return String(localized: localized)
    }

    public static func prepareResources() { _ = bundles }

    public static func resourceBundle(for identifier: String, in host: Bundle = .main) -> Bundle {
        host.path(forResource: identifier, ofType: "lproj").flatMap(Bundle.init(path:)) ?? host
    }

    public static func apply(_ language: QuickFileLanguage) {
        let identifier = language.resolvedIdentifier()
        let bundle = bundles[identifier]!
        selection.withLock { $0 = Selection(identifier: identifier, bundle: bundle, locale: Locale(identifier: identifier)) }
    }
}
