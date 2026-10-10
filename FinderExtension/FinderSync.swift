import Cocoa
import FinderSync
import OSLog
import QuickFileApplication
import QuickFileCore
import QuickFileInfrastructure

final class FinderSync: FIFinderSync {
    private let menuModelBuilder = FinderMenuModelBuilder()
    private let menuActionRegistry = FinderMenuActionRegistry()
    private let templateCache = FinderTemplateCache()
    private let menuSettingsCache = FinderMenuSettingsCache()
    private let destinationCache = FinderMenuDestinationCache()
    private var directoryMonitor: FinderDirectoryMonitor?
    private let activityRecorder = FinderActivityRecorder()
    @MainActor private var diagnosticResponder: FinderExtensionProbeResponder?
    private let authorizationRequestStore = FinderAuthorizationRequestStore()
    private let failureClassifier = FinderExtensionFailureClassifier(
        authorizationFailureClassifier: AuthorizedDirectoryFailureClassifier.activityFailure,
        templateFailureClassifier: TemplateStoreFailureClassifier.activityFailure
    )
    private let logger = Logger(
        subsystem: QuickFileConfiguration.appBundleIdentifier,
        category: "FinderExtension"
    )
    private let operationScheduler = FinderOperationScheduler()
    private let authorizedDirectoryStore = AuthorizedDirectoryStore()
    private let fileCreationService = FileCreationService(clipboardProvider: {
        // FileCreationService calls this only for an actual clipboard variable, after access checks.
        DispatchQueue.main.sync { NSPasteboard.general.string(forType: .string) }
    })

    override var toolbarItemName: String {
        "QuickFile"
    }

    override var toolbarItemImage: NSImage {
        let image = NSImage(
            systemSymbolName: "doc.badge.plus",
            accessibilityDescription: "QuickFile"
        ) ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }

    override var toolbarItemToolTip: String {
        "使用 QuickFile 新建文件"
    }

    override init() {
        super.init()

        // 根目录不能覆盖其他挂载卷；卷挂载、卸载或改名时同步 Finder 监听范围。
        // 监听不授予写入权限，创建仍须通过安全作用域授权。
        directoryMonitor = FinderDirectoryMonitor { directories in
            FIFinderSyncController.default().directoryURLs = directories
        }
        recordActivity(.launched)
        Task { @MainActor [weak self] in
            self?.diagnosticResponder = FinderExtensionProbeResponder()
        }
    }

    override func beginObservingDirectory(at url: URL) {
        // One bounded directory proof warms both unambiguous observed contexts.
        destinationCache.prewarmObservedDirectory(at: url)
    }

