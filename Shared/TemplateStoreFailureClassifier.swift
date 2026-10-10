import Foundation
import QuickFileCore

public enum TemplateStoreFailureClassifier {
    public static func activityFailure(_ error: Error) -> FinderExtensionActivityFailure? {
        guard let error = error as? TemplateStore.StoreError else { return nil }
        let reason: FinderExtensionFailureReason
        let underlying: Error?
        switch error {
        case let .readFailed(cause):
            reason = .templateReadFailed
            underlying = cause
        case .savedConfigurationMissing:
            reason = .templateReadFailed
            underlying = nil
        case .sharedDefaultsUnavailable:
            reason = .templateStorageUnavailable
            underlying = nil
        case let .persistenceFailed(cause):
            reason = .templateWriteFailed
            underlying = cause
        case .configurationChanged:
            reason = .templateUnavailable
            underlying = nil
        }
        let systemError = underlying as NSError?
        return FinderExtensionActivityFailure(
            reason: reason, errorDomain: systemError?.domain, errorCode: systemError?.code
        )
    }
}
