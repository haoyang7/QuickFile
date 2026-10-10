import Foundation
import QuickFileCore
import QuickFileInfrastructure

/// Window-local draft only. The application ViewModel remains the authority for persistence.
@MainActor
struct TemplateEditorState {
    enum Dismissal: Equatable {
        case dismiss
        case confirmDiscard
        case blocked
    }

    // Observe the actual write, including nested Binding/inout mutations and whole
    // draft replacements. Swift String/TemplateDraft equality would miss edits
    // between canonically equivalent strings with different UTF-8 bytes.
    var draft: TemplateDraft {
        didSet {
            isDirty = differsFromBaseline
            didCopyDraft = false
        }
    }
    // Body rendering and dismissal only read this cached result. Exact comparison
    // runs once per draft write, never for unrelated view updates; no async result
    // can lag behind an edit and incorrectly allow Cancel/Escape to discard it.
    private(set) var isDirty = false
    private let baseline: TemplateDraft
    private let isCopy: Bool
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var offersConflictRecovery = false
    private(set) var didCopyDraft = false

    init(template: FileTemplate?, isCopy: Bool = false) {
        self.isCopy = isCopy
        var draft = TemplateDraft(template: template)
        if isCopy { draft.id = nil }
        self.draft = draft
        baseline = draft
    }

    func makeTemplate() throws -> FileTemplate {
        var template = try draft.makeTemplate()
        // Import preserves valid literal metadata. Copying must not silently
        // normalize untouched fields; edited fields retain normal edit rules.
        if isCopy {
            if TemplateByteOperations.areEqual(draft.name.utf8, baseline.name.utf8) {
                template.name = baseline.name
            }
            if TemplateByteOperations.areEqual(draft.fileExtension.utf8, baseline.fileExtension.utf8) {
                template.fileExtension = baseline.fileExtension
            }
            if TemplateByteOperations.areEqual(draft.defaultFilename.utf8, baseline.defaultFilename.utf8) {
                template.defaultFilename = baseline.defaultFilename
            }
        }
        return template
    }

    private var differsFromBaseline: Bool {
        draft.id != baseline.id || draft.isEnabled != baseline.isEnabled
            || draft.officeFormat != baseline.officeFormat
            || !TemplateByteOperations.areEqual(draft.name.utf8, baseline.name.utf8)
            || !TemplateByteOperations.areEqual(draft.fileExtension.utf8, baseline.fileExtension.utf8)
            || !TemplateByteOperations.areEqual(draft.defaultFilename.utf8, baseline.defaultFilename.utf8)
            || !TemplateByteOperations.areEqual(draft.content.utf8, baseline.content.utf8)
    }

    func requestDismissal() -> Dismissal {
        if isSaving { return .blocked }
        return isDirty ? .confirmDiscard : .dismiss
    }

    mutating func beginSave() -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        errorMessage = nil
        return true
    }

    mutating func finishSave(error: Error? = nil) {
        isSaving = false
        guard let error else {
            errorMessage = nil
            offersConflictRecovery = false
            return
        }
        errorMessage = QuickFileViewModel.templateOperationErrorMessage(error)
        if let error = error as? QuickFileViewModel.TemplateSaveError {
            switch error {
            case .changed, .deleted, .notLoaded: offersConflictRecovery = true
            case .busy: break
            }
        } else if let error = error as? TemplateStore.StoreError,
                  case .configurationChanged = error {
            offersConflictRecovery = true
        }
    }

    /// Copies literal draft values; this never evaluates variables or reads the pasteboard.
    var copyText: String {
        let documentDescription = draft.officeFormat.map { "\n文档类型：\($0.blankDocumentDescription)" } ?? ""
        return "模板名称：\(draft.name)\n文件扩展名：\(draft.fileExtension)\n默认文件名：\(draft.defaultFilename)\n启用：\(draft.isEnabled ? "是" : "否")\(documentDescription)\n\n\(draft.content)"
    }

    mutating func copyDraft(using copy: (String) -> Void) {
        copy(copyText)
        didCopyDraft = true
    }
}
