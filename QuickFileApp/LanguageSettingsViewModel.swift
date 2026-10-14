import Combine
import Foundation
import QuickFileCore
import QuickFileInfrastructure

@MainActor
final class LanguageSettingsViewModel: ObservableObject {
    @Published private(set) var language: QuickFileLanguage = .system
    @Published private(set) var isBusy = false
    @Published private(set) var hasLoaded = false
    var errorMessage: String? { failure?.localizedDescription }
    @Published private var failure: Error?
    var locale: Locale { Locale(identifier: language.resolvedIdentifier()) }
    private let load: @Sendable () throws -> QuickFileLanguage
    private let save: @Sendable (QuickFileLanguage) throws -> Void

    init(load: @escaping @Sendable () throws -> QuickFileLanguage = { try LanguageSettingsStore().load() },
         save: @escaping @Sendable (QuickFileLanguage) throws -> Void = { try LanguageSettingsStore().save($0) }) {
        self.load = load
        self.save = save
    }

    func reload() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false; hasLoaded = true }
        let load = load
        switch await BackgroundWork.result({ try load() }) {
        case let .success(value):
            QuickFileLocalization.apply(value)
            language = value
            failure = nil
        case let .failure(error):
            failure = error
        }
    }

    func select(_ value: QuickFileLanguage) async {
        guard !isBusy, hasLoaded else { return }
        isBusy = true
        defer { isBusy = false }
        let save = save
        switch await BackgroundWork.result({ try save(value) }) {
        case .success:
            QuickFileLocalization.apply(value)
            language = value
            failure = nil
        case let .failure(error):
            failure = error
        }
    }
}
