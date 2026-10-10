import XCTest
import SwiftUI
@testable import QuickFile
@testable import QuickFileCore
@testable import QuickFileInfrastructure

@MainActor
final class TemplateManagerSelectionTests: XCTestCase {
    func testSearchDeletionSelectsVisibleSurvivorInsteadOfHiddenFirstTemplate() {
        let hidden = template("Alpha", fileExtension: "md")
        let deleted = template("Bravo", fileExtension: "txt")
        let survivor = template("Charlie", fileExtension: "txt")
        let current = model([hidden, survivor])
        XCTAssertEqual(current.templates.first?.id, hidden.id)
        XCTAssertEqual(TemplateManagerSelection.afterDeletion(
            of: deleted.id, succeeded: true, currentSelectionID: deleted.id,
            firstVisibleID: current.filteredTemplates(search: " TXT ").first?.id
        ), survivor.id)
    }

    func testEnabledOnlyDeletionSkipsDisabledFirstTemplate() {
        let hidden = template("Alpha", enabled: false)
        let deleted = template("Bravo")
        let survivor = template("Charlie")
        let current = model([hidden, survivor])
        XCTAssertEqual(TemplateManagerSelection.afterDeletion(
            of: deleted.id, succeeded: true, currentSelectionID: deleted.id,
            firstVisibleID: current.filteredTemplates(search: "", enabledOnly: true).first?.id
        ), survivor.id)
    }

    func testCombinedFiltersSkipBothDisabledMatchesAndEnabledNonmatches() {
        let deleted = template("Match deleted")
        let survivor = template("Match survivor")
        let current = model([template("Match disabled", enabled: false), template("Other"), survivor])
        XCTAssertEqual(TemplateManagerSelection.afterDeletion(
            of: deleted.id, succeeded: true, currentSelectionID: deleted.id,
            firstVisibleID: current.filteredTemplates(search: "match", enabledOnly: true).first?.id
        ), survivor.id)
    }

    func testDeletingLastSearchMatchClearsSelectionEvenWhenInventoryRemains() {
        let deleted = template("Match")
        let current = model([template("Other")])
        XCTAssertFalse(current.templates.isEmpty)
        XCTAssertNil(TemplateManagerSelection.afterDeletion(
            of: deleted.id, succeeded: true, currentSelectionID: deleted.id,
            firstVisibleID: current.filteredTemplates(search: "match").first?.id
        ))
    }

    func testDeletingLastEnabledTemplateClearsSelection() {
        let deleted = template("Enabled")
        let current = model([template("Disabled", enabled: false)])
        XCTAssertNil(TemplateManagerSelection.afterDeletion(
            of: deleted.id, succeeded: true, currentSelectionID: deleted.id,
            firstVisibleID: current.filteredTemplates(search: "", enabledOnly: true).first?.id
        ))
    }

    func testNewerSelectionIsNotOverwrittenByDeletionCompletion() {
        let deleted = UUID()
        let newerSelection = UUID()
        XCTAssertEqual(TemplateManagerSelection.afterDeletion(
            of: deleted, succeeded: true, currentSelectionID: newerSelection,
            firstVisibleID: UUID()
        ), newerSelection)
    }

    func testExplicitlyClearedSelectionIsNotOverwrittenByDeletionCompletion() {
        XCTAssertNil(TemplateManagerSelection.afterDeletion(
            of: UUID(), succeeded: true, currentSelectionID: nil, firstVisibleID: UUID()
        ))
    }

    func testFailedDeletionKeepsExistingOrNewerSelectionIncludingNil() {
        let deleted = UUID()
        for selection in [deleted, UUID(), nil] as [UUID?] {
            XCTAssertEqual(TemplateManagerSelection.afterDeletion(
                of: deleted, succeeded: false, currentSelectionID: selection,
                firstVisibleID: UUID()
            ), selection)
        }
    }

    func testCompletionUsesLatestFilterAndInventoryInsteadOfOriginalSurvivor() {
        let deleted = template("Old deleted")
        let originalSurvivor = template("Old survivor")
        var current = model([deleted, originalSurvivor])
        var search = "old"
        var enabledOnly = false
        XCTAssertEqual(current.filteredTemplates(search: search, enabledOnly: enabledOnly).map(\.id),
                       [deleted.id, originalSurvivor.id])

        // These are the latest inputs read after the save's suspension. No old
        // inventory, filter, or proposed replacement is an input to the policy.
        let latestSurvivor = template("New survivor")
        current = model([originalSurvivor, template("New disabled", enabled: false), latestSurvivor])
        search = "new"
        enabledOnly = true
        XCTAssertEqual(TemplateManagerSelection.afterDeletion(
            of: deleted.id, succeeded: true, currentSelectionID: deleted.id,
            firstVisibleID: current.filteredTemplates(search: search, enabledOnly: enabledOnly).first?.id
        ), latestSurvivor.id)
    }

    func testUnfilteredDeletionDeliberatelySelectsFirstVisibleSurvivor() {
        let first = template("First")
        let deleted = template("Middle")
        let last = template("Last")
        let current = model([first, last])
        XCTAssertEqual(TemplateManagerSelection.afterDeletion(
            of: deleted.id, succeeded: true, currentSelectionID: deleted.id,
            firstVisibleID: current.filteredTemplates(search: "").first?.id
        ), first.id)
        XCTAssertNil(TemplateManagerSelection.afterDeletion(
            of: deleted.id, succeeded: true, currentSelectionID: deleted.id,
            firstVisibleID: model([]).filteredTemplates(search: "").first?.id
        ))
    }

