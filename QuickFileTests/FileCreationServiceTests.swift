import XCTest
import Darwin
@testable import QuickFileCore

final class FileCreationServiceTests: XCTestCase {

    func testDefaultFilenamePriorityLiteralVariablesAndConflictNeverOverwrite() throws {
        let template = FileTemplate(name: "A", fileExtension: "md", content: "new", defaultFilename: "默认-{{date}}.md")
        let service = FileCreationService()
        for (requested, expected) in [(nil as String?, "默认-{{date}}.md"), (" \n ", "默认-{{date}} 2.md"), ("本次.md", "本次.md")] {
            let result = try service.createFile(for: .init(template: template, destinationFolder: temporaryDirectory,
                                                          requestedFilename: requested))
            XCTAssertEqual(result.fileURL.lastPathComponent, expected)
        }
        XCTAssertEqual(try String(contentsOf: temporaryDirectory.appendingPathComponent("默认-{{date}}.md"), encoding: .utf8), "new")
    }

    func testDefaultFilenamePreservesDotfilesUnicodeAndEmptyFallback() throws {
        let service = FileCreationService()
        for (name, expected) in [(".gitignore", ".gitignore"), ("👩‍💻-e\u{301}", "👩‍💻-e\u{301}"), ("  ", "未命名")] {
            let template = FileTemplate(name: "A", fileExtension: "", content: "", defaultFilename: name)
            let result = try service.createFile(for: .init(template: template, destinationFolder: temporaryDirectory, requestedFilename: nil))
            XCTAssertEqual(Array(result.fileURL.lastPathComponent.utf8), Array(expected.utf8))
        }
    }

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testCreatesFileWithRenderedContentAndAutomaticExtension() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let service = FileCreationService(
            templateRenderer: TemplateRenderer(timeZone: timeZone),
            dateProvider: { Date(timeIntervalSince1970: 0) },
            clipboardProvider: { "剪贴板内容" }
        )
        let template = FileTemplate(
            name: "Markdown",
            fileExtension: "md",
            content: "folder={{folderName}} clipboard={{clipboard}} sequence={{sequence}}"
        )

        let result = try service.createFile(
            for: FileCreationRequest(
                template: template,
                destinationFolder: temporaryDirectory,
                requestedFilename: "说明"
            )
        )

