import XCTest
@testable import QuickFileCore

final class FinderMenuModelTests: XCTestCase {
    func testCachedMenuMetadataPreservesIdentityTitlesOrderAndDisplayLimit() throws {
        let originals = (0..<300).map {
            FileTemplate(name: "Template \($0)", fileExtension: "txt", content: "original \($0)")
        }
        let builder = FinderMenuModelBuilder()
        let entries = builder.entries(from: originals)
        let changedBodies = originals.map { template in
            var changed = template
            changed.content = String(repeating: "changed content ", count: 2048)
            return changed
        }
        XCTAssertEqual(entries, builder.entries(from: changedBodies))
        for count in [1, 10, 300, Int.max] {
            let limit = try FinderMenuDisplayLimit(maximumCount: count)
            let presentation = builder.presentation(fromEntries: entries, limit: limit)
            XCTAssertEqual(presentation, builder.presentation(from: originals, limit: limit))
            XCTAssertEqual(presentation.entries.map(\.id), Array(originals.prefix(count)).map(\.id))
        }
        XCTAssertEqual(builder.presentation(fromEntries: entries).entries.map(\.id), originals.map(\.id))
        XCTAssertTrue(builder.presentation(fromEntries: []).entries.isEmpty)
    }

    func testDisplayLimitValidationRejectsInvalidAndOverflowingInput() throws {
        XCTAssertEqual(try FinderMenuDisplayLimit(maximumCount: nil), .all)
        XCTAssertEqual(try FinderMenuDisplayLimit.parse(" 1 ").maximumCount, 1)
        XCTAssertEqual(try FinderMenuDisplayLimit.parse(String(Int.max)).maximumCount, Int.max)
        for text in ["", "0", "-1", "+1", "1.5", "１", "1 0", "999999999999999999999999999"] {
            XCTAssertThrowsError(try FinderMenuDisplayLimit.parse(text), text)
        }
        XCTAssertThrowsError(try FinderMenuDisplayLimit(maximumCount: 0))
        XCTAssertThrowsError(try FinderMenuDisplayLimit(maximumCount: -1))
    }

    func testLimitFiltersEnabledFirstPreservesOrderAndNeverMutatesTemplates() throws {
        let disabled = FileTemplate(name: "Disabled", fileExtension: "txt", content: "", isEnabled: false)
        let first = FileTemplate(name: "First", fileExtension: "txt", content: "")
        let second = FileTemplate(name: "Second", fileExtension: "txt", content: "")
        let templates = [disabled, second, first]
        let builder = FinderMenuModelBuilder()
        let limited = builder.presentation(from: templates, limit: try FinderMenuDisplayLimit(maximumCount: 1))
        XCTAssertEqual(limited.entries.map(\.id), [second.id])
        XCTAssertEqual(builder.entries(from: templates).map(\.id), [second.id, first.id])
        XCTAssertEqual(templates, [disabled, second, first])
        XCTAssertTrue(first.isEnabled)
        for count in [2, 3, Int.max] {
            let presentation = builder.presentation(from: templates, limit: try FinderMenuDisplayLimit(maximumCount: count))
            XCTAssertEqual(presentation.entries.map(\.id), [second.id, first.id])
        }
        XCTAssertTrue(builder.presentation(from: []).entries.isEmpty)
        XCTAssertTrue(builder.entries(from: [disabled], limit: try FinderMenuDisplayLimit(maximumCount: 1)).isEmpty)
    }

    func testLimitedBuilderStopsConsumingInputAtTheKthEnabledTemplate() throws {
        let disabled = FileTemplate(name: "Disabled", fileExtension: "txt", content: "", isEnabled: false)
        let first = FileTemplate(name: "First", fileExtension: "txt", content: "")
        let second = FileTemplate(name: "Second", fileExtension: "txt", content: "")
        let tail = (0..<5_000).map { FileTemplate(name: "Tail \($0)", fileExtension: "txt", content: "") }
        let templates = [disabled, first, disabled, second] + tail
        let cases: [(FinderMenuDisplayLimit, [FileTemplate], Int)] = [
            (try FinderMenuDisplayLimit(maximumCount: 1), [first], 2),
            (try FinderMenuDisplayLimit(maximumCount: 2), [first, second], 4),
            (.all, [first, second] + tail, templates.count),
            (try FinderMenuDisplayLimit(maximumCount: Int.max), [first, second] + tail, templates.count)
        ]
        for (limit, expected, expectedInspections) in cases {
            var inspected: [FileTemplate.ID] = []
            let input = AnySequence<FileTemplate> {
                var iterator = templates.makeIterator()
                return AnyIterator<FileTemplate> {
                    guard let template = iterator.next() else { return nil }
                    inspected.append(template.id)
                    return template
                }
            }
            let presentation = FinderMenuModelBuilder().buildPresentation(from: input, limit: limit)

            XCTAssertEqual(presentation.entries.map(\.id), expected.map(\.id))
            XCTAssertEqual(inspected, Array(templates.prefix(expectedInspections)).map(\.id),
                           "Limited menus must not even consume an item after the Kth enabled template")
        }
        XCTAssertEqual(templates, [disabled, first, disabled, second] + tail)
    }

