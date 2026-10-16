"""Compile the production community updater without Sparkle and exercise its behavior."""
import base64
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid
from xml.parsers.expat import ExpatError

if __package__:
    from .native_test_support import compile_fixture_localizations, shared_native_modules
else:
    from native_test_support import compile_fixture_localizations, shared_native_modules

ROOT = Path(__file__).resolve().parents[2]
TEMPORARY = ROOT / ".build" / "Temporary" / "community-update-controller-tests"
BETA_PREFERENCE = "QuickFileReceivesBetaUpdates"


def verify_empty_preferences_export(result, delete_exit_code):
    diagnostic = f"delete_exit_code={delete_exit_code}, export_exit_code={result.returncode}"
    if result.returncode:
        raise AssertionError(f"Preference export failed ({diagnostic})")
    try:
        domain = plistlib.loads(result.stdout)
    except (plistlib.InvalidFileException, ValueError, TypeError, ExpatError):
        raise AssertionError(f"Preference export was not a valid plist ({diagnostic})") from None
    if not isinstance(domain, dict):
        raise AssertionError(f"Preference export was not a dictionary ({diagnostic})")
    if domain:
        # Only report the known synthetic key and a count, never exported values
        # or unexpected key names, even when cleanup fails.
        raise AssertionError(
            f"Native test preference suite was not empty ({diagnostic}, "
            f"test_key_present={BETA_PREFERENCE in domain}, remaining_key_count={len(domain)})"
        )

HARNESS = r'''
import Foundation

@main
struct CommunityUpdateCases {
    @MainActor
    static func main() throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let suite = CommandLine.arguments[2]
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let betaKey = "QuickFileReceivesBetaUpdates"
        defer {
            defaults.removePersistentDomain(forName: suite)
            let synchronized = defaults.synchronize()
            let remaining = defaults.persistentDomain(forName: suite) ?? [:]
            if !synchronized || !remaining.isEmpty {
                let diagnostic = "Native preference cleanup failed: synchronized=\(synchronized), "
                    + "test_key_present=\(remaining[betaKey] != nil), remaining_key_count=\(remaining.count)\n"
                FileHandle.standardError.write(Data(diagnostic.utf8))
                exit(1)
            }
        }
        let initialBeta = CommandLine.arguments[3] == "true"
        defaults.set(initialBeta, forKey: betaKey)

        // Valid metadata and a non-test initializer keep other disabling guards
        // from masking a regression in the community compilation condition.
        precondition(UpdateConfiguration(info: bundle.infoDictionary ?? [:]) != nil)
        let controller = UpdateController(bundle: bundle, defaults: defaults, isTesting: false)
        func state(_ controller: UpdateController) -> [String: Bool] {
            ["available": controller.isAvailable,
             "canCheck": controller.canCheckForUpdates,
             "automatic": controller.automaticallyChecksForUpdates,
             "beta": controller.receivesBetaUpdates]
        }
        let initial = state(controller)
        controller.checkForUpdates()
        controller.setAutomaticallyChecksForUpdates(true)
        controller.checkForUpdates()
        controller.setReceivesBetaUpdates(!initialBeta)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        let afterEnable = state(controller)
        let reloaded = UpdateController(bundle: bundle, defaults: defaults, isTesting: false)
        let afterReload = state(reloaded)
        controller.setAutomaticallyChecksForUpdates(false)
        controller.setReceivesBetaUpdates(initialBeta)
        controller.checkForUpdates()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        let report: [String: Any] = [
            "validConfiguration": true,
            "initial": initial,
            "afterEnable": afterEnable,
            "afterReload": afterReload,
            "afterDisable": state(controller),
            "persistedBeta": defaults.bool(forKey: betaKey),
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
'''


