import XCTest
@testable import QuickFileApplication
@testable import QuickFileCore
@testable import QuickFileInfrastructure

final class FinderExtensionFailureClassifierTests: XCTestCase {
    func testKeepsMenuAndAuthorizationFailuresDistinct() {
        let classifier = FinderExtensionFailureClassifier(
            authorizationFailureClassifier: AuthorizedDirectoryFailureClassifier.activityFailure
        )

        XCTAssertEqual(classifier.classify(FinderFileCreationError.operationInProgress).reason, .operationInProgress)
        XCTAssertFalse(AuthorizedDirectoryFailureClassifier.requiresAuthorization(FinderFileCreationError.operationInProgress))

        XCTAssertEqual(
            classifier.classify(FinderFileCreationError.menuContextUnavailable).reason,
            .menuContextUnavailable
        )
        XCTAssertEqual(
            classifier.classify(FinderFileCreationError.templateUnavailable).reason,
            .templateUnavailable
        )
        XCTAssertEqual(
            classifier.classify(AuthorizedDirectoryStore.StoreError.directoryNotAuthorized).reason,
            .directoryNotAuthorized
        )
        XCTAssertEqual(
            classifier.classify(
                FinderFileCreationError.directoryAuthorizationRequired(
                    templateID: UUID(),
                    destinationFolder: URL(fileURLWithPath: "/tmp", isDirectory: true)
                )
            ).reason,
            .directoryNotAuthorized
        )
    }

    func testRecognizesNestedPermissionError() {
        let underlyingError = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.EACCES.rawValue)
        )
        let wrappingError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: underlyingError]
        )

        let failure = FinderExtensionFailureClassifier().classify(wrappingError)

        XCTAssertEqual(failure.reason, .permissionDenied)
        XCTAssertEqual(failure.errorDomain, NSCocoaErrorDomain)
        XCTAssertEqual(failure.errorCode, NSFileWriteUnknownError)
    }

    func testTemplateStorageFailuresKeepReadAndWriteCausesDistinct() {
        let classifier = FinderExtensionFailureClassifier(
            templateFailureClassifier: TemplateStoreFailureClassifier.activityFailure
        )
        let readError = CocoaError(.fileReadNoPermission)
        let read = classifier.classify(TemplateStore.StoreError.readFailed(readError))
        XCTAssertEqual(read.reason, .templateReadFailed)
        XCTAssertEqual(read.errorDomain, NSCocoaErrorDomain)
        XCTAssertEqual(read.errorCode, NSFileReadNoPermissionError)
        XCTAssertEqual(classifier.classify(TemplateStore.StoreError.savedConfigurationMissing).reason, .templateReadFailed)
        XCTAssertEqual(classifier.classify(TemplateStore.StoreError.sharedDefaultsUnavailable).reason, .templateStorageUnavailable)
        let write = classifier.classify(TemplateStore.StoreError.persistenceFailed(CocoaError(.fileWriteNoPermission)))
        XCTAssertEqual(write.reason, .templateWriteFailed)
        XCTAssertEqual(write.errorCode, NSFileWriteNoPermissionError)
    }

    func testCommittedFileWithUnknownLocationIsNotClassifiedAsWriteFailure() {
        let error = FileCreationError.createdFileLocationUnavailable(
            filename: "created.txt", underlyingError: POSIXError(.ENOENT)
        )
        let failure = FinderExtensionFailureClassifier().classify(error)
        XCTAssertEqual(failure.reason, .createdFileLocationUnavailable)
        XCTAssertEqual(failure.errorDomain, NSPOSIXErrorDomain)
        XCTAssertEqual(failure.errorCode, Int(ENOENT))
        XCTAssertTrue(error.localizedDescription.contains("已"))
    }

    func testChangedDirectoryIsNotAnAuthorizationRetryOrWriteSuccess() {
        let error = FileCreationError.destinationIdentityChanged
        XCTAssertEqual(FinderExtensionFailureClassifier().classify(error).reason, .destinationUnavailable)
        XCTAssertFalse(AuthorizedDirectoryFailureClassifier.requiresAuthorization(error))
        XCTAssertTrue(error.localizedDescription.contains("未创建"))
    }

    func testOversizedRenderingIsDistinctAndDoesNotRequestAuthorization() throws {
        let error = FileCreationError.renderedContentTooLarge(maximumUTF8Bytes: 8)
        let failure = FinderExtensionFailureClassifier().classify(error)

        XCTAssertEqual(failure.reason, .renderedContentTooLarge)
        XCTAssertNil(failure.errorDomain)
        XCTAssertNil(failure.errorCode)
        XCTAssertFalse(AuthorizedDirectoryFailureClassifier.requiresAuthorization(error))
        XCTAssertTrue(error.localizedDescription.contains("8 字节"))
        XCTAssertTrue(error.localizedDescription.contains("UTF-8"))
        XCTAssertTrue(error.localizedDescription.contains("未创建文件"))
        XCTAssertTrue(failure.reason.displayName.contains("未创建文件"))
        let encoded = try JSONEncoder().encode(failure)
        XCTAssertEqual(try JSONDecoder().decode(FinderExtensionActivityFailure.self, from: encoded), failure)
    }
}