    override func endObservingDirectory(at url: URL) {
        for context in [FinderMenuContext.container, .toolbar] {
            destinationCache.invalidate(FinderMenuSelection(
                context: context, targetedURL: url, selectedItemURLs: []
            ))
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // One total readiness budget, shared by destination and template preparation.
        // Filesystem work remains off this callback; slow reads cannot extend the wait.
        let readinessDeadline = DispatchTime.now() + .milliseconds(20)
        let timing = CreationTiming.begin("menu")
        timing?.mark("menu.callback")
        defer { timing?.finish(outcome: "menu-returned") }
        let controller = FIFinderSyncController.default()
        guard let context = finderMenuContext(for: menuKind) else {
            return nil
        }
        guard operationScheduler.hasCreationCapacity else {
            return unavailableMenu(.operationInProgress)
        }
        let selectedURLs = controller.selectedItemURLs() ?? []
        let targetedURL = controller.targetedURL()
        if context == .sidebar, selectedURLs.count != 1 {
            return unavailableMenu(.sidebarSelectionUnavailable)
        }
        if context == .items, FinderMenuSelectionPreflight.check(selectedURLs) == .differentParents {
            return unavailableMenu(.mixedSelection)
        }
        // A URL alone is not an actionable destination. Preparation resolves metadata on
        // a bounded background queue; this callback can briefly await its immutable snapshot.
        guard targetedURL != nil || !selectedURLs.isEmpty else {
            return unavailableMenu(.destinationMissing)
        }

        let selection = FinderMenuSelection(
            context: context, targetedURL: targetedURL, selectedItemURLs: selectedURLs
        )
        let destination: FinderMenuDestination
        switch destinationCache.menuSnapshot(for: selection, waitingUntil: readinessDeadline, timing: timing) {
        case let .ready(prepared): destination = prepared; timing?.mark("menu.destination.ready")
        case .loading:
            timing?.mark("menu.destination.loading")
            return unavailableMenu(.destinationLoading)
        case .busy:
            return unavailableMenu(.destinationBusy)
        case .unavailable:
            timing?.mark("menu.destination.unavailable")
            return unavailableMenu(.destinationUnavailable)
        }

        let entries: [FinderTemplateMenuEntry]
        switch templateCache.menuSnapshot(waitingUntil: readinessDeadline) {
        case let .ready(current): entries = current
        case .loading: return unavailableMenu(.templatesLoading)
        case .refreshFailed: return unavailableMenu(.templateReadFailed)
        }
        let presentation = menuModelBuilder.presentation(fromEntries: entries, limit: menuSettingsCache.currentLimit())
        // Only this branch has an immutable destination proof. Recovery-only menus
        // never register creation tags and cannot upgrade a URL into a write target.
        let menu = menuPresentation.templates(presentation) { entries in
            menuActionRegistry.registerMenu(entries.map { entry in
                FinderMenuAction(
                    templateID: entry.id,
                    context: context,
                    targetedURL: targetedURL,
                    selectedItemURLs: selectedURLs,
                    preparedDestination: destination,
                    menuTimingID: timing?.id
                )
            })
        }
        recordActivity(.menuPrepared)
        timing?.mark("menu.prepared")
        return menu
    }

    private var menuPresentation: FinderMenuPresentation {
        FinderMenuPresentation(
            target: self,
            createAction: #selector(createFileFromMenu(_:)),
            openCreateAction: #selector(openCreatePage(_:)),
            openTemplatesAction: #selector(openTemplateManager(_:))
        )
    }

    private func unavailableMenu(_ state: FinderMenuPresentation.UnavailableState) -> NSMenu {
        menuPresentation.unavailable(state)
    }

    @objc @MainActor
    private func openCreatePage(_ sender: NSMenuItem) {
        openContainingApplication(route: .create)
    }

    @objc @MainActor
    private func openTemplateManager(_ sender: NSMenuItem) {
        openContainingApplication(route: .templates)
    }

    @objc
    @MainActor
    private func createFileFromMenu(_ sender: NSMenuItem) {
        let timing = CreationTiming.begin()
        timing?.mark("action.callback")
        guard let action = menuActionRegistry.takeAction(for: sender.tag) else {
            let error = FinderFileCreationError.menuContextUnavailable
            recordActivity(.fileCreationFailed, failure: failureClassifier.classify(error))
            presentCreationError(error)
            timing?.finish(outcome: "context-unavailable")
            return
        }
        if let menuTimingID = action.menuTimingID { timing?.mark("action.menu.link", relatedID: menuTimingID) }

        let verificationAttempt = action.preparedDestination.flatMap {
            diagnosticResponder?.verificationAttempt(in: $0.identity)
        }
        let coordinator = makeFileCreationCoordinator(timing: timing)
        let completion: @MainActor @Sendable (Result<FileCreationResult, Error>) -> Void = {
            [weak self] result in
            timing?.mark("main.completion.entered")
            guard let self else {
                timing?.finish(outcome: "owner-ended")
                return
            }
            if case .failure = result, case let .selection(targetedURL, selectedItemURLs) = action.target {
                self.destinationCache.invalidate(FinderMenuSelection(
                    context: action.context, targetedURL: targetedURL, selectedItemURLs: selectedItemURLs
                ))
            }
            self.finishCreation(result, destinationIdentity: action.preparedDestination?.identity,
                                verificationAttempt: verificationAttempt, timing: timing)
            switch result {
            case .success: timing?.finish(outcome: "reveal-returned")
            case .failure: timing?.finish(outcome: "failed")
            }
        }
        timing?.mark("background.submit")
        let admission = operationScheduler.submitCreation(action) {
            timing?.mark("background.entered")
            let result = Result {
                try coordinator.createFile(for: action, timing: timing)
            }
            timing?.mark("background.work.finished")
            timing?.mark("main.completion.enqueued")
            Task { @MainActor in
                completion(result)
            }
        }
        if admission != .accepted {
            let error = FinderFileCreationError.operationInProgress
            recordActivity(.fileCreationFailed, failure: failureClassifier.classify(error))
            presentCreationError(error)
            timing?.finish(outcome: "capacity-rejected")
        }
    }

    private func makeFileCreationCoordinator(timing: CreationTiming?) -> FinderFileCreationCoordinator {
        let service = fileCreationService
        return FinderFileCreationCoordinator(
            loadTemplate: { [templateCache] id in
                try templateCache.templateForCreation(id: id)
            },
            performWithAccess: { [authorizedDirectoryStore] destinationFolder, operation in
                try authorizedDirectoryStore.withAccess(to: destinationFolder, timing: timing, perform: operation)
            },
            createFile: { request in
                try service.createFile(for: request)
            },
            requiresAuthorization: { error in
                AuthorizedDirectoryFailureClassifier.requiresAuthorization(error)
            }
        )
    }

    @MainActor
    private func finishCreation(
        _ result: Result<FileCreationResult, Error>,
        destinationIdentity: DirectoryIdentity?,
        verificationAttempt: UUID?,
        timing: CreationTiming?
    ) {
        switch result {
        case let .success(result):
            // Only this extension-side write can report a guided verification result.
            // Use the revalidated action identity; no metadata reads on the main thread.
            if let destinationIdentity, let verificationAttempt {
                diagnosticResponder?.reportSuccessfulCreation(in: destinationIdentity, attemptNonce: verificationAttempt)
            }
            timing?.mark("finder.reveal.request")
            NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
            timing?.mark("finder.reveal.return")
            recordActivity(.fileCreated)
        case let .failure(error):
            recordActivity(.fileCreationFailed, failure: failureClassifier.classify(error))
            presentCreationError(error)
        }
    }

    private func finderMenuContext(for menuKind: FIMenuKind) -> FinderMenuContext? {
        switch menuKind {
        case .contextualMenuForItems:
            return .items
        case .contextualMenuForContainer:
            return .container
        case .contextualMenuForSidebar:
            return .sidebar
        case .toolbarItemMenu:
            return .toolbar
        @unknown default:
            return nil
        }
    }

    @MainActor
    private func presentCreationError(_ error: Error) {
        // Finder invokes menu actions while its menu is still being dismissed. Presenting an
        // app-modal alert synchronously here can leave the extension's window behind Finder (or
        // on another Space), which looks like the action silently failed.
        DispatchQueue.main.async { [weak self] in
            self?.showCreationError(error)
        }
    }

    @MainActor
    private func showCreationError(_ error: Error) {
        if let creationError = error as? FinderFileCreationError,
           case let .directoryAuthorizationRequired(templateID, destinationFolder, destinationIdentity) = creationError {
            continueAuthorizationInContainingApplication(
                FinderAuthorizationRequest(
                    templateID: templateID,
                    destinationFolder: destinationFolder,
                    destinationIdentity: destinationIdentity
                )
            )
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if let creationError = error as? FileCreationError,
           case .createdFileLocationUnavailable = creationError {
            alert.messageText = "文件已创建，无法定位"
        } else {
            alert.messageText = "QuickFile 无法创建文件"
        }
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        let recoveryRoute = failureClassifier.classify(error).reason.recoveryRoute
        alert.addButton(withTitle: recoveryRoute.recoveryTitle)

        alert.window.level = .modalPanel
        alert.window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.activate(ignoringOtherApps: true)
        alert.window.orderFrontRegardless()

        if alert.runModal() == .alertSecondButtonReturn {
            openContainingApplication(route: recoveryRoute)
        }
    }

    @MainActor
    private func continueAuthorizationInContainingApplication(
        _ request: FinderAuthorizationRequest
    ) {
        let store = authorizationRequestStore
        let completion: @MainActor @Sendable (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.openContainingApplication(route: .create, notifyAuthorization: true)
            case let .failure(error):
                let nsError = error as NSError
                self.logger.error(
                    "Unable to persist authorization request: domain=\(nsError.domain, privacy: .public) code=\(nsError.code)"
                )
                self.presentAuthorizationTransferError(error)
            }
        }
        let accepted = operationScheduler.submitAuthorization {
            let result = Result { try store.save(request) }
            Task { @MainActor in completion(result) }
        }
        if !accepted {
            presentAuthorizationTransferError(FinderFileCreationError.operationInProgress)
        }
    }

    @MainActor
    private func presentAuthorizationTransferError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "无法启动快捷授权"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: QuickFileAppRoute.diagnostics.recoveryTitle)
        alert.window.level = .modalPanel
        alert.window.collectionBehavior.insert(.moveToActiveSpace)
        if alert.runModal() == .alertSecondButtonReturn {
            openContainingApplication(route: .diagnostics)
        }
    }

    @MainActor
    private func openContainingApplication(
        route: QuickFileAppRoute,
        notifyAuthorization: Bool = false
    ) {
        ContainingApplicationLauncher.open(route) { [weak self] error in
            if let error {
                if notifyAuthorization {
                    self?.presentAuthorizationTransferError(error)
                } else {
                    self?.presentApplicationOpenError(error)
                }
            } else if notifyAuthorization {
                // Activation alone does not notify an app that is already frontmost.
                DistributedNotificationCenter.default().postNotificationName(
                    FinderAuthorizationRequestStore.didSaveRequestNotification,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
            }
        }
    }

    @MainActor
    private func presentApplicationOpenError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法打开 QuickFile"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.window.level = .modalPanel
        alert.window.collectionBehavior.insert(.moveToActiveSpace)
        alert.runModal()
    }

    private func recordActivity(
        _ kind: FinderExtensionActivityKind,
        failure: FinderExtensionActivityFailure? = nil
    ) {
        activityRecorder.record(kind, failure: failure)

        if let failure {
            let errorDomain = failure.errorDomain ?? "none"
            let errorCode = failure.errorCode ?? 0
            logger.error(
                "File creation failed: reason=\(failure.reason.rawValue, privacy: .public) domain=\(errorDomain, privacy: .public) code=\(errorCode)"
            )
            return
        }

        switch kind {
        case .launched:
            logger.notice("Finder extension launched")
        case .menuPrepared:
            logger.debug("Finder menu prepared")
        case .fileCreated:
            logger.notice("File created successfully")
        case .fileCreationFailed:
            logger.error("File creation failed without classified failure metadata")
        }
    }

}
