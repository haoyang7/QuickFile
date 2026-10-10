import XCTest
@testable import QuickFileCore

final class FinderContextResolverTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var childDirectory: URL!
    private var fileURL: URL!
    private let resolver = FinderContextResolver()

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickFileFinderContextTests-\(UUID().uuidString)", isDirectory: true)
        childDirectory = temporaryDirectory.appendingPathComponent("Child", isDirectory: true)
        fileURL = temporaryDirectory.appendingPathComponent("note.md")

        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        try Data().write(to: fileURL)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        childDirectory = nil
        fileURL = nil
    }

    func testContainerMenuUsesTargetedDirectory() {
        let result = resolver.destinationFolder(
            for: .container,
            targetedURL: temporaryDirectory,
            selectedItemURLs: []
        )

        XCTAssertEqual(result, temporaryDirectory.standardizedFileURL)
    }

    func testItemActionFallsBackToTargetedDirectoryWhenSelectionIsEmpty() {
        let result = resolver.destinationFolder(
            for: .items,
            targetedURL: temporaryDirectory,
            selectedItemURLs: []
        )

        XCTAssertEqual(result, temporaryDirectory.standardizedFileURL)
    }

    func testSingleSelectedDirectoryCreatesInsideDirectory() {
        let result = resolver.destinationFolder(
            for: .items,
            targetedURL: childDirectory,
            selectedItemURLs: [childDirectory]
        )

        XCTAssertEqual(result, childDirectory.standardizedFileURL)
    }

    func testSingleSelectedFileUsesContainingDirectory() {
        let result = resolver.destinationFolder(
            for: .items,
            targetedURL: fileURL,
            selectedItemURLs: [fileURL]
        )

        XCTAssertEqual(result, temporaryDirectory.standardizedFileURL)
    }

    func testMultipleSelectedItemsUseCommonParent() throws {
        let secondFile = temporaryDirectory.appendingPathComponent("second.txt")
        try Data().write(to: secondFile)

        let result = resolver.destinationFolder(
            for: .items,
            targetedURL: fileURL,
            selectedItemURLs: [fileURL, secondFile]
        )

        XCTAssertEqual(result, temporaryDirectory.standardizedFileURL)
    }

    func testMultipleItemsFromDifferentFoldersDoNotResolve() throws {
        let nestedFile = childDirectory.appendingPathComponent("nested.txt")
        try Data().write(to: nestedFile)

        let result = resolver.destinationFolder(
            for: .items,
            targetedURL: nil,
            selectedItemURLs: [fileURL, nestedFile]
        )

        XCTAssertNil(result)
    }

    func testMixedParentsRejectBeforeExplicitMetadataReadsIncludingDeferredTail() {
        // Index 256 is outside the menu preflight's 256-item inspection window.
        for differingIndex in [1, 256] {
            for context in [FinderMenuContext.items, .toolbar] {
                var parentReads = 0
                var itemReads = 0
                let resolver = FinderContextResolver(isDirectory: { _ in
                    parentReads += 1
                    return true
                }, entryExists: { _ in
                    itemReads += 1
                    return true
                })
                var items = Array(repeating: fileURL!, count: 257)
                items[differingIndex] = childDirectory.appendingPathComponent("other.txt")

                XCTAssertNil(resolver.destinationFolder(
                    for: context, targetedURL: nil, selectedItemURLs: items
                ))
                XCTAssertEqual(parentReads, 0, "Mixed parents must fail before explicit directory metadata")
                XCTAssertEqual(itemReads, 0, "Mixed parents must fail before explicit entry metadata")
            }
        }
    }

    func testSameParentSelectionValidatesEveryEntryIncludingMissingDeferredTail() {
        let items = (0..<257).map { temporaryDirectory.appendingPathComponent("item-\($0)") }
        for tailExists in [true, false] {
            var checkedParents: [URL] = []
            var checkedItems: [URL] = []
            let resolver = FinderContextResolver(isDirectory: { url in
                checkedParents.append(url)
                return true
            }, entryExists: { url in
                checkedItems.append(url)
                return tailExists || url != items.last
            })

            XCTAssertEqual(resolver.destinationFolder(
                for: .items, targetedURL: temporaryDirectory, selectedItemURLs: items
            ), tailExists ? temporaryDirectory.standardizedFileURL : nil)
            XCTAssertEqual(checkedParents, [temporaryDirectory.standardizedFileURL])
            XCTAssertEqual(checkedItems, items, "The menu preflight limit must not truncate background validation")
        }
    }

    func testMissingCommonParentSkipsEntryMetadata() {
        var parentReads = 0
        var itemReads = 0
        let resolver = FinderContextResolver(isDirectory: { _ in
            parentReads += 1
            return false
        }, entryExists: { _ in
            itemReads += 1
            return true
        })
        XCTAssertNil(resolver.destinationFolder(
            for: .items, targetedURL: temporaryDirectory,
            selectedItemURLs: Array(repeating: fileURL!, count: 257)
        ))
        XCTAssertEqual(parentReads, 1)
        XCTAssertEqual(itemReads, 0)
    }

    func testToolbarFallsBackToSelectedItem() {
        let result = resolver.destinationFolder(
            for: .toolbar,
            targetedURL: nil,
            selectedItemURLs: [fileURL]
        )

        XCTAssertEqual(result, temporaryDirectory.standardizedFileURL)
    }

    func testSidebarUsesClickedSelectionInsteadOfCurrentWindowTarget() {
        let result = resolver.destinationFolder(
            for: .sidebar,
            targetedURL: temporaryDirectory,
            selectedItemURLs: [childDirectory]
        )

        XCTAssertEqual(result, childDirectory.standardizedFileURL)
    }

    func testSidebarRejectsMissingAmbiguousOrNonDirectorySelection() throws {
        let missingDirectory = childDirectory.appendingPathComponent("missing")
        let nonFileURL = try XCTUnwrap(URL(string: "https://example.com/sidebar"))
        let selections: [[URL]] = [[], [childDirectory, temporaryDirectory], [fileURL], [missingDirectory], [nonFileURL]]
        for selection in selections {
            XCTAssertNil(resolver.destinationFolder(
                for: .sidebar, targetedURL: temporaryDirectory, selectedItemURLs: selection
            ), "A valid window target must not rescue an invalid sidebar selection")
        }
    }

    func testSidebarSelectionDoesNotRequireAWindowTarget() {
        XCTAssertEqual(resolver.destinationFolder(
            for: .sidebar, targetedURL: nil, selectedItemURLs: [childDirectory]
        ), childDirectory.standardizedFileURL)
    }

    func testToolbarPrefersCurrentTargetOverSelectedFolder() {
        let result = resolver.destinationFolder(
            for: .toolbar,
            targetedURL: temporaryDirectory,
            selectedItemURLs: [childDirectory]
        )

        XCTAssertEqual(result, temporaryDirectory.standardizedFileURL)
    }

    func testMissingTargetsDoNotFallBackToParentOrSelection() {
        let missingURL = childDirectory.appendingPathComponent("missing.txt")

        XCTAssertNil(resolver.destinationFolder(
            for: .container,
            targetedURL: missingURL,
            selectedItemURLs: [fileURL]
        ))
        XCTAssertNil(resolver.destinationFolder(
            for: .items,
            targetedURL: missingURL,
            selectedItemURLs: []
        ))
        XCTAssertNil(resolver.destinationFolder(
            for: .sidebar,
            targetedURL: missingURL,
            selectedItemURLs: [fileURL]
        ))
        XCTAssertNil(resolver.destinationFolder(
            for: .toolbar,
            targetedURL: missingURL,
            selectedItemURLs: [fileURL]
        ))
    }

    func testContainerRejectsExistingFile() {
        XCTAssertNil(resolver.destinationFolder(
            for: .container,
            targetedURL: fileURL,
            selectedItemURLs: []
        ))
    }

    func testItemSelectionsContainingMissingItemDoNotFallBackToTarget() {
        let missingSibling = temporaryDirectory.appendingPathComponent("missing.txt")

        XCTAssertNil(resolver.destinationFolder(
            for: .items,
            targetedURL: temporaryDirectory,
            selectedItemURLs: [missingSibling]
        ))
        XCTAssertNil(resolver.destinationFolder(
            for: .items,
            targetedURL: temporaryDirectory,
            selectedItemURLs: [fileURL, missingSibling]
        ))
    }

    func testNonFileURLsAreRejectedInEveryContext() throws {
        let nonFileURL = try XCTUnwrap(URL(string: "https://example.com/item"))

        XCTAssertNil(resolver.destinationFolder(
            for: .container,
            targetedURL: nonFileURL,
            selectedItemURLs: []
        ))
        XCTAssertNil(resolver.destinationFolder(
            for: .items,
            targetedURL: temporaryDirectory,
            selectedItemURLs: [nonFileURL]
        ))
        XCTAssertNil(resolver.destinationFolder(
            for: .sidebar,
            targetedURL: nonFileURL,
            selectedItemURLs: [fileURL]
        ))
        XCTAssertNil(resolver.destinationFolder(
            for: .toolbar,
            targetedURL: nonFileURL,
            selectedItemURLs: [fileURL]
        ))
    }

    func testDanglingLinkIsAnExistingSelectionEntry() throws {
        let link = temporaryDirectory.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: temporaryDirectory.appendingPathComponent("missing")
        )
        for selection in [[link], [link, fileURL!]] {
            XCTAssertEqual(resolver.destinationFolder(
                for: .items, targetedURL: temporaryDirectory, selectedItemURLs: selection
            ), temporaryDirectory.standardizedFileURL)
        }
    }

    func testLiveDirectoryLinkStillCreatesInsideDirectory() throws {
        let link = temporaryDirectory.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: childDirectory)
        XCTAssertEqual(resolver.destinationFolder(
            for: .items, targetedURL: temporaryDirectory, selectedItemURLs: [link]
        ), link.standardizedFileURL)
    }

    func testInaccessibleDirectoryLinkDoesNotFallBackToItsParent() throws {
        let protected = temporaryDirectory.appendingPathComponent("protected")
        let target = protected.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = temporaryDirectory.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: protected.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.path) }
        XCTAssertNil(resolver.destinationFolder(
            for: .items, targetedURL: temporaryDirectory, selectedItemURLs: [link]
        ))
    }
}
