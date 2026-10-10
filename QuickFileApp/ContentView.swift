import Combine
import Foundation
import QuickFileCore
import QuickFileInfrastructure
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: QuickFileViewModel
    @StateObject private var finderIntegrationViewModel: FinderIntegrationViewModel
    @StateObject private var finderMenuSettings: FinderMenuSettingsViewModel
    @StateObject private var finderRequestRecovery: FinderRequestRecoveryViewModel
    @State private var selectedTab = AppTab.create
    @State private var hasCheckedStartupAuthorizationRequests = false
    @State private var pendingAppRoute = QuickFilePendingAppRoute()
    @State private var windowPresentation = QuickFileWindowPresentationState()
    @State private var windowID = UUID()
    private let authorizationRequestStore: FinderAuthorizationRequestStore

    init(
        viewModel: QuickFileViewModel,
        finderMenuSettings: FinderMenuSettingsViewModel? = nil,
        finderIntegrationViewModel: FinderIntegrationViewModel? = nil,
        authorizationRequestStore: FinderAuthorizationRequestStore = FinderAuthorizationRequestStore()
    ) {
        self.viewModel = viewModel
        self.authorizationRequestStore = authorizationRequestStore
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
            AppTabsView(
                viewModel: viewModel,
                finderIntegrationViewModel: finderIntegrationViewModel,
                finderMenuSettings: finderMenuSettings,
                selectedTab: Binding(get: { selectedTab }, set: { tab in
                    selectedTab = tab
                    // A newer native tab choice supersedes pending external navigation.
                    // Programmatic authorization/route selection bypasses this setter.
                    pendingAppRoute.discard()
                })
            )
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 600)
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
        guard let generation = windowPresentation.requestAuthorizationCheck() else { return }
        Task { @MainActor in
            guard windowPresentation.canPresent(generation) else { return }
            await viewModel.processPendingFinderAuthorizationRequests(
                from: authorizationRequestStore,
                resumingPauseID: resumingPauseID,
                isPresentationAvailable: { windowPresentation.canPresent(generation) },
                willPresent: { selectedTab = .create },
                confirmAuthorization: { request in
                    AppKitFileActions.confirmFinderAuthorization(
                        for: request,
                        templateName: viewModel.template(withID: request.templateID)?.name
                    )
                }
            )
            guard windowPresentation.finishAuthorizationCheck(for: generation, isBusy: viewModel.isAuthorizationCheckBusy) else { return }
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

    @MainActor
    private func applyPendingAppRoute() {
        guard windowPresentation.generation != nil,
              !windowPresentation.isAwaitingAuthorizationCheck,
              pendingAppRoute.route != nil else { return }
        guard let route = pendingAppRoute.takeIfReady(
            startupAuthorizationChecked: hasCheckedStartupAuthorizationRequests,
            isBusy: viewModel.isAuthorizationCheckBusy
        ) else { return }
        // Only select the existing controller; do not replace its content or .id.
        selectedTab = AppTab(route: route)
    }
}