    private func template(_ name: String, fileExtension: String = "txt", enabled: Bool = true) -> FileTemplate {
        FileTemplate(name: name, fileExtension: fileExtension, content: "", isEnabled: enabled)
    }

    private func model(_ templates: [FileTemplate]) -> QuickFileViewModel {
        // This suite exercises the manager's pure completion decision and the
        // real filter, not the ViewModel's separate file-creation selection.
        // Explicit unavailable stores keep all App Group and bookmark I/O out.
        let grants = AuthorizedDirectoryStore(
            defaults: nil,
            persistentBookmarkCreator: { _ in throw FixtureError.unexpectedStorageAccess },
            transferBookmarkCreator: { _ in throw FixtureError.unexpectedStorageAccess },
            persistentBookmarkResolver: { _ in throw FixtureError.unexpectedStorageAccess },
            transferBookmarkResolver: { _ in throw FixtureError.unexpectedStorageAccess },
            startAccessing: { _ in false }, stopAccessing: { _ in }
        )
        return QuickFileViewModel(templateStore: TemplateStore(defaults: nil), templates: templates,
                                  authorizedDirectoryStore: grants)
    }

    private enum FixtureError: Error { case unexpectedStorageAccess }
}

@MainActor
final class TemplateEditorStateTests: XCTestCase {
    func testCopySavePreservesUntouchedImportedMetadataBytes() throws {
        let raw = FileTemplate(name: " e\u{301} ", fileExtension: " .txt ", content: "{{clipboard}}", isEnabled: false,
                               defaultFilename: " README ")
        let imported = try XCTUnwrap(TemplateTransfer.makeImportPlan(
            bundle: TemplateTransferBundle(templates: [raw]), existing: []
        ).templates.first)
        var state = TemplateEditorState(template: imported, isCopy: true)
        for content in [imported.content, "changed body"] {
            state.draft.content = content
            let copy = try state.makeTemplate()
            XCTAssertNotEqual(copy.id, imported.id)
            XCTAssertTrue(copy.name.utf8.elementsEqual(imported.name.utf8))
            XCTAssertTrue(copy.fileExtension.utf8.elementsEqual(imported.fileExtension.utf8))
            XCTAssertTrue(copy.defaultFilename.utf8.elementsEqual(imported.defaultFilename.utf8))
            XCTAssertEqual(copy.content, content)
            XCTAssertEqual(copy.isEnabled, imported.isEnabled)
        }
        state.draft.defaultFilename = " New "
        let editedCopy = try state.makeTemplate()
        XCTAssertEqual(editedCopy.defaultFilename, "New")
        XCTAssertTrue(editedCopy.name.utf8.elementsEqual(imported.name.utf8))
        let normalEdit = try TemplateEditorState(template: imported).makeTemplate()
        XCTAssertEqual(normalEdit.name, "e\u{301}")
        XCTAssertEqual(normalEdit.fileExtension, "txt")
        XCTAssertEqual(normalEdit.defaultFilename, "README")
    }