    func testThreeHundredTemplatesRemainAvailableWhenLimitIsRestoredToAll() throws {
        let templates = (0..<300).map { FileTemplate(name: "Template \($0)", fileExtension: "txt", content: "") }
        let builder = FinderMenuModelBuilder()
        XCTAssertEqual(builder.entries(from: templates, limit: try FinderMenuDisplayLimit(maximumCount: 10)).count, 10)
        XCTAssertEqual(builder.entries(from: templates).map(\.id), templates.map(\.id))
        XCTAssertEqual(templates.count, 300)
    }

    func testSelectionPreflightStopsAtItsLimitAndNeverApprovesTheUninspectedTail() {
        let parent = URL(fileURLWithPath: "/tmp/Selection")
        let items = (0..<50_000).map { parent.appendingPathComponent("item\($0)") }
        XCTAssertEqual(FinderMenuSelectionPreflight.check([]), .sameParent)
        XCTAssertEqual(FinderMenuSelectionPreflight.check(Array(items.prefix(256))), .sameParent)
        XCTAssertEqual(FinderMenuSelectionPreflight.check(items), .deferred)
        var differingTail = items
        differingTail[256] = URL(fileURLWithPath: "/tmp/Other/item")
        XCTAssertEqual(FinderMenuSelectionPreflight.check(differingTail), .deferred)
        differingTail[1] = URL(fileURLWithPath: "/tmp/Other/item")
        XCTAssertEqual(FinderMenuSelectionPreflight.check(differingTail), .differentParents)
    }

    func testOnlyEnabledTemplatesBecomeMenuEntries() {
        let enabled = FileTemplate(name: "Markdown", fileExtension: "md", content: "")
        let disabled = FileTemplate(
            name: "JSON",
            fileExtension: "json",
            content: "{}",
            isEnabled: false
        )

        let entries = FinderMenuModelBuilder().entries(from: [enabled, disabled])

        XCTAssertEqual(entries.map(\.id), [enabled.id])
    }

    func testMenuTitleIncludesNormalizedExtension() {
        let template = FileTemplate(name: "Markdown", fileExtension: ".md", content: "")

        let entry = try? XCTUnwrap(FinderMenuModelBuilder().entries(from: [template]).first)

        XCTAssertEqual(entry?.title, "Markdown (.md)")
    }

    func testMenuTitleOmitsEmptyExtensionLabel() throws {
        let template = FileTemplate(name: "精确文件名", fileExtension: " . ", content: "")

        let entry = try XCTUnwrap(FinderMenuModelBuilder().entries(from: [template]).first)

        XCTAssertEqual(entry.title, "精确文件名")
    }

