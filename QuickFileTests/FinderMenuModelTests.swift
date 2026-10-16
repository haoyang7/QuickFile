import XCTest
@testable import QuickFileCore

final class FinderMenuModelTests: XCTestCase {
    func testHistoricalControlsAreRemovedOnlyFromMenuProjection() throws {
        let values = Array(0...31) + Array(127...159)
            + [0x061C, 0x200B, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069)
        let controls = values.map { String(UnicodeScalar($0)!) }.joined()
        let name = "می\u{200C}خواهم-👩‍💻-✈\u{FE0F}-e\u{301}"
        let original = FileTemplate(name: name + controls, fileExtension: ".t" + controls + "xt", content: "unchanged")
        let historical = try JSONDecoder().decode(FileTemplate.self, from: JSONEncoder().encode(original))
        let entry = FinderTemplateMenuEntry(template: historical)
        XCTAssertEqual(entry.id, original.id)
        XCTAssertEqual(Array(entry.title.utf8), Array((name + " (.txt)").utf8))
        XCTAssertEqual(Array(historical.name.utf8), Array(original.name.utf8))
        XCTAssertEqual(Array(historical.fileExtension.utf8), Array(original.fileExtension.utf8))
        XCTAssertEqual(historical.content, original.content)

        let blank = FileTemplate(name: " " + controls, fileExtension: controls, content: "")
        XCTAssertEqual(FinderTemplateMenuEntry(template: blank).title, "未命名模板")
    }

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

        let tag = registry.registerMenu([FinderMenuAction(
            templateID: templateID,
            context: .container,
            destinationFolder: destination
        )])[0]

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

        let firstTag = registry.registerMenu([FinderMenuAction(
            templateID: firstID,
            context: .items,
            destinationFolder: firstDestination
        )])[0]
        let secondTag = registry.registerMenu([FinderMenuAction(
            templateID: secondID,
            context: .toolbar,
            destinationFolder: secondDestination
        )])[0]

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
        let firstTag = registry.registerMenu([FinderMenuAction(
            templateID: UUID(),
            context: .items,
            destinationFolder: destination
        )])[0]
        let secondTag = registry.registerMenu([FinderMenuAction(
            templateID: UUID(),
            context: .container,
            destinationFolder: destination
        )])[0]
        let thirdTag = registry.registerMenu([FinderMenuAction(
            templateID: UUID(),
            context: .sidebar,
            destinationFolder: destination
        )])[0]