    func testCopyStartsWithIndependentIdentityAndPreservesLiteralFields() {
        let source = FileTemplate(name: "Dotfile", fileExtension: "", content: "{{clipboard}}", isEnabled: false,
                                  defaultFilename: ".gitignore")
        var state = TemplateEditorState(template: source, isCopy: true)
        XCTAssertNil(state.draft.id)
        XCTAssertEqual(state.draft.name, source.name)
        XCTAssertEqual(state.draft.content, source.content)
        XCTAssertEqual(state.draft.defaultFilename, ".gitignore")
        XCTAssertFalse(state.draft.isEnabled)
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.requestDismissal(), .dismiss)
        state.draft.defaultFilename = ".env"
        XCTAssertTrue(state.isDirty)
        XCTAssertEqual(source.defaultFilename, ".gitignore")
        XCTAssertTrue(state.copyText.contains("默认文件名：.env\n"))
    }

    func testDefaultFilenameUsesExactBytesForDirtyStateAndRestoration() {
        let source = FileTemplate(name: "Name", fileExtension: "txt", content: "", defaultFilename: "é")
        var state = TemplateEditorState(template: source)
        state.draft.defaultFilename = "e\u{0301}"
        XCTAssertEqual(state.draft.defaultFilename, source.defaultFilename)
        XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
        state.draft.defaultFilename = source.defaultFilename
        XCTAssertEqual(state.requestDismissal(), .dismiss)
    }

    func testUnchangedDraftCancelsWithoutConfirmation() {
        let state = TemplateEditorState(template: FileTemplate(name: "Name", fileExtension: "txt", content: "body"))
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.requestDismissal(), .dismiss)
        XCTAssertEqual(TemplateEditorState(template: nil).requestDismissal(), .dismiss)
    }

    func testEveryEditableFieldBecomesDirtyAndRevertingClearsIt() {
        let template = FileTemplate(name: "Name", fileExtension: "txt", content: "body")
        var state = TemplateEditorState(template: template)
        let baseline = state.draft
        state.draft.name += " changed"
        XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
        state.draft = baseline
        state.draft.fileExtension = "md"
        XCTAssertTrue(state.isDirty)
        state.draft = baseline
        state.draft.content += " draft"
        XCTAssertTrue(state.isDirty)
        state.draft = baseline
        state.draft.isEnabled = false
        XCTAssertTrue(state.isDirty)
        state.draft = baseline
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.requestDismissal(), .dismiss)
    }

    func testSavingBlocksCancelEscapeAndDuplicateSaveAndFailureRetainsDraft() {
        var state = TemplateEditorState(template: nil)
        state.draft.name = "New"
        state.draft.content = "unsaved {{clipboard}}"
        let draft = state.draft
        XCTAssertTrue(state.beginSave())
        XCTAssertFalse(state.beginSave())
        XCTAssertEqual(state.requestDismissal(), .blocked)
        state.finishSave(error: QuickFileViewModel.TemplateSaveError.changed)
        XCTAssertFalse(state.isSaving)
        XCTAssertEqual(state.draft, draft)
        XCTAssertTrue(state.offersConflictRecovery)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
    }

    func testConflictRecoveryFailureContinuesToPreserveLiteralDraft() {
        var state = TemplateEditorState(template: nil)
        state.draft.name = "Private draft"
        state.draft.content = "{{clipboard}}\n{{date}}\n"
        _ = state.beginSave()
        state.finishSave(error: TemplateStore.StoreError.configurationChanged)
        let draft = state.draft
        XCTAssertTrue(state.offersConflictRecovery)
        _ = state.beginSave()
        state.finishSave(error: TemplateStore.StoreError.persistenceFailed(NSError(domain: "test", code: 1)))
        XCTAssertEqual(state.draft, draft)
        XCTAssertTrue(state.offersConflictRecovery)
        XCTAssertTrue(state.copyText.contains("{{clipboard}}\n{{date}}\n"))
        XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
    }

    func testUnicodeEquivalentButByteDifferentEditStillRequiresDiscardConfirmation() {
        let template = FileTemplate(name: "Name", fileExtension: "txt", content: "\u{00e9}")
        var state = TemplateEditorState(template: template)
        state.draft.content = "e\u{0301}"
        XCTAssertTrue(state.isDirty)
        XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
        state.draft.content = template.content
        XCTAssertFalse(state.isDirty)
    }

    func testCancelledDiscardConfirmationDoesNotMutateDraft() {
        var state = TemplateEditorState(template: nil)
        state.draft.name = "Keep"
        let draft = state.draft
        XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
        XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
        XCTAssertEqual(state.draft, draft)
        XCTAssertFalse(state.isSaving)
    }

    func testNestedBindingsInvalidateForEveryFieldAndExactRevertsBecomeClean() {
        let template = FileTemplate(name: "Name", fileExtension: "txt", content: "body")
        var state = TemplateEditorState(template: template)
        // This is the same nested writable-key-path route as $editor.draft in
        // TemplateEditorView, rather than an onChange/equality-based callback.
        let binding = Binding(get: { state }, set: { state = $0 })
        let draft = binding.draft

        draft.name.wrappedValue = "Changed"
        XCTAssertTrue(state.isDirty)
        draft.name.wrappedValue = template.name
        XCTAssertFalse(state.isDirty)
        draft.fileExtension.wrappedValue = "md"
        XCTAssertTrue(state.isDirty)
        draft.fileExtension.wrappedValue = template.fileExtension
        XCTAssertFalse(state.isDirty)
        draft.content.wrappedValue = "changed body"
        XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
        draft.content.wrappedValue = template.content
        XCTAssertEqual(state.requestDismissal(), .dismiss)
        draft.isEnabled.wrappedValue.toggle()
        XCTAssertTrue(state.isDirty)
        draft.isEnabled.wrappedValue = template.isEnabled
        XCTAssertFalse(state.isDirty)
        draft.id.wrappedValue = nil
        XCTAssertTrue(state.isDirty)
        draft.id.wrappedValue = template.id
        XCTAssertFalse(state.isDirty)
    }

    func testCanonicalEquivalentNestedBindingEditsAreByteDirtyForEveryTextField() {
        let composed = "\u{00e9}"
        let decomposed = "e\u{0301}"
        let template = FileTemplate(name: composed, fileExtension: composed, content: composed)
        var state = TemplateEditorState(template: template)
        let binding = Binding(get: { state }, set: { state = $0 })
        let fields: [Binding<String>] = [binding.draft.name, binding.draft.fileExtension, binding.draft.content]
        for field in fields {
            field.wrappedValue = decomposed
            XCTAssertEqual(state.draft, TemplateDraft(template: template))
            XCTAssertTrue(state.isDirty, "Canonical equality must not hide a byte edit")
            XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
            field.wrappedValue = composed
            XCTAssertFalse(state.isDirty)
            XCTAssertEqual(state.requestDismissal(), .dismiss)
        }
    }

    func testWholeDraftReplacementInvalidatesEvenWhenEquatableReportsEqual() {
        let template = FileTemplate(name: "\u{00e9}", fileExtension: "\u{00e9}", content: "\u{00e9}")
        var state = TemplateEditorState(template: template)
        let baseline = state.draft
        let fields: [WritableKeyPath<TemplateDraft, String>] = [\.name, \.fileExtension, \.content]
        for field in fields {
            var replacement = baseline
            replacement[keyPath: field] = "e\u{0301}"
            XCTAssertEqual(replacement, baseline)
            state.draft = replacement
            XCTAssertTrue(state.isDirty)
            XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
            state.draft = baseline
            XCTAssertFalse(state.isDirty)
        }
        var replacement = baseline
        replacement.id = UUID()
        state.draft = replacement
        XCTAssertTrue(state.isDirty)
        state.draft = baseline
        replacement = baseline
        replacement.isEnabled.toggle()
        state.draft = replacement
        XCTAssertTrue(state.isDirty)
        state.draft = baseline
        XCTAssertEqual(state.requestDismissal(), .dismiss)
    }

    func testInoutMutationAndStateCopiesKeepIndependentDirtyResults() {
        func changeContent(_ draft: inout TemplateDraft) { draft.content += " changed" }
        var state = TemplateEditorState(template: FileTemplate(name: "Name", fileExtension: "txt", content: "body"))
        let clean = state
        changeContent(&state.draft)
        XCTAssertTrue(state.isDirty)
        XCTAssertFalse(clean.isDirty)
        let dirty = state
        state.draft = clean.draft
        XCTAssertFalse(state.isDirty)
        XCTAssertTrue(dirty.isDirty)
        XCTAssertEqual(dirty.requestDismissal(), .confirmDiscard)
    }

    func testEqualLengthCanonicalEditAndEmbeddedNULAreByteDirty() {
        // Both canonically equivalent forms use the same number of UTF-8 bytes,
        // so length rejection alone cannot protect exact draft semantics.
        let original = "a\u{0301}\u{0323}\0tail"
        let reordered = "a\u{0323}\u{0301}\0tail"
        XCTAssertEqual(original, reordered)
        XCTAssertEqual(original.utf8.count, reordered.utf8.count)
        var state = TemplateEditorState(template: FileTemplate(name: "Name", fileExtension: "txt", content: original))
        state.draft.content = reordered
        XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
        state.draft.content = original
        XCTAssertFalse(state.isDirty)
        state.draft.content = "a\u{0301}\u{0323}\0fail"
        XCTAssertTrue(state.isDirty, "Bytes after a NUL must also be compared")
    }

    func testBridgedUnicodeDraftEditsAndExactRestoration() {
        let source = NSString(string: String(repeating: "中🙂e\u{0301}", count: 1_024))
        let body = source as String
        var state = TemplateEditorState(template: FileTemplate(name: "Name", fileExtension: "txt", content: body))
        let clean = state
        let changed = NSMutableString(string: body)
        changed.replaceCharacters(in: NSRange(location: changed.length - 1, length: 1), with: "\u{0300}")
        state.draft.content = changed as String
        XCTAssertTrue(state.isDirty)
        XCTAssertFalse(clean.isDirty)
        XCTAssertTrue(clean.draft.content.utf8.elementsEqual(body.utf8))
        state.draft.content = source as String
        XCTAssertEqual(state.requestDismissal(), .dismiss)
        // Foundation chooses the representation. The counting fixture below
        // separately guarantees coverage when contiguous storage is unavailable.
    }

    func testLargeEqualLengthTailEditAndStateCopyRetainExactBaseline() {
        let body = String(repeating: "x", count: 2 * 1024 * 1024)
        var state = TemplateEditorState(template: FileTemplate(name: "Name", fileExtension: "txt", content: body))
        let clean = state
        state.draft.content.removeLast()
        state.draft.content.append("y")
        XCTAssertEqual(state.draft.content.utf8.count, body.utf8.count)
        XCTAssertTrue(state.isDirty)
        XCTAssertFalse(clean.isDirty)
        state.draft.content = clean.draft.content
        XCTAssertEqual(state.requestDismissal(), .dismiss)
    }

    func testRepeatedReadsOfLargeDraftDoNotNeedToRecomputeDirtyState() {
        let body = String(repeating: "x", count: 2 * 1024 * 1024)
        var state = TemplateEditorState(template: FileTemplate(name: "Name", fileExtension: "txt", content: body))
        // Protect correctness across the read sites used by body/dismissal. The
        // stored-property source contract, not this loop's timing, guards cost.
        for _ in 0..<1_000 {
            XCTAssertFalse(state.isDirty)
            XCTAssertEqual(state.requestDismissal(), .dismiss)
        }
        state.draft.content += "y"
        for _ in 0..<1_000 {
            XCTAssertTrue(state.isDirty)
            XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
        }
        state.draft.content = body
        XCTAssertFalse(state.isDirty)
    }
}


