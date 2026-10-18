import Combine
import Foundation
import QuickFileCore
import QuickFileInfrastructure
import SwiftUI

struct ContentView: View {
    @Environment(\.locale) private var quickFileLocale
    @ObservedObject var viewModel: QuickFileViewModel
    @StateObject private var finderIntegrationViewModel: FinderIntegrationViewModel
    @StateObject private var finderMenuSettings: FinderMenuSettingsViewModel
    @StateObject private var finderRequestRecovery: FinderRequestRecoveryViewModel
    @StateObject private var templatePresentation = TemplateModalPresentation()
    @ObservedObject private var modalPresentationGate = AppModalPresentationGate.shared
    @State private var selectedTab = AppTab.create
    @State private var hasCheckedStartupAuthorizationRequests = false
    @State private var pendingAppRoute = QuickFilePendingAppRoute()
    @State private var windowPresentation = QuickFileWindowPresentationState()
    @State private var windowID = UUID()
    @State private var nativeWindow = AppNativeWindowReference()
    private let authorizationRequestStore: FinderAuthorizationRequestStore
    private let folderService: QuickFileFolderService?

    init(
        viewModel: QuickFileViewModel,
        finderMenuSettings: FinderMenuSettingsViewModel? = nil,
        finderIntegrationViewModel: FinderIntegrationViewModel? = nil,
        authorizationRequestStore: FinderAuthorizationRequestStore = FinderAuthorizationRequestStore(),
        folderService: QuickFileFolderService? = nil
    ) {
        self.viewModel = viewModel
        self.authorizationRequestStore = authorizationRequestStore
        self.folderService = folderService
        _finderRequestRecovery = StateObject(wrappedValue: FinderRequestRecoveryViewModel(
            backend: .init(store: authorizationRequestStore),
            canOperate: {
                guard !viewModel.isBusy,
                      let pause = viewModel.finderAuthorizationQueuePause,
                      case .readFailed = pause.reason else { return false }
                return true
            }
        ))
        _finderMenuSettings = StateObject(wrappedValue: finderMenuSettings ?? FinderMenuSettingsViewModel(
            load: { .all }, save: { _ in }
        ))
        _finderIntegrationViewModel = StateObject(
            wrappedValue: finderIntegrationViewModel ?? FinderIntegrationViewModel()
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            finderAuthorizationQueueFeedback
            if let folderService {
                QuickFileFolderServiceBanner(
                    service: folderService, viewModel: viewModel,
                    finderIntegration: finderIntegrationViewModel,
                    presentationGeneration: windowPresentation.generation,
                    presentationWindow: { nativeWindow.window },
                    isPresentationAvailable: { generation in
                        windowPresentation.canPresent(generation)
                    },
                    isInteractionAvailable: {
                        !windowPresentation.isAwaitingAuthorizationCheck && !isPresentingModal
                    },
                    willPresent: {
                        pendingAppRoute.discard()
                        selectedTab = .create
                    }
                )
            }
            AppTabsView(
                viewModel: viewModel,
                finderIntegrationViewModel: finderIntegrationViewModel,
                finderMenuSettings: finderMenuSettings,
                templatePresentation: templatePresentation,
                selectedTab: Binding(get: { selectedTab }, set: { tab in
                    selectedTab = tab
                    // A newer native tab choice supersedes pending external navigation.
                    // Programmatic authorization/route selection bypasses this setter.
                    pendingAppRoute.discard()
                })
            )
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 600)
        .background(AppNativeWindowReader(reference: nativeWindow))
        .handlesExternalEvents(preferring: QuickFileAppRoute.externalEventIdentifiers,
                               allowing: QuickFileAppRoute.externalEventIdentifiers)
        .sheet(isPresented: Binding(
            get: { finderRequestRecovery.isPresented },
            set: { if !$0 { finderRequestRecovery.close() } }
        )) {
            FinderRequestRecoveryView(model: finderRequestRecovery)
        }
        .onOpenURL { url in
            // SwiftUI delivers the event to one receiving window. Keep pending
            // navigation here so a background window cannot consume or mirror it.
            guard pendingAppRoute.receive(url) else { return }
            schedulePendingFinderAuthorizationRequest()
        }
        .task { await finderIntegrationViewModel.refresh() }
        .task { await viewModel.loadTemplatesIfNeeded() }
        // Inventory refresh may wait on an unrelated volume. Window appearance,
        // activation and notifications admit interactive requests independently.
        .task { await viewModel.refreshAuthorizationBookmarks() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: AppKitFileActions.applicationDidBecomeActiveNotification
            )
        ) { _ in
            Task {
                await finderIntegrationViewModel.refresh()
                await finderIntegrationViewModel.checkVerification()
            }
            schedulePendingFinderAuthorizationRequest()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: FinderAuthorizationRequestStore.didSaveRequestNotification
            ).receive(on: RunLoop.main)
        ) { _ in
            schedulePendingFinderAuthorizationRequest()
        }
        .onReceive(
            Publishers.CombineLatest3(
                viewModel.$isCreatingFile,
                viewModel.$isAuthorizingDirectory,
                viewModel.$isProcessingFinderAuthorizationRequests
            )
            .map { $0.0 || $0.1 || $0.2 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
        ) { isBusy in
            // Track the full drain lease, even while queue reads leave the form
            // usable. Observe every kind of operation release, including short operations
            // between SwiftUI renders. Delivery is deferred past @Published willSet.
            // An initial idle value only resumes an existing intent; it never polls.
            if !isBusy { resumeAuthorizationCheckOrApplyRoute() }
        }
        .onReceive(templatePresentation.objectWillChange.receive(on: RunLoop.main)) { _ in
            applyPendingAppRoute()
        }
        .onReceive(modalPresentationGate.$isPresenting.receive(on: RunLoop.main)) { _ in
            applyPendingAppRoute()
        }
        .onChange(of: finderRequestRecovery.isPresented) { _ in applyPendingAppRoute() }
        .onChange(of: viewModel.destinationFolder) { folder in
            finderIntegrationViewModel.destinationDidChange(to: folder)
        }
        .onAppear {
            windowPresentation.appear()
            finderIntegrationViewModel.windowDidAppear(windowID)
            schedulePendingFinderAuthorizationRequest()
        }
        .onDisappear {
            // Invalidate callbacks before notifying other window lifecycle owners.
            windowPresentation.disappear()
            finderRequestRecovery.close()
            pendingAppRoute.discard()
            hasCheckedStartupAuthorizationRequests = false
            finderIntegrationViewModel.windowDidDisappear(windowID)
        }
    }

    @ViewBuilder
    private var finderAuthorizationQueueFeedback: some View {
        if let pause = viewModel.finderAuthorizationQueuePause {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "pause.circle")
                Text(pause.message)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if case .readFailed = pause.reason {
                    Button("检查异常请求…") { finderRequestRecovery.open() }
                        .disabled(viewModel.isBusy || windowPresentation.isAwaitingAuthorizationCheck
                                  || finderRequestRecovery.isOperationInFlight)
                }
                Button(pause.actionTitle) {
                    schedulePendingFinderAuthorizationRequest(resumingPauseID: pause.id)
                }
                .disabled(viewModel.isBusy || windowPresentation.isAwaitingAuthorizationCheck
                          || finderRequestRecovery.isPresented || finderRequestRecovery.isOperationInFlight)
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
        } else if let message = viewModel.finderAuthorizationRequestPhase.message {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(message).font(.callout)
                Spacer()
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
        }
    }

    @MainActor
    private func schedulePendingFinderAuthorizationRequest(resumingPauseID: UUID? = nil) {
        guard let generation = windowPresentation.requestAuthorizationCheck(resumingPauseID: resumingPauseID) else { return }
        Task { @MainActor in
            guard windowPresentation.canPresent(generation) else { return }
            let resumePauseID = windowPresentation.takeAuthorizationResumePauseID(
                for: generation, currentPauseID: viewModel.finderAuthorizationQueuePause?.id
            )
            await viewModel.processPendingFinderAuthorizationRequests(
                from: authorizationRequestStore,
                resumingPauseID: resumePauseID,
                isPresentationAvailable: { windowPresentation.canPresent(generation) },
                willPresent: { selectedTab = .create },
                confirmAuthorization: { request in
                    guard let owner = nativeWindow.window else { return nil }
                    return await AppKitFileActions.confirmFinderAuthorization(
                        for: request,
                        templateName: viewModel.template(withID: request.templateID)?.displayName,
                        owner: owner
                    )
                }
            )
            guard windowPresentation.finishAuthorizationCheck(
                for: generation, isBusy: viewModel.isAuthorizationCheckBusy,
                resumingPauseID: resumePauseID, currentPauseID: viewModel.finderAuthorizationQueuePause?.id
            ) else { return }
            hasCheckedStartupAuthorizationRequests = true
            resumeAuthorizationCheckOrApplyRoute()
        }
    }

    @MainActor
    private func resumeAuthorizationCheckOrApplyRoute() {
        if windowPresentation.shouldResumeAuthorizationCheck(isBusy: viewModel.isAuthorizationCheckBusy) {
            schedulePendingFinderAuthorizationRequest()
        } else {
            applyPendingAppRoute()
        }
    }

    private var isPresentingModal: Bool {
        templatePresentation.isActive || modalPresentationGate.isPresenting || finderRequestRecovery.isPresented
    }

    @MainActor
    private func applyPendingAppRoute() {
        guard windowPresentation.generation != nil,
              !windowPresentation.isAwaitingAuthorizationCheck,
              pendingAppRoute.route != nil else { return }
        guard let route = pendingAppRoute.takeIfReady(
            startupAuthorizationChecked: hasCheckedStartupAuthorizationRequests,
            isBusy: viewModel.isAuthorizationCheckBusy,
            isPresentingModal: isPresentingModal
        ) else { return }
        // Only select the existing controller; do not replace its content or .id.
        selectedTab = AppTab(route: route)
    }
}

