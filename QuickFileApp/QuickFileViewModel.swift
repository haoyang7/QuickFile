import Combine
import Foundation
import QuickFileApplication
import QuickFileCore
import QuickFileInfrastructure

/// App-scoped authority for shared form/template state, operation admission, and results.
/// Async completions reconcile generation counters here; the request pump never copies
/// this state or owns a competing busy flag.
@MainActor
final class QuickFileViewModel: ObservableObject {
    enum Status: Equatable {
        case success(String)
        case failure(String)
    }

    /// The load state owns its classification and safe display text together.
    /// Never infer damaged configuration from an arbitrary I/O error or display
    /// an underlying error's path, payload or debug description.
    enum TemplateLoadFailure: Equatable {
        case configurationChanged
        case missingConfiguration
        case permissionDenied
        case storageUnavailable
        case malformedConfiguration
        case unreadable

        init(_ error: Error) {
            var underlying = error
            var mayClassifyMalformed = true
            // Bound traversal even for cyclic or unexpectedly deep NSError chains.
            for _ in 0..<8 {
                if let storeError = underlying as? TemplateStore.StoreError {
                    switch storeError {
                    case .configurationChanged: self = .configurationChanged; return
                    case .savedConfigurationMissing: self = .missingConfiguration; return
                    case .sharedDefaultsUnavailable: self = .storageUnavailable; return
                    case let .readFailed(cause): underlying = cause; continue
                    case let .persistenceFailed(cause):
                        // A write/migration failure is not evidence of malformed input.
                        mayClassifyMalformed = false
                        underlying = cause
                        continue
                    }
                }
                if let recoveryError = underlying as? TemplateStore.RecoveryError {
                    switch recoveryError {
                    case .configurationChanged, .notRecoverable:
                        self = .configurationChanged
                    case .backupFailed, .replacementFailed:
                        self = .unreadable
                    }
                    return
                }
                if mayClassifyMalformed, underlying is DecodingError {
                    self = .malformedConfiguration
                    return
                }
                let nsError = underlying as NSError
                if nsError.domain == NSCocoaErrorDomain {
                    switch nsError.code {
                    case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                        self = .permissionDenied; return
                    case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                        self = .missingConfiguration; return
                    default: break
                    }
                } else if nsError.domain == NSPOSIXErrorDomain {
                    switch nsError.code {
                    case Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue):
                        self = .permissionDenied; return
                    case Int(POSIXErrorCode.ENOENT.rawValue):
                        self = .missingConfiguration; return
                    case Int(POSIXErrorCode.ENODEV.rawValue), Int(POSIXErrorCode.ENXIO.rawValue),
                         Int(POSIXErrorCode.ENOTCONN.rawValue):
                        self = .storageUnavailable; return
                    default: break
                    }
                }
                guard let cause = nsError.userInfo[NSUnderlyingErrorKey] as? Error else { break }
                underlying = cause
            }
            self = .unreadable
        }

        var recoveryActionTitle: String? {
            switch self {
            case .malformedConfiguration: return "修复损坏的配置…"
            case .missingConfiguration: return "恢复缺失的配置…"
            default: return nil
            }
        }

        var offersConfigurationRecovery: Bool { recoveryActionTitle != nil }

