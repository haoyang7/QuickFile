import XCTest
import Darwin
@testable import QuickFileApplication
@testable import QuickFileCore
@testable import QuickFileInfrastructure

final class FinderFileCreationCoordinatorTests: XCTestCase {

    func testFinderCreationUsesAuthoritativeDefaultFilenameAndDoesNotOverwrite() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let template = FileTemplate(name: "A", fileExtension: "", content: "new", defaultFilename: ".env")
        try Data("existing".utf8).write(to: destination.appendingPathComponent(".env"))
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in template },
            performWithAccess: { _, operation in try operation() },
            createFile: { try FileCreationService().createFile(for: $0) },
            requiresAuthorization: { _ in false }
        )
        let result = try coordinator.createFile(for: .init(
            templateID: template.id, context: .container, destinationFolder: destination,
            destinationIdentity: DirectoryIdentity.capture(at: destination)
        ))
        XCTAssertEqual(result.fileURL.lastPathComponent, ".env 2")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(".env"), encoding: .utf8), "existing")
    }

    private enum TestError: Error, Equatable {
        case writeFailed
    }

    func testSelectedLoaderReceivesActionIDAndCannotSubstituteAnotherOrDisabledTemplate() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let wanted = FileTemplate(name: "Wanted", fileExtension: "txt", content: "wanted")
        let other = FileTemplate(name: "Other", fileExtension: "txt", content: "wrong")
        var disabled = wanted
        disabled.isEnabled = false
        let action = FinderMenuAction(templateID: wanted.id, context: .container, destinationFolder: destination,
                                     destinationIdentity: try DirectoryIdentity.capture(at: destination))
        for candidate in [other, disabled] {
            let coordinator = FinderFileCreationCoordinator(
                loadTemplate: { id in XCTAssertEqual(id, wanted.id); return candidate },
                performWithAccess: { _, _ in XCTFail("An invalid template must not request access"); throw TestError.writeFailed },
                createFile: { _ in XCTFail("An invalid template must not write"); throw TestError.writeFailed },
                requiresAuthorization: { _ in XCTFail("Must not offer authorization"); return false }
            )
            XCTAssertThrowsError(try coordinator.createFile(for: action)) {
                XCTAssertEqual($0 as? FinderFileCreationError, .templateUnavailable)
            }
        }
    }

    func testDeferredSelectionRejectsDifferentParentBeyondMenuPreflightBeforeAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = first.appendingPathComponent("one.txt")
        let two = second.appendingPathComponent("two.txt")
        try Data().write(to: one)
        try Data().write(to: two)
        let selection = Array(repeating: one, count: FinderMenuSelectionPreflight.maximumInspectedItems) + [two]
        XCTAssertEqual(FinderMenuSelectionPreflight.check(selection), .deferred)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "")
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in template },
            performWithAccess: { _, _ in XCTFail("Mixed selection must not request access"); throw TestError.writeFailed },
            createFile: { _ in XCTFail("Mixed selection must not write"); throw TestError.writeFailed },
            requiresAuthorization: { _ in XCTFail("Must not offer authorization"); return false }
        )
        XCTAssertThrowsError(try coordinator.createFile(for: FinderMenuAction(
            templateID: template.id, context: .items, targetedURL: first, selectedItemURLs: selection,
            preparedDestination: FinderMenuDestination(folder: first, identity: try DirectoryIdentity.capture(at: first))
        ))) { error in
            XCTAssertEqual(error as? FinderFileCreationError, .destinationUnavailable)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.path), ["one.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: second.path), ["two.txt"])
    }

    func testOldMenuActionRemainsBoundToHiddenTemplateButRejectsDeletedOrDisabledTemplate() throws {
        let visible = FileTemplate(name: "Visible", fileExtension: "txt", content: "visible")
        var hidden = FileTemplate(name: "Hidden", fileExtension: "txt", content: "hidden")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let registry = FinderMenuActionRegistry()
        let tag = registry.registerMenu([FinderMenuAction(templateID: hidden.id, context: .container, destinationFolder: destination,
                                    destinationIdentity: try DirectoryIdentity.capture(at: destination))])[0]
        let entries = FinderMenuModelBuilder().entries(from: [visible, hidden], limit: try FinderMenuDisplayLimit(maximumCount: 1))
        XCTAssertEqual(entries.map(\.id), [visible.id])
        _ = registry.registerMenu(entries.map {
            FinderMenuAction(templateID: $0.id, context: .container, destinationFolder: destination)
        })
        let action = try XCTUnwrap(registry.takeAction(for: tag))
        let authoritativeTemplates = LockedTestValue([visible, hidden])
        let createdTemplates = LockedTestValue<[FileTemplate]>([])
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { id in authoritativeTemplates.value.first { $0.id == id && $0.isEnabled } },
            performWithAccess: { _, operation in try operation() },
            createFile: { request in
                createdTemplates.update { $0.append(request.template) }
                return FileCreationResult(fileURL: destination.appendingPathComponent("created.txt"), didRenameForConflict: false)
            },
            requiresAuthorization: { _ in false }
        )
        _ = try coordinator.createFile(for: action)
        XCTAssertEqual(createdTemplates.value, [hidden])
        hidden.isEnabled = false
        authoritativeTemplates.value = [visible, hidden]
        XCTAssertThrowsError(try coordinator.createFile(for: action)) {
            XCTAssertEqual($0 as? FinderFileCreationError, .templateUnavailable)
        }
        authoritativeTemplates.value = [visible]
        XCTAssertThrowsError(try coordinator.createFile(for: action)) {
            XCTAssertEqual($0 as? FinderFileCreationError, .templateUnavailable)
        }
        XCTAssertEqual(createdTemplates.value.count, 1)
    }

    func testCreatesFileInDestinationCapturedByMenuAction() throws {
        let template = FileTemplate(name: "Markdown", fileExtension: "md", content: "")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let expectedURL = destination.appendingPathComponent("未命名.md")
        let expectedResult = FileCreationResult(fileURL: expectedURL, didRenameForConflict: false)
        let accessedURL = LockedTestValue<URL?>(nil)
        let receivedRequest = LockedTestValue<FileCreationRequest?>(nil)
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in template },
            performWithAccess: { url, operation in
                accessedURL.value = url
                return try operation()
            },
            createFile: { request in
                receivedRequest.value = request
                return expectedResult
            },
            requiresAuthorization: { _ in false }
        )

        let result = try coordinator.createFile(
            for: FinderMenuAction(
                templateID: template.id,
                context: .container,
                destinationFolder: destination,
                destinationIdentity: try DirectoryIdentity.capture(at: destination)
            )
        )

        XCTAssertEqual(result, expectedResult)
        XCTAssertEqual(accessedURL.value, destination)
        XCTAssertEqual(receivedRequest.value?.template, template)
        XCTAssertEqual(receivedRequest.value?.destinationFolder, destination)
        XCTAssertNil(receivedRequest.value?.requestedFilename)
        XCTAssertEqual(receivedRequest.value?.expectedDirectoryIdentity, try DirectoryIdentity.capture(at: destination))
    }

    func testSendableDependenciesSupportConcurrentCreations() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "")
        let action = FinderMenuAction(
            templateID: template.id,
            context: .container,
            destinationFolder: destination,
            destinationIdentity: try DirectoryIdentity.capture(at: destination)
        )
        // The menu snapshot owns the standardized URL, not the original URL representation.
        let expectedDestination = try XCTUnwrap(action.preparedDestination)
        let accessedCount = LockedTestValue(0)
        let requests = LockedTestValue<[FileCreationRequest]>([])
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in template },
            performWithAccess: { _, operation in
                accessedCount.update { $0 += 1 }
                return try operation()
            },
            createFile: { request in
                requests.update { $0.append(request) }
                return FileCreationResult(
                    fileURL: request.destinationFolder.appendingPathComponent("created.txt"),
                    didRenameForConflict: false
                )
            },
            requiresAuthorization: { _ in false }
        )

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                _ = try coordinator.createFile(for: action)
            } catch {
                XCTFail("Unexpected concurrent creation failure: \(error)")
            }
        }

        XCTAssertEqual(accessedCount.value, 32)
        let capturedRequests = requests.value
        XCTAssertEqual(capturedRequests.count, 32)
        XCTAssertTrue(capturedRequests.allSatisfy { $0.template == template })
        XCTAssertTrue(capturedRequests.allSatisfy { $0.destinationFolder == expectedDestination.folder })
        XCTAssertTrue(capturedRequests.allSatisfy { $0.expectedDirectoryIdentity == expectedDestination.identity })
    }

    func testRejectsTemplateThatWasDisabledAfterMenuCreation() {
        let template = FileTemplate(
            name: "Markdown",
            fileExtension: "md",
            content: "",
            isEnabled: false
        )
        let destination = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let coordinator = makeCoordinator(templates: [template])

        XCTAssertThrowsError(
            try coordinator.createFile(
                for: FinderMenuAction(
                    templateID: template.id,
                    context: .container,
                    destinationFolder: destination,
                    destinationIdentity: try DirectoryIdentity.capture(at: destination)
                )
            )
        ) { error in
            XCTAssertEqual(error as? FinderFileCreationError, .templateUnavailable)
        }
    }

    func testWrapsRecoverableAuthorizationFailuresWithRetryContext() throws {
        let errors: [AuthorizedDirectoryStore.StoreError] = [
            .directoryNotAuthorized,
            .bookmarkResolutionFailed(TestError.writeFailed),
            .securityScopeUnavailable
        ]

        for error in errors {
            try assertAuthorizationRequired(for: error)
        }
    }

    func testAuthorizationHandoffRetainsIdentityFromBeforeAccessFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("A")
        let moved = root.appendingPathComponent("A-old")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalIdentity = try DirectoryIdentity.capture(at: target)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "")
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in template },
            performWithAccess: { _, _ in
                try FileManager.default.moveItem(at: target, to: moved)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                throw AuthorizedDirectoryStore.StoreError.directoryNotAuthorized
            },
            createFile: { _ in XCTFail("Must not create without authorization"); throw TestError.writeFailed },
            requiresAuthorization: { AuthorizedDirectoryFailureClassifier.requiresAuthorization($0) }
        )
        XCTAssertThrowsError(try coordinator.createFile(for: FinderMenuAction(
            templateID: template.id, context: .container, destinationFolder: target, destinationIdentity: originalIdentity
        ))) { error in
            guard case let FinderFileCreationError.directoryAuthorizationRequired(templateID, destination, identity) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identity, originalIdentity)
            let request = FinderAuthorizationRequest(templateID: templateID, destinationFolder: destination, destinationIdentity: identity)
            do {
                let replacementIdentity = try DirectoryIdentity.capture(at: target)
                XCTAssertNotEqual(identity, replacementIdentity)
                let transferred = try JSONDecoder().decode(FinderAuthorizationRequest.self, from: JSONEncoder().encode(request))
                XCTAssertEqual(transferred.destinationIdentity, originalIdentity)
            } catch {
                XCTFail("Unable to transfer authorization request: \(error)")
            }
        }
    }

    func testDirectoryTargetRejectsDirectoryRecreatedDuringTemplateLoading() throws {
        try assertTargetReplacementDuringTemplateLoading(usesSelection: false, replacesWithSymlink: false)
    }

    func testDirectoryTargetRejectsSymlinkReplacementDuringTemplateLoading() throws {
        try assertTargetReplacementDuringTemplateLoading(usesSelection: false, replacesWithSymlink: true)
    }

    func testSelectionTargetRejectsDirectoryRecreatedDuringTemplateLoading() throws {
        try assertTargetReplacementDuringTemplateLoading(usesSelection: true, replacesWithSymlink: false)
    }

    func testSelectionTargetRejectsSymlinkReplacementDuringTemplateLoading() throws {
        try assertTargetReplacementDuringTemplateLoading(usesSelection: true, replacesWithSymlink: true)
    }

    func testMissingDestinationRejectsBeforeLoadingTemplatesOrRequestingAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("Missing")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalIdentity = try DirectoryIdentity.capture(at: target)
        try FileManager.default.removeItem(at: target)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "must not be written")
        let didLoadTemplates = LockedTestValue(false)
        let didRequestAccess = LockedTestValue(false)
        let didCreate = LockedTestValue(false)
        let service = FileCreationService()
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in
                didLoadTemplates.value = true
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                return template
            },
            performWithAccess: { _, operation in
                didRequestAccess.value = true
                return try operation()
            },
            createFile: {
                didCreate.value = true
                return try service.createFile(for: $0)
            },
            requiresAuthorization: { AuthorizedDirectoryFailureClassifier.requiresAuthorization($0) }
        )

        XCTAssertThrowsError(try coordinator.createFile(for: FinderMenuAction(
            templateID: template.id, context: .container, destinationFolder: target, destinationIdentity: originalIdentity
        ))) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
        XCTAssertFalse(didLoadTemplates.value)
        XCTAssertFalse(didRequestAccess.value)
        XCTAssertFalse(didCreate.value)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testUnsearchableAncestorPreservesPermissionErrorBeforeLoadingTemplatesOrRequestingAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let parent = root.appendingPathComponent("No-search")
        let target = parent.appendingPathComponent("Target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalIdentity = try DirectoryIdentity.capture(at: target)
        XCTAssertEqual(chmod(parent.path, 0o600), 0)
        defer { chmod(parent.path, 0o700) }
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "must not be written")
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in XCTFail("Unavailable identity must not load templates"); return template },
            performWithAccess: { _, operation in
                XCTFail("Unavailable identity must not request access")
                return try operation()
            },
            createFile: { _ in XCTFail("Unavailable identity must not create"); throw TestError.writeFailed },
            requiresAuthorization: { _ in XCTFail("Must preserve the original permission error"); return false }
        )

        XCTAssertThrowsError(try coordinator.createFile(for: FinderMenuAction(
            templateID: template.id, context: .container, destinationFolder: target, destinationIdentity: originalIdentity
        ))) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EACCES))
            XCTAssertEqual(FinderExtensionFailureClassifier().classify(error).reason, .permissionDenied)
        }
        XCTAssertEqual(chmod(parent.path, 0o700), 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testAuthorizationHandoffRetainsIdentityFromBeforeTemplateLoading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("A")
        let moved = root.appendingPathComponent("A-old")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalIdentity = try DirectoryIdentity.capture(at: target)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "must not be written")
        let service = FileCreationService()
        var authorizationRequest: FinderAuthorizationRequest?
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in
                try FileManager.default.moveItem(at: target, to: moved)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                return template
            },
            performWithAccess: { _, _ in throw AuthorizedDirectoryStore.StoreError.directoryNotAuthorized },
            createFile: { _ in XCTFail("Must not create without authorization"); throw TestError.writeFailed },
            requiresAuthorization: { AuthorizedDirectoryFailureClassifier.requiresAuthorization($0) }
        )

        XCTAssertThrowsError(try coordinator.createFile(for: FinderMenuAction(
            templateID: template.id, context: .container, destinationFolder: target, destinationIdentity: originalIdentity
        ))) { error in
            guard case let FinderFileCreationError.directoryAuthorizationRequired(templateID, destination, identity) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identity, originalIdentity)
            authorizationRequest = FinderAuthorizationRequest(
                templateID: templateID, destinationFolder: destination, destinationIdentity: identity
            )
        }
        let completion = FinderAuthorizationCoordinator(
            loadTemplates: { [template] },
            authorizeDirectory: { _ in UUID() },
            performWithAccess: { _, _, operation in try operation() },
            createFile: { try service.createFile(for: $0) }
        )
        XCTAssertThrowsError(try completion.complete(
            XCTUnwrap(authorizationRequest), authorizedDirectory: root
        )) { error in
            guard case FileCreationError.destinationIdentityChanged = error else {
                return XCTFail("Expected original identity rejection during authorization, got \(error)")
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    func testPropagatesNonAuthorizationFailure() {
        let template = FileTemplate(name: "Markdown", fileExtension: "md", content: "")
        let destination = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in template },
            performWithAccess: { _, _ in throw TestError.writeFailed },
            createFile: { _ in
                XCTFail("File creation must not run after access fails")
                return FileCreationResult(fileURL: destination, didRenameForConflict: false)
            },
            requiresAuthorization: { AuthorizedDirectoryFailureClassifier.requiresAuthorization($0) }
        )

        XCTAssertThrowsError(
            try coordinator.createFile(
                for: FinderMenuAction(
                    templateID: template.id,
                    context: .container,
                    destinationFolder: destination,
                    destinationIdentity: try DirectoryIdentity.capture(at: destination)
                )
            )
        ) { error in
            XCTAssertEqual(error as? TestError, .writeFailed)
        }
    }

    func testSlowMetadataResolutionIsDeferredUntilBackgroundExecution() throws {
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = (0..<100).map { directory.appendingPathComponent("item\($0)") }
        let registry = FinderMenuActionRegistry()
        let resolverStarted = expectation(description: "background resolution started")
        let completed = expectation(description: "created after resolution")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in template },
            performWithAccess: { _, operation in try operation() },
            createFile: { request in
                XCTAssertEqual(request.destinationFolder, directory)
                return FileCreationResult(fileURL: directory.appendingPathComponent("created.txt"), didRenameForConflict: false)
            },
            requiresAuthorization: { _ in false },
            resolveSelection: { _, _, items in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(items, selected)
                resolverStarted.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return directory
            }
        )
        let tag = registry.registerMenu([FinderMenuAction(
            templateID: template.id, context: .items,
            targetedURL: directory, selectedItemURLs: selected,
            preparedDestination: FinderMenuDestination(folder: directory, identity: try DirectoryIdentity.capture(at: directory))
        )])[0]
        let action = try XCTUnwrap(registry.takeAction(for: tag))
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try coordinator.createFile(for: action)
            } catch {
                XCTFail("Unexpected creation failure: \(error)")
            }
            completed.fulfill()
        }
        wait(for: [resolverStarted], timeout: 5)
        // The caller can continue while volume metadata is unavailable.
        release.signal()
        wait(for: [completed], timeout: 5)
    }

    func testDeferredSelectionRejectsDeletedItemBeforeAuthorizationOrCreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = directory.appendingPathComponent("deleted.txt")
        try Data().write(to: item)
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "")
        let action = FinderMenuAction(
            templateID: template.id, context: .items, targetedURL: directory, selectedItemURLs: [item],
            preparedDestination: try XCTUnwrap(FinderMenuDestination.prepare(for: FinderMenuSelection(
                context: .items, targetedURL: directory, selectedItemURLs: [item]
            )))
        )
        try FileManager.default.removeItem(at: item)
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in template },
            performWithAccess: { _, operation in XCTFail("Invalid selection must not request access"); return try operation() },
            createFile: { _ in XCTFail("Invalid selection must not create"); throw TestError.writeFailed },
            requiresAuthorization: { _ in false }
        )
        XCTAssertThrowsError(try coordinator.createFile(for: action)) {
            XCTAssertEqual($0 as? FinderFileCreationError, .destinationUnavailable)
        }
    }

    func testSidebarMenuSnapshotWritesInsideClickedDirectoryNotWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sidebar = root.appendingPathComponent("Sidebar")
        let window = root.appendingPathComponent("Window")
        try FileManager.default.createDirectory(at: sidebar, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: window, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let template = FileTemplate(name: "Markdown", fileExtension: "md", content: "sidebar content")
        let registry = FinderMenuActionRegistry()
        let tag = registry.registerMenu([FinderMenuAction(templateID: template.id, context: .sidebar,
                                    targetedURL: window, selectedItemURLs: [sidebar],
                                    preparedDestination: try XCTUnwrap(FinderMenuDestination.prepare(for: FinderMenuSelection(
                                        context: .sidebar, targetedURL: window, selectedItemURLs: [sidebar]
                                    ))))])[0]
        let service = FileCreationService()
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in template },
            performWithAccess: { url, operation in
                XCTAssertEqual(url, sidebar.standardizedFileURL)
                return try operation()
            },
            createFile: { try service.createFile(for: $0) },
            requiresAuthorization: { _ in false }
        )
        let result = try coordinator.createFile(for: XCTUnwrap(registry.takeAction(for: tag)))
        XCTAssertEqual(result.fileURL.deletingLastPathComponent().resolvingSymlinksInPath(), sidebar.resolvingSymlinksInPath())
        XCTAssertEqual(try String(contentsOf: result.fileURL), "sidebar content")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: window.path).isEmpty)
    }

    func testSidebarWithoutClickedDirectoryNeverRequestsAccessOrWrites() throws {
        let template = FileTemplate(name: "Markdown", fileExtension: "md", content: "")
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in template },
            performWithAccess: { _, operation in XCTFail("Missing sidebar selection must not request access"); return try operation() },
            createFile: { _ in XCTFail("Missing sidebar selection must not create"); throw TestError.writeFailed },
            requiresAuthorization: { _ in false }
        )
        let action = FinderMenuAction(templateID: template.id, context: .sidebar,
                                      targetedURL: FileManager.default.temporaryDirectory, selectedItemURLs: [],
                                      preparedDestination: FinderMenuDestination(folder: FileManager.default.temporaryDirectory,
                                          identity: try DirectoryIdentity.capture(at: FileManager.default.temporaryDirectory)))
        XCTAssertThrowsError(try coordinator.createFile(for: action)) {
            XCTAssertEqual($0 as? FinderFileCreationError, .destinationUnavailable)
        }
    }

    private func assertTargetReplacementDuringTemplateLoading(
        usesSelection: Bool,
        replacesWithSymlink: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("A")
        let moved = root.appendingPathComponent("A-old")
        let other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "must not be written")
        let prepared = FinderMenuDestination(folder: target, identity: try DirectoryIdentity.capture(at: target))
        let action = usesSelection
            ? FinderMenuAction(templateID: template.id, context: .items, targetedURL: target, selectedItemURLs: [target], preparedDestination: prepared)
            : FinderMenuAction(templateID: template.id, context: .container, destinationFolder: target, destinationIdentity: prepared.identity)
        let service = FileCreationService()
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in
                try FileManager.default.moveItem(at: target, to: moved)
                if replacesWithSymlink {
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
                } else {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                }
                return template
            },
            performWithAccess: { _, operation in try operation() },
            createFile: { try service.createFile(for: $0) },
            requiresAuthorization: { AuthorizedDirectoryFailureClassifier.requiresAuthorization($0) }
        )

        XCTAssertThrowsError(try coordinator.createFile(for: action), file: file, line: line) { error in
            guard case FileCreationError.destinationIdentityChanged = error else {
                return XCTFail("Expected original identity rejection, got \(error)", file: file, line: line)
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty, file: file, line: line)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty, file: file, line: line)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty, file: file, line: line)
    }

    private func assertAuthorizationRequired(for authorizationError: AuthorizedDirectoryStore.StoreError) throws {
        let template = FileTemplate(name: "Markdown", fileExtension: "md", content: "original request")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let originalIdentity = try DirectoryIdentity.capture(at: destination)
        var authorizationRequest: FinderAuthorizationRequest?
        let coordinator = FinderFileCreationCoordinator(
            loadTemplate: { _ in template },
            performWithAccess: { _, _ in throw authorizationError },
            createFile: { _ in
                XCTFail("File creation must not run without authorization")
                return FileCreationResult(fileURL: destination, didRenameForConflict: false)
            },
            requiresAuthorization: { AuthorizedDirectoryFailureClassifier.requiresAuthorization($0) }
        )

        XCTAssertThrowsError(
            try coordinator.createFile(
                for: FinderMenuAction(
                    templateID: template.id,
                    context: .container,
                    destinationFolder: destination,
                    destinationIdentity: try DirectoryIdentity.capture(at: destination)
                )
            )
        ) { error in
            guard case let FinderFileCreationError.directoryAuthorizationRequired(
                templateID,
                destinationFolder,
                destinationIdentity
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(templateID, template.id)
            XCTAssertEqual(destinationFolder, destination)
            XCTAssertEqual(destinationIdentity, originalIdentity)
            authorizationRequest = FinderAuthorizationRequest(
                templateID: templateID, destinationFolder: destinationFolder, destinationIdentity: destinationIdentity
            )
        }

        let service = FileCreationService()
        let completion = FinderAuthorizationCoordinator(
            loadTemplates: { [template] },
            authorizeDirectory: { XCTAssertEqual($0, destination); return UUID() },
            performWithAccess: { _, _, operation in try operation() },
            createFile: { try service.createFile(for: $0) }
        )
        let result = try completion.complete(XCTUnwrap(authorizationRequest), authorizedDirectory: destination)
        XCTAssertEqual(result.creationResult.fileURL.deletingLastPathComponent().resolvingSymlinksInPath(), destination.resolvingSymlinksInPath())
        XCTAssertEqual(try String(contentsOf: result.creationResult.fileURL), "original request")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 1)
    }

    private func makeCoordinator(templates: [FileTemplate]) -> FinderFileCreationCoordinator {
        FinderFileCreationCoordinator(
            loadTemplate: { id in templates.first { $0.id == id && $0.isEnabled } },
            performWithAccess: { _, operation in try operation() },
            createFile: { request in
                FileCreationResult(
                    fileURL: request.destinationFolder.appendingPathComponent("created"),
                    didRenameForConflict: false
                )
            },
            requiresAuthorization: { _ in false }
        )
    }
}
