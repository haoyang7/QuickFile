import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "Scripts/resolve-packages.py"
SPEC = importlib.util.spec_from_file_location("resolve_packages", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

TIMEOUT = (
    "failed downloading 'https://example.invalid/Sparkle.zip' which is required "
    "by binary target 'Sparkle': downloadError(\"The request timed out.\")"
)
TIMEOUT_LOG = MODULE.RESOLUTION_ERROR + "\n  " + TIMEOUT + "\n  fatalError\n"


class PackageResolutionTests(unittest.TestCase):
    def setUp(self):
        temporary_root = ROOT / ".build/Temporary/ci-package-download"
        temporary_root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=temporary_root)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.lock = self.root / "Package.resolved"
        self.lock.write_bytes(b"committed pinned packages\n")
        self.lock_hash = hashlib.sha256(self.lock.read_bytes()).hexdigest()
        self.calls = self.root / "calls.jsonl"
        self.plan = self.root / "plan.json"
        self.executable = self.root / "xcodebuild-fixture"
        self.executable.write_text('''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
root = Path(__file__).parent
arguments = sys.argv[1:]
stage = ("resolve" if "-resolvePackageDependencies" in arguments else
         "settings" if "-showBuildSettings" in arguments else arguments[-1])
calls = root / "calls.jsonl"
previous = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
with calls.open("a") as stream:
    stream.write(json.dumps({"stage": stage, "arguments": arguments}) + "\\n")
attempt = sum(call["stage"] == stage for call in previous)
plan = json.loads((root / "plan.json").read_text())
entries = plan.get(stage, [{"code": 0, "log": ""}])
entry = entries[min(attempt, len(entries) - 1)]
lock = root / "Package.resolved"
if entry.get("lock") == "missing":
    lock.unlink()
elif entry.get("lock") == "changed":
    lock.write_text("unexpected resolution drift\\n")
print(entry.get("log", ""), end="", flush=True)
if "signal" in entry:
    os.kill(os.getpid(), entry["signal"])
sys.exit(entry["code"])
''')
        self.executable.chmod(0o755)

    def set_plan(self, **stages):
        self.plan.write_text(json.dumps(stages))

    def observed_calls(self):
        if not self.calls.exists():
            return []
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def run_resolution(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), \
                patch.object(MODULE.time, "sleep") as sleep:
            code = MODULE.resolve_packages(str(self.executable), "QuickFile.xcodeproj",
                                           "source-packages", self.lock, self.lock_hash)
        return code, stdout.getvalue(), stderr.getvalue(), sleep

    def test_first_attempt_success_uses_pinned_project_and_scheme(self):
        self.set_plan(resolve=[{"code": 0, "log": "resolved packages\n"}])
        code, stdout, stderr, sleep = self.run_resolution()
        self.assertEqual(code, 0, stderr)
        self.assertIn("resolved packages", stdout)
        self.assertEqual(self.observed_calls(), [{"stage": "resolve", "arguments": [
            "-resolvePackageDependencies", "-project", "QuickFile.xcodeproj",
            "-scheme", "QuickFile", "-clonedSourcePackagesDirPath", "source-packages",
            "-disableAutomaticPackageResolution",
        ]}])
        sleep.assert_not_called()

    def test_binary_timeout_then_success(self):
        self.set_plan(resolve=[{"code": 65, "log": TIMEOUT_LOG}, {"code": 0}])
        code, stdout, stderr, sleep = self.run_resolution()
        self.assertEqual(code, 0, stderr)
        self.assertEqual(len(self.observed_calls()), 2)
        self.assertIn(TIMEOUT, stdout)
        sleep.assert_called_once_with(2)

    def test_optional_derived_data_path_is_passed_without_changing_default_commands(self):
        self.set_plan(resolve=[{"code": 0}])
        code = MODULE.resolve_packages(str(self.executable), "QuickFile.xcodeproj",
                                       "source-packages", self.lock, self.lock_hash,
                                       "invocation/Release")
        self.assertEqual(code, 0)
        self.assertEqual(self.observed_calls()[0]["arguments"][-2:],
                         ["-derivedDataPath", "invocation/Release"])

    @unittest.skipUnless(Path("/usr/bin/python3").is_file(), "system Python is unavailable")
    def test_cli_help_runs_with_system_python(self):
        # macOS may provide Python 3.9 even when CI uses a newer interpreter.
        result = subprocess.run(["/usr/bin/python3", "-B", str(SCRIPT), "--help"],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--derived-data-path", result.stdout)

    def test_three_timeouts_return_last_real_status(self):
        self.set_plan(resolve=[{"code": code, "log": TIMEOUT_LOG} for code in (65, 66, 74)])
        code, _, _, sleep = self.run_resolution()
        self.assertEqual(code, 74)
        self.assertEqual(len(self.observed_calls()), 3)
        self.assertEqual([call.args for call in sleep.call_args_list], [(2,), (4,)])

    def test_binary_timeout_followed_by_signal_is_not_retried(self):
        self.set_plan(resolve=[
            {"code": 65, "log": TIMEOUT_LOG, "signal": signal.SIGTERM},
            {"code": 0},
        ])
        code, stdout, stderr, sleep = self.run_resolution()
        self.assertEqual(code, 128 + signal.SIGTERM, stderr)
        self.assertIn(TIMEOUT, stdout)
        self.assertEqual(len(self.observed_calls()), 1)
        sleep.assert_not_called()

    def test_non_download_timeout_and_non_network_errors_are_not_retried(self):
        logs = [
            "", "The request timed out.\n", "error: build timed out\n",
            TIMEOUT.replace("binary target", "source target"),
            TIMEOUT.replace("The request timed out.", "HTTP 503"),
            "error: checksum of downloaded artifact does not match\n",
            "error: invalid package manifest\n", "error: dependency conflict\n",
            "error: HTTP 403 forbidden\n", "error: Permission denied\n",
            "error: No space left on device\n",
        ]
        for log in logs:
            with self.subTest(log=log):
                self.calls.unlink(missing_ok=True)
                self.set_plan(resolve=[{"code": 65, "log": log}])
                code, _, _, sleep = self.run_resolution()
                self.assertEqual(code, 65)
                self.assertEqual(len(self.observed_calls()), 1)
                sleep.assert_not_called()

    def test_mixed_timeout_and_other_diagnostics_are_not_retried(self):
        for error in ("error: checksum mismatch", "invalid package manifest", "dependency conflict",
                      "HTTP 403 forbidden", "Permission denied", "No space left on device"):
            for log in (TIMEOUT_LOG + error + "\n", error + "\n" + TIMEOUT_LOG):
                with self.subTest(log=log):
                    self.calls.unlink(missing_ok=True)
                    self.set_plan(resolve=[{"code": 65, "log": log}])
                    code, _, _, sleep = self.run_resolution()
                    self.assertEqual(code, 65)
                    self.assertEqual(len(self.observed_calls()), 1)
                    sleep.assert_not_called()

    def test_second_attempt_lock_drift_or_removal_rejects_success_and_failure(self):
        for outcome in (0, 65):
            for change in ("changed", "missing"):
                with self.subTest(outcome=outcome, change=change):
                    self.calls.unlink(missing_ok=True)
                    self.lock.write_bytes(b"committed pinned packages\n")
                    self.set_plan(resolve=[
                        {"code": 65, "log": TIMEOUT_LOG},
                        {"code": outcome, "log": TIMEOUT_LOG, "lock": change},
                    ])
                    code, _, stderr, sleep = self.run_resolution()
                    self.assertEqual(code, 1)
                    self.assertIn("Package.resolved", stderr)
                    self.assertEqual(len(self.observed_calls()), 2)
                    sleep.assert_called_once_with(2)

    def test_lock_drift_and_removal_reject_success_and_failure_before_retry(self):
        for outcome in (0, 65):
            for change in ("changed", "missing"):
                with self.subTest(outcome=outcome, change=change):
                    self.calls.unlink(missing_ok=True)
                    self.lock.write_bytes(b"committed pinned packages\n")
                    self.set_plan(resolve=[{"code": outcome, "log": TIMEOUT_LOG, "lock": change}])
                    code, _, stderr, sleep = self.run_resolution()
                    self.assertEqual(code, 1)
                    self.assertIn("Package.resolved", stderr)
                    self.assertEqual(len(self.observed_calls()), 1)
                    sleep.assert_not_called()

    def run_readiness_stages(self):
        scripts = self.root / "Scripts"
        scripts.mkdir(exist_ok=True)
        for name in ("resolve-packages.py", "verify-build-settings.py"):
            shutil.copyfile(ROOT / "Scripts" / name, scripts / name)
        source = (ROOT / "Scripts/verify-release-readiness.sh").read_text()
        resolve_and_settings = source[
            source.index("# Explicitly resolve pinned packages"):
            source.index("\nverify_icon_image() {")
        ]
        tests_and_build = source[
            source.index("# This macOS hosted XCTest run"):
            source.index('\nAPP_BUNDLE="')
        ]
        # Run the actual affected commands and pipeline in bash on Linux as well.
        # Unrelated plist/icon/product inspections require the macOS SDK.
        prelude = '''set -euo pipefail
print() {
    [[ "${1:-}" != "--" ]] || shift
    printf '%s\\n' "$*"
}
'''
        env = os.environ.copy()
        env.update({
            "SCRIPT_DIRECTORY": str(scripts), "XCODEBUILD_COMMAND": str(self.executable),
            "PACKAGE_DIRECTORY": "source-packages", "PACKAGE_LOCK": str(self.lock),
            "PACKAGE_LOCK_HASH": self.lock_hash, "EXPECTED_MACOS_VERSION": "13.0",
            "TEST_ARCH": "arm64", "TEST_DERIVED_DATA": "test-data",
            "TEST_RESULT_BUNDLE": "tests.xcresult", "RELEASE_DERIVED_DATA": "release-data",
            "RELEASE_RESULT_BUNDLE": "release.xcresult",
        })
        return subprocess.run(["bash", "-c", prelude + resolve_and_settings + tests_and_build],
                              cwd=self.root, env=env, capture_output=True, text=True, check=False)

    def settings_json(self):
        entries = []
        for target in ("QuickFile", "QuickFileCore", "QuickFileInfrastructure",
                       "QuickFileApplication", "FinderExtension", "QuickFileTests"):
            settings = {"MACOSX_DEPLOYMENT_TARGET": "13.0"}
            if target in ("QuickFile", "FinderExtension"):
                settings["ENABLE_HARDENED_RUNTIME"] = "YES"
            if target not in ("QuickFile", "QuickFileTests"):
                settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
            if target == "QuickFile":
                settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
            entries.append({"target": target, "buildSettings": settings})
        return json.dumps(entries)

    def test_resolution_failure_stops_before_settings_tests_and_release(self):
        self.set_plan(resolve=[{"code": 65, "log": "error: checksum mismatch\n"}])
        result = self.run_readiness_stages()
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertEqual([call["stage"] for call in self.observed_calls()], ["resolve"])

    def test_success_and_later_failures_never_retry_readiness_stages(self):
        for failed_stage, expected in (
            (None, ["resolve", "settings", "test", "build"]),
            ("settings", ["resolve", "settings"]),
            ("test", ["resolve", "settings", "test"]),
            ("build", ["resolve", "settings", "test", "build"]),
        ):
            with self.subTest(failed_stage=failed_stage):
                self.calls.unlink(missing_ok=True)
                self.set_plan(
                    resolve=[{"code": 0}],
                    settings=[{"code": 75 if failed_stage == "settings" else 0,
                               "log": self.settings_json()}],
                    test=[{"code": 75 if failed_stage == "test" else 0}],
                    build=[{"code": 75 if failed_stage == "build" else 0}],
                )
                result = self.run_readiness_stages()
                self.assertEqual(result.returncode, 75 if failed_stage else 0, result.stderr)
                calls = self.observed_calls()
                self.assertEqual([call["stage"] for call in calls], expected)
                for call in calls:
                    self.assertIn("-disableAutomaticPackageResolution", call["arguments"])
                    index = call["arguments"].index("-clonedSourcePackagesDirPath")
                    self.assertEqual(call["arguments"][index + 1], "source-packages")


if __name__ == "__main__":
    unittest.main()