final class TemplateContentPreviewTests: XCTestCase {
    func testShortLiteralTextAndNewlineFormattingArePreserved() {
        XCTAssertEqual(TemplateContentPreview.summary(""), "")
        XCTAssertEqual(TemplateContentPreview.summary("  plain text  "), "plain text")
        XCTAssertEqual(TemplateContentPreview.summary("one\ntwo"), "one ↩︎ two")
        XCTAssertEqual(TemplateContentPreview.summary("{{clipboard}}\n{{date}}"), "{{clipboard}} ↩︎ {{date}}")
    }

    func testCharacterLimitStillTruncatesOrdinaryText() {
        let exact = String(repeating: "a", count: TemplateContentPreview.maximumCharacters)
        XCTAssertEqual(TemplateContentPreview.summary(exact), exact)
        XCTAssertEqual(TemplateContentPreview.summary(exact + "b"), exact + "…")
        XCTAssertEqual(TemplateContentPreview.summary(exact + String(repeating: "b", count: 1_000_000)), exact + "…")
    }

    func testHugeFirstCombiningClusterDoesNotBecomeAnUnboundedPreview() {
        let content = "e" + String(repeating: "\u{0301}", count: 1_000_000) + "tail"
        XCTAssertEqual(TemplateContentPreview.summary(content), "…")
    }

