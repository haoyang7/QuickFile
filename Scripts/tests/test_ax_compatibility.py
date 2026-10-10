import pathlib
import contextlib
import importlib.util
import io
import itertools
import os
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
INVESTIGATIONS = ROOT / "Scripts/Investigations"
SPEC = importlib.util.spec_from_file_location("verify_ax_compatibility", INVESTIGATIONS / "verify-ax-compatibility.py")
PROBE = importlib.util.module_from_spec(SPEC)
with mock.patch.object(sys, "path", [str(INVESTIGATIONS), *sys.path]):
    SPEC.loader.exec_module(PROBE)


class AXCompatibilityPreflightTests(unittest.TestCase):
    def test_only_the_actual_reader_controls_accessibility_preflight(self):
        for host_trusted in (False, True):
            for reader_trusted in (False, True):
                with self.subTest(host=host_trusted, reader=reader_trusted):
                    host = {"enabled": True, "status": "enabled", "trusted": host_trusted}
                    reason = PROBE.preflight_reason(host, {"trusted": reader_trusted})
                    self.assertEqual(reason, None if reader_trusted else "reader-not-trusted")

    def test_unknown_images_and_reader_permission_are_distinct(self):
        host = {"enabled": False, "status": "unsupported-images"}
        self.assertEqual(PROBE.preflight_reason(host, {"trusted": True}), "unsupported-images")
        host = {"enabled": False, "status": "system-baseline"}
        self.assertEqual(PROBE.preflight_reason(host, {"trusted": False}, system_baseline=True), "reader-not-trusted")
        self.assertIsNone(PROBE.preflight_reason(host, {"trusted": True}, system_baseline=True))

    def test_installation_failures_and_invalid_reader_receipts_do_not_skip(self):
        for status in ("unsupported-call-site", "unsupported-array-methods", "non-system-methods", "disabled-at-startup"):
            with self.subTest(status=status), self.assertRaises(RuntimeError):
                PROBE.preflight_reason({"enabled": False, "status": status}, {"trusted": False})
        with self.assertRaises(RuntimeError):
            PROBE.preflight_reason({"enabled": True, "status": "enabled"}, {"trusted": "true"})
        with self.assertRaises(RuntimeError):
            PROBE.preflight_reason({"enabled": True, "status": "enabled"}, {"trusted": True}, system_baseline=True)


class AXCompatibilityHeapValidationTests(unittest.TestCase):
    @staticmethod
    def scan(nodes=0, byte_count=0, root_type="NSXPCConnection", ax=False):
        return {"leak_nodes": nodes, "leak_bytes": byte_count,
                "destroyed_notification_stack_present": ax, "unclassified_nodes": 0,
                "groups": [{"root_type": root_type, "root_instances": 1, "tree_nodes": nodes}] if nodes else []}

    def test_zero_heap_and_stable_xpc_baseline_are_reported_separately(self):
        empty = self.scan()
        PROBE.validate_product_scan(empty)
        PROBE.validate_product_scan(empty, empty)
        baseline = self.scan(288, 18_816)
        PROBE.validate_product_scan(baseline)
        PROBE.validate_product_scan(self.scan(288, 18_816), baseline)
        self.assertEqual(baseline["leak_nodes"], 288)

    def test_target_ax_and_unclassified_or_unexpected_roots_fail(self):
        for value in (self.scan(1, 32, ax=True), self.scan(1, 32, root_type="__NSArrayM"),
                      self.scan() | {"unclassified_nodes": 1}):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                PROBE.validate_product_scan(value)

    def test_non_ax_growth_cannot_be_hidden_as_a_startup_baseline(self):
        baseline = self.scan(288, 18_816)
        for value in (self.scan(289, 18_816), self.scan(288, 18_832),
                      self.scan(288, 18_816) | {"groups": [{"root_type": "NSXPCConnection", "root_instances": 2}]}):
            with self.subTest(value=value), self.assertRaises(RuntimeError) as failure:
                PROBE.validate_product_scan(value, baseline)
            self.assertIn(f"baseline={baseline}", str(failure.exception))
            self.assertIn(f"current={value}", str(failure.exception))

    def test_real_leaks_cycle_label_is_parsed_as_its_class(self):
        text = "STACK OF 3 INSTANCES OF 'ROOT CYCLE: NSXPCConnection':\n  288 (18.4K) ROOT CYCLE: <NSXPCConnection>\n"
        groups = PROBE.leak_groups(text)
        self.assertEqual(groups[0]["root_type"], "NSXPCConnection")
        self.assertEqual(groups[0]["root_kind"], "CYCLE")
        entry = self.scan(288, 18_816) | {"groups": groups}
        PROBE.validate_product_scan(entry, entry)
        with self.assertRaises(RuntimeError):
            PROBE.validate_product_scan(entry | {"groups": PROBE.leak_groups(text.replace("NSXPCConnection", "UnexpectedConnection"))})


