import XCTest
@testable import QuickFileApplication
@testable import QuickFileCore
@testable import QuickFileInfrastructure

final class FinderAuthorizationCoordinatorTests: XCTestCase {

    func testAuthorizationContinuationUsesTemplateDefaultFilename() throws {
        let destination = try makeTemporaryDirectory()
        let template = FileTemplate(name: "A", fileExtension: "md", content: "body", defaultFilename: "续办.md")
        let coordinator = FinderAuthorizationCoordinator(
            loadTemplates: { [template] },
            authorizeDirectory: { _ in UUID() },
            performWithAccess: { _, _, operation in try operation() },
            createFile: { try FileCreationService().createFile(for: $0) }
        )
        let completion = try coordinator.complete(
            .init(templateID: template.id, destinationFolder: destination), authorizedDirectory: destination
        )
        XCTAssertEqual(completion.creationResult.fileURL.lastPathComponent, "续办.md")
        XCTAssertEqual(try String(contentsOf: completion.creationResult.fileURL, encoding: .utf8), "body")
    }

    func testCompletesAuthorizationAndOriginalCreationRequest() throws {
        let template = FileTemplate(name: "Markdown", fileExtension: "md", content: "# Title")
        let authorizedDirectory = try makeTemporaryDirectory()
        let destinationFolder = authorizedDirectory.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: false)
        let expectedResult = FileCreationResult(
            fileURL: destinationFolder.appendingPathComponent("Untitled.md"),
            didRenameForConflict: false
        )
        let authorizationID = UUID()
        let authorizedURL = LockedTestValue<URL?>(nil)
        let accessedURL = LockedTestValue<URL?>(nil)
        let createdRequest = LockedTestValue<FileCreationRequest?>(nil)

        let coordinator = FinderAuthorizationCoordinator(
            loadTemplates: { [template] },
            authorizeDirectory: { authorizedURL.value = $0; return authorizationID },
            performWithAccess: { url, grantID, operation in
                XCTAssertEqual(grantID, authorizationID)
                accessedURL.value = url
                return try operation()
            },
            createFile: { request in
                createdRequest.value = request
                return expectedResult
            }
        )

        let completion = try coordinator.complete(
            FinderAuthorizationRequest(
                templateID: template.id,
                destinationFolder: destinationFolder
            ),
            authorizedDirectory: authorizedDirectory,
            clipboard: "captured"
        )

