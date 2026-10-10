"""Protect actual SwiftUI wiring alongside the native blocked-resolver tests.

These assertions do not launch macOS UI. QuickFileViewModelTests exercises the
real store, shared-model pump and window/route policy with a held resolver; this
file ensures ContentView connects those paths without reinstating the old gate.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AuthorizationStartupWiringTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / "QuickFileApp/ContentView.swift").read_text()

    def test_inventory_refresh_is_separate_from_window_request_admission(self):
        self.assertIn(".task { await viewModel.refreshAuthorizationBookmarks() }", self.source)
        self.assertNotIn("hasCompletedStartupAuthorizationRefresh", self.source)
        appearance = self.source.split(".onAppear {", 1)[1].split(".onDisappear {", 1)[0]
        self.assertIn("windowPresentation.appear()", appearance)
        self.assertIn("schedulePendingFinderAuthorizationRequest()", appearance)
        self.assertNotIn("if ", appearance)
        self.assertNotIn("await ", appearance)

    def test_activation_and_request_notification_do_not_wait_for_inventory(self):
        activation = self.source.split("AppKitFileActions.applicationDidBecomeActiveNotification", 1)[1]
        activation = activation.split(".onReceive(", 1)[0]
        notification = self.source.split("FinderAuthorizationRequestStore.didSaveRequestNotification", 1)[1]
        notification = notification.split(".onReceive(", 1)[0]
        for callback in (activation, notification):
            self.assertIn("schedulePendingFinderAuthorizationRequest()", callback)
            self.assertNotIn("refreshAuthorizationBookmarks", callback)
            self.assertNotIn("if ", callback)

    def test_window_lifetime_and_request_priority_guards_remain(self):
        scheduler = self.source.split("private func schedulePendingFinderAuthorizationRequest(", 1)[1]
        scheduler = scheduler.split("private func resumeAuthorizationCheckOrApplyRoute()", 1)[0]
        self.assertIn("guard let generation = windowPresentation.requestAuthorizationCheck()", scheduler)
        self.assertIn("guard windowPresentation.canPresent(generation)", scheduler)
        self.assertIn("isPresentationAvailable: { windowPresentation.canPresent(generation) }", scheduler)
        self.assertIn("windowPresentation.finishAuthorizationCheck(for: generation, isBusy: viewModel.isAuthorizationCheckBusy)", scheduler)
        self.assertNotIn("refreshAuthorizationBookmarks", scheduler)
        self.assertIn("windowPresentation.disappear()", self.source)
        self.assertIn("!windowPresentation.isAwaitingAuthorizationCheck", self.source)
        self.assertIn("startupAuthorizationChecked: hasCheckedStartupAuthorizationRequests", self.source)


    def test_only_explicit_continue_requests_resume_and_reuses_window_scheduler(self):
        feedback = self.source.split("private var finderAuthorizationQueueFeedback", 1)[1]
        feedback = feedback.split("private func schedulePendingFinderAuthorizationRequest", 1)[0]
        self.assertIn("viewModel.finderAuthorizationQueuePause", feedback)
        self.assertIn("Button(pause.actionTitle)", feedback)
        self.assertIn("schedulePendingFinderAuthorizationRequest(resumingPauseID: pause.id)", feedback)
        self.assertIn(".disabled(viewModel.isBusy || windowPresentation.isAwaitingAuthorizationCheck", feedback)
        self.assertIn("|| finderRequestRecovery.isPresented || finderRequestRecovery.isOperationInFlight", feedback)
        self.assertEqual(self.source.count("resumingPauseID: pause.id"), 1)
        self.assertIn("resumingPauseID: resumingPauseID", self.source)
        self.assertIn("finderAuthorizationRequestPhase.message", feedback)

    def test_window_retry_and_navigation_keep_full_drain_ownership(self):
        self.assertIn("viewModel.$isProcessingFinderAuthorizationRequests", self.source)
        self.assertIn(".map { $0.0 || $0.1 || $0.2 }", self.source)
        self.assertIn("windowPresentation.shouldResumeAuthorizationCheck(isBusy: viewModel.isAuthorizationCheckBusy)", self.source)
        self.assertIn("isBusy: viewModel.isAuthorizationCheckBusy", self.source)
        self.assertNotIn("isBusy: viewModel.isBusy", self.source)

    def test_form_admission_is_separate_from_real_queue_ownership(self):
        model = (ROOT / "QuickFileApp/QuickFileViewModel.swift").read_text()
        busy = model.split("var isBusy: Bool {", 1)[1].split("var isAuthorizationCheckBusy", 1)[0]
        self.assertIn("case .idle, .readingQueue: return false", busy)
        self.assertIn("case .waitingForCurrentOperation, .awaitingAuthorization, .creatingFile: return true", busy)
        self.assertIn("isBusy || isProcessingFinderAuthorizationRequests", model)
        self.assertIn("prepareForPresentation: { await self.prepareFinderPresentation() }", model)
        self.assertIn("finderPresentationWaiter = nil", model)
        self.assertNotIn("withTaskCancellationHandler", model)
        self.assertNotIn("Task.sleep", model)

    def test_direct_folder_choosers_enter_model_admission_before_opening_panels(self):
        view = (ROOT / "QuickFileApp/CreateFileView.swift").read_text()
        model = (ROOT / "QuickFileApp/QuickFileViewModel.swift").read_text()
        self.assertIn("await viewModel.selectDestinationFolder(choosing: {", view)
        self.assertIn("await viewModel.saveFinderAuthorization(choosing: {", view)
        for method in ("selectDestinationFolder", "saveFinderAuthorization"):
            chooser = model.split("func " + method + "(choosing", 1)[1].split("\n    }", 1)[0]
            self.assertLess(chooser.index("isAuthorizingDirectory = true"), chooser.index("await choose()"))
            self.assertIn("defer { isAuthorizingDirectory = false }", chooser)

    def test_late_queue_feedback_and_form_updates_keep_read_generation_ownership(self):
        model = (ROOT / "QuickFileApp/QuickFileViewModel.swift").read_text()
        self.assertIn("readStatusGeneration = self.statusGeneration", model)
        self.assertIn("readFormGeneration = (self.selectionGeneration, self.filenameGeneration)", model)
        self.assertIn("formGeneration: readFormGeneration", model)
        self.assertIn("self.statusGeneration == readStatusGeneration", model)
        pump = (ROOT / "QuickFileApp/FinderAuthorizationRequestPump.swift").read_text()
        failure = pump.split("case let .failure(error):", 1)[1].split("\n            }", 1)[0]
        self.assertIn("didFail(error)", failure)
        self.assertNotIn("willPresent()", failure)
        admission = pump.split("await prepareForPresentation()", 1)[1].split("willPresent()", 1)[0]
        self.assertIn("guard isPresentationAvailable()", admission)

    def test_recovery_entry_is_limited_to_read_failure_and_uses_same_store(self):
        feedback = self.source.split("private var finderAuthorizationQueueFeedback", 1)[1]
        feedback = feedback.split("private func schedulePendingFinderAuthorizationRequest", 1)[0]
        self.assertIn("if case .readFailed = pause.reason", feedback)
        self.assertIn('Button("检查异常请求…") { finderRequestRecovery.open() }', feedback)
        self.assertIn("backend: .init(store: authorizationRequestStore)", self.source)
        self.assertIn("FinderRequestRecoveryView(model: finderRequestRecovery)", self.source)
        self.assertIn("finderRequestRecovery.close()", self.source)

    def test_recovery_does_not_resume_pump_or_display_unclassified_errors(self):
        model = (ROOT / "QuickFileApp/FinderRequestRecoveryViewModel.swift").read_text()
        view = (ROOT / "QuickFileApp/FinderRequestRecoveryView.swift").read_text()
        for source in (model, view):
            self.assertNotIn("processPendingFinderAuthorizationRequests", source)
            self.assertNotIn("resumingPauseID", source)
            self.assertNotIn("destinationFolderPath", source)
            self.assertNotIn("error.localizedDescription", source)
        self.assertIn("error as? FinderAuthorizationRequestStore.RecoveryError", model)
        self.assertIn("@Published private(set) var lastArchive: ArchiveResult?", model)
        self.assertIn("if let archiveURL = archive.archiveURL", view)
        self.assertIn("提交时确认的本机归档位置", view)

    def test_recovery_native_confirmation_defaults_to_cancel(self):
        view = (ROOT / "QuickFileApp/FinderRequestRecoveryView.swift").read_text()
        self.assertIn('let cancel = alert.addButton(withTitle: "取消")', view)
        self.assertIn('archive.keyEquivalent = ""', view)
        self.assertIn("alert.window.defaultButtonCell = cancel.cell as? NSButtonCell", view)
        self.assertIn("return AppModalPresentationGate.shared.present({ alert.runModal() }) == .alertSecondButtonReturn", view)
        self.assertIn(".interactiveDismissDisabled(model.operation == .archiving)", view)

    def test_pause_and_read_feedback_are_app_scoped_and_do_not_count_queue_payloads(self):
        model = (ROOT / "QuickFileApp/QuickFileViewModel.swift").read_text()
        pump = (ROOT / "QuickFileApp/FinderAuthorizationRequestPump.swift").read_text()
        self.assertIn("@Published private(set) var finderAuthorizationQueuePause", model)
        self.assertIn("guard finderAuthorizationQueuePause?.id == resumingPauseID else { return }", model)
        self.assertIn("self.finderAuthorizationRequestPhase = .readingQueue", model)
        cancel = pump.split("guard let directory else {", 1)[1].split("}", 1)[0]
        self.assertIn("didCancel()", cancel)
        self.assertIn("return", cancel)
        self.assertNotIn("continue", cancel)
        self.assertNotIn("pendingRequestCount", self.source)


if __name__ == "__main__":
    unittest.main()
