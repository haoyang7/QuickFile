"""Compile the production community updater without Sparkle and exercise its behavior."""
import base64
import json
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

ROOT = Path(__file__).resolve().parents[2]
TEMPORARY = ROOT / ".build" / "Temporary"
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
        main = cls.directory / "CommunityUpdateCases.swift"
        main.write_text(HARNESS)
        cls.executable = cls.directory / "CommunityUpdateCases"
        # Deliberately omit DEBUG and any Sparkle module, framework or search path.
        compiled = subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-D", "QUICKFILE_COMMUNITY", "-module-cache-path", str(cls.directory / "module-cache"),
            str(ROOT / "QuickFileApp" / "UpdateController.swift"), str(main),
            "-o", str(cls.executable),
        ], capture_output=True, text=True, timeout=60, cwd=ROOT)
        if compiled.returncode:
            raise RuntimeError(compiled.stdout + compiled.stderr)

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