        XCTAssertEqual(authorizedURL.value, authorizedDirectory.standardizedFileURL)
        XCTAssertEqual(accessedURL.value, destinationFolder.standardizedFileURL)
        XCTAssertEqual(createdRequest.value?.template, template)
        XCTAssertEqual(createdRequest.value?.destinationFolder, destinationFolder.standardizedFileURL)
        XCTAssertNil(createdRequest.value?.requestedFilename)
        XCTAssertEqual(createdRequest.value?.clipboard, "captured")
        XCTAssertEqual(createdRequest.value?.expectedDirectoryIdentity, try DirectoryIdentity.capture(at: destinationFolder))
        XCTAssertEqual(completion.templates, [template])
        XCTAssertEqual(completion.selectedTemplateID, template.id)
        XCTAssertEqual(completion.destinationFolder, destinationFolder.standardizedFileURL)
        XCTAssertEqual(completion.creationResult, expectedResult)
        XCTAssertEqual(completion.authorizationID, authorizationID)
        XCTAssertEqual(completion.destinationIdentity, try DirectoryIdentity.capture(at: destinationFolder))
    }

    func testFirstAuthorizationUsesOriginalPanelScopeUntilCompletion() throws {
        let root = try makeTemporaryDirectory()
        let target = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        // Keep a nonstandardized URL to prove scope calls use the panel's original value.
        let selectedDirectory = target.appendingPathComponent("..", isDirectory: true)
        XCTAssertNotEqual(selectedDirectory, selectedDirectory.standardizedFileURL)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "expected")
        let request = FinderAuthorizationRequest(templateID: template.id, destinationFolder: target)
        let isAccessing = LockedTestValue(false)
        let didAuthorize = LockedTestValue(false)
        let events = LockedTestValue<[String]>([])
        let coordinator = FinderAuthorizationCoordinator(
            loadTemplates: {
                XCTAssertTrue(isAccessing.value)
                events.update { $0.append("load") }
                return [template]
            },
            authorizeDirectory: { url in
                XCTAssertTrue(isAccessing.value)
                XCTAssertEqual(url, selectedDirectory.standardizedFileURL)
                didAuthorize.value = true
                events.update { $0.append("authorize") }
                return UUID()
            },
            performWithAccess: { _, _, operation in
                // First authorization must be persisted before the saved-grant access path.
                XCTAssertTrue(didAuthorize.value)
                events.update { $0.append("stored-access") }
                return try operation()
            },
            createFile: {
                XCTAssertTrue(isAccessing.value)
                events.update { $0.append("create") }
                return try FileCreationService().createFile(for: $0)
            },
            startAccessing: { url in
                XCTAssertEqual(url, selectedDirectory)
                XCTAssertFalse(isAccessing.value)
                isAccessing.value = true
                events.update { $0.append("start") }
                return true
            },
            stopAccessing: { url in
                XCTAssertEqual(url, selectedDirectory)
                XCTAssertTrue(isAccessing.value)
                isAccessing.value = false
                events.update { $0.append("stop") }
            }
        )

        let result = try coordinator.complete(request, authorizedDirectory: selectedDirectory)

        XCTAssertEqual(try String(contentsOf: result.creationResult.fileURL), "expected")
        XCTAssertEqual(events.value, ["start", "load", "authorize", "stored-access", "create", "stop"])
        XCTAssertFalse(isAccessing.value)
    }

    func testImplicitPanelAccessCanCompleteWithoutExplicitScopeStart() throws {
        let root = try makeTemporaryDirectory()
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "expected")
        let request = FinderAuthorizationRequest(templateID: template.id, destinationFolder: root)
        let didAuthorize = LockedTestValue(false)
        let startCount = LockedTestValue(0)
        let coordinator = FinderAuthorizationCoordinator(
            loadTemplates: { [template] },
            authorizeDirectory: { _ in didAuthorize.value = true; return UUID() },
            performWithAccess: { _, _, operation in
                XCTAssertTrue(didAuthorize.value)
                return try operation()
            },
            createFile: { try FileCreationService().createFile(for: $0) },
            startAccessing: { _ in
                startCount.update { $0 += 1 }
                // A panel-granted or otherwise already-accessible URL need not start a scope.
                return false
            },
            stopAccessing: { _ in XCTFail("Must not stop a scope that did not start") }
        )

        let result = try coordinator.complete(request, authorizedDirectory: root)

        XCTAssertEqual(startCount.value, 1)
        XCTAssertTrue(didAuthorize.value)
        XCTAssertEqual(try String(contentsOf: result.creationResult.fileURL), "expected")
    }

    func testStopsPanelScopeWhenAuthorizationThrows() throws {
        let root = try makeTemporaryDirectory()
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "")
        let request = FinderAuthorizationRequest(templateID: template.id, destinationFolder: root)
        let failure = NSError(domain: "QuickFileTests.Authorization", code: 1)
        let isAccessing = LockedTestValue(false)
        let stopCount = LockedTestValue(0)
        let coordinator = FinderAuthorizationCoordinator(
            loadTemplates: { [template] },
            authorizeDirectory: { _ in
                XCTAssertTrue(isAccessing.value)
                throw failure
            },
            performWithAccess: { _, _, operation in
                XCTFail("Must not access a grant after authorization failed")
                return try operation()
            },
            createFile: { try FileCreationService().createFile(for: $0) },
            startAccessing: { _ in isAccessing.value = true; return true },
            stopAccessing: { _ in isAccessing.value = false; stopCount.update { $0 += 1 } }
        )

        XCTAssertThrowsError(try coordinator.complete(request, authorizedDirectory: root)) { error in
            XCTAssertEqual(error as NSError, failure)
        }
        XCTAssertFalse(isAccessing.value)
        XCTAssertEqual(stopCount.value, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testRejectsAuthorizationOutsideRequestedDestinationBeforePersisting() {
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "")
        let didAuthorize = LockedTestValue(false)
        let coordinator = FinderAuthorizationCoordinator(
            loadTemplates: { [template] },
            authorizeDirectory: { _ in didAuthorize.value = true; return UUID() },
            performWithAccess: { _, _, operation in try operation() },
            createFile: { request in
                FileCreationResult(
                    fileURL: request.destinationFolder.appendingPathComponent("Untitled.txt"),
                    didRenameForConflict: false
                )
            }
        )

        XCTAssertThrowsError(
            try coordinator.complete(
                FinderAuthorizationRequest(
                    templateID: template.id,
                    destinationFolder: URL(
                        fileURLWithPath: "/Users/example/Documents",
                        isDirectory: true
                    )
                ),
                authorizedDirectory: URL(
                    fileURLWithPath: "/Users/example/Desktop",
                    isDirectory: true
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? FinderAuthorizationCompletionError,
                .authorizedDirectoryDoesNotContainDestination
            )
        }
        XCTAssertFalse(didAuthorize.value)
    }

    func testRejectsDisabledTemplateBeforePersistingAuthorization() {
        let template = FileTemplate(
            name: "Disabled",
            fileExtension: "txt",
            content: "",
            isEnabled: false
        )
        let didAuthorize = LockedTestValue(false)
        let directory = URL(fileURLWithPath: "/Users/example/Documents", isDirectory: true)
        let coordinator = FinderAuthorizationCoordinator(
            loadTemplates: { [template] },
            authorizeDirectory: { _ in didAuthorize.value = true; return UUID() },
            performWithAccess: { _, _, operation in try operation() },
            createFile: { request in
                FileCreationResult(
                    fileURL: request.destinationFolder.appendingPathComponent("Untitled.txt"),
                    didRenameForConflict: false
                )
            }
        )

        XCTAssertThrowsError(
            try coordinator.complete(
                FinderAuthorizationRequest(
                    templateID: template.id,
                    destinationFolder: directory
                ),
                authorizedDirectory: directory
            )
        ) { error in
            XCTAssertEqual(error as? FinderAuthorizationCompletionError, .templateUnavailable)
        }
        XCTAssertFalse(didAuthorize.value)
    }

    func testRejectsTargetReplacedDuringAuthorizationWaitBeforePersistingGrant() throws {
        for replacement in ["directory", "symlink", "missing"] {
            let root = try makeTemporaryDirectory()
            let target = root.appendingPathComponent("A")
            let original = root.appendingPathComponent("A-old")
            let other = root.appendingPathComponent("B")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            let template = FileTemplate(name: "Text", fileExtension: "txt", content: "expected")
            let request = FinderAuthorizationRequest(templateID: template.id, destinationFolder: target)
            XCTAssertNotNil(request.destinationIdentity)
            try FileManager.default.moveItem(at: target, to: original)
            if replacement == "directory" {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            } else if replacement == "symlink" {
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
            }
            let didAuthorize = LockedTestValue(false)
            let didCreate = LockedTestValue(false)
            let isAccessing = LockedTestValue(false)
            let stopCount = LockedTestValue(0)
            let coordinator = FinderAuthorizationCoordinator(
                loadTemplates: {
                    XCTAssertTrue(isAccessing.value)
                    return [template]
                },
                authorizeDirectory: { _ in didAuthorize.value = true; return UUID() },
                performWithAccess: { _, _, operation in try operation() },
                createFile: { request in
                    didCreate.value = true
                    return try FileCreationService().createFile(for: request)
                },
                startAccessing: { _ in isAccessing.value = true; return true },
                stopAccessing: { _ in isAccessing.value = false; stopCount.update { $0 += 1 } }
            )

            XCTAssertThrowsError(try coordinator.complete(request, authorizedDirectory: root)) { error in
                guard case FileCreationError.destinationIdentityChanged = error else {
                    return XCTFail("Expected changed-directory rejection, got \(error)")
                }
            }
            XCTAssertFalse(didAuthorize.value, replacement)
            XCTAssertFalse(didCreate.value, replacement)
            XCTAssertFalse(isAccessing.value, replacement)
            XCTAssertEqual(stopCount.value, 1, replacement)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: original.path).isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
            if replacement == "directory" {
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
            }
        }
    }

    func testRetainsIdentityCheckAfterAuthorizationPersistence() throws {
        let root = try makeTemporaryDirectory()
        let target = root.appendingPathComponent("A", isDirectory: true)
        let moved = root.appendingPathComponent("A-old", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "expected")
        let request = FinderAuthorizationRequest(templateID: template.id, destinationFolder: target)
        let didAuthorize = LockedTestValue(false)
        let didCreate = LockedTestValue(false)
        let coordinator = FinderAuthorizationCoordinator(
            loadTemplates: { [template] },
            authorizeDirectory: { _ in
                // Prevalidation is not an atomic filesystem/grant transaction. A later
                // replacement must still be rejected without rolling back concurrent grants.
                didAuthorize.value = true
                try FileManager.default.moveItem(at: target, to: moved)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                return UUID()
            },
            performWithAccess: { _, _, operation in try operation() },
            createFile: {
                didCreate.value = true
                return try FileCreationService().createFile(for: $0)
            }
        )

        XCTAssertThrowsError(try coordinator.complete(request, authorizedDirectory: root)) { error in
            guard case FileCreationError.destinationIdentityChanged = error else {
                return XCTFail("Expected post-authorization identity rejection, got \(error)")
            }
        }
        XCTAssertTrue(didAuthorize.value)
        XCTAssertFalse(didCreate.value)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    func testFinalOpenedDirectoryMustStillMatchAfterCoordinatorValidation() throws {
        let root = try makeTemporaryDirectory()
        let target = root.appendingPathComponent("A")
        let moved = root.appendingPathComponent("A-old")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "expected")
        let request = FinderAuthorizationRequest(templateID: template.id, destinationFolder: target)
        let coordinator = FinderAuthorizationCoordinator(
            loadTemplates: { [template] }, authorizeDirectory: { _ in UUID() },
            performWithAccess: { _, _, operation in try operation() },
            createFile: { creationRequest in
                // The path changes after the coordinator check but before the service opens it.
                try FileManager.default.moveItem(at: target, to: moved)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                return try FileCreationService().createFile(for: creationRequest)
            }
        )
        XCTAssertThrowsError(try coordinator.complete(request, authorizedDirectory: root)) { error in
            guard case FileCreationError.destinationIdentityChanged = error else {
                return XCTFail("Expected final-handle identity rejection, got \(error)")
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    func testLegacyPathOnlyRequestCannotAdoptCurrentDirectory() throws {
        let root = try makeTemporaryDirectory()
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "")
        let request = FinderAuthorizationRequest(templateID: template.id, destinationFolder: root)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        payload.removeValue(forKey: "destinationIdentity")
        let legacy = try JSONDecoder().decode(FinderAuthorizationRequest.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertNil(legacy.destinationIdentity)
        let didAuthorize = LockedTestValue(false)
        let coordinator = FinderAuthorizationCoordinator(
            loadTemplates: { [template] }, authorizeDirectory: { _ in didAuthorize.value = true; return UUID() },
            performWithAccess: { _, _, operation in try operation() },
            createFile: { try FileCreationService().createFile(for: $0) }
        )
        XCTAssertThrowsError(try coordinator.complete(legacy, authorizedDirectory: root)) { error in
            guard case FileCreationError.destinationIdentityChanged = error else {
                return XCTFail("Expected unidentifiable target rejection, got \(error)")
            }
        }
        XCTAssertFalse(didAuthorize.value)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testUnrelatedDirectoryContentsDoNotInvalidateIdentity() throws {
        let root = try makeTemporaryDirectory()
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "expected")
        let request = FinderAuthorizationRequest(templateID: template.id, destinationFolder: root)
        try Data("existing".utf8).write(to: root.appendingPathComponent("existing.txt"))
        let coordinator = FinderAuthorizationCoordinator(
            loadTemplates: { [template] }, authorizeDirectory: { _ in UUID() },
            performWithAccess: { _, _, operation in try operation() },
            createFile: { try FileCreationService().createFile(for: $0) }
        )
        let result = try coordinator.complete(request, authorizedDirectory: root)
        XCTAssertEqual(try String(contentsOf: result.creationResult.fileURL), "expected")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("existing.txt")), "existing")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickFile-Identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
