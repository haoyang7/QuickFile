import pathlib
import importlib.util
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