    func testHugeFirstZWJClusterDoesNotBecomeAnUnboundedPreview() {
        let content = "👩" + String(repeating: "\u{200D}👩", count: 200_000) + "tail"
        XCTAssertEqual(TemplateContentPreview.summary(content), "…")
    }

    func testCompletePrefixBeforeHugeClusterIsRetainedWithoutItsPartialTail() {
        let content = "prefix " + "e" + String(repeating: "\u{0301}", count: 100_000)
        XCTAssertEqual(TemplateContentPreview.summary(content), "prefix…")
    }

    func testZWJSequencesAreNotSplitByByteCutoff() {
        let family = "👩‍👩‍👧‍👦"
        XCTAssertEqual(family.utf8.count, 25)
        let content = String(repeating: family, count: 100)
        let summary = TemplateContentPreview.summary(content)
        // 32 families fit the 800-byte window. Its last cluster is dropped
        // conservatively because a suffix outside the window might extend it.
        XCTAssertEqual(summary, String(repeating: family, count: 31) + "…")
        assertBoundedValidUTF8(summary)
    }

    func testPartialMultibyteScalarAtWindowBoundaryIsNotRepairedOrDisplayed() {
        // Each unit is one 15-byte grapheme; 53 units use 795 bytes. The
        // remaining bytes split the three-byte scalar at the cutoff.
        let unit = "中" + String(repeating: "\u{0301}", count: 6)
        XCTAssertEqual(unit.utf8.count, 15)
        let prefix = String(repeating: unit, count: 53)
        let content = prefix + "🙂中suffix"
        let summary = TemplateContentPreview.summary(content)
        // The complete emoji is conservatively discarded along with the
        // incomplete following scalar. The 53 preceding clusters stay intact.
        XCTAssertEqual(summary, prefix + "…")
        XCTAssertFalse(summary.contains("\u{FFFD}"))
        assertBoundedValidUTF8(summary)
    }

    func testEveryMultibyteCutPositionProducesOnlyCompleteOriginalClusters() {
        let unit = "e" + String(repeating: "\u{0301}", count: 9) // 19 bytes, one cluster.
        for padding in 0..<12 {
            let prefix = String(repeating: unit, count: 41) + String(repeating: "x", count: padding)
            for scalar in ["é", "中", "🙂"] {
                let content = prefix + String(repeating: scalar, count: 100)
                let summary = TemplateContentPreview.summary(content)
                XCTAssertTrue(summary.hasSuffix("…"))
                let shown = String(summary.dropLast())
                XCTAssertTrue(content.utf8.starts(with: shown.utf8))
                XCTAssertFalse(shown.contains("\u{FFFD}"))
                assertBoundedValidUTF8(summary)
            }
        }
    }

    func testOutputBudgetIncludesNewlineExpansionAndEllipsis() {
        let content = String(repeating: "\n", count: 1_000_000)
        let summary = TemplateContentPreview.summary(content)
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertTrue(summary.contains("↩︎"))
        XCTAssertFalse(summary.contains("\n"))
        assertBoundedValidUTF8(summary)
    }

    func testOutputBudgetIncludesCRLFExpansionAndEllipsis() {
        let summary = TemplateContentPreview.summary(String(repeating: "\r\n", count: 1_000))
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertFalse(summary.contains("\n"))
        assertBoundedValidUTF8(summary)
    }

    func testExactInputByteBoundaryRetainsWholeClusterWithoutEllipsis() {
        // 800 bytes, a single complete cluster: no input truncation occurred.
        let content = "é" + String(repeating: "\u{0301}", count: 399)
        XCTAssertEqual(content.utf8.count, TemplateContentPreview.maximumInputBytes)
        let summary = TemplateContentPreview.summary(content)
        XCTAssertTrue(summary.utf8.elementsEqual(content.utf8))
        assertBoundedValidUTF8(summary)
    }

    func testSummaryNeverChangesOriginalBodyBytes() throws {
        let content = "  e\u{0301}\n{{clipboard}}👩‍👩‍👧‍👦" + String(repeating: "\u{0301}", count: 1_000)
        let template = FileTemplate(name: "Name", fileExtension: "txt", content: content)
        let originalBytes = Array(template.content.utf8)
        _ = TemplateContentPreview.summary(template.content)
        XCTAssertEqual(Array(template.content.utf8), originalBytes)
        let saved = try TemplateDraft(template: template).makeTemplate()
        XCTAssertEqual(Array(saved.content.utf8), originalBytes)
    }

