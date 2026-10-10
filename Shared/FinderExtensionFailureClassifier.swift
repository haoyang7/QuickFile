import Foundation
import QuickFileCore

public struct FinderExtensionFailureClassifier {
    public typealias AuthorizationFailureClassifier = (Error) -> FinderExtensionActivityFailure?

    private let authorizationFailureClassifier: AuthorizationFailureClassifier
    private let templateFailureClassifier: AuthorizationFailureClassifier

    public init(
        authorizationFailureClassifier: @escaping AuthorizationFailureClassifier = { _ in nil },
        templateFailureClassifier: @escaping AuthorizationFailureClassifier = { _ in nil }
    ) {
        self.authorizationFailureClassifier = authorizationFailureClassifier
        self.templateFailureClassifier = templateFailureClassifier
    }

    public func classify(_ error: Error) -> FinderExtensionActivityFailure {
        if let templateFailure = templateFailureClassifier(error) {
            return templateFailure
        }
        if let menuError = error as? FinderFileCreationError {
            switch menuError {
            case .menuContextUnavailable:
                return failure(reason: .menuContextUnavailable)
            case .templateUnavailable:
                return failure(reason: .templateUnavailable)
            case .destinationUnavailable:
                return failure(reason: .destinationUnavailable)
            case .operationInProgress:
                return failure(reason: .operationInProgress)
            case .directoryAuthorizationRequired:
                return failure(reason: .directoryNotAuthorized)
            }
        }

        if let creationError = error as? FileCreationError {
            switch creationError {
            case .destinationIsNotFileURL, .destinationIsNotDirectory, .destinationIdentityChanged:
                return failure(reason: .destinationUnavailable)
            case .destinationDoesNotExist:
                return failure(reason: .destinationMissing)
            case .invalidFilename:
                return failure(reason: .invalidFilename)
            case .conflictLimitReached:
                return failure(reason: .conflictLimitReached)
            case .renderedContentTooLarge:
                return failure(reason: .renderedContentTooLarge)
            case let .writeFailed(_, underlyingError):
                return writeFailure(for: underlyingError)
            case let .createdFileLocationUnavailable(_, underlyingError):
                let systemError = underlyingError as NSError
                return failure(
                    reason: .createdFileLocationUnavailable,
                    errorDomain: systemError.domain,
                    errorCode: systemError.code
                )
            }
        }

        if let authorizationFailure = authorizationFailureClassifier(error) {
            return authorizationFailure
        }

        return writeFailure(for: error)
    }

    private func writeFailure(for error: Error) -> FinderExtensionActivityFailure {
        let nsError = error as NSError
        let reason: FinderExtensionFailureReason

        if errorChainContains(
            nsError,
            domain: NSCocoaErrorDomain,
            codes: [NSFileWriteNoPermissionError, NSFileReadNoPermissionError]
        ) || errorChainContains(
            nsError,
            domain: NSPOSIXErrorDomain,
            codes: [
                Int(POSIXErrorCode.EPERM.rawValue),
                Int(POSIXErrorCode.EACCES.rawValue)
            ]
        ) {
            reason = .permissionDenied
        } else if errorChainContains(
            nsError,
            domain: NSCocoaErrorDomain,
            codes: [NSFileWriteVolumeReadOnlyError]
        ) || errorChainContains(
            nsError,
            domain: NSPOSIXErrorDomain,
            codes: [Int(POSIXErrorCode.EROFS.rawValue)]
        ) {
            reason = .readOnlyVolume
        } else {
            reason = .writeFailed
        }

        return failure(
            reason: reason,
            errorDomain: nsError.domain,
            errorCode: nsError.code
        )
    }

    private func errorChainContains(
        _ error: NSError,
        domain: String,
        codes: Set<Int>
    ) -> Bool {
        var currentError: NSError? = error
        var visitedErrors = Set<ObjectIdentifier>()

        while let current = currentError {
            guard visitedErrors.insert(ObjectIdentifier(current)).inserted else {
                return false
            }
            if current.domain == domain, codes.contains(current.code) {
                return true
            }
            currentError = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }

        return false
    }

    private func failure(
        reason: FinderExtensionFailureReason,
        errorDomain: String? = nil,
        errorCode: Int? = nil
    ) -> FinderExtensionActivityFailure {
        FinderExtensionActivityFailure(
            reason: reason,
            errorDomain: errorDomain,
            errorCode: errorCode
        )
    }
}
