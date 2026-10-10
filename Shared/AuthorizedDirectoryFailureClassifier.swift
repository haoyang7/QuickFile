import Foundation
import QuickFileCore

public enum AuthorizedDirectoryFailureClassifier {
    public static func requiresAuthorization(_ error: Error) -> Bool {
        guard let authorizationError = error as? AuthorizedDirectoryStore.StoreError else {
            return false
        }

        switch authorizationError {
        case .directoryNotAuthorized,
             .bookmarkResolutionFailed,
             .securityScopeUnavailable:
            return true
        case .sharedDefaultsUnavailable,
             .directoryIsNotFileURL,
             .directoryDoesNotExist,
             .directoryIsNotDirectory,
             .bookmarkCreationFailed,
             .authorizationResolutionFailed,
             .bookmarkRefreshFailed,
             .authorizationChanged,
             .persistenceFailed:
            return false
        }
    }

    public static func activityFailure(_ error: Error) -> FinderExtensionActivityFailure? {
        guard let authorizationError = error as? AuthorizedDirectoryStore.StoreError else {
            return nil
        }

        let reason: FinderExtensionFailureReason
        switch authorizationError {
        case .directoryNotAuthorized:
            reason = .directoryNotAuthorized
        case .sharedDefaultsUnavailable,
             .directoryIsNotFileURL,
             .directoryDoesNotExist,
             .directoryIsNotDirectory,
             .bookmarkCreationFailed,
             .bookmarkResolutionFailed,
             .authorizationResolutionFailed,
             .bookmarkRefreshFailed,
             .authorizationChanged,
             .persistenceFailed,
             .securityScopeUnavailable:
            reason = .authorizationUnavailable
        }

        guard let underlyingError = authorizationError.underlyingError else {
            return FinderExtensionActivityFailure(
                reason: reason,
                errorDomain: nil,
                errorCode: nil
            )
        }

        let nsError = underlyingError as NSError
        return FinderExtensionActivityFailure(
            reason: reason,
            errorDomain: nsError.domain,
            errorCode: nsError.code
        )
    }
}