COMMUNITY_HARNESS = r'''
import Foundation

actor CommunityCheckProbe {
    struct Call: Sendable {
        let version: String
        let build: String
        let releaseTag: String?
        let betas: Bool
    }
    private var calls: [Call] = []
    private var pending: CheckedContinuation<CommunityReleaseCheckResult, Error>?

    func check(version: String, build: String, releaseTag: String?, betas: Bool) async throws -> CommunityReleaseCheckResult {
        // Deliberately ignore cancellation until the transport returns, so the
        // controller must retain its single request slot and discard stale data.
        try await withCheckedThrowingContinuation { continuation in
            precondition(pending == nil, "Overlapping community requests")
            calls.append(Call(version: version, build: build, releaseTag: releaseTag, betas: betas))
            pending = continuation
        }
    }

    func recordedCalls() -> [Call] { calls }

    func finish(_ result: Result<CommunityReleaseCheckResult, CommunityReleaseCheckError>) {
        precondition(pending != nil, "No pending community request")
        let continuation = pending!
        pending = nil
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

@main
struct ManualCommunityUpdateCases {
    @MainActor
    static func state(_ controller: UpdateController) -> [String: Any] {
        ["available": controller.isAvailable,
         "canCheck": controller.canCheckForUpdates,
         "automatic": controller.automaticallyChecksForUpdates,
         "beta": controller.receivesBetaUpdates,
         "checking": controller.isCheckingForUpdates,
         "usesGitHub": controller.usesGitHubReleases,
         "status": status(controller.communityCheckStatus)]
    }

    static func status(_ value: CommunityUpdateStatus?) -> String {
        switch value {
        case .checked(.updateAvailable(let release)):
            return "available:\(release.tag):\(release.version):\(release.build):\(release.pageURL.absoluteString)"
        case .checked(.upToDate): return "upToDate"
        case .checked(.noPublishedRelease): return "noPublishedRelease"
        case .failed(.rateLimited): return "rateLimited"
        case .failed: return "otherFailure"
        case nil: return "none"
        }
    }

    static func waitForCalls(_ count: Int, probe: CommunityCheckProbe) async throws {
        for _ in 0..<200 {
            if await probe.recordedCalls().count == count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Community request did not start")
    }

    @MainActor
    static func waitForCompletion(_ controller: UpdateController) async throws {
        for _ in 0..<200 {
            if !controller.isCheckingForUpdates { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Community request did not finish")
    }

    @MainActor
    static func main() async throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let suite = CommandLine.arguments[2]
        let initialBeta = CommandLine.arguments[3] == "true"
        let mode = CommandLine.arguments[4]
        let defaults = UserDefaults(suiteName: suite)!
        let betaKey = "QuickFileReceivesBetaUpdates"
        defaults.removePersistentDomain(forName: suite)
        defaults.set(initialBeta, forKey: betaKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            let synchronized = defaults.synchronize()
            let remaining = defaults.persistentDomain(forName: suite) ?? [:]
            if !synchronized || !remaining.isEmpty {
                let diagnostic = "Native preference cleanup failed: synchronized=\(synchronized), "
                    + "test_key_present=\(remaining[betaKey] != nil), remaining_key_count=\(remaining.count)\n"
                FileHandle.standardError.write(Data(diagnostic.utf8))
                exit(1)
            }
        }
        precondition(UpdateConfiguration(info: bundle.infoDictionary ?? [:]) == nil)
        let probe = CommunityCheckProbe()
        let check: UpdateController.CommunityCheck = { version, build, releaseTag, betas in
            try await probe.check(version: version, build: build, releaseTag: releaseTag, betas: betas)
        }
        var presented: [String] = []
        let controller: UpdateController
        if mode == "xctest" {
            precondition(ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil)
            controller = UpdateController(bundle: bundle, defaults: defaults, checkCommunityRelease: check,
                                          presentCommunityResult: { presented.append(status($0)) })
        } else {
            controller = UpdateController(bundle: bundle, defaults: defaults, isTesting: mode == "testing",
                                          checkCommunityRelease: check,
                                          presentCommunityResult: { presented.append(status($0)) })
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        var report: [String: Any] = ["initial": state(controller),
                                   "initialRequests": await probe.recordedCalls().count]
        controller.setAutomaticallyChecksForUpdates(true)
        controller.setReceivesBetaUpdates(!initialBeta)
        controller.setAutomaticallyChecksForUpdates(false)
        controller.setReceivesBetaUpdates(initialBeta)
        try await Task.sleep(nanoseconds: 20_000_000)
        report["afterPreferences"] = state(controller)
        report["preferenceRequests"] = await probe.recordedCalls().count
        if mode != "manual" {
            controller.checkForUpdates()
            try await Task.sleep(nanoseconds: 20_000_000)
            report["afterManual"] = state(controller)
        } else {
            controller.checkForUpdates()
            report["inFlight"] = state(controller)
            try await waitForCalls(1, probe: probe)
            controller.checkForUpdates()
            try await Task.sleep(nanoseconds: 20_000_000)
            report["duplicateRequests"] = await probe.recordedCalls().count
            await probe.finish(.success(.updateAvailable(CommunityRelease(
                tag: "v9.8.7", version: "9.8.7", build: "987",
                pageURL: URL(string: "https://github.com/haoyang7/QuickFile/releases/tag/v9.8.7")!
            ))))
            try await waitForCompletion(controller)
            report["availableResult"] = state(controller)
            controller.setReceivesBetaUpdates(!initialBeta)
            report["afterResultPreference"] = state(controller)
            controller.checkForUpdates()
            try await waitForCalls(2, probe: probe)
            controller.setReceivesBetaUpdates(initialBeta)
            controller.checkForUpdates()
            try await Task.sleep(nanoseconds: 20_000_000)
            report["cancelledInFlight"] = state(controller)
            report["cancelledRequests"] = await probe.recordedCalls().count
            await probe.finish(.success(.upToDate))
            try await waitForCompletion(controller)
            report["afterStaleResult"] = state(controller)
            report["presentedAfterStale"] = presented
            for (index, result) in [Result<CommunityReleaseCheckResult, CommunityReleaseCheckError>.success(.upToDate),
                                    .success(.noPublishedRelease), .failure(.rateLimited)].enumerated() {
                controller.checkForUpdates()
                try await waitForCalls(index + 3, probe: probe)
                await probe.finish(result)
                try await waitForCompletion(controller)
                report[["upToDateResult", "unpublishedResult", "failedResult"][index]] = state(controller)
            }
        }
        report["calls"] = await probe.recordedCalls().map {
            ["version": $0.version, "build": $0.build,
             "releaseTag": $0.releaseTag as Any? ?? NSNull(), "betas": $0.betas] as [String: Any]
        }
        report["presented"] = presented
        report["persistedBeta"] = defaults.bool(forKey: betaKey)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
'''