private struct QuickFileFolderServiceBanner: View {
    @ObservedObject var service: QuickFileFolderService
    @ObservedObject var viewModel: QuickFileViewModel
    let finderIntegration: FinderIntegrationViewModel
    let presentationGeneration: UUID?
    let presentationWindow: @MainActor () -> NSWindow?
    let isPresentationAvailable: @MainActor (UUID) -> Bool
    let isInteractionAvailable: @MainActor () -> Bool
    let willPresent: @MainActor () -> Void

    var body: some View {
        if let request = service.pendingRequest {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder")
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: request.folderHint.path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(request.folderHint.path)
                    if service.couldNotOpenWindow {
                        Text("无法打开创建窗口。请在 QuickFile 中继续处理此请求。")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("选择这个文件夹…") {
                    guard let generation = presentationGeneration, let owner = presentationWindow() else { return }
                    Task { @MainActor in
                        guard isInteractionAvailable() else { return }
                        await service.selectFolder(
                            requestID: request.id, viewModel: viewModel,
                            finderIntegration: finderIntegration,
                            isPresentationAvailable: { isPresentationAvailable(generation) },
                            willPresent: willPresent,
                            choose: { await AppKitFileActions.chooseDestinationFolder(startingAt: $0, for: owner) }
                        )
                    }
                }
                .disabled(viewModel.isAuthorizationCheckBusy || service.isSelectingFolder
                          || !isInteractionAvailable()
                          || presentationGeneration.map { !isPresentationAvailable($0) } != false)
                Button("取消") { service.cancel(requestID: request.id) }
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
        }
    }
}

/// A window-specific reference, read at presentation time rather than guessing
/// whichever window is key after an asynchronous authorization queue wait.
@MainActor
private final class AppNativeWindowReference {
    weak var window: NSWindow?
}

private struct AppNativeWindowReader: NSViewRepresentable {
    let reference: AppNativeWindowReference

    func makeNSView(context: Context) -> WindowView { WindowView(reference: reference) }
    func updateNSView(_ view: WindowView, context: Context) {}

    final class WindowView: NSView {
        let reference: AppNativeWindowReference
        init(reference: AppNativeWindowReference) {
            self.reference = reference
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init(reference:)") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference.window = window
        }
    }
}
