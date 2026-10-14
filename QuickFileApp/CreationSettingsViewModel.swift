import Combine
import Foundation
import QuickFileInfrastructure

@MainActor
final class CreationSettingsViewModel: ObservableObject {
    @Published private(set) var automaticallyOpen = false
    @Published private(set) var isBusy = false
    @Published private(set) var hasLoaded = false
    var errorMessage: String? { failure?.localizedDescription }
    @Published private var failure: Error?
    private let load: @Sendable () throws -> Bool
    private let save: @Sendable (Bool) throws -> Void

    init(
        load: @escaping @Sendable () throws -> Bool = { try FileCreationSettingsStore().loadAutomaticallyOpen() },
        save: @escaping @Sendable (Bool) throws -> Void = { try FileCreationSettingsStore().saveAutomaticallyOpen($0) }
    ) {
        self.load = load
        self.save = save
    }

    func reload() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let load = load
        switch await BackgroundWork.result({ try load() }) {
        case let .success(value):
            automaticallyOpen = value
            hasLoaded = true
            failure = nil
        case let .failure(error):
            automaticallyOpen = false
            failure = error
        }
    }

    func setAutomaticallyOpen(_ value: Bool) async {
        guard !isBusy, hasLoaded || errorMessage != nil else { return }
        isBusy = true
        defer { isBusy = false }
        let save = save
        switch await BackgroundWork.result({ try save(value) }) {
        case .success:
            automaticallyOpen = value
            hasLoaded = true
            failure = nil
        case let .failure(error):
            failure = error
        }
    }
}