        XCTAssertEqual(result.fileURL.lastPathComponent, "说明.md")
        XCTAssertFalse(result.didRenameForConflict)
        XCTAssertEqual(
            try String(contentsOf: result.fileURL, encoding: .utf8),
            "folder=\(temporaryDirectory.lastPathComponent) clipboard=剪贴板内容 sequence=1"
        )
    }

    func testReusedServiceRefreshesTemplateTimeZoneBetweenCreations() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let west = try XCTUnwrap(TimeZone(secondsFromGMT: -8 * 60 * 60))
        let provider = TestTimeZoneProvider(utc)
        let service = FileCreationService(
            templateRenderer: TemplateRenderer(timeZoneProvider: { provider.current() }),
            dateProvider: { Date(timeIntervalSince1970: 0) }
        )
        let request = FileCreationRequest(
            template: FileTemplate(name: "Date", fileExtension: "txt", content: "{{date}}|{{time}}|{{year}}"),
            destinationFolder: temporaryDirectory,
            requestedFilename: "timestamp"
        )

        let first = try service.createFile(for: request)
        provider.setTimeZone(west)
        let second = try service.createFile(for: request)

        XCTAssertEqual(try String(contentsOf: first.fileURL, encoding: .utf8), "1970-01-01|00:00:00|1970")
        XCTAssertEqual(try String(contentsOf: second.fileURL, encoding: .utf8), "1969-12-31|16:00:00|1969")
        XCTAssertNotEqual(first.fileURL, second.fileURL)
        XCTAssertTrue(second.didRenameForConflict)
        XCTAssertEqual(provider.readCount, 2)
    }

    func testAvoidsOverwritingExistingFile() throws {
        let existingURL = temporaryDirectory.appendingPathComponent("报告.md")
        try "原内容".write(to: existingURL, atomically: true, encoding: .utf8)
        let template = FileTemplate(
            name: "Markdown",
            fileExtension: "md",
            content: "sequence={{sequence}}"
        )

        let result = try FileCreationService().createFile(
            for: FileCreationRequest(
                template: template,
                destinationFolder: temporaryDirectory,
                requestedFilename: "报告.md"
            )
        )

        XCTAssertEqual(result.fileURL.lastPathComponent, "报告 2.md")
        XCTAssertTrue(result.didRenameForConflict)
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "原内容")
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "sequence=2")
    }

    func testCreatesUnicodeAndEmojiFilename() throws {
        let template = FileTemplate(name: "文本", fileExtension: "txt", content: "")

        let result = try FileCreationService().createFile(
            for: FileCreationRequest(
                template: template,
                destinationFolder: temporaryDirectory,
                requestedFilename: "中文 🧪"
            )
        )

        XCTAssertEqual(result.fileURL.lastPathComponent, "中文 🧪.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path))
    }

    func testCreatesExactDotfileNameWhenTemplateHasNoExtension() throws {
        let template = FileTemplate(name: "无扩展名", fileExtension: "", content: "dotenv")

        let result = try FileCreationService().createFile(
            for: FileCreationRequest(
                template: template,
                destinationFolder: temporaryDirectory,
                requestedFilename: ".gitignore"
            )
        )

        XCTAssertEqual(result.fileURL.lastPathComponent, ".gitignore")
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "dotenv")
    }

    func testExplicitClipboardOverridesConfiguredProvider() throws {
        let template = FileTemplate(
            name: "文本",
            fileExtension: "txt",
            content: "{{clipboard}}"
        )
        let service = FileCreationService(clipboardProvider: { "configured" })

        let result = try service.createFile(
            for: FileCreationRequest(
                template: template,
                destinationFolder: temporaryDirectory,
                requestedFilename: "clipboard"
            ),
            clipboard: "captured"
        )

        XCTAssertEqual(
            try String(contentsOf: result.fileURL, encoding: .utf8),
            "captured"
        )
    }

    func testRequestClipboardOverridesProviderIncludingExplicitEmptyContent() throws {
        let template = FileTemplate(name: "Clipboard", fileExtension: "txt", content: "{{clipboard}}")
        let service = FileCreationService(clipboardProvider: { "provider" })
        for clipboard in ["captured", ""] {
            let result = try service.createFile(for: FileCreationRequest(
                template: template,
                destinationFolder: temporaryDirectory,
                requestedFilename: nil,
                clipboard: clipboard
            ))
            XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), clipboard)
        }
    }

    func testCreatesRenderedFilesBelowAndAtInjectedUTF8Budget() throws {
        let service = FileCreationService(templateRenderer: TemplateRenderer(maximumOutputUTF8Bytes: 8))
        for (content, expected) in [("{{clipboard}}x", "界🧪x"), ("{{clipboard}}", "界🧪")] {
            let result = try service.createFile(for: FileCreationRequest(
                template: FileTemplate(name: "text", fileExtension: "txt", content: content),
                destinationFolder: temporaryDirectory, requestedFilename: "bounded", clipboard: "界🧪"
            ))
            let actual = try Data(contentsOf: result.fileURL)
            XCTAssertEqual(actual, Data(expected.utf8))
            XCTAssertLessThanOrEqual(actual.count, 8)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).count, 2)
    }

    func testPreservesMultibyteUTF8AndEmbeddedNULInLiteralAndRenderedContent() throws {
        let content = "前缀\u{0}界🧪e\u{301}\u{0}尾部"
        let service = FileCreationService()
        for body in [content, "{{clipboard}}"] {
            let result = try service.createFile(for: FileCreationRequest(
                template: FileTemplate(name: "text", fileExtension: "txt", content: body),
                destinationFolder: temporaryDirectory, requestedFilename: "bytes", clipboard: content
            ))
            XCTAssertEqual(try Data(contentsOf: result.fileURL), Data(content.utf8))
        }
    }

    func testOversizedLiteralAndClipboardExpansionDoNotMutateDestinationOrRequestStaging() throws {
        let stage = temporaryDirectory.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let existing = temporaryDirectory.appendingPathComponent("result.txt")
        let marker = stage.appendingPathComponent("marker")
        try Data("existing".utf8).write(to: existing)
        try Data("private marker".utf8).write(to: marker)
        let manager = ReplacementDirectoryFileManager(directory: stage)
        let service = FileCreationService(
            fileManager: manager,
            templateRenderer: TemplateRenderer(maximumOutputUTF8Bytes: 8),
            beforeCommit: { _ in XCTFail("Oversized output must not reach commit") }
        )
        let before = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).sorted()
        for content in ["123456789", "{{clipboard}}{{clipboard}}{{clipboard}}"] {
            XCTAssertThrowsError(try service.createFile(for: FileCreationRequest(
                template: FileTemplate(name: "text", fileExtension: "txt", content: content),
                destinationFolder: temporaryDirectory, requestedFilename: "result", clipboard: "界"
            ))) { error in
                guard case let FileCreationError.renderedContentTooLarge(limit) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(limit, 8)
            }
            XCTAssertEqual(manager.requestCount, 0, "No temporary directory may be allocated")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).sorted(), before)
            XCTAssertEqual(try Data(contentsOf: existing), Data("existing".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), ["marker"])
            XCTAssertEqual(try Data(contentsOf: marker), Data("private marker".utf8))
        }
    }

    func testOutputBudgetFailureAfterConflictCleansStagingAndCapturesInputsOnce() throws {
        let parent = temporaryDirectory.appendingPathComponent("private", isDirectory: true)
        let stage = parent.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for sequence in 1...8 {
            let name = sequence == 1 ? "race.txt" : "race \(sequence).txt"
            try Data("existing".utf8).write(to: temporaryDirectory.appendingPathComponent(name))
        }
        let competingURL = temporaryDirectory.appendingPathComponent("race 9.txt")
        let manager = ReplacementDirectoryFileManager(directory: stage)
        let dateReads = FileCreationCallCounter()
        let clipboardReads = FileCreationCallCounter()
        let service = FileCreationService(
            fileManager: manager,
            templateRenderer: TemplateRenderer(maximumOutputUTF8Bytes: 2),
            dateProvider: {
                dateReads.record()
                return Date(timeIntervalSince1970: 0)
            },
            clipboardProvider: {
                clipboardReads.record()
                return "x"
            },
            beforeCommit: { _ in
                try Data("competitor".utf8).write(to: competingURL, options: .withoutOverwriting)
            }
        )

        XCTAssertThrowsError(try service.createFile(for: FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "{{clipboard}}{{sequence}}"),
            destinationFolder: temporaryDirectory, requestedFilename: "race"
        ))) { error in
            guard case let FileCreationError.renderedContentTooLarge(limit) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(limit, 2)
        }
        XCTAssertEqual(dateReads.count, 1)
        XCTAssertEqual(clipboardReads.count, 1)
        XCTAssertEqual(manager.requestCount, 1, "Only the within-budget attempt may stage")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent("race 10.txt").path))
        XCTAssertEqual(try Data(contentsOf: competingURL), Data("competitor".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).count, 10)
        for sequence in 1...8 {
            let name = sequence == 1 ? "race.txt" : "race \(sequence).txt"
            XCTAssertEqual(try Data(contentsOf: temporaryDirectory.appendingPathComponent(name)), Data("existing".utf8))
        }
    }

    func testDefaultBudgetCreatesExistingLargeBodyUnchanged() throws {
        let content = String(repeating: "a", count: 4_600_000)
        let result = try FileCreationService().createFile(for: FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: content),
            destinationFolder: temporaryDirectory, requestedFilename: "large"
        ))
        XCTAssertEqual(try Data(contentsOf: result.fileURL), Data(content.utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), ["large.txt"])
    }

    func testRejectsFileAsDestinationFolder() throws {
        let destinationFile = temporaryDirectory.appendingPathComponent("not-a-folder")
        try Data().write(to: destinationFile)
        let template = FileTemplate(name: "文本", fileExtension: "txt", content: "")

        XCTAssertThrowsError(
            try FileCreationService().createFile(
                for: FileCreationRequest(
                    template: template,
                    destinationFolder: destinationFile,
                    requestedFilename: "测试"
                )
            )
        ) { error in
            guard case FileCreationError.destinationIsNotDirectory = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDoesNotReadClipboardForTemplatesWithoutRecognizedVariable() throws {
        let service = FileCreationService(clipboardProvider: {
            XCTFail("Clipboard must not be read")
            return nil
        })
        for content in ["", "{{ clipboard }}", "{{unknown {{clipboard}}"] {
            let result = try service.createFile(for: FileCreationRequest(
                template: FileTemplate(name: "text", fileExtension: "txt", content: content),
                destinationFolder: temporaryDirectory, requestedFilename: "test"
            ))
            XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), content)
        }
    }

    func testCommitRetriesWhenCompetitorCreatesDanglingSymlinkAfterPreflight() throws {
        let competingURL = temporaryDirectory.appendingPathComponent("race.txt")
        let service = FileCreationService(clipboardProvider: {
            // A dangling symlink must count as occupied without touching its target.
            do {
                try FileManager.default.createSymbolicLink(atPath: competingURL.path, withDestinationPath: "missing")
            } catch { XCTFail("Clipboard should be captured once: \(error)") }
            return "snapshot"
        })
        let result = try service.createFile(for: FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "{{clipboard}} {{sequence}}"),
            destinationFolder: temporaryDirectory, requestedFilename: "race"
        ))
        XCTAssertEqual(result.fileURL.lastPathComponent, "race 2.txt")
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "snapshot 2")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: competingURL.path), "missing")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).sorted(), ["race 2.txt", "race.txt"])
    }

    func testCreatesFileInWritableSearchableDirectoryWithoutReadPermission() throws {
        let folder = temporaryDirectory.appendingPathComponent("drop", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(folder.path, 0o300), 0)
        defer { chmod(folder.path, 0o700) }

        let result = try FileCreationService().createFile(for: FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "complete"),
            destinationFolder: folder, requestedFilename: "drop"
        ))
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "complete")
        XCTAssertEqual(result.fileURL.lastPathComponent, "drop.txt")
    }

    func testReturnsCreatedObjectWhenDirectoryMovesAndOriginalPathIsReused() throws {
        let original = temporaryDirectory.appendingPathComponent("D", isDirectory: true)
        let moved = temporaryDirectory.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let sentinel = original.appendingPathComponent("name.txt")
        let service = FileCreationService(clipboardProvider: {
            do {
                try FileManager.default.moveItem(at: original, to: moved)
                try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
                try "sentinel".write(to: sentinel, atomically: false, encoding: .utf8)
            } catch { XCTFail("Failed to replace original directory: \(error)") }
            return "created"
        })
        let result = try service.createFile(for: FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "{{clipboard}}"),
            destinationFolder: original, requestedFilename: "name"
        ))
        XCTAssertEqual(result.fileURL.resolvingSymlinksInPath(), moved.appendingPathComponent("name.txt").resolvingSymlinksInPath())
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "created")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "sentinel")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), ["name.txt"])
    }

    func testMaximumLengthNameCanBeCreatedAgain() throws {
        let request = FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "complete"),
            destinationFolder: temporaryDirectory, requestedFilename: String(repeating: "a", count: 251)
        )
        let service = FileCreationService()
        let first = try service.createFile(for: request)
        let second = try service.createFile(for: request)
        XCTAssertNotEqual(first.fileURL, second.fileURL)
        XCTAssertTrue(second.didRenameForConflict)
        XCTAssertLessThanOrEqual(second.fileURL.lastPathComponent.utf8.count, 255)
        XCTAssertEqual(try String(contentsOf: second.fileURL, encoding: .utf8), "complete")
    }

    func testConcurrentCreationPublishesDistinctCompleteFiles() async throws {
        let request = FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: String(repeating: "complete", count: 1000)),
            destinationFolder: temporaryDirectory, requestedFilename: "parallel"
        )
        let results = try await withThrowingTaskGroup(of: FileCreationResult.self) { group in
            for _ in 0..<12 { group.addTask { try FileCreationService().createFile(for: request) } }
            var results: [FileCreationResult] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(Set(results.map(\.fileURL)).count, 12)
        for result in results {
            XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), request.template.content)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).count, 12)
    }

    func testPreservesLongUnicodeNameAcceptedByDestinationFilesystem() throws {
        let name = String(repeating: "报", count: 100)
        let original = temporaryDirectory.appendingPathComponent(name + ".txt")
        do {
            try Data("existing".utf8).write(to: original, options: .withoutOverwriting)
        } catch {
            throw XCTSkip("Destination filesystem does not support this Unicode name: \(error)")
        }
        let result = try FileCreationService().createFile(for: FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "complete"),
            destinationFolder: temporaryDirectory, requestedFilename: name
        ))
        XCTAssertEqual(result.fileURL.lastPathComponent, name + " 2.txt")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "existing")
    }

    func testRejectsChangedDirectoryBeforeClipboardOrStaging() throws {
        let folder = temporaryDirectory.appendingPathComponent("target")
        let moved = temporaryDirectory.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let identity = try DirectoryIdentity.capture(at: folder)
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let service = FileCreationService(clipboardProvider: {
            XCTFail("Changed destination must be rejected before reading the clipboard")
            return nil
        }, beforeCommit: { _ in XCTFail("Changed destination must not reach staging") })

        XCTAssertThrowsError(try service.createFile(for: FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "{{clipboard}}"),
            destinationFolder: folder, requestedFilename: "result", expectedDirectoryIdentity: identity
        ))) { error in
            guard case FileCreationError.destinationIdentityChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [])
    }

    func testReadOnlyVolumeReportsReadOnlyInsteadOfCrossDeviceError() throws {
        XCTAssertThrowsError(try FileCreationService.validateCreationVolume(
            flags: UInt32(MNT_RDONLY | MNT_UNKNOWNPERMISSIONS), folderURL: temporaryDirectory
        )) { error in
            guard case let FileCreationError.writeFailed(url, underlying) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(url, self.temporaryDirectory)
            XCTAssertEqual((underlying as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((underlying as NSError).code, Int(EROFS))
            XCTAssertTrue(error.localizedDescription.contains("只读"))
        }
    }

    func testUnknownOwnershipVolumeExplainsUnsafeStagingAndOwnedVolumeIsAllowed() throws {
        XCTAssertNoThrow(try FileCreationService.validateCreationVolume(
            flags: UInt32(MNT_LOCAL), folderURL: temporaryDirectory
        ))
        XCTAssertThrowsError(try FileCreationService.validateCreationVolume(
            flags: UInt32(MNT_UNKNOWNPERMISSIONS), folderURL: temporaryDirectory
        )) { error in
            guard case let FileCreationError.writeFailed(_, underlying) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual((underlying as NSError).code, Int(ENOTSUP))
            XCTAssertTrue(error.localizedDescription.contains("忽略文件所有权"))
        }
    }

    func testCommitSourceIsPrivateAndPublicSameNameCannotReplaceIt() throws {
        let folder = try XCTUnwrap(temporaryDirectory)
        let service = FileCreationService(beforeCommit: { staging in
            var source = stat()
            var parent = stat()
            var destination = stat()
            XCTAssertEqual(lstat(staging.path, &source), 0)
            XCTAssertEqual(lstat(staging.deletingLastPathComponent().path, &parent), 0)
            XCTAssertEqual(lstat(folder.path, &destination), 0)
            XCTAssertEqual(source.st_mode & 0o777, 0o700)
            XCTAssertEqual(parent.st_mode & 0o777, 0o700)
            XCTAssertEqual(source.st_uid, geteuid())
            XCTAssertEqual(parent.st_uid, geteuid())
            XCTAssertEqual(source.st_dev, destination.st_dev)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
            // A process with write access to the destination can only insert a public
            // same-name entry; the actual source is in the private directory above.
            try "replacement".write(to: folder.appendingPathComponent("payload"), atomically: false, encoding: .utf8)
        })

        let result = try service.createFile(for: FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "expected"),
            destinationFolder: folder, requestedFilename: "result"
        ))

        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "expected")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("payload"), encoding: .utf8), "replacement")
    }

    func testCommitUsesOpenedStagingDirectoryAfterItsPathIsReplaced() throws {
        let parent = temporaryDirectory.appendingPathComponent("private")
        let stage = parent.appendingPathComponent("stage")
        let moved = parent.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manager = ReplacementDirectoryFileManager(directory: stage)
        let service = FileCreationService(fileManager: manager, beforeCommit: { staging in
            try FileManager.default.moveItem(at: staging, to: moved)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try "replacement".write(to: staging.appendingPathComponent("payload"), atomically: false, encoding: .utf8)
        })

        let result = try service.createFile(for: FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "expected"),
            destinationFolder: temporaryDirectory, requestedFilename: "result"
        ))

        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "expected")
        XCTAssertEqual(try String(contentsOf: stage.appendingPathComponent("payload"), encoding: .utf8), "replacement")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [])
    }

    func testRejectsStagingWithSharedWritableParentBeforePublishing() throws {
        let parent = temporaryDirectory.appendingPathComponent("shared")
        let stage = parent.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        XCTAssertEqual(chmod(parent.path, 0o777), 0)
        let service = FileCreationService(fileManager: ReplacementDirectoryFileManager(directory: stage))

        XCTAssertThrowsError(try service.createFile(for: FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "expected"),
            destinationFolder: temporaryDirectory, requestedFilename: "result"
        )))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent("result.txt").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), [])
    }

    func testRejectsStagingACLThatGrantsAccessDespiteOwnerOnlyMode() throws {
        let parent = temporaryDirectory.appendingPathComponent("private")
        let stage = parent.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let acl = try XCTUnwrap(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:execute\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertEqual(acl_set_file(stage.path, ACL_TYPE_EXTENDED, acl), 0)
        var status = stat()
        XCTAssertEqual(lstat(stage.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o700)
        let service = FileCreationService(fileManager: ReplacementDirectoryFileManager(directory: stage))

        XCTAssertThrowsError(try service.createFile(for: FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "expected"),
            destinationFolder: temporaryDirectory, requestedFilename: "result"
        )))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent("result.txt").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), [])
    }

    func testRejectsFileInheritanceACLInsteadOfDroppingTargetPermissions() throws {
        for tag in ["allow", "deny"] {
            let folder = temporaryDirectory.appendingPathComponent(tag)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let acl = try XCTUnwrap(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:\(tag),file_inherit,only_inherit:read\n"))
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            XCTAssertEqual(acl_set_file(folder.path, ACL_TYPE_EXTENDED, acl), 0)
            let direct = folder.appendingPathComponent("direct.txt")
            let descriptor = open(direct.path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            if descriptor >= 0 { close(descriptor) }
            let inheritedACL = try XCTUnwrap(acl_get_file(direct.path, ACL_TYPE_EXTENDED))
            acl_free(UnsafeMutableRawPointer(inheritedACL))
            let service = FileCreationService(beforeCommit: { _ in
                XCTFail("Unsupported inherited ACL must be rejected before publication")
            })

            XCTAssertThrowsError(try service.createFile(for: FileCreationRequest(
                template: FileTemplate(name: "text", fileExtension: "txt", content: "expected"),
                destinationFolder: folder, requestedFilename: "result"
            ))) { error in
                XCTAssertTrue(error.localizedDescription.contains("继承 ACL"), error.localizedDescription)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["direct.txt"])
        }
    }

    func testDestinationGroupIsAppliedBeforePublication() throws {
        var groups = [gid_t](repeating: 0, count: Int(getgroups(0, nil)))
        XCTAssertEqual(getgroups(Int32(groups.count), &groups), Int32(groups.count))
        guard let destinationGroup = groups.first(where: { $0 != getegid() }) else {
            throw XCTSkip("The test account has no alternate group for the inheritance comparison")
        }
        let folder = try XCTUnwrap(temporaryDirectory)
        XCTAssertEqual(chown(folder.path, uid_t.max, destinationGroup), 0)
        let direct = folder.appendingPathComponent("direct.txt")
        let descriptor = open(direct.path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        if descriptor >= 0 { close(descriptor) }
        let service = FileCreationService(beforeCommit: { stage in
            var staged = stat()
            XCTAssertEqual(lstat(stage.appendingPathComponent("payload").path, &staged), 0)
            XCTAssertEqual(staged.st_gid, destinationGroup)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("result.txt").path))
        })

        let result = try service.createFile(for: FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "expected"),
            destinationFolder: folder, requestedFilename: "result"
        ))

        var directStatus = stat(), serviceStatus = stat()
        XCTAssertEqual(lstat(direct.path, &directStatus), 0)
        XCTAssertEqual(lstat(result.fileURL.path, &serviceStatus), 0)
        XCTAssertEqual(directStatus.st_gid, destinationGroup)
        XCTAssertEqual(serviceStatus.st_gid, directStatus.st_gid)
    }

    func testNonmemberDestinationGroupMatchesNativeCreationIncludingStickyAndUnlistableDirectories() throws {
        let folder = try makeNonmemberGroupDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for mode: mode_t in [0o700, 0o300, 0o1777] {
            XCTAssertEqual(chmod(folder.path, mode), 0)
            defer { chmod(folder.path, 0o700) }
            let direct = folder.appendingPathComponent("native-\(mode).txt")
            let native = open(direct.path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
            XCTAssertGreaterThanOrEqual(native, 0)
            guard native >= 0 else { return }
            var nativeInfo = stat()
            XCTAssertEqual(fstat(native, &nativeInfo), 0)
            close(native)
            let group = nativeInfo.st_gid
            let requestedName = "created-\(mode)"
            let service = FileCreationService(beforeCommit: { stage in
                XCTAssertEqual(stage.deletingLastPathComponent().resolvingSymlinksInPath(), folder.resolvingSymlinksInPath())
                var directory = stat(), payload = stat()
                XCTAssertEqual(lstat(stage.path, &directory), 0)
                XCTAssertEqual(directory.st_uid, geteuid())
                XCTAssertEqual(directory.st_mode & 0o777, 0o700)
                XCTAssertEqual(lstat(stage.appendingPathComponent("payload").path, &payload), 0)
                XCTAssertEqual(payload.st_gid, group)
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(requestedName + ".txt").path))
            })

            let result = try service.createFile(for: FileCreationRequest(
                template: FileTemplate(name: "text", fileExtension: "txt", content: "complete"),
                destinationFolder: folder, requestedFilename: requestedName
            ))

            var actual = stat()
            XCTAssertEqual(lstat(result.fileURL.path, &actual), 0)
            XCTAssertEqual(actual.st_gid, nativeInfo.st_gid)
            XCTAssertEqual(actual.st_mode & 0o777, nativeInfo.st_mode & 0o777)
            XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "complete")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 6)
    }

    func testNonmemberGroupStagingPreservesReplacementsDuringCleanup() throws {
        let root = try makeNonmemberGroupDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for kind in ["file", "empty", "nonempty"] {
            let folder = root.appendingPathComponent(kind)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let moved = folder.appendingPathComponent("moved-stage")
            let service = FileCreationService(beforeCommit: { stage in
                try FileManager.default.moveItem(at: stage, to: moved)
                if kind == "file" {
                    try "sentinel".write(to: stage, atomically: false, encoding: .utf8)
                } else {
                    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                    if kind == "nonempty" {
                        try "sentinel".write(to: stage.appendingPathComponent("payload"), atomically: false, encoding: .utf8)
                    }
                }
            })

            let result = try service.createFile(for: FileCreationRequest(
                template: FileTemplate(name: "text", fileExtension: "txt", content: "complete"),
                destinationFolder: folder, requestedFilename: "result"
            ))

            XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "complete")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [])
            let replacement = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".quickfile-staging-") })
            if kind == "empty" {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replacement.path), [])
            } else {
                let sentinel = kind == "file" ? replacement : replacement.appendingPathComponent("payload")
                XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "sentinel")
            }
        }
    }

    func testDestinationPermissionsRejectUncorrectablePayloadGroup() throws {
        let folder = try makeNonmemberGroupDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = open(temporaryDirectory.path, O_SEARCH | O_CLOEXEC)
        let destination = open(folder.path, O_SEARCH | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(source, 0)
        XCTAssertGreaterThanOrEqual(destination, 0)
        guard source >= 0, destination >= 0 else { return }
        defer { close(source); close(destination) }
        let staging = try PrivateFileStagingDirectory.replacementDirectory(
            for: temporaryDirectory, directoryDescriptor: source, fileManager: .default
        )
        defer { try? staging.remove() }
        let payload = openat(staging.descriptor, "payload", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        XCTAssertGreaterThanOrEqual(payload, 0)
        guard payload >= 0 else { return }
        defer { close(payload); try? staging.removeFile(named: "payload") }

        XCTAssertThrowsError(try staging.applyDestinationPermissions(to: payload, in: destination)) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EPERM))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testNonmemberGroupStillRejectsFileInheritanceACL() throws {
        let root = try makeNonmemberGroupDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for tag in ["allow", "deny"] {
            let folder = root.appendingPathComponent(tag)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let acl = try XCTUnwrap(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:\(tag),file_inherit,only_inherit:read\n"))
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            XCTAssertEqual(acl_set_file(folder.path, ACL_TYPE_EXTENDED, acl), 0)

            XCTAssertThrowsError(try FileCreationService().createFile(for: FileCreationRequest(
                template: FileTemplate(name: "text", fileExtension: "txt", content: "complete"),
                destinationFolder: folder, requestedFilename: "result"
            ))) { error in
                XCTAssertTrue(error.localizedDescription.contains("继承 ACL"), error.localizedDescription)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        }
    }

    func testConcurrentNonmemberGroupCreationPublishesDistinctCompleteFiles() async throws {
        let folder = try makeNonmemberGroupDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(chmod(folder.path, 0o1777), 0)
        let content = String(repeating: "complete", count: 10_000)
        let request = FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: content),
            destinationFolder: folder, requestedFilename: "parallel"
        )

        let results = try await withThrowingTaskGroup(of: FileCreationResult.self) { group in
            for _ in 0..<12 { group.addTask { try FileCreationService().createFile(for: request) } }
            var results: [FileCreationResult] = []
            for try await result in group { results.append(result) }
            return results
        }

        XCTAssertEqual(Set(results.map(\.fileURL)).count, 12)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 12)
        var parent = stat()
        XCTAssertEqual(stat(folder.path, &parent), 0)
        for result in results {
            XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), content)
            var file = stat()
            XCTAssertEqual(stat(result.fileURL.path, &file), 0)
            XCTAssertEqual(file.st_gid, parent.st_gid)
        }
    }

    func testNonmemberGroupRejectsUnsafeStagingParentBeforeCreatingEntry() throws {
        let folder = try makeNonmemberGroupDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for restriction in ["nonsticky", "delete_child", "directory_inherit"] {
            let destination = folder.appendingPathComponent(restriction)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            if restriction == "nonsticky" {
                XCTAssertEqual(chmod(destination.path, 0o777), 0)
            } else {
                let entry = restriction == "directory_inherit" ? "allow,directory_inherit,only_inherit:delete" : "allow:delete_child"
                let acl = try XCTUnwrap(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:\(entry)\n"))
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                XCTAssertEqual(acl_set_file(destination.path, ACL_TYPE_EXTENDED, acl), 0)
            }
            let service = FileCreationService(beforeCommit: { _ in XCTFail("Unsafe staging must not reach publication") })

            XCTAssertThrowsError(try service.createFile(for: FileCreationRequest(
                template: FileTemplate(name: "text", fileExtension: "txt", content: "complete"),
                destinationFolder: destination, requestedFilename: "result"
            ))) { error in
                XCTAssertTrue(error.localizedDescription.contains("其他用户替换"), error.localizedDescription)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        }
    }

    func testUnsearchableAncestorPreservesPermissionErrorAndRecoversAfterRestoringAccess() throws {
        let parent = temporaryDirectory.appendingPathComponent("no-search")
        let child = parent.appendingPathComponent("existing-child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent.path, 0o600), 0)
        defer { chmod(parent.path, 0o700) }
        let request = FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "complete"),
            destinationFolder: child, requestedFilename: "result"
        )
        XCTAssertThrowsError(try FileCreationService().createFile(for: request)) { error in
            guard case let FileCreationError.writeFailed(_, underlying) = error else {
                return XCTFail("Permission denial must not report missing: \(error)")
            }
            XCTAssertEqual((underlying as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((underlying as NSError).code, Int(EACCES))
        }
        XCTAssertEqual(chmod(parent.path, 0o700), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: child.path), [])
        let result = try FileCreationService().createFile(for: request)
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "complete")
    }

    func testDestinationMetadataDistinguishesMissingNonDirectoryAndOtherErrors() throws {
        let file = temporaryDirectory.appendingPathComponent("file")
        try Data().write(to: file)
        let loop = temporaryDirectory.appendingPathComponent("loop")
        XCTAssertEqual(symlink("loop", loop.path), 0)
        for (destination, code) in [(temporaryDirectory.appendingPathComponent("missing"), ENOENT),
                                    (file.appendingPathComponent("child"), ENOTDIR), (loop, ELOOP)] {
            XCTAssertThrowsError(try FileCreationService().createFile(for: FileCreationRequest(
                template: FileTemplate(name: "text", fileExtension: "txt", content: "complete"),
                destinationFolder: destination, requestedFilename: "result"
            ))) { error in
                switch (code, error) {
                case (ENOENT, FileCreationError.destinationDoesNotExist): break
                case (ENOTDIR, FileCreationError.destinationIsNotDirectory): break
                case (ELOOP, let FileCreationError.writeFailed(_, underlying)):
                    XCTAssertEqual((underlying as NSError).domain, NSPOSIXErrorDomain)
                    XCTAssertEqual((underlying as NSError).code, Int(ELOOP))
                default: XCTFail("Unexpected error for errno \(code): \(error)")
                }
            }
        }
    }

    private func makeNonmemberGroupDirectory() throws -> URL {
        let folder = URL(fileURLWithPath: "/private/tmp/QuickFileNonmemberGroupTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var info = stat()
        XCTAssertEqual(stat(folder.path, &info), 0)
        var groups = [gid_t](repeating: 0, count: Int(getgroups(0, nil)))
        XCTAssertEqual(getgroups(Int32(groups.count), &groups), Int32(groups.count))
        guard info.st_gid != getegid(), !groups.contains(info.st_gid) else {
            try FileManager.default.removeItem(at: folder)
            throw XCTSkip("The isolated /private/tmp directory must inherit a group outside the test account's groups")
        }
        return folder
    }

    func testRootOwnedStickyDirectoryCreatesWithInheritedGroupWhileProbePolicyStaysRestricted() throws {
        let descriptor = open("/private/tmp", O_SEARCH | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var info = stat()
        XCTAssertEqual(fstat(descriptor, &info), 0)
        guard info.st_uid == 0, info.st_mode & S_ISVTX != 0, geteuid() != 0 else {
            throw XCTSkip("This check requires the standard root-owned sticky /private/tmp")
        }

        XCTAssertNoThrow(try PrivateFileStagingDirectory.validateDestinationParent(descriptor, allowRootOwnedStickyParent: true))
        XCTAssertThrowsError(try PrivateFileStagingDirectory.validateDestinationParent(descriptor, allowRootOwnedStickyParent: false))
        var groups = [gid_t](repeating: 0, count: Int(getgroups(0, nil)))
        XCTAssertEqual(getgroups(Int32(groups.count), &groups), Int32(groups.count))
        guard info.st_gid != getegid(), !groups.contains(info.st_gid) else {
            throw XCTSkip("The root-owned sticky directory must have a group outside this account's groups")
        }
        let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        let group = info.st_gid
        let name = "QuickFileRootStickyTests-" + UUID().uuidString
        let service = FileCreationService(beforeCommit: { stage in
            XCTAssertEqual(stage.deletingLastPathComponent().resolvingSymlinksInPath(), folder.resolvingSymlinksInPath())
            XCTAssertTrue(stage.lastPathComponent.hasPrefix(".quickfile-staging-"))
        })
        let result = try service.createFile(for: FileCreationRequest(
            template: FileTemplate(name: "text", fileExtension: "txt", content: "complete"),
            destinationFolder: folder, requestedFilename: name
        ))
        let file = openat(descriptor, result.fileURL.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(file, 0)
        guard file >= 0 else { return }
        defer { close(file) }
        var owned = stat()
        XCTAssertEqual(fstat(file, &owned), 0)
        // The root-owned sticky parent prevents another user from replacing our
        // entry. Still verify identity and never recursively clean the public root.
        defer {
            var current = stat()
            if fstatat(descriptor, result.fileURL.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_dev == owned.st_dev, current.st_ino == owned.st_ino, current.st_uid == geteuid() {
                XCTAssertEqual(unlinkat(descriptor, result.fileURL.lastPathComponent, 0), 0)
            } else {
                XCTFail("Created test entry identity changed; preserved \(result.fileURL.path)")
            }
        }
        XCTAssertEqual(owned.st_gid, group)
        XCTAssertEqual(result.fileURL.lastPathComponent, name + ".txt")
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "complete")
    }
}

private final class ReplacementDirectoryFileManager: FileManager, @unchecked Sendable {
    private let directory: URL
    private let requests = FileCreationCallCounter()

    var requestCount: Int { requests.count }

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    override func url(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?,
        create shouldCreate: Bool
    ) throws -> URL {
        requests.record()
        return self.directory
    }
}

// Provider callbacks may run on different queues; protect all observations with the lock.
private final class FileCreationCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