class PreferenceCleanupExportTests(unittest.TestCase):
    def result(self, domain, returncode=0):
        return subprocess.CompletedProcess(["defaults", "export", "synthetic-suite", "-"],
                                           returncode, plistlib.dumps(domain), b"")

    def test_empty_dictionary_is_clean_even_when_delete_found_no_domain(self):
        for delete_exit_code in (0, 1):
            with self.subTest(delete_exit_code=delete_exit_code):
                verify_empty_preferences_export(self.result({}), delete_exit_code)

    def test_persisted_beta_key_is_rejected_for_both_boolean_values(self):
        for beta in (False, True):
            with self.subTest(beta=beta), self.assertRaisesRegex(AssertionError, "test_key_present=True"):
                verify_empty_preferences_export(self.result({BETA_PREFERENCE: beta}), 0)

    def test_unexpected_keys_are_rejected_without_disclosing_names_or_values(self):
        with self.assertRaisesRegex(AssertionError, "remaining_key_count=1") as failure:
            verify_empty_preferences_export(self.result({"private-key": "private-value"}), 0)
        self.assertNotIn("private-key", str(failure.exception))
        self.assertNotIn("private-value", str(failure.exception))

    def test_export_failure_is_rejected_even_with_empty_plist(self):
        with self.assertRaisesRegex(AssertionError, "export_exit_code=1"):
            verify_empty_preferences_export(self.result({}, returncode=1), 0)

    def test_malformed_export_is_rejected_without_disclosing_output(self):
        for output in (b"", b"private-output", b"<plist><dict>"):
            with self.subTest(output=output), self.assertRaisesRegex(AssertionError, "not a valid plist") as failure:
                result = subprocess.CompletedProcess([], 0, output, b"private-error")
                verify_empty_preferences_export(result, 0)
            self.assertNotIn("private-output", str(failure.exception))
            self.assertNotIn("private-error", str(failure.exception))

    def test_non_dictionary_plist_is_rejected(self):
        with self.assertRaisesRegex(AssertionError, "not a dictionary"):
            verify_empty_preferences_export(self.result([]), 0)