    func testLegacyBlankNamesHaveVisibleTitlesWithoutChangingTemplates() throws {
        for name in ["", " \t\n", "\u{00A0}\u{2003}"] {
            for fileExtension in ["", " . \t\n", " .txt "] {
                let original = FileTemplate(name: name, fileExtension: fileExtension, content: "unchanged")
                let stored = try JSONEncoder().encode([original])
                let loaded = try JSONDecoder().decode([FileTemplate].self, from: stored)
                let presentation = FinderMenuModelBuilder().presentation(from: loaded)
                let entry = try XCTUnwrap(presentation.entries.first)

                XCTAssertEqual(entry.title, fileExtension == " .txt " ? "未命名模板 (.txt)" : "未命名模板")
                XCTAssertFalse(entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertEqual(presentation.entries.count, 1)
                XCTAssertEqual(entry.id, original.id)
                XCTAssertEqual(entry.id, original.id)
                XCTAssertEqual(loaded, [original])
            }
        }
    }

    func testVisibleTemplateNamesKeepTheirExistingDisplayAndStoredWhitespace() throws {
        let template = FileTemplate(name: "  My template  ", fileExtension: "txt", content: "")
        let entry = try XCTUnwrap(FinderMenuModelBuilder().entries(from: [template]).first)
        XCTAssertEqual(entry.title, "  My template   (.txt)")
        XCTAssertEqual(entry.id, template.id)
    }

    func testActionRegistryPreservesDestinationSnapshot() throws {
        let templateID = UUID()
        let destination = URL(fileURLWithPath: "/tmp/Menu Target", isDirectory: true)
        let registry = FinderMenuActionRegistry()

        let tag = registry.register(
            templateID: templateID,
            context: .container,
            destinationFolder: destination
        )

        XCTAssertNotEqual(tag, 0)
        XCTAssertEqual(
            registry.takeAction(for: tag),
            FinderMenuAction(
                templateID: templateID,
                context: .container,
                destinationFolder: destination
            )
        )
        XCTAssertNil(registry.takeAction(for: tag))
    }

    func testActionRegistryKeepsOverlappingMenusSeparate() throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstDestination = URL(fileURLWithPath: "/tmp/First", isDirectory: true)
        let secondDestination = URL(fileURLWithPath: "/tmp/Second", isDirectory: true)
        let registry = FinderMenuActionRegistry()

        let firstTag = registry.register(
            templateID: firstID,
            context: .items,
            destinationFolder: firstDestination
        )
        registry.beginMenu()
        let secondTag = registry.register(
            templateID: secondID,
            context: .toolbar,
            destinationFolder: secondDestination
        )

        XCTAssertNotEqual(firstTag, secondTag)
        XCTAssertEqual(
            registry.takeAction(for: secondTag),
            FinderMenuAction(
                templateID: secondID,
                context: .toolbar,
                destinationFolder: secondDestination
            )
        )
        XCTAssertEqual(
            registry.takeAction(for: firstTag),
            FinderMenuAction(
                templateID: firstID,
                context: .items,
                destinationFolder: firstDestination
            )
        )
    }

    func testActionRegistryDiscardsActionsOlderThanRetainedMenuGenerations() {
        let registry = FinderMenuActionRegistry(retainedGenerationCount: 2)
        let destination = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let firstTag = registry.register(
            templateID: UUID(),
            context: .items,
            destinationFolder: destination
        )
        registry.beginMenu()
        let secondTag = registry.register(
            templateID: UUID(),
            context: .container,
            destinationFolder: destination
        )
        registry.beginMenu()
        let thirdTag = registry.register(
            templateID: UUID(),
            context: .sidebar,
            destinationFolder: destination
        )

        XCTAssertNil(registry.takeAction(for: firstTag))
        XCTAssertNotNil(registry.takeAction(for: secondTag))
        XCTAssertNotNil(registry.takeAction(for: thirdTag))
    }

    func testCurrentMenuDoesNotEvictActionsWhenTemplateCountExceedsFormerLimit() {
        let registry = FinderMenuActionRegistry()
        let destination = URL(fileURLWithPath: "/tmp", isDirectory: true)
        registry.beginMenu()

        let tags = (0..<300).map { _ in
            registry.register(
                templateID: UUID(),
                context: .container,
                destinationFolder: destination
            )
        }

        XCTAssertEqual(tags.compactMap(registry.takeAction(for:)).count, 300)
    }

    func testRegistryCapturesRawSelectionWithoutResolvingTheVolume() throws {
        let registry = FinderMenuActionRegistry()
        let templateID = UUID()
        let original = URL(fileURLWithPath: "/Volumes/NotMounted/folder/item")
        var selection = [original]
        let tag = registry.register(
            templateID: templateID, context: .items,
            targetedURL: original, selectedItemURLs: selection
        )
        selection.removeAll()
        let action = try XCTUnwrap(registry.takeAction(for: tag))
        XCTAssertEqual(action.target, .selection(targetedURL: original, selectedItemURLs: [original]))
        XCTAssertNil(registry.takeAction(for: tag))
    }

    func testRegistryPreservesMenuTraceIdentityAcrossMenuRebuild() throws {
        let registry = FinderMenuActionRegistry()
        let menuID = UUID().uuidString
        let tag = registry.register(templateID: UUID(), context: .container,
            targetedURL: URL(fileURLWithPath: "/tmp"), selectedItemURLs: [], menuTimingID: menuID)
        registry.beginMenu()
        XCTAssertEqual(try XCTUnwrap(registry.takeAction(for: tag)).menuTimingID, menuID)
        XCTAssertNil(registry.takeAction(for: tag))
    }
}