    private func assertBoundedValidUTF8(_ summary: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(summary.utf8.count, TemplateContentPreview.maximumOutputBytes, file: file, line: line)
        XCTAssertNotNil(String(bytes: summary.utf8, encoding: .utf8), file: file, line: line)
    }
}

final class TemplateByteOperationsTests: XCTestCase {
    func testAliasedBuffersStillCompareLengthsAndOffsetsExactly() {
        let bytes: [UInt8] = [1, 2, 1, 2, 0, 3]
        bytes.withUnsafeBufferPointer { buffer in
            XCTAssertTrue(TemplateByteOperations.areEqual(buffer, buffer))
            let prefix = UnsafeBufferPointer(start: buffer.baseAddress, count: 2)
            let longer = UnsafeBufferPointer(start: buffer.baseAddress, count: 3)
            let equalAtOffset = UnsafeBufferPointer(start: buffer.baseAddress!.advanced(by: 2), count: 2)
            let differentAtOffset = UnsafeBufferPointer(start: buffer.baseAddress!.advanced(by: 4), count: 2)
            XCTAssertFalse(TemplateByteOperations.areEqual(prefix, longer))
            XCTAssertTrue(TemplateByteOperations.areEqual(prefix, equalAtOffset))
            XCTAssertFalse(TemplateByteOperations.areEqual(prefix, differentAtOffset))
        }
    }

    func testContiguousBuffersUseBulkComparisonWithoutElementIteration() {
        for (left, right, expected) in [
            ([UInt8](), [UInt8](), true),
            ([], [0], false),
            ([0], [], false),
            ([1, 0, 2], [1, 0, 2], true),
            ([1, 0, 2], [1, 0, 3], false),
            (Array(repeating: UInt8(120), count: 65_536), Array(repeating: UInt8(120), count: 65_537), false)
        ] {
            let accesses = ByteAccesses()
            XCTAssertEqual(TemplateByteOperations.areEqual(
                TestBytes(left, contiguous: true, accesses: accesses),
                TestBytes(right, contiguous: true, accesses: accesses)
            ), expected)
            XCTAssertEqual(accesses.elementReads, 0, "Contiguous storage must bypass per-byte iteration")
        }
    }

    func testUTF8InputsAgreeWithByteOracleAcrossEmptyUnicodeAndNULValues() {
        let values = ["", "a", "b", "\0", "a\0b", "a\0c", "é", "e\u{0301}", "中", "🙂",
                      "a\u{0301}\u{0323}", "a\u{0323}\u{0301}"]
        for left in values {
            for right in values {
                XCTAssertEqual(TemplateByteOperations.areEqual(left.utf8, right.utf8),
                               Array(left.utf8) == Array(right.utf8))
            }
        }
    }

    func testUnavailableStorageOnEitherSideFallsBackToExactElementComparison() {
        for (leftContiguous, rightContiguous) in [(false, true), (true, false), (false, false)] {
            for (right, expected) in [([UInt8(1), 0, 2], true), ([UInt8(1), 0, 3], false)] {
                let accesses = ByteAccesses()
                XCTAssertEqual(TemplateByteOperations.areEqual(
                    TestBytes([1, 0, 2], contiguous: leftContiguous, accesses: accesses),
                    TestBytes(right, contiguous: rightContiguous, accesses: accesses)
                ), expected)
                XCTAssertGreaterThan(accesses.elementReads, 0)
            }
        }
    }

    func testHashAgreesAcrossContiguousAndFallbackStorageAtChunkBoundaries() {
        for count in [0, 1, 4_095, 4_096, 4_097, 8_192, 8_193] {
            let bytes = (0..<count).map { UInt8(truncatingIfNeeded: $0) }
            let directAccesses = ByteAccesses(), fallbackAccesses = ByteAccesses()
            let seed = Hasher()
            var direct = seed, fallback = seed
            TemplateByteOperations.hash(TestBytes(bytes, contiguous: true, accesses: directAccesses), into: &direct)
            TemplateByteOperations.hash(TestBytes(bytes, contiguous: false, accesses: fallbackAccesses), into: &fallback)
            XCTAssertEqual(direct.finalize(), fallback.finalize(), "Storage must not change a template's hash: \(count)")
            XCTAssertEqual(directAccesses.elementReads, 0)
            XCTAssertEqual(fallbackAccesses.elementReads, count)
        }
    }

    private final class ByteAccesses {
        var elementReads = 0
    }

    /// Supplies optional contiguous storage while counting only element access.
    /// This checks the algorithm's route without relying on timings or the
    /// Foundation bridge's choice of String representation on a given OS.
    private struct TestBytes: RandomAccessCollection {
        let storage: [UInt8]
        let contiguous: Bool
        let accesses: ByteAccesses

        init(_ storage: [UInt8], contiguous: Bool, accesses: ByteAccesses) {
            self.storage = storage
            self.contiguous = contiguous
            self.accesses = accesses
        }

        var startIndex: Int { storage.startIndex }
        var endIndex: Int { storage.endIndex }
        func index(after index: Int) -> Int { index + 1 }
        func index(before index: Int) -> Int { index - 1 }
        subscript(index: Int) -> UInt8 {
            accesses.elementReads += 1
            return storage[index]
        }