@unittest.skipUnless(sys.platform == "darwin", "Community updater native regression requires macOS")
class CommunityUpdateControllerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        TEMPORARY.mkdir(parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix="community-update-controller-", dir=TEMPORARY)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        compile_fixture_localizations(cls.directory)
        modules = shared_native_modules()
        cls.executable = cls.compile_harness("CommunityUpdateCases", HARNESS, modules)
        cls.manual_executable = cls.compile_harness("ManualCommunityUpdateCases", COMMUNITY_HARNESS, modules)

    @classmethod
    def compile_harness(cls, name, source, modules):
        main = cls.directory / (name + ".swift")
        main.write_text(source)
        executable = cls.directory / name
        # Deliberately omit DEBUG and any Sparkle module, framework or search path.
        compiled = subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-D", "QUICKFILE_COMMUNITY", "-module-cache-path", str(cls.directory / "module-cache"),
            "-I", str(modules), "-L", str(modules), "-lQuickFileCore",
            "-Xlinker", "-rpath", "-Xlinker", str(modules),
            str(ROOT / "QuickFileApp" / "CommunityReleaseChecker.swift"),
            str(ROOT / "QuickFileApp" / "UpdateController.swift"), str(main),
            "-o", str(executable),
        ], capture_output=True, text=True, timeout=60, cwd=ROOT)
        if compiled.returncode:
            raise RuntimeError(compiled.stdout + compiled.stderr)
        return executable

    def run_manual_controller(self, initial_beta, mode="manual", release_tag=None):
        bundle = self.directory / "Community.bundle"
        info = bundle / "Contents" / "Info.plist"
        info.parent.mkdir(parents=True, exist_ok=True)
        metadata = {
            "CFBundleIdentifier": "org.example.QuickFile.ManualCommunityUpdateFixture",
            "CFBundlePackageType": "BNDL",
            "QuickFileDistributionChannel": "community",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "123",
        }
        if release_tag is not None:
            metadata["QuickFileReleaseTag"] = release_tag
        info.write_bytes(plistlib.dumps(metadata))
        suite = "org.example.QuickFile.CommunityUpdateTest." + uuid.uuid4().hex
        environment = os.environ.copy()
        if mode == "xctest":
            environment["XCTestBundlePath"] = "SyntheticTests.xctest"
        try:
            result = subprocess.run([
                str(self.manual_executable), str(bundle), suite, str(initial_beta).lower(), mode,
            ], capture_output=True, text=True, timeout=15, cwd=ROOT, env=environment)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return json.loads(result.stdout)
        finally:
            deleted = subprocess.run(["defaults", "delete", suite], capture_output=True, timeout=5)
            remaining = subprocess.run(["defaults", "export", suite, "-"], capture_output=True, timeout=5)
            verify_empty_preferences_export(remaining, deleted.returncode)

    def test_community_manual_checks_publish_results_and_retain_cancelled_slot(self):
        available_status = ("available:v9.8.7:9.8.7:987:"
                            "https://github.com/haoyang7/QuickFile/releases/tag/v9.8.7")
        for initial_beta in (False, True):
            with self.subTest(initial_beta=initial_beta):
                report = self.run_manual_controller(initial_beta)
                idle = {"available": True, "canCheck": True, "automatic": False,
                        "beta": initial_beta, "checking": False, "usesGitHub": True, "status": "none"}
                self.assertEqual(report["initial"], idle)
                self.assertEqual(report["afterPreferences"], idle)
                self.assertEqual(report["initialRequests"], 0)
                self.assertEqual(report["preferenceRequests"], 0)
                self.assertEqual(report["inFlight"], {**idle, "canCheck": False, "checking": True})
                self.assertEqual(report["duplicateRequests"], 1)
                self.assertEqual(report["availableResult"], {**idle, "status": available_status})
                self.assertEqual(report["afterResultPreference"], {**idle, "beta": not initial_beta})
                self.assertEqual(report["cancelledInFlight"], {**idle, "canCheck": False, "checking": True})
                self.assertEqual(report["cancelledRequests"], 2)
                self.assertEqual(report["afterStaleResult"], idle)
                self.assertEqual(report["presentedAfterStale"], [available_status])
                for phase, status in (("upToDateResult", "upToDate"),
                                      ("unpublishedResult", "noPublishedRelease"), ("failedResult", "rateLimited")):
                    self.assertEqual(report[phase], {**idle, "status": status}, phase)
                self.assertEqual(report["presented"], [available_status, "upToDate", "noPublishedRelease", "rateLimited"])
                self.assertEqual(report["calls"], [
                    {"version": "1.2.3", "build": "123", "releaseTag": None, "betas": beta}
                    for beta in (initial_beta, not initial_beta, initial_beta, initial_beta, initial_beta)
                ])
                self.assertEqual(report["persistedBeta"], initial_beta)

    def test_installed_release_tag_survives_beta_preference_changes(self):
        for release_tag in ("v1.2.3-beta.7", "v1.2.3", None, "", " v1.2.3-beta.7 "):
            with self.subTest(release_tag=release_tag):
                report = self.run_manual_controller(False, release_tag=release_tag)
                self.assertEqual(report["initialRequests"], 0)
                self.assertEqual(report["preferenceRequests"], 0)
                self.assertEqual(report["calls"], [
                    {"version": "1.2.3", "build": "123", "releaseTag": release_tag, "betas": beta}
                    for beta in (False, True, False, False, False)
                ])

    def test_community_checks_are_disabled_for_explicit_and_detected_xctest(self):
        for mode in ("testing", "xctest"):
            for initial_beta in (False, True):
                with self.subTest(mode=mode, initial_beta=initial_beta):
                    report = self.run_manual_controller(initial_beta, mode)
                    disabled = {"available": False, "canCheck": False, "automatic": False,
                                "beta": initial_beta, "checking": False, "usesGitHub": True, "status": "none"}
                    for phase in ("initial", "afterPreferences", "afterManual"):
                        self.assertEqual(report[phase], disabled, phase)
                    self.assertEqual(report["initialRequests"], 0)
                    self.assertEqual(report["preferenceRequests"], 0)
                    self.assertEqual(report["calls"], [])
                    self.assertEqual(report["presented"], [])
                    self.assertEqual(report["persistedBeta"], initial_beta)

    def test_valid_metadata_cannot_enable_updates_or_network_but_beta_persists(self):
        for initial_beta in (False, True):
            with self.subTest(initial_beta=initial_beta):
                self.check_community_controller(initial_beta)

    def check_community_controller(self, initial_beta):
        connections = []
        stopped = threading.Event()
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(0.05)
            port = listener.getsockname()[1]

            def observe_connections():
                while not stopped.is_set():
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        connections.append(True)

            observer = threading.Thread(target=observe_connections, daemon=True)
            observer.start()
            try:
                # Prove the listener can detect a connection before testing zero
                # updater requests. TLS success is unnecessary to detect attempts.
                with socket.create_connection(("127.0.0.1", port), timeout=2):
                    pass
                for _ in range(40):
                    if connections:
                        break
                    stopped.wait(0.05)
                self.assertEqual(len(connections), 1, "Feed connection observer is not functioning")
                connections.clear()

                bundle = self.directory / "Synthetic.bundle"
                info = bundle / "Contents" / "Info.plist"
                info.parent.mkdir(parents=True, exist_ok=True)
                info.write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": "org.example.QuickFile.CommunityUpdateFixture",
                    "CFBundlePackageType": "BNDL",
                    "QuickFileDistributionChannel": "developer-id",
                    "QuickFileUpdatesEnabled": "YES",
                    "SUFeedURL": f"https://127.0.0.1:{port}/appcast.xml",
                    "SUPublicEDKey": base64.b64encode(bytes(range(32))).decode("ascii"),
                    "SUEnableAutomaticChecks": True,
                }))
                suite = "org.example.QuickFile.CommunityUpdateTest." + uuid.uuid4().hex
                try:
                    result = subprocess.run([
                        str(self.executable), str(bundle), suite, str(initial_beta).lower(),
                    ], capture_output=True, text=True, timeout=15, cwd=ROOT)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    report = json.loads(result.stdout)
                    self.assertTrue(report["validConfiguration"])
                    for phase, beta in (("initial", initial_beta), ("afterEnable", not initial_beta),
                                        ("afterReload", not initial_beta), ("afterDisable", initial_beta)):
                        self.assertEqual(report[phase], {
                            "available": False, "canCheck": False, "automatic": False, "beta": beta,
                        }, phase)
                    self.assertEqual(report["persistedBeta"], initial_beta)
                finally:
                    # Also remove preferences if the native harness crashes before
                    # its defer executes; the suite is unique to this invocation.
                    deleted = subprocess.run(["defaults", "delete", suite], capture_output=True, timeout=5)
                    remaining = subprocess.run(["defaults", "export", suite, "-"], capture_output=True, timeout=5)
                    # An absent domain can export successfully as an empty plist;
                    # command status alone does not prove whether keys remain.
                    verify_empty_preferences_export(remaining, deleted.returncode)
                stopped.wait(0.1)
                self.assertEqual(connections, [], "Community updater attempted to contact the feed")
            finally:
                stopped.set()
                observer.join(timeout=2)
                self.assertFalse(observer.is_alive(), "Feed observer did not stop")


if __name__ == "__main__":
    unittest.main()