class AXCompatibilityNotificationTests(unittest.TestCase):
    def test_extra_application_notifications_do_not_hide_per_button_coverage(self):
        receipt = {"notifications": 200, "all_notifications": 204, "unmatched_notifications": 4,
                   "tracked_buttons": 100, "target_notification_counts": [[1, 1] for _ in range(100)]}
        PROBE.validate_notifications(receipt, 100)
        # The aggregate still equals 200: a missing delivery cannot be replaced by
        # a duplicate from another observer or by application-level notifications.
        for deliveries in ([[0, 2]], [[1, 1], [1, 0]]):
            invalid = receipt | {"target_notification_counts": deliveries + [[1, 1]] * (100 - len(deliveries))}
            with self.subTest(deliveries=deliveries), self.assertRaises(RuntimeError):
                PROBE.validate_notifications(invalid, 100)
        with self.assertRaises(RuntimeError):
            PROBE.validate_notifications(receipt | {"all_notifications": 205}, 100)

    def test_read_only_tracks_all_buttons_without_any_notification(self):
        receipt = {"notifications": 0, "all_notifications": 0, "unmatched_notifications": 0,
                   "tracked_buttons": 100, "target_notification_counts": [[] for _ in range(100)]}
        PROBE.validate_notifications(receipt, 100, read_only=True)