        func withContiguousStorageIfAvailable<Result>(
            _ body: (UnsafeBufferPointer<UInt8>) throws -> Result
        ) rethrows -> Result? {
            guard contiguous else { return nil }
            if storage.isEmpty {
                return try body(UnsafeBufferPointer(start: nil, count: 0))
            }
            return try storage.withUnsafeBufferPointer(body)
        }
    }
}

final class TemplateEditorCapacityGuidanceTests: XCTestCase {
    func testStaticFieldGuidanceUsesExistingUTF8SaveBudgets() {
        let limits = TemplateTransferLimits.default
        XCTAssertEqual(limits.maximumNameBytes, 1_024)
        XCTAssertEqual(limits.maximumExtensionBytes, 255)
        XCTAssertEqual(limits.maximumContentBytes, 16 * 1024 * 1024)
        XCTAssertEqual(TemplateEditorCapacityGuidance.name, "名称保存上限：\(limits.maximumNameBytes) UTF-8 字节")
        XCTAssertEqual(TemplateEditorCapacityGuidance.fileExtension, "扩展名保存上限：\(limits.maximumExtensionBytes) UTF-8 字节")
        XCTAssertEqual(TemplateEditorCapacityGuidance.content,
            "正文保存上限：\(limits.maximumContentBytes / 1024 / 1024) MiB（按 UTF-8 字节计算，非字符数）")
    }

    func testCollectionGuidanceSeparatesEncodedBudgetAndPreservesHistoricalRepair() {
        let limits = TemplateTransferLimits.default
        let guidance = TemplateEditorCapacityGuidance.collection
        XCTAssertTrue(guidance.contains("整库保存"))
        XCTAssertTrue(guidance.contains("\(limits.maximumTemplates) 个模板"))
        XCTAssertTrue(guidance.contains("\(limits.maximumFileBytes / 1024 / 1024) MiB"))
        XCTAssertTrue(guidance.contains("含 JSON 转义"))
        XCTAssertTrue(guidance.contains("历史超限配置"))
        XCTAssertTrue(guidance.contains("逐步缩减修复"))
    }
}

@MainActor
final class TemplateEditorSafeFailureTests: XCTestCase {
    func testCopiedDraftFeedbackExpiresOnEveryEditableFieldIncludingExactByteEdits() {
        var state = TemplateEditorState(template: nil)
        state.draft.content = "é"
        let edits: [(inout TemplateDraft) -> Void] = [
            { $0.name = "Changed" }, { $0.fileExtension = "md" },
            { $0.defaultFilename = "README" },
            { $0.isEnabled.toggle() }, { $0.content = "e\u{0301}" }
        ]
        for edit in edits {
            var copied = ""
            state.copyDraft { copied = $0 }
            XCTAssertTrue(state.didCopyDraft)
            XCTAssertEqual(copied, state.copyText)
            edit(&state.draft)
            XCTAssertFalse(state.didCopyDraft)
        }
        let latest = state.copyText
        state.copyDraft { XCTAssertTrue($0.utf8.elementsEqual(latest.utf8)) }
        XCTAssertTrue(state.didCopyDraft)
    }

    func testStoreReadErrorIsSanitizedWithoutChangingLiteralDraft() {
        var state = TemplateEditorState(template: nil)
        state.draft.name = "Private draft"
        state.draft.content = "e\u{0301}\n{{clipboard}}"
        let originalBytes = Array(state.draft.content.utf8)
        XCTAssertTrue(state.beginSave())
        let secret = "/private/user-folder/templates.json"
        state.finishSave(error: TemplateStore.StoreError.readFailed(NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: secret]
        )))
        XCTAssertEqual(state.errorMessage, QuickFileViewModel.TemplateLoadFailure.permissionDenied.message)
        XCTAssertFalse(state.errorMessage?.contains(secret) ?? true)
        XCTAssertEqual(Array(state.draft.content.utf8), originalBytes)
        XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
        XCTAssertFalse(state.offersConflictRecovery)
    }

    func testWriteErrorRemainsSaveFailureAndDoesNotLoseConflictRecovery() {
        var state = TemplateEditorState(template: nil)
        state.draft.name = "Keep"
        XCTAssertTrue(state.beginSave())
        state.finishSave(error: TemplateStore.StoreError.configurationChanged)
        XCTAssertTrue(state.offersConflictRecovery)
        let draft = state.draft
        XCTAssertTrue(state.beginSave())
        let error = TemplateStore.StoreError.persistenceFailed(DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "/private/write-error")
        ))
        state.finishSave(error: error)
        XCTAssertTrue(state.errorMessage?.contains("未能保存模板") ?? false)
        XCTAssertFalse(state.errorMessage?.contains("格式无效") ?? true)
        XCTAssertFalse(state.errorMessage?.contains("/private") ?? true)
        XCTAssertTrue(state.offersConflictRecovery)
        XCTAssertEqual(state.draft, draft)
        XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
    }

    func testRecoveryErrorProjectionKeepsBackupFailureAndReplacementFailureDistinct() {
        let privatePath = "/private/user-folder/template-backup"
        let cause = NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: privatePath])
        let backup = QuickFileViewModel.templateOperationErrorMessage(
            TemplateStore.RecoveryError.backupFailed(cause)
        )
        let replacement = QuickFileViewModel.templateOperationErrorMessage(
            TemplateStore.RecoveryError.replacementFailed(backupURL: URL(fileURLWithPath: privatePath), underlying: cause)
        )
        XCTAssertTrue(backup.contains("无法备份恢复前状态"))
        XCTAssertTrue(backup.contains("未写入替代配置"))
        XCTAssertTrue(replacement.contains("恢复前状态已备份"))
        XCTAssertTrue(replacement.contains("恢复写入失败"))
        XCTAssertFalse(backup.contains(privatePath))
        XCTAssertFalse(replacement.contains(privatePath))
        for error in [TemplateStore.RecoveryError.notRecoverable, .configurationChanged] {
            XCTAssertEqual(QuickFileViewModel.templateOperationErrorMessage(error), error.localizedDescription)
        }
        let unrelated = NSError(domain: "Fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Specific external error"])
        XCTAssertEqual(QuickFileViewModel.templateOperationErrorMessage(unrelated), unrelated.localizedDescription)
    }

    func testBudgetValidationMeaningAndDraftRemainIntact() {
        var state = TemplateEditorState(template: nil)
        state.draft.name = "Keep"
        state.draft.content = "literal {{clipboard}}"
        let draft = state.draft
        let errors: [TemplateTransferError] = [
            .fieldTooLarge(index: 0, field: "名称", maximumBytes: 1_024),
            .fieldTooLarge(index: 0, field: "正文", maximumBytes: 16 * 1024 * 1024),
            .fileTooLarge(maximumBytes: 32 * 1024 * 1024),
            .tooManyTemplates(maximum: 1_000),
            .invalidTemplate(index: 0, reason: "名称不能为空")
        ]
        for error in errors {
            XCTAssertTrue(state.beginSave())
            state.finishSave(error: error)
            XCTAssertEqual(state.errorMessage, error.localizedDescription)
            XCTAssertEqual(state.draft, draft)
            XCTAssertFalse(state.offersConflictRecovery)
            XCTAssertEqual(state.requestDismissal(), .confirmDiscard)
        }
    }
}