        XCTAssertNil(registry.takeAction(for: firstTag))
        XCTAssertNotNil(registry.takeAction(for: secondTag))
        XCTAssertNotNil(registry.takeAction(for: thirdTag))
    }

    func testCurrentMenuDoesNotEvictActionsWhenTemplateCountExceedsFormerLimit() {
        let registry = FinderMenuActionRegistry()
        let destination = URL(fileURLWithPath: "/tmp", isDirectory: true)

        let tags = registry.registerMenu((0..<300).map { _ in
            FinderMenuAction(
                templateID: UUID(),
                context: .container,
                destinationFolder: destination
            )
        })

        XCTAssertEqual(tags.compactMap(registry.takeAction(for:)).count, 300)
    }

    func testConcurrentMenuBatchesAreRetainedOrEvictedAsAWhole() {
        let registry = FinderMenuActionRegistry(retainedGenerationCount: 3)
        let batches = LockedTestValue<[(tags: [Int], actions: [FinderMenuAction])]>([])
        DispatchQueue.concurrentPerform(iterations: 12) { batch in
            let destination = URL(fileURLWithPath: "/tmp/Menu-\(batch)", isDirectory: true)
            let actions = (0..<300).map { _ in
                FinderMenuAction(templateID: UUID(), context: .container, destinationFolder: destination,
                                 menuTimingID: "menu-\(batch)")
            }
            let tags = registry.registerMenu(actions)
            batches.update { $0.append((tags, actions)) }
        }

        // Tags are increasing within this bounded run, so their first value
        // identifies registration order independently of worker completion order.
        let ordered = batches.value.sorted { $0.tags[0] < $1.tags[0] }
        let allTags = ordered.flatMap(\.tags)
        XCTAssertEqual(Set(allTags).count, 3_600)
        XCTAssertTrue(allTags.allSatisfy { $0 > 0 })
        for (index, batch) in ordered.enumerated() {
            let taken = batch.tags.compactMap(registry.takeAction(for:))
            XCTAssertEqual(taken, index < 9 ? [] : batch.actions,
                           "Eviction must never leave only part of a menu registered")
            XCTAssertTrue(batch.tags.compactMap(registry.takeAction(for:)).isEmpty)
        }
    }

    func testDuplicateTemplateIDsKeepDistinctActionsAndEmptyMenusAdvanceRetention() {
        let registry = FinderMenuActionRegistry(retainedGenerationCount: 2)
        let id = UUID()
        let actions = ["First", "Second"].map {
            FinderMenuAction(templateID: id, context: .container,
                             destinationFolder: URL(fileURLWithPath: "/tmp/\($0)"))
        }
        let tags = registry.registerMenu(actions)
        XCTAssertEqual(Set(tags).count, 2)
        XCTAssertEqual(registry.takeAction(for: tags[0]), actions[0])
        XCTAssertTrue(registry.registerMenu([]).isEmpty)
        let newerTags = registry.registerMenu(actions)
        XCTAssertNil(registry.takeAction(for: tags[1]))
        XCTAssertEqual(newerTags.compactMap(registry.takeAction(for:)), actions)
    }

    func testRegistryCapturesRawSelectionWithoutResolvingTheVolume() throws {
        let registry = FinderMenuActionRegistry()
        let templateID = UUID()
        let original = URL(fileURLWithPath: "/Volumes/NotMounted/folder/item")
        var selection = [original]
        let tag = registry.registerMenu([FinderMenuAction(
            templateID: templateID, context: .items,
            targetedURL: original, selectedItemURLs: selection
        )])[0]
        selection.removeAll()
        let action = try XCTUnwrap(registry.takeAction(for: tag))
        XCTAssertEqual(action.target, .selection(targetedURL: original, selectedItemURLs: [original]))
        XCTAssertNil(registry.takeAction(for: tag))
    }

    func testActionsCaptureOnlyTheSelectionRequiredByEachContext() throws {
        let first = URL(fileURLWithPath: "/Volumes/NotMounted/folder/../first")
        let second = URL(fileURLWithPath: "/Volumes/NotMounted/folder/second")
        let target = URL(fileURLWithPath: "/Volumes/NotMounted/target/../folder")
        let templateID = UUID()
        let identity = try DirectoryIdentity.capture(at: FileManager.default.temporaryDirectory)
        let prepared = FinderMenuDestination(folder: target, identity: identity)

        for context in [FinderMenuContext.container, .toolbar, .items, .sidebar] {
            for targetedURL in [nil, target] {
                for selection in [[], [first], [first, second]] {
                    let action = FinderMenuAction(
                        templateID: templateID, context: context, targetedURL: targetedURL,
                        selectedItemURLs: selection, preparedDestination: prepared, menuTimingID: "original-menu"
                    )
                    let ignoresSelection = context == .container || (context == .toolbar && targetedURL != nil)
                    let expected = ignoresSelection ? selection.first.map { [$0] } ?? [] : selection
                    XCTAssertEqual(action.target, .selection(targetedURL: targetedURL, selectedItemURLs: expected))
                    XCTAssertEqual(action.templateID, templateID)
                    XCTAssertEqual(action.context, context)
                    XCTAssertEqual(action.preparedDestination, prepared)
                    XCTAssertEqual(action.menuTimingID, "original-menu")
                }
            }
        }
    }

    func testActionSelectionPreservesMixedAndMissingTailForBackgroundValidation() throws {
        let parent = URL(fileURLWithPath: "/QuickFileFixture/Selection")
        let items = (0..<257).map { parent.appendingPathComponent("item-\($0)") }
        for context in [FinderMenuContext.items, .toolbar] {
            for mixedParents in [false, true] {
                var selection = items
                if mixedParents {
                    selection[256] = URL(fileURLWithPath: "/QuickFileFixture/Other/tail")
                }
                let action = FinderMenuAction(templateID: UUID(), context: context,
                                              targetedURL: nil, selectedItemURLs: selection)
                guard case let .selection(targetedURL, captured) = action.target else {
                    return XCTFail("Expected captured selection")
                }
                var inspected: [URL] = []
                let resolver = FinderContextResolver(isDirectory: { _ in true }, entryExists: { url in
                    inspected.append(url)
                    return url != items.last
                })
                XCTAssertEqual(captured, selection)
                XCTAssertNil(resolver.destinationFolder(for: context, targetedURL: targetedURL, selectedItemURLs: captured))
                XCTAssertEqual(inspected, mixedParents ? [] : items)
            }
        }
    }

    func testRegistryKeepsThreeGenerationsOfReducedSelectionActionsAndTheirOriginalProof() throws {
        let registry = FinderMenuActionRegistry()
        let parent = URL(fileURLWithPath: "/Volumes/NotMounted/Selection")
        let identity = try DirectoryIdentity.capture(at: FileManager.default.temporaryDirectory)
        let prepared = FinderMenuDestination(folder: parent, identity: identity)
        var tags: [[Int]] = []
        var expectedActions: [FinderMenuAction] = []
        for generation in 0..<3 {
            let selection = (0..<5_000).map { parent.appendingPathComponent("generation-\(generation)-item-\($0)") }
            let context: FinderMenuContext = generation == 1 ? .toolbar : .container
            let action = FinderMenuAction(templateID: UUID(), context: context,
                                          targetedURL: parent, selectedItemURLs: selection,
                                          preparedDestination: prepared, menuTimingID: "menu-\(generation)")
            tags.append(registry.registerMenu([action, action]))
            expectedActions.append(action)
            XCTAssertEqual(action.target, .selection(targetedURL: parent, selectedItemURLs: [selection[0]]))
        }
        for index in 0..<3 {
            XCTAssertEqual(registry.takeAction(for: tags[index][0]), expectedActions[index])
        }
        // An empty fourth menu advances retention without replacing any captured proof.
        _ = registry.registerMenu([])
        XCTAssertNil(registry.takeAction(for: tags[0][1]))
        for index in 1..<3 {
            let retained = try XCTUnwrap(registry.takeAction(for: tags[index][1]))
            XCTAssertEqual(retained, expectedActions[index])
            XCTAssertEqual(retained.preparedDestination, prepared)
            XCTAssertNil(registry.takeAction(for: tags[index][1]))
        }
    }

    func testRegistryPreservesMenuTraceIdentityAcrossMenuRebuild() throws {
        let registry = FinderMenuActionRegistry()
        let menuID = UUID().uuidString
        let tag = registry.registerMenu([FinderMenuAction(templateID: UUID(), context: .container,
            targetedURL: URL(fileURLWithPath: "/tmp"), selectedItemURLs: [], menuTimingID: menuID)])[0]
        _ = registry.registerMenu([])
        XCTAssertEqual(try XCTUnwrap(registry.takeAction(for: tag)).menuTimingID, menuID)
        XCTAssertNil(registry.takeAction(for: tag))
    }
}