class AXCompatibilityLifecycleTests(unittest.TestCase):
    """Inject process/scan results while exercising the real runner protocol."""

    def exercise_runner(self, *, failed_scan=None, invalid_notifications=False,
                        system_baseline=False, insufficient_compensation=False):
        with tempfile.TemporaryDirectory(prefix="ax-protocol-") as directory:
            temporary = pathlib.Path(directory).resolve()
            work = temporary / "fixture"
            records = temporary / "records"
            state = work / "state"
            host_state = {"pid": 1234, "sequence": 0, "buttons": 0, "allocatedButtons": 0,
                          "destroyedButtons": 0, "compensations": 0, "mutableCompensations": 0}
            notifications = {"notifications": 60, "all_notifications": 60, "unmatched_notifications": 0,
                             "tracked_buttons": 30, "target_notification_counts": [[1, 1] for _ in range(30)]}
            if invalid_notifications == "missing-count":
                del notifications["notifications"]
            elif invalid_notifications:
                notifications["target_notification_counts"][0] = [0, 2]
            scan_labels = (["baseline", "removed-10", "removed-30", "observer-exited"] if system_baseline else
                           ["baseline", "registered-10", "removed-10", "removed-20", "removed-30", "observer-exited"])
            scanned = []
            processes = []

            class FixtureProcess:
                returncode = None

                def __init__(self, command, **_kwargs):
                    self.is_reader = pathlib.Path(command[0]).name == "ax-reader"
                    self.pid = 1235 if self.is_reader else 1234
                    processes.append(self)

                def poll(self):
                    return self.returncode

                def wait(self, timeout):
                    self.returncode = 0
                    if self.is_reader:
                        PROBE.write_json(state / "reader-completed.json", notifications)
                    return 0

            def run(command, **_kwargs):
                output = ""
                if "--capabilities" in command:
                    capability = {"trusted": True} if pathlib.Path(command[0]).name == "ax-reader" else {
                        "enabled": not system_baseline, "status": "system-baseline" if system_baseline else "enabled",
                        "images": {"AppKit": "synthetic", "CoreFoundation": "synthetic"}}
                    output = json.dumps(capability)
                elif command[0] == "leaks":
                    label = scan_labels[len(scanned)]
                    scanned.append(label)
                    nodes, size = (287, 18_768) if label == failed_scan else (280, 18_416)
                    output = (f"Process 1234: {nodes} leaks for {size} total leaked bytes.\n"
                              "STACK OF 3 INSTANCES OF 'ROOT CYCLE: NSXPCConnection':\n"
                              f"  {nodes} ({size} bytes) ROOT CYCLE: NSXPCConnection\n")
                return subprocess.CompletedProcess(command, 1 if command[0] == "leaks" else 0, output, "")

            def wait_json(path, predicate, _processes):
                if path.name == "reader-ready.json":
                    command = json.loads((state / "reader-command.json").read_text())
                    receipt = {"sequence": command["sequence"], "buttons": host_state["buttons"],
                               "registrations": host_state["buttons"] * 2,
                               "notifications": host_state["destroyedButtons"] * 2}
                else:
                    command_path = state / "command.json"
                    if command_path.exists():
                        command = json.loads(command_path.read_text())
                        host_state.update(sequence=command["sequence"], action=command["action"])
                        if command["action"] == "add":
                            host_state["buttons"] = 10
                            host_state["allocatedButtons"] += 10
                        elif command["action"] == "remove":
                            host_state["buttons"] = 0
                            host_state["destroyedButtons"] += 10
                            if not system_baseline:
                                host_state["compensations"] += 20
                                host_state["mutableCompensations"] += 10
                                if insufficient_compensation and host_state["destroyedButtons"] == 30:
                                    host_state["compensations"] -= 1
                    receipt = dict(host_state)
                self.assertTrue(predicate(receipt))
                return receipt

            # The real source hashes are retained; only the allowed work root and
            # external processes/time are substituted. No GUI or AX is invoked.
            class ProbeRoot:
                def __truediv__(self, child):
                    return temporary if child == ".build/Temporary" else ROOT / child

            arguments = ["verify-ax-compatibility.py", "--work-directory", str(work), "--records-directory", str(records)]
            if system_baseline:
                arguments.append("--system-baseline")
            with mock.patch.object(sys, "argv", arguments), mock.patch.object(PROBE, "ROOT", ProbeRoot()), \
                    mock.patch.object(PROBE.subprocess, "run", side_effect=run), \
                    mock.patch.object(PROBE.subprocess, "Popen", side_effect=FixtureProcess), \
                    mock.patch.object(PROBE, "wait_json", side_effect=wait_json), \
                    mock.patch.object(PROBE.time, "sleep"), \
                    mock.patch.object(PROBE.time, "monotonic", side_effect=itertools.count(step=0.25)), \
                    contextlib.redirect_stdout(io.StringIO()):
                exit_code = PROBE.main()
            summary = json.loads((records / "result.json").read_text())
            self.assertEqual(scanned, scan_labels)
            self.assertEqual(json.loads((records / "notifications.json").read_text()), notifications)
            self.assertTrue((state / "stop-reader").exists())
            self.assertTrue((state / "quit").exists())
            self.assertTrue(all(process.returncode == 0 for process in processes))
            self.assertEqual(summary["scans"][0]["label"], "baseline")
            scans = json.loads((records / "scans.json").read_text())
            self.assertEqual(scans[0]["host"]["allocatedButtons"], 0)
            self.assertEqual(scans[-1]["host"]["destroyedButtons"], 30)
            if not system_baseline:
                self.assertEqual(scans[1]["host"]["allocatedButtons"], 10)
                self.assertEqual(scans[1]["host"]["destroyedButtons"], 0)
            if exit_code:
                self.assertEqual(json.loads((records / "validation-errors.json").read_text()), summary["validation_errors"])
            return exit_code, summary

    def test_stable_heap_completes_every_lifecycle_checkpoint(self):
        exit_code, summary = self.exercise_runner()
        self.assertEqual(exit_code, 0)
        self.assertEqual(summary["coverage"], "passed")
        self.assertEqual(summary["ax_leak_nodes"], 0)
        self.assertNotIn("validation_errors", summary)

    def test_intermediate_growth_still_fails_after_heap_returns_to_baseline(self):
        for label in ("registered-10", "removed-10", "removed-20", "removed-30", "observer-exited"):
            with self.subTest(label=label):
                exit_code, summary = self.exercise_runner(failed_scan=label)
                self.assertEqual(exit_code, 1)
                self.assertEqual(summary["coverage"], "failed")
                self.assertIsNone(summary["ax_leak_nodes"])
                self.assertEqual([error["stage"] for error in summary["validation_errors"]], [label])

    def test_heap_failure_does_not_skip_per_button_notification_validation(self):
        exit_code, summary = self.exercise_runner(failed_scan="removed-30", invalid_notifications=True)
        self.assertEqual(exit_code, 1)
        self.assertEqual([error["stage"] for error in summary["validation_errors"]], ["removed-30", "notifications"])

    def test_invalid_notifications_preserve_the_exit_scan_and_fail_both_modes(self):
        for baseline in (False, True):
            for invalid in (True, "missing-count"):
                with self.subTest(system_baseline=baseline, invalid=invalid):
                    exit_code, summary = self.exercise_runner(invalid_notifications=invalid, system_baseline=baseline)
                    self.assertEqual(exit_code, 1)
                    self.assertEqual(summary["coverage"], "failed")
                    self.assertEqual([error["stage"] for error in summary["validation_errors"]], ["notifications"])

    def test_system_baseline_still_measures_growth_without_claiming_product_coverage(self):
        exit_code, summary = self.exercise_runner(failed_scan="removed-30", system_baseline=True)
        self.assertEqual(exit_code, 0)
        self.assertEqual(summary["coverage"], "measured")
        self.assertFalse(summary["product_compensation_enabled"])

    def test_insufficient_compensation_preserves_evidence_and_fails(self):
        exit_code, summary = self.exercise_runner(insufficient_compensation=True)
        self.assertEqual(exit_code, 1)
        self.assertEqual(summary["coverage"], "failed")
        self.assertEqual(summary["ordinary_compensations"], 29)
        self.assertEqual([error["stage"] for error in summary["validation_errors"]], ["compensation-branches"])


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "requires macOS SDK")
class AXCompatibilityCopyTests(unittest.TestCase):
    def run_fixture(self, reject_image=False, disable_environment=False, disable_argument=False):
        with tempfile.TemporaryDirectory(prefix="ax-copy-") as directory:
            work = pathlib.Path(directory)
            source = ROOT / "QuickFileApp/AXCompatibility.m"
            if reject_image:
                contents = source.read_text()
                for expected in ("{0x93,0x4e,0x31,0x29", "{0xb6,0xb4,0xbd,0xad"):
                    self.assertEqual(contents.count(expected), 1)
                    contents = contents.replace(expected, "{0x00" + expected[5:])
                source = work / "UnsupportedImage.m"
                source.write_text(contents)
            binary = work / "copy-tests"
            subprocess.run([
                "xcrun", "clang", "-fno-objc-arc", "-O2", "-framework", "AppKit",
                "-I", str(ROOT / "QuickFileApp"), str(source),
                str(ROOT / "Scripts/tests/fixtures/AXCompatibilityCopies.m"),
                "-o", str(binary),
            ], check=True, capture_output=True, text=True, timeout=60)
            environment = dict(os.environ)
            environment.pop("QUICKFILE_DISABLE_AX_COMPATIBILITY", None)
            arguments = [str(binary)]
            if disable_environment:
                environment["QUICKFILE_DISABLE_AX_COMPATIBILITY"] = "1"
            if disable_argument:
                arguments.append("--disable-ax-compatibility")
            if reject_image or disable_environment or disable_argument:
                arguments.append("--expect-disabled")
            result = subprocess.run(arguments, env=environment, check=True, capture_output=True,
                                    text=True, timeout=30)
            self.assertIn("2000 concurrent copy/mutableCopy ownership checks passed", result.stdout)
            if reject_image:
                self.assertIn("compatibility=0", result.stdout)
            if disable_environment or disable_argument:
                self.assertIn("compatibility=0", result.stdout)
                self.assertIn("status=disabled-at-startup", result.stdout)

    def test_startup_environment_can_disable_compensation(self):
        self.run_fixture(disable_environment=True)

    def test_startup_argument_can_disable_compensation(self):
        self.run_fixture(disable_argument=True)

    def test_real_destroyed_notifications_cover_both_compensation_branches(self):
        temporary_root = ROOT / ".build/Temporary"
        temporary_root.mkdir(parents=True, exist_ok=True)
        parent = pathlib.Path(tempfile.gettempdir()).resolve()
        if not parent.is_relative_to(temporary_root):
            parent = temporary_root
        with tempfile.TemporaryDirectory(prefix="ax-notifications-", dir=parent) as directory:
            work = pathlib.Path(directory)
            records = pathlib.Path(os.environ.get("QUICKFILE_AX_TEST_RECORDS", work / "records"))
            result = subprocess.run([
                sys.executable, str(ROOT / "Scripts/Investigations/verify-ax-compatibility.py"),
                "--work-directory", str(work / "fixture"), "--records-directory", str(records)
            ], capture_output=True, text=True, timeout=300)
            if result.returncode == 77:
                self.skipTest("AX notification coverage unavailable: " + result.stdout.strip())
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            receipt = json.loads((records / "result.json").read_text())
            self.assertEqual(receipt["coverage"], "passed")
            self.assertEqual(receipt["notifications"], 60)
            self.assertGreaterEqual(receipt["ordinary_compensations"], 30)
            self.assertGreaterEqual(receipt["mutable_compensations"], 30)
            self.assertEqual(receipt["ax_leak_nodes"], 0)
            self.assertLessEqual(receipt["leak_nodes"], receipt["baseline_leak_nodes"])
            self.assertLessEqual(receipt["leak_bytes"], receipt["baseline_leak_bytes"])

    def test_unrelated_copy_ownership_and_concurrency(self):
        self.run_fixture()

    def test_unknown_system_image_does_not_enable_patch(self):
        self.run_fixture(reject_image=True)