@MainActor
final class TemplateReorderStateTests: XCTestCase {
    func testDragTypeIsDeclaredByTheHostApplication() throws {
        let declarations = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]
        )
        let declaration = try XCTUnwrap(declarations.first {
            $0["UTTypeIdentifier"] as? String == TemplateReorderState.typeIdentifier
        })
        XCTAssertTrue((declaration["UTTypeConformsTo"] as? [String])?.contains("public.data") == true)
    }

    func testHoverContainsOnlyDestinationAndDropIsAcceptedOnce() throws {
        var state = TemplateReorderState()
        let source = UUID(), target = UUID()
        let payload = state.begin(sourceID: source)
        XCTAssertEqual(payload.count, 36)
        for _ in 0..<100 {
            state.hover(targetID: target, placement: .after)
            XCTAssertNil(state.pending)
            XCTAssertEqual(state.active?.sourceID, source)
        }
        let staged = try XCTUnwrap(state.stage())
        XCTAssertNil(state.active)
        XCTAssertNil(state.destination)
        XCTAssertNil(state.stage())
        let accepted = try XCTUnwrap(state.finish(token: staged.session.token, payload: payload))
        XCTAssertEqual(accepted.session.sourceID, source)
        XCTAssertEqual(accepted.destination.targetID, target)
        XCTAssertEqual(accepted.destination.placement, .after)
        XCTAssertNil(state.finish(token: staged.session.token, payload: payload))
        XCTAssertNil(state.pending)
    }

    func testCancelledOrForeignPayloadNeverFinishesDrop() throws {
        for payload in [nil, Data(), Data(UUID().uuidString.utf8)] as [Data?] {
            var state = TemplateReorderState()
            _ = state.begin(sourceID: UUID())
            state.hover(targetID: UUID(), placement: .before)
            let drop = try XCTUnwrap(state.stage())
            XCTAssertNil(state.finish(token: drop.session.token, payload: payload))
            XCTAssertNil(state.pending)
        }
        var state = TemplateReorderState()
        let payload = state.begin(sourceID: UUID())
        state.hover(targetID: UUID(), placement: .before)
        let drop = try XCTUnwrap(state.stage())
        state.cancel()
        XCTAssertNil(state.finish(token: drop.session.token, payload: payload))
    }

    func testLateCallbackCannotConsumeNewDragAndLeavingOnlyClearsItsOwnTarget() throws {
        var state = TemplateReorderState()
        let oldPayload = state.begin(sourceID: UUID())
        state.hover(targetID: UUID(), placement: .after)
        let oldDrop = try XCTUnwrap(state.stage())
        let source = UUID(), target = UUID()
        let payload = state.begin(sourceID: source)
        state.hover(targetID: source, placement: .before)
        XCTAssertNil(state.stage())
        state.hover(targetID: target, placement: .before)
        state.leave(targetID: UUID())
        XCTAssertEqual(state.destination?.targetID, target)
        state.leave(targetID: target)
        XCTAssertNil(state.destination)
        state.hover(targetID: target, placement: .before)
        let drop = try XCTUnwrap(state.stage())
        XCTAssertNil(state.finish(token: oldDrop.session.token, payload: oldPayload))
        XCTAssertNotNil(state.finish(token: drop.session.token, payload: payload))
    }
}