        var message: String {
            switch self {
            case .configurationChanged:
                return "模板已在其他实例修改。当前修改未保存，请保留草稿并重新加载模板后重试。"
            case .missingConfiguration:
                return "找不到已保存的模板配置。可恢复原配置文件后重新加载，或从备份／默认模板恢复缺失的配置。"
            case .permissionDenied:
                return "没有足够权限访问模板配置。请检查配置文件及所在文件夹的访问权限后重试。"
            case .storageUnavailable:
                return "暂时无法访问共享模板存储。请确认存储位置可用后重新加载模板。"
            case .malformedConfiguration:
                return "模板配置格式无效，无法读取。可重新加载，或先备份原配置再恢复。"
            case .unreadable:
                return "暂时无法读取模板配置。请稍后重试；读取失败不代表配置损坏。"
            }
        }
    }

    /// Sanitize known store/recovery failures across template surfaces. Preserve
    /// existing validation and unrelated operation errors without reclassifying them.
    static func templateOperationErrorMessage(_ error: Error) -> String {
        if let recoveryError = error as? TemplateStore.RecoveryError {
            switch recoveryError {
            case .notRecoverable, .configurationChanged:
                return recoveryError.localizedDescription
            case .backupFailed:
                return "无法备份恢复前状态，恢复已停止，未写入替代配置。请检查存储空间和访问权限后重试。"
            case .replacementFailed:
                return "恢复前状态已备份，但恢复写入失败。请保留备份，并在检查存储空间和访问权限后重新加载。"
            }
        }
        guard let storeError = error as? TemplateStore.StoreError else { return error.localizedDescription }
        if case .persistenceFailed = storeError {
            return "未能保存模板，当前修改未保存。请检查存储空间和访问权限后重试，或复制草稿。"
        }
        return TemplateLoadFailure(storeError).message
    }

    // Selecting a destination for the app is independent from saving Finder's grant.
    // A saved grant is not a claim that the extension can currently write there.
    enum FinderAuthorizationState: Equatable {
        case notConfirmed
        case saving
        case saved
        case failed(String)
    }

    enum FinderAuthorizationRequestPhase: Equatable {
        case idle, readingQueue, waitingForCurrentOperation, awaitingAuthorization, creatingFile

        var message: String? {
            switch self {
            case .idle: return nil
            case .readingQueue: return "正在读取 Finder 交接队列；仍可在 App 中直接创建文件。"
            case .waitingForCurrentOperation: return "已领取一个 Finder 请求，等待当前操作完成后再确认授权…"
            case .awaitingAuthorization: return "已领取一个 Finder 请求，正在等待授权确认…"
            case .creatingFile: return "正在保存授权并继续本次 Finder 创建…"
            }
        }
    }

    enum FinderAuthorizationQueueReadFailure: Equatable {
        case unavailable, oversizedRequest, unreadable

        init(_ error: Error) {
            // The store wraps read errors. Unwrap only a bounded number of known
            // wrappers; never surface raw paths, payloads or arbitrary error text.
            var underlying = error
            for _ in 0..<4 {
                if let storeError = underlying as? FinderAuthorizationRequestStore.StoreError {
                    switch storeError {
                    case .sharedStoreUnavailable: self = .unavailable; return
                    case .requestTooLarge: self = .oversizedRequest; return
                    case let .persistenceFailed(cause): underlying = cause
                    case .queueFull: self = .unreadable; return
                    }
                } else if let cause = (underlying as NSError).userInfo[NSUnderlyingErrorKey] as? Error {
                    underlying = cause
                } else {
                    break
                }
            }
            self = .unreadable
        }

        var message: String {
            switch self {
            case .unavailable:
                return "暂时无法访问 Finder 交接队列，自动处理已暂停。可重试读取；不会清空队列。"
            case .oversizedRequest:
                return "Finder 交接队列中有超过大小上限的记录，原始记录仍保留，自动处理已暂停。可重试读取其他可用请求；重试不会移除超限记录。"
            case .unreadable:
                return "未能读取或领取 Finder 请求，自动处理已暂停。可重试读取；不会清空队列或重新执行已领取的请求。"
            }
        }
    }

    struct FinderAuthorizationQueuePause: Equatable, Identifiable {
        enum Reason: Equatable {
            case cancelled
            case readFailed(FinderAuthorizationQueueReadFailure)
        }

        // A Continue button captures this receipt before scheduling a window task.
        // A delayed click for an earlier pause cannot resume a newer cancellation.
        let id = UUID()
        let reason: Reason

        var message: String {
            switch reason {
            case .cancelled:
                return "仅取消了当前 Finder 创建请求，自动确认已暂停。其他待处理请求（如有）未被取消；点击“继续处理”后再逐个确认。"
            case let .readFailed(failure): return failure.message
            }
        }

        var actionTitle: String {
            switch reason {
            case .cancelled: return "继续处理"
            case .readFailed: return "重试读取"
            }
        }
    }

    enum TemplateSaveError: LocalizedError {
        case changed
        case deleted
        case notLoaded
        case busy

        var errorDescription: String? {
            switch self {
            case .changed:
                return "模板已在其他窗口修改，当前草稿仍保留。可复制草稿或另存为新模板。"
            case .deleted:
                return "此模板已被删除，当前草稿仍保留。可复制草稿或另存为新模板。"
            case .busy:
                return "模板操作尚未完成，请稍后重试。"
            case .notLoaded:
                return "模板尚未成功读取，请先重新加载模板。"
            }
        }
    }

    @Published var destinationFolder: URL? {
        didSet {
            if oldValue != destinationFolder {
                finderAuthorizationState = .notConfirmed
                selectedSavedAuthorizationID = nil
                selectedSavedDirectoryIdentity = nil
            }
        }
    }
    @Published private(set) var finderAuthorizationState: FinderAuthorizationState = .notConfirmed
    @Published var selectedTemplateID: FileTemplate.ID {
        didSet { if oldValue != selectedTemplateID { selectionGeneration &+= 1 } }
    }
    @Published var requestedFilename = "" {
        didSet { if !oldValue.utf8.elementsEqual(requestedFilename.utf8) { filenameGeneration &+= 1 } }
    }
    @Published private(set) var status: Status? {
        didSet { statusGeneration &+= 1 }
    }
    @Published private(set) var createdFileURL: URL?
    @Published private(set) var templates: [FileTemplate]
    @Published private(set) var templateLoadFailure: TemplateLoadFailure?
    // Compatibility projection; there is no second mutable error state.
    var templateLoadError: String? { templateLoadFailure?.message }
    @Published private(set) var recoveryBackupURL: URL?
    @Published private(set) var isLoadingTemplates = false
    @Published private(set) var isSavingTemplates = false
    private var hasLoadedTemplates: Bool
    private var didAttemptInitialTemplateLoad = false
    @Published private(set) var isCreatingFile = false {
        didSet { resumeFinderPresentationIfReady() }
    }
    @Published private(set) var isAuthorizingDirectory = false {
        didSet { resumeFinderPresentationIfReady() }
    }
    // True for the entire drain, including actual queue I/O and a claimed request
    // waiting for a direct operation. Cancellation never releases this ownership.
    @Published private(set) var isProcessingFinderAuthorizationRequests = false
    @Published private(set) var finderAuthorizationRequestPhase: FinderAuthorizationRequestPhase = .idle
    // Session-wide, independent of any window's lifetime, route or ordinary result.
    // Notifications, window appearance and other completed operations cannot clear it.
    @Published private(set) var finderAuthorizationQueuePause: FinderAuthorizationQueuePause?

    // Only the single app-owned pump can wait here. The returned claim remains
    // in its stack; this continuation neither copies it nor starts another task.
    private var finderPresentationWaiter: CheckedContinuation<Void, Never>?
    private var selectedSavedAuthorizationID: AuthorizedDirectory.ID?
    private var selectedSavedDirectoryIdentity: DirectoryIdentity?
    private var statusGeneration: UInt64 = 0
    private var finderAuthorizationQueueStatusGeneration: UInt64?
    private var selectionGeneration: UInt64 = 0
    private var filenameGeneration: UInt64 = 0
    private var templateStateGeneration: UInt64 = 0
    private var persistedTemplates: [FileTemplate]
    private let templateStore: TemplateStore
    private let authoritativeTemplateLoader: @Sendable () throws -> [FileTemplate]
    private let fileCreationService: FileCreationService
    private let authorizedDirectoryStore: AuthorizedDirectoryStore
    private let finderAuthorizationCoordinator: FinderAuthorizationCoordinator
    private let clipboardProvider: (@MainActor () -> String?)?
    private let revealCreatedFile: @MainActor (URL) -> Void
    private var didRefreshAuthorizationBookmarks = false
    private let finderAuthorizationRequestPump = FinderAuthorizationRequestPump()

    init(
        templateStore: TemplateStore = TemplateStore(),
        templates: [FileTemplate]? = nil,
        authorizedDirectoryStore: AuthorizedDirectoryStore = AuthorizedDirectoryStore(),
        fileCreationService: FileCreationService = FileCreationService(),
        clipboardProvider: (@MainActor () -> String?)? = nil,
        authoritativeTemplateLoader: (@Sendable () throws -> [FileTemplate])? = nil,
        finderAuthorizationCoordinator: FinderAuthorizationCoordinator? = nil,
        revealCreatedFile: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        let loadedTemplates = templates ?? []
        self.hasLoadedTemplates = templates != nil
        // Injected templates are an explicit snapshot; initialization must not access storage.
        self.persistedTemplates = loadedTemplates
        self.templateStore = templateStore
        self.authoritativeTemplateLoader = authoritativeTemplateLoader ?? { [templateStore] in
            try templateStore.reloadTemplates()
        }
        self.templates = loadedTemplates
        self.templateLoadFailure = nil
        self.selectedTemplateID = loadedTemplates.first(where: \.isEnabled)?.id ?? UUID()
        self.authorizedDirectoryStore = authorizedDirectoryStore
        self.fileCreationService = fileCreationService
        self.clipboardProvider = clipboardProvider
        self.revealCreatedFile = revealCreatedFile
        self.finderAuthorizationCoordinator = finderAuthorizationCoordinator
            ?? FinderAuthorizationCoordinator(
                loadTemplates: { [templateStore] in
                    try templateStore.reloadTemplates()
                },
                authorizeDirectory: { directoryURL in
                    try authorizedDirectoryStore.authorize(directoryURL).id
                },
                performWithAccess: { destinationFolder, authorizationID, operation in
                    try authorizedDirectoryStore.withAccess(
                        to: destinationFolder,
                        authorizationID: authorizationID,
                        perform: operation
                    )
                },
                createFile: { request in
                    // The coordinator has loaded the current template and obtained directory access.
                    // Its operation runs on BackgroundWork, so clipboard access can hop to AppKit.
                    if request.template.usesClipboard, let clipboardProvider {
                        let clipboard = DispatchQueue.main.sync { clipboardProvider() ?? "" }
                        return try fileCreationService.createFile(for: request, clipboard: clipboard)
                    }
                    return try fileCreationService.createFile(for: request)
                }
            )
    }

    // One inventory refresh per application, independent of interactive admission.
    // Even if its caller is cancelled/closed, synchronous bookmark I/O still owns
    // this once-only slot until it returns; another window must not start a copy.
    func refreshAuthorizationBookmarks() async {
        guard !didRefreshAuthorizationBookmarks else {
            return
        }
        didRefreshAuthorizationBookmarks = true

        let store = authorizedDirectoryStore
        let initialStatusGeneration = statusGeneration
        let result = await BackgroundWork.result {
            try store.refreshTransferBookmarks()
        }
        // Background inventory warnings cannot replace a newer interactive result.
        if case let .failure(error) = result, initialStatusGeneration == statusGeneration {
            status = .failure("部分 Finder 文件夹授权需要重新确认：\(error.localizedDescription)")
        }
    }

    var enabledTemplates: [FileTemplate] {
        templates.filter(\.isEnabled)
    }

    var selectedTemplate: FileTemplate? {
        enabledTemplates.first { $0.id == selectedTemplateID }
    }

    var extensionHint: String {
        guard let fileExtension = selectedTemplate?.fileExtension, !fileExtension.isEmpty else {
            return ""
        }
        return ".\(fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")))"
    }

    var canCreate: Bool {
        destinationFolder != nil
            && selectedTemplate != nil
            && hasLoadedTemplates
            && templateLoadError == nil
            && !isLoadingTemplates && !isSavingTemplates
            && !isBusy
    }

    var isBusy: Bool {
        if isCreatingFile || isAuthorizingDirectory { return true }
        switch finderAuthorizationRequestPhase {
        case .idle, .readingQueue: return false
        case .waitingForCurrentOperation, .awaitingAuthorization, .creatingFile: return true
        }
    }

    // Window retries/navigation follow the full drain, not the form's admission.
    // Otherwise a second or reopened window can lose its deferred check while a
    // non-busy queue read still belongs to the first window.
    var isAuthorizationCheckBusy: Bool {
        isBusy || isProcessingFinderAuthorizationRequests
    }

    private func prepareFinderPresentation() async {
        // Reserve the next interactive turn before suspending. No new direct
        // operation may race the resumed continuation to open a panel or create.
        finderAuthorizationRequestPhase = .waitingForCurrentOperation
        if isCreatingFile || isAuthorizingDirectory {
            await withCheckedContinuation { continuation in
                precondition(finderPresentationWaiter == nil)
                finderPresentationWaiter = continuation
            }
        }
        finderAuthorizationRequestPhase = .awaitingAuthorization
    }

    private func resumeFinderPresentationIfReady() {
        guard !isCreatingFile, !isAuthorizingDirectory,
              let waiter = finderPresentationWaiter else { return }
        finderPresentationWaiter = nil
        waiter.resume()
    }

    func template(withID id: FileTemplate.ID?) -> FileTemplate? {
        guard let id else {
            return nil
        }
        return templates.first { $0.id == id }
    }

    func saveTemplate(_ template: FileTemplate, replacing original: FileTemplate?) async throws {
        do {
            var updatedTemplates = templates
            if let original {
                guard template.id == original.id,
                      let index = updatedTemplates.firstIndex(where: { $0.id == original.id }) else {
                    throw TemplateSaveError.deleted
                }
                guard TransferTemplate(updatedTemplates[index]) == TransferTemplate(original) else {
                    throw TemplateSaveError.changed
                }
                updatedTemplates[index] = template
            } else {
                guard !updatedTemplates.contains(where: { $0.id == template.id }) else {
                    throw TemplateSaveError.changed
                }
                updatedTemplates.append(template)
            }
            try await persistTemplates(updatedTemplates, successMessage: "模板已保存。")
        } catch {
            status = .failure(Self.templateOperationErrorMessage(error))
            throw error
        }
    }

    /// Conflict recovery is a fresh read plus one compare-and-swap append, never a force-save.
    @discardableResult
    func saveTemplateAsNew(_ draft: FileTemplate) async throws -> FileTemplate.ID {
        guard !isLoadingTemplates, !isSavingTemplates else { throw TemplateSaveError.busy }
        isSavingTemplates = true
        templateStateGeneration &+= 1
        defer { isSavingTemplates = false }
        let store = templateStore
        let load = authoritativeTemplateLoader
        do {
            let result = try await BackgroundWork.result {
                let latest = try load()
                let copy = FileTemplate(name: draft.name, fileExtension: draft.fileExtension,
                                        content: draft.content, isEnabled: draft.isEnabled,
                                        defaultFilename: draft.defaultFilename)
                let updated = latest + [copy]
                try store.saveTemplates(updated, expectedTemplates: latest)
                return (templates: updated, id: copy.id)
            }.get()
            publishTemplates(result.templates, successMessage: "草稿已另存为新模板。")
            return result.id
        } catch let error as TemplateTransferError {
            // Draft validation follows the store's authoritative read and CAS checks.
            // A rejected append does not make the unchanged library unreadable.
            status = .failure(Self.templateOperationErrorMessage(error))
            throw error
        } catch {
            invalidateTemplatesAfterFailure(error)
            status = .failure(Self.templateOperationErrorMessage(error))
            throw error
        }
    }

    /// Search deliberately excludes template bodies, including large or private content.
    func filteredTemplates(search: String, enabledOnly: Bool = false) -> [FileTemplate] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return templates.filter {
            (!enabledOnly || $0.isEnabled) && (query.isEmpty
                || $0.name.localizedCaseInsensitiveContains(query)
                || $0.fileExtension.localizedCaseInsensitiveContains(query))
        }
    }

    enum TemplatePosition: Equatable { case first, last }
    enum TemplatePlacement: Equatable { case before, after }

    /// Resolve both IDs in the complete library once, at drop time. Removing only
    /// the source preserves the relative order of every other (including hidden) row.
    func moveTemplate(
        withID id: FileTemplate.ID,
        relativeTo targetID: FileTemplate.ID,
        placement: TemplatePlacement
    ) async -> Bool {
        guard hasLoadedTemplates, templateLoadError == nil,
              !isLoadingTemplates, !isSavingTemplates,
              id != targetID,
              let sourceIndex = templates.firstIndex(where: { $0.id == id }),
              let targetIndex = templates.firstIndex(where: { $0.id == targetID }) else {
            return false
        }
        let remainingTargetIndex = targetIndex - (sourceIndex < targetIndex ? 1 : 0)
        let destination = remainingTargetIndex + (placement == .after ? 1 : 0)
        guard sourceIndex != destination else { return false }
        var updated = templates
        let moved = updated.remove(at: sourceIndex)
        updated.insert(moved, at: destination)
        return await commitTemplates(updated, successMessage: "模板顺序已更新。")
    }

    func moveTemplate(withID id: FileTemplate.ID, to position: TemplatePosition) async -> Bool {
        guard let sourceIndex = templates.firstIndex(where: { $0.id == id }) else { return false }
        let destination = position == .first ? 0 : templates.count - 1
        guard sourceIndex != destination else { return false }
        var updated = templates
        let moved = updated.remove(at: sourceIndex)
        updated.insert(moved, at: destination)
        return await commitTemplates(updated, successMessage: "模板顺序已更新。")
    }

    struct TemplateImportPreview: Identifiable, Sendable {
        let id = UUID()
        let plan: TemplateImportPlan
        let clipboardCount: Int
    }

    struct TemplateRecoveryPreview: Identifiable, Sendable {
        let id = UUID()
        let snapshot: TemplateStore.RecoverySnapshot
        let templates: [FileTemplate]
        let sourceName: String
        let clipboardCount: Int

        // The fresh store snapshot, not the earlier UI hint, owns this disclosure.
        var isMissingConfiguration: Bool { snapshot.reason == .missingSavedConfiguration }
        var title: String { isMissingConfiguration ? "恢复缺失的模板配置" : "恢复损坏的模板配置" }
        var confirmationActionTitle: String {
            isMissingConfiguration ? "记录缺失状态并恢复" : "备份原配置并恢复"
        }
        var explanation: String {
            if isMissingConfiguration {
                return "原配置文件已缺失，无法备份其原始内容。将先在本地保存缺失状态记录及可用的旧配置数据，再用“\(sourceName)”恢复模板；保存记录失败则停止。这不是追加导入。"
            }
            return "将用“\(sourceName)”替换当前配置。先在本地保留原始配置备份，备份失败则停止恢复。这不是追加导入。"
        }
    }

    func prepareTemplateImport(from url: URL) async throws -> TemplateImportPreview {
        guard hasLoadedTemplates, templateLoadError == nil else { throw TemplateSaveError.notLoaded }
        guard !isLoadingTemplates, !isSavingTemplates else { throw TemplateSaveError.busy }
        isLoadingTemplates = true
        templateStateGeneration &+= 1
        defer { isLoadingTemplates = false }
        let load = authoritativeTemplateLoader
        do {
            return try await BackgroundWork.result {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let bundle = try TemplateTransferFile.read(from: url)
                let plan = try TemplateTransfer.makeImportPlan(bundle: bundle, existing: load())
                return TemplateImportPreview(plan: plan, clipboardCount: plan.clipboardCount)
            }.get()
        } catch {
            if error is TemplateStore.StoreError { invalidateTemplatesAfterFailure(error) }
            status = .failure(Self.templateOperationErrorMessage(error))
            throw error
        }
    }

    /// The immutable preview supplies the baseline for exactly one atomic append attempt.
    func importTemplates(_ preview: TemplateImportPreview) async throws {
        guard hasLoadedTemplates, templateLoadError == nil else { throw TemplateSaveError.notLoaded }
        guard !isLoadingTemplates, !isSavingTemplates else { throw TemplateSaveError.busy }
        guard preview.plan.addedCount > 0 else { return }
        isSavingTemplates = true
        templateStateGeneration &+= 1
        defer { isSavingTemplates = false }
        let store = templateStore
        let plan = preview.plan
        do {
            try await BackgroundWork.result {
                try store.saveTemplates(plan.templates, expectedTemplates: plan.baseline)
            }.get()
            publishTemplates(plan.templates, successMessage: "已追加导入 \(plan.addedCount) 个模板。")
        } catch {
            if error is TemplateStore.StoreError { invalidateTemplatesAfterFailure(error) }
            status = .failure(Self.templateOperationErrorMessage(error))
            throw error
        }
    }

    /// Call only after the local export warning and Save panel were confirmed.
    func exportTemplates(to url: URL) async throws {
        guard hasLoadedTemplates, templateLoadError == nil else { throw TemplateSaveError.notLoaded }
        guard !isLoadingTemplates, !isSavingTemplates else { throw TemplateSaveError.busy }
        isLoadingTemplates = true
        defer { isLoadingTemplates = false }
        let load = authoritativeTemplateLoader
        let store = templateStore
        do {
            let count = try await BackgroundWork.result {
                let latest = try load()
                let bundle = TemplateTransferBundle(templates: latest)
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                try store.exportTemplates(bundle, to: url)
                return latest.count
            }.get()
            status = .success("已将全部 \(count) 个模板导出到本地：\(url.path)")
        } catch {
            if error is TemplateStore.StoreError { invalidateTemplatesAfterFailure(error) }
            status = .failure(Self.templateOperationErrorMessage(error))
            throw error
        }
    }

    /// Recovery stays separate from normal saves/imports and requires an explicit review.
    func prepareTemplateRecovery(from url: URL? = nil) async throws -> TemplateRecoveryPreview {
        guard templateLoadFailure?.offersConfigurationRecovery == true else {
            throw TemplateStore.RecoveryError.notRecoverable
        }
        guard !isLoadingTemplates, !isSavingTemplates else { throw TemplateSaveError.busy }
        isLoadingTemplates = true
        templateStateGeneration &+= 1
        defer { isLoadingTemplates = false }
        let store = templateStore
        let previousFailureMessage = templateLoadError
        do {
            let preview = try await BackgroundWork.result {
                // Store verifies a malformed or saved-but-missing configuration;
                // a healthy or unreadable source cannot produce a recovery plan.
                let snapshot = try store.prepareRecovery()
                let replacement: [FileTemplate]
                if let url {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    replacement = try TemplateTransferFile.read(from: url).templates.map { $0.makeTemplate() }
                } else { replacement = BuiltInTemplates.all }
                return TemplateRecoveryPreview(snapshot: snapshot, templates: replacement,
                    sourceName: url?.lastPathComponent ?? "默认模板",
                    clipboardCount: replacement.filter(\.usesClipboard).count)
            }.get()
            let failure: TemplateLoadFailure = preview.isMissingConfiguration ? .missingConfiguration : .malformedConfiguration
            templateLoadFailure = failure
            templateStateGeneration &+= 1
            if let previousFailureMessage, status == .failure(previousFailureMessage) {
                status = .failure(failure.message)
            }
            return preview
        } catch {
            invalidateTemplatesAfterRecoveryFailure(error)
            status = .failure(Self.templateOperationErrorMessage(error))
            throw error
        }
    }

    func recoverTemplates(_ preview: TemplateRecoveryPreview) async throws {
        guard templateLoadFailure?.offersConfigurationRecovery == true else {
            throw TemplateStore.RecoveryError.notRecoverable
        }
        guard !isLoadingTemplates, !isSavingTemplates else { throw TemplateSaveError.busy }
        isSavingTemplates = true
        templateStateGeneration &+= 1
        recoveryBackupURL = nil
        defer { isSavingTemplates = false }
        let store = templateStore
        do {
            let result = try await BackgroundWork.result {
                try store.recoverTemplates(preview.templates, expectedRecoveryState: preview.snapshot)
            }.get()
            recoveryBackupURL = result.backupURL.isFileURL ? result.backupURL : nil
            publishTemplates(result.templates, successMessage: preview.isMissingConfiguration
                ? "已记录缺失状态并恢复模板，恢复前状态记录保存在本地备份中。"
                : "已备份原配置并恢复模板。")
        } catch {
            if case let TemplateStore.RecoveryError.replacementFailed(backupURL, _) = error,
               backupURL.isFileURL { recoveryBackupURL = backupURL }
            invalidateTemplatesAfterRecoveryFailure(error)
            status = .failure(Self.templateOperationErrorMessage(error))
            throw error
        }
    }

    func loadTemplatesIfNeeded() async {
        guard !hasLoadedTemplates, !didAttemptInitialTemplateLoad else { return }
        didAttemptInitialTemplateLoad = true
        await reloadTemplates()
    }

    func reloadTemplates() async {
        guard !isLoadingTemplates, !isSavingTemplates else { return }
        isLoadingTemplates = true
        templateStateGeneration &+= 1
        defer { isLoadingTemplates = false }
        let store = templateStore
        let result = await BackgroundWork.result { try store.reloadTemplates() }
        switch result {
        case let .success(loaded):
            templates = loaded
            persistedTemplates = loaded
            hasLoadedTemplates = true
            templateLoadFailure = nil
            templateStateGeneration &+= 1
            ensureSelectedTemplateIsAvailable()
            status = .success("模板已重新加载。")
        case let .failure(error):
            // Preserve the last successful list, but require a successful reload before editing.
            let failure = TemplateLoadFailure(error)
            templateLoadFailure = failure
            templateStateGeneration &+= 1
            status = .failure(failure.message)
        }
    }

    func deleteTemplate(withID id: FileTemplate.ID) async -> Bool {
        let updatedTemplates = templates.filter { $0.id != id }
        guard updatedTemplates.count != templates.count else {
            return false
        }

        return await commitTemplates(updatedTemplates, successMessage: "模板已删除。")
    }

    func setTemplateEnabled(_ isEnabled: Bool, id: FileTemplate.ID) async {
        guard let index = templates.firstIndex(where: { $0.id == id }) else {
            return
        }

        var updatedTemplates = templates
        updatedTemplates[index].isEnabled = isEnabled
        _ = await commitTemplates(updatedTemplates, successMessage: "模板状态已更新。")
    }

    func moveTemplate(withID id: FileTemplate.ID, offset: Int) async -> Bool {
        guard
            let sourceIndex = templates.firstIndex(where: { $0.id == id }),
            templates.indices.contains(sourceIndex + offset)
        else {
            return false
        }

        var updatedTemplates = templates
        let template = updatedTemplates.remove(at: sourceIndex)
        updatedTemplates.insert(template, at: sourceIndex + offset)
        return await commitTemplates(updatedTemplates, successMessage: "模板顺序已更新。")
    }

    func canMoveTemplate(withID id: FileTemplate.ID?, offset: Int) -> Bool {
        guard let id, let sourceIndex = templates.firstIndex(where: { $0.id == id }) else {
            return false
        }
        return templates.indices.contains(sourceIndex + offset)
    }

    func restoreBuiltInTemplates() async -> Bool {
        await commitTemplates(BuiltInTemplates.all, successMessage: "已恢复默认模板。")
    }

    /// An ordinary Open-panel selection is temporary and does not persist a Finder grant.
    func selectDestinationFolder(_ selectedURL: URL) async {
        guard !isBusy else { return }
        applyDestinationSelection(selectedURL)
    }

    // NSOpenPanel.runModal can reenter MainActor. Hold interactive admission
    // before opening it so a late queue claim cannot open a second modal panel.
    func selectDestinationFolder(choosing choose: @MainActor () async -> URL?) async {
        guard !isBusy else { return }
        isAuthorizingDirectory = true
        defer { isAuthorizingDirectory = false }
        guard let selectedURL = await choose() else { return }
        applyDestinationSelection(selectedURL)
    }

    private func applyDestinationSelection(_ selectedURL: URL) {
        destinationFolder = selectedURL
        selectedSavedAuthorizationID = nil
        selectedSavedDirectoryIdentity = nil
        finderAuthorizationState = .notConfirmed
        createdFileURL = nil
        status = .success("已选择保存位置；本次创建无需启用 Finder 扩展。")
    }

    /// Inventory rows are hints. Resolve and admit the selected grant again before using it.
    func selectAuthorizedDirectory(_ directory: AuthorizedDirectory) async {
        guard !isBusy else { return }
        isAuthorizingDirectory = true
        defer { isAuthorizingDirectory = false }
        let store = authorizedDirectoryStore
        let result = await BackgroundWork.result {
            guard !directory.isBookmarkStale,
                  try store.authorizedDirectory(withID: directory.id) == directory else {
                throw AuthorizedDirectoryStoreError.authorizationChanged
            }
            return try store.withAccess(to: directory.url, authorizationID: directory.id) {
                try DirectoryIdentity.capture(at: directory.url)
            }
        }
        switch result {
        case let .success(identity):
            destinationFolder = directory.url
            selectedSavedAuthorizationID = directory.id
            selectedSavedDirectoryIdentity = identity
            finderAuthorizationState = .saved
            createdFileURL = nil
            status = .success("已选择已授权文件夹；创建时会再次验证授权。")
        case let .failure(error):
            status = .failure(error.localizedDescription)
        }
    }

    func saveFinderAuthorization(for selectedURL: URL) async {
        guard !isBusy else { return }
        isAuthorizingDirectory = true
        defer { isAuthorizingDirectory = false }
        await persistFinderAuthorization(for: selectedURL)
    }

    @discardableResult
    func saveFinderAuthorization(choosing choose: @MainActor () async -> URL?) async -> Bool {
        guard !isBusy else { return false }
        isAuthorizingDirectory = true
        defer { isAuthorizingDirectory = false }
        guard let selectedURL = await choose() else { return false }
        await persistFinderAuthorization(for: selectedURL)
        return true
    }

    private func persistFinderAuthorization(for selectedURL: URL) async {
        destinationFolder = selectedURL
        selectedSavedAuthorizationID = nil
        selectedSavedDirectoryIdentity = nil
        createdFileURL = nil
        finderAuthorizationState = .saving
        status = nil

        let store = authorizedDirectoryStore
        let result = await BackgroundWork.result {
            try store.authorize(selectedURL)
        }

        switch result {
        case .success:
            finderAuthorizationState = .saved
            status = .success("已选择文件夹，并保存 Finder Extension 的安全授权。")
        case let .failure(error):
            finderAuthorizationState = .failed(error.localizedDescription)
            status = .failure("文件夹已选择，但 Finder Extension 授权保存失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func completeFinderAuthorizationRequest(
        _ request: FinderAuthorizationRequest,
        authorizedDirectory: URL
    ) async -> Bool {
        await completeFinderAuthorizationRequest(request, authorizedDirectory: authorizedDirectory,
            formGeneration: (selectionGeneration, filenameGeneration))
    }

    private func completeFinderAuthorizationRequest(
        _ request: FinderAuthorizationRequest,
        authorizedDirectory: URL,
        formGeneration: (selection: UInt64, filename: UInt64)
    ) async -> Bool {
        guard !isCreatingFile, !isAuthorizingDirectory else {
            status = .failure("当前操作尚未完成，请稍后再处理 Finder 授权。")
            return false
        }

        let coordinator = finderAuthorizationCoordinator
        let initialSelectionGeneration = formGeneration.selection
        let initialFilenameGeneration = formGeneration.filename
        let initialTemplateStateGeneration = templateStateGeneration
        isCreatingFile = true
        status = nil
        createdFileURL = nil
        defer { isCreatingFile = false }

        let result = await BackgroundWork.result {
            try coordinator.complete(
                request,
                authorizedDirectory: authorizedDirectory
            )
        }

        switch result {
        case let .success(completion):
            // Reconcile the authoritative snapshot used by the continuation. A reload
            // or save completed while writing owns a newer snapshot and must win.
            if templateStateGeneration == initialTemplateStateGeneration {
                templates = completion.templates
                persistedTemplates = completion.templates
                hasLoadedTemplates = true
                templateLoadFailure = nil
                templateStateGeneration &+= 1
            }
            if selectionGeneration == initialSelectionGeneration,
               templates.contains(where: { $0.id == completion.selectedTemplateID && $0.isEnabled }) {
                selectedTemplateID = completion.selectedTemplateID
            }
            ensureSelectedTemplateIsAvailable()
            destinationFolder = completion.destinationFolder
            // didSet deliberately only clears provenance for changed URLs. A same-path
            // reauthorization still replaces the grant and may replace target identity.
            selectedSavedAuthorizationID = completion.authorizationID
            selectedSavedDirectoryIdentity = completion.destinationIdentity
            finderAuthorizationState = .saved
            if filenameGeneration == initialFilenameGeneration {
                requestedFilename = ""
            }
            createdFileURL = completion.creationResult.fileURL
            revealCreatedFile(completion.creationResult.fileURL)
            let conflictNote = completion.creationResult.didRenameForConflict
                ? "（为避免覆盖已自动改名）"
                : ""
            status = .success(
                "已授权并创建 \(completion.creationResult.fileURL.lastPathComponent)\(conflictNote)"
            )
            return true
        case let .failure(error):
            createdFileURL = nil
            status = .failure(error.localizedDescription)
            return false
        }
    }

    func cancelFinderAuthorizationRequest() {
        finderAuthorizationQueuePause = FinderAuthorizationQueuePause(reason: .cancelled)
        status = .failure("本次 Finder 文件创建已取消。")
        finderAuthorizationQueueStatusGeneration = statusGeneration
    }

    private func failFinderAuthorizationRequest(_ error: Error, readStatusGeneration: UInt64) {
        let failure = FinderAuthorizationQueueReadFailure(error)
        finderAuthorizationQueuePause = FinderAuthorizationQueuePause(reason: .readFailed(failure))
        finderAuthorizationQueueStatusGeneration = nil
        // The app-wide banner always explains the pause. A late background read
        // must not replace the result of an independent creation/folder operation.
        if statusGeneration == readStatusGeneration, !isCreatingFile, !isAuthorizingDirectory {
            status = .failure(failure.message)
            finderAuthorizationQueueStatusGeneration = statusGeneration
        }
    }

    func processPendingFinderAuthorizationRequests(
        from store: FinderAuthorizationRequestStore,
        resumingPauseID: UUID? = nil,
        isPresentationAvailable: @MainActor () -> Bool = { true },
        willPresent: @MainActor () -> Void = {},
        confirmAuthorization: @MainActor (FinderAuthorizationRequest) -> URL?
    ) async {
        // A queued task from an old window must not clear the app-wide pause. Only
        // an explicit continuation admitted by a live, idle window may resume it.
        guard isPresentationAvailable() else { return }
        if let resumingPauseID {
            guard finderAuthorizationQueuePause?.id == resumingPauseID else { return }
        } else if finderAuthorizationQueuePause != nil {
            return
        }
        // The app owns one ViewModel across all windows. This lease is separate
        // from form admission and lasts until actual reads, panels and writes end.
        if isProcessingFinderAuthorizationRequests {
            finderAuthorizationRequestPump.requestRecheck()
            return
        }
        guard !isBusy else { return }
        isProcessingFinderAuthorizationRequests = true
        let pausedStatusGeneration = resumingPauseID == nil ? nil : finderAuthorizationQueueStatusGeneration
        finderAuthorizationQueuePause = nil
        finderAuthorizationQueueStatusGeneration = nil
        defer {
            finderAuthorizationRequestPhase = .idle
            isProcessingFinderAuthorizationRequests = false
        }

        var readStatusGeneration = statusGeneration
        var readFormGeneration = (selection: selectionGeneration, filename: filenameGeneration)
        await finderAuthorizationRequestPump.drain(
            takePendingRequest: { try store.takePendingRequest() },
            willReadQueue: {
                readStatusGeneration = self.statusGeneration
                readFormGeneration = (self.selectionGeneration, self.filenameGeneration)
                self.finderAuthorizationRequestPhase = .readingQueue
            },
            prepareForPresentation: { await self.prepareFinderPresentation() },
            willPresent: willPresent,
            confirmAuthorization: { request in
                self.finderAuthorizationRequestPhase = .awaitingAuthorization
                return confirmAuthorization(request)
            },
            complete: { request, directory in
                self.finderAuthorizationRequestPhase = .creatingFile
                return await self.completeFinderAuthorizationRequest(request, authorizedDirectory: directory,
                    formGeneration: readFormGeneration)
            },
            didCancel: { self.cancelFinderAuthorizationRequest() },
            didFail: { self.failFinderAuthorizationRequest($0, readStatusGeneration: readStatusGeneration) },
            didFindNoClaimableRequest: {
                // An empty read is not an all-clear: future-dated records may remain.
                // Remove only this pause's stale feedback, never a newer user result.
                if let pausedStatusGeneration, self.statusGeneration == pausedStatusGeneration,
                   !self.isCreatingFile, !self.isAuthorizingDirectory {
                    self.status = nil
                }
            },
            isPresentationAvailable: isPresentationAvailable,
            didCancelForUnavailableWindow: { _ in
                guard self.statusGeneration == readStatusGeneration,
                      !self.isCreatingFile, !self.isAuthorizingDirectory else { return }
                self.status = .failure("创建窗口已关闭，本次 Finder 请求已取消；请从 Finder 重新发起。其他待处理请求会在可用窗口中继续确认。")
            }
        )
    }

    func createFile() async {
        guard !isLoadingTemplates, !isSavingTemplates else { return }
        guard !isBusy else {
            return
        }
        guard hasLoadedTemplates, templateLoadError == nil else {
            status = .failure(TemplateSaveError.notLoaded.localizedDescription)
            return
        }
        guard let destinationFolder, selectedTemplate != nil else {
            status = .failure("请先选择目标文件夹和模板。")
            return
        }

        let requestedTemplateID = selectedTemplateID
        let requestedFilename = self.requestedFilename
        let initialTemplateStateGeneration = templateStateGeneration
        let loadAuthoritativeTemplates = authoritativeTemplateLoader
        let savedAuthorizationID = selectedSavedAuthorizationID
        let savedIdentity = selectedSavedDirectoryIdentity
        let authorizationStore = authorizedDirectoryStore

        isCreatingFile = true
        status = nil
        createdFileURL = nil
        defer { isCreatingFile = false }

        // Capture the target before waiting for template storage. The service compares
        // this identity with its opened directory, so a same-path replacement cannot
        // silently become the destination. Metadata access stays off MainActor.
        let identityResult = await BackgroundWork.result {
            if let savedAuthorizationID {
                return try authorizationStore.withAccess(
                    to: destinationFolder, authorizationID: savedAuthorizationID
                ) {
                    let identity = try DirectoryIdentity.capture(at: destinationFolder)
                    guard identity == savedIdentity else { throw FileCreationError.destinationIdentityChanged }
                    return identity
                }
            }
            let accessing = destinationFolder.startAccessingSecurityScopedResource()
            defer { if accessing { destinationFolder.stopAccessingSecurityScopedResource() } }
            return try DirectoryIdentity.capture(at: destinationFolder)
        }
        let destinationIdentity: DirectoryIdentity
        switch identityResult {
        case let .success(identity):
            destinationIdentity = identity
        case let .failure(error):
            status = .failure("无法确认目标文件夹，本次未创建文件：\(error.localizedDescription)")
            return
        }

        let templateResult = await BackgroundWork.result {
            let loaded = try loadAuthoritativeTemplates()
            // Scanning a large body can block UI updates. Use the same authoritative
            // snapshot as creation; only the pasteboard read belongs on MainActor.
            let usesClipboard = loaded.first(where: {
                $0.id == requestedTemplateID && $0.isEnabled
            })?.usesClipboard ?? false
            return (templates: loaded, usesClipboard: usesClipboard)
        }
        guard templateStateGeneration == initialTemplateStateGeneration else {
            status = .failure("模板配置已在创建期间更新，本次未创建文件。请确认当前模板后重试。")
            return
        }
        let authoritativeTemplates: [FileTemplate]
        let selectedUsesClipboard: Bool
        switch templateResult {
        case let .success(snapshot):
            let loadedTemplates = snapshot.templates
            selectedUsesClipboard = snapshot.usesClipboard
            authoritativeTemplates = loadedTemplates
            templates = loadedTemplates
            persistedTemplates = loadedTemplates
            templateLoadFailure = nil
            templateStateGeneration &+= 1
            ensureSelectedTemplateIsAvailable()
        case let .failure(error):
            templateLoadFailure = TemplateLoadFailure(error)
            templateStateGeneration &+= 1
            status = .failure("无法确认最新模板配置，本次未创建文件：\(TemplateLoadFailure(error).message)")
            return
        }

        guard let authoritativeTemplate = authoritativeTemplates.first(where: {
            $0.id == requestedTemplateID && $0.isEnabled
        }) else {
            status = .failure("所选模板已被删除或停用，请重新选择模板后再试。")
            return
        }

        let request = FileCreationRequest(
            template: authoritativeTemplate,
            destinationFolder: destinationFolder,
            requestedFilename: requestedFilename,
            clipboard: selectedUsesClipboard ? clipboardProvider.map { $0() ?? "" } : nil,
            expectedDirectoryIdentity: destinationIdentity
        )
        let service = fileCreationService

        let result = await BackgroundWork.result {
            if let savedAuthorizationID {
                return try authorizationStore.withAccess(
                    to: destinationFolder, authorizationID: savedAuthorizationID
                ) { try service.createFile(for: request) }
            }
            return try service.createFile(for: request)
        }

        switch result {
        case let .success(result):
            createdFileURL = result.fileURL
            let conflictNote = result.didRenameForConflict ? "（为避免覆盖已自动改名）" : ""
            status = .success("已创建 \(result.fileURL.lastPathComponent)\(conflictNote)")
        case let .failure(error):
            createdFileURL = nil
            status = .failure(error.localizedDescription)
        }
    }

    private func commitTemplates(_ updatedTemplates: [FileTemplate], successMessage: String) async -> Bool {
        do {
            try await persistTemplates(updatedTemplates, successMessage: successMessage)
            return true
        } catch {
            status = .failure(Self.templateOperationErrorMessage(error))
            return false
        }
    }

    private func persistTemplates(_ updatedTemplates: [FileTemplate], successMessage: String) async throws {
        guard hasLoadedTemplates, templateLoadError == nil else { throw TemplateSaveError.notLoaded }
        guard !isLoadingTemplates, !isSavingTemplates else { throw TemplateSaveError.busy }
        isSavingTemplates = true
        // Invalidate a creation preflight before suspending, not only after the write completes.
        templateStateGeneration &+= 1
        defer { isSavingTemplates = false }
        let store = templateStore
        let expectedTemplates = persistedTemplates
        do {
            try await BackgroundWork.result {
                try store.saveTemplates(updatedTemplates, expectedTemplates: expectedTemplates)
            }.get()
        } catch let error as TemplateStore.StoreError {
            switch error {
            case .configurationChanged, .readFailed, .savedConfigurationMissing, .sharedDefaultsUnavailable:
                // A failed preflight read invalidates the editing snapshot until an explicit reload.
                templateLoadFailure = TemplateLoadFailure(error)
                templateStateGeneration &+= 1
            case .persistenceFailed:
                break
            }
            throw error
        }
        publishTemplates(updatedTemplates, successMessage: successMessage)
    }

    private func publishTemplates(_ snapshot: [FileTemplate], successMessage: String) {
        templates = snapshot
        persistedTemplates = snapshot
        hasLoadedTemplates = true
        templateLoadFailure = nil
        templateStateGeneration &+= 1
        // Repair unavailable selections while preserving a newer valid selection.
        ensureSelectedTemplateIsAvailable()
        status = .success(successMessage)
    }

    private func invalidateTemplatesAfterRecoveryFailure(_ error: Error) {
        if error is TemplateStore.StoreError {
            invalidateTemplatesAfterFailure(error)
        } else if let recoveryError = error as? TemplateStore.RecoveryError {
            switch recoveryError {
            case .notRecoverable, .configurationChanged:
                // The recovery read supersedes an earlier corruption diagnosis.
                // Require a fresh load rather than keeping a stale repair action.
                templateLoadFailure = .configurationChanged
                templateStateGeneration &+= 1
            case .backupFailed, .replacementFailed:
                break
            }
        }
    }

    private func invalidateTemplatesAfterFailure(_ error: Error) {
        if let storeError = error as? TemplateStore.StoreError,
           case .persistenceFailed = storeError { return }
        templateLoadFailure = TemplateLoadFailure(error)
        templateStateGeneration &+= 1
    }

    private func ensureSelectedTemplateIsAvailable() {
        guard enabledTemplates.contains(where: { $0.id == selectedTemplateID }) else {
            selectedTemplateID = enabledTemplates.first?.id ?? UUID()
            return
        }
    }
}
