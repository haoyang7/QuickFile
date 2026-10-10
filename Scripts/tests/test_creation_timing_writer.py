"""Actual bounded JSON writer on an injected sink in test-owned directories."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("writer_timeline", ROOT / "Scripts/Investigations/creation-timeline.py")
TIMELINE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TIMELINE)


@unittest.skipUnless(sys.platform == "darwin", "Native bounded timing writer requires macOS")
class CreationTimingWriterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="quickfile-timing-writer-build-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.executable = Path(cls.temporary.name) / "CreationTimingWriterCases"
        result = subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            str(ROOT / "Shared/CreationTiming.swift"),
            str(ROOT / "Scripts/tests/fixtures/CreationTimingWriterCases.swift"),
            "-o", str(cls.executable),
        ], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def run_case(self, scenario):
        with tempfile.TemporaryDirectory(prefix="owned-timing-writer-") as directory:
            result = subprocess.run([str(self.executable), scenario, directory],
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            traces = {path.stem: json.loads(path.read_text()) for path in Path(directory).glob("*.json")}
            receipts = [json.loads(path.read_text()) for path in (Path(directory) / "receipts").glob("*.json")]
            return json.loads(result.stdout), traces, receipts

    def test_blocked_writer_holds_capacity_rejects_without_encoding_and_persists_drops(self):
        result, traces, receipts = self.run_case("overflow")
        self.assertEqual(result["pendingWhileBlocked"], 2)
        self.assertEqual(result["encodedWhileBlocked"], 1)
        self.assertEqual(result["accepted"], 2)
        self.assertEqual(result["rejected"], 1024)
        self.assertEqual(result["encodedAfterFirstSession"], 2)
        self.assertEqual(result["pendingAfterDrain"], 0)
        self.assertEqual(set(traces), {"first", "second", "next-session"})
        self.assertEqual(len(receipts), 2)
        original = next(receipt for receipt in receipts if receipt["sessionID"] == traces["first"]["delivery"]["sessionID"])
        self.assertTrue(original["closed"])
        self.assertEqual(original["acceptedReports"], 2)
        self.assertEqual(original["writtenReports"], 2)
        self.assertEqual(original["droppedReports"], 1024)
        self.assertEqual(original["failedReports"], 0)
        self.assertEqual(traces["second"]["delivery"]["sequence"], 2)
        with self.assertRaises(ValueError):
            TIMELINE.validate_delivery([traces["first"]], [original], "json")
        subsequent = next(receipt for receipt in receipts if receipt != original)
        self.assertEqual(traces["next-session"]["delivery"]["sequence"], 1)
        TIMELINE.validate_delivery([traces["next-session"]], [subsequent], "json")

    def test_report_write_failure_is_persistent_invalid_evidence(self):
        for scenario in ("write-failure", "encode-failure"):
            with self.subTest(scenario=scenario):
                result, traces, receipts = self.run_case(scenario)
                self.assertEqual(result["pendingAfterDrain"], 0)
                self.assertEqual(traces, {})
                self.assertEqual(len(receipts), 1)
                self.assertEqual(receipts[0]["acceptedReports"], 1)
                self.assertEqual(receipts[0]["writtenReports"], 0)
                self.assertEqual(receipts[0]["failedReports"], 1)
                with self.assertRaises(ValueError):
                    TIMELINE.validate_delivery([], receipts, "json")

    def test_blocked_receipt_allows_bounded_new_session_and_serializes_concurrent_drains(self):
        result, traces, receipts = self.run_case("receipt-concurrency")
        self.assertEqual(result["pendingWhileBlocked"], 2)
        self.assertEqual(result["encodedWhileBlocked"], 1)
        self.assertEqual(result["accepted"], 3)
        self.assertEqual(result["rejected"], 1024)
        self.assertEqual(result["pendingAfterDrain"], 0)
        self.assertEqual(set(traces), {"first", "second", "third"})
        self.assertEqual(len(receipts), 2)
        original = next(receipt for receipt in receipts if receipt["sessionID"] == traces["first"]["delivery"]["sessionID"])
        TIMELINE.validate_delivery([traces["first"]], [original], "json")
        subsequent = next(receipt for receipt in receipts if receipt != original)
        self.assertEqual(subsequent["acceptedReports"], 2)
        self.assertEqual(subsequent["writtenReports"], 2)
        self.assertEqual(subsequent["droppedReports"], 1024)
        self.assertEqual(subsequent["failedReports"], 0)
        for name, sequence in (("second", 1), ("third", 2)):
            self.assertEqual(traces[name]["delivery"], {"sessionID": subsequent["sessionID"], "sequence": sequence})
        with self.assertRaises(ValueError):
            TIMELINE.validate_delivery([traces["second"], traces["third"]], [subsequent], "json")

    def test_completed_reports_without_explicit_closure_have_no_clean_receipt(self):
        result, traces, receipts = self.run_case("unclosed")
        self.assertEqual(result["pendingAfterDrain"], 0)
        self.assertEqual(set(traces), {"first"})
        self.assertEqual(receipts, [])
        with self.assertRaises(ValueError):
            TIMELINE.validate_delivery(list(traces.values()), receipts, "json")

    def test_receipt_write_failure_cannot_certify_existing_report(self):
        _, traces, receipts = self.run_case("receipt-failure")
        self.assertEqual(set(traces), {"first"})
        self.assertEqual(receipts, [])
        with self.assertRaises(ValueError):
            TIMELINE.validate_delivery(list(traces.values()), receipts, "json")

    def test_repeated_drains_rotate_nonempty_sessions_without_reopening_receipts(self):
        _, traces, receipts = self.run_case("rotation")
        self.assertEqual(set(traces), {"first", "next-session"})
        self.assertEqual(len(receipts), 2)
        self.assertNotEqual(traces["first"]["delivery"]["sessionID"], traces["next-session"]["delivery"]["sessionID"])
        TIMELINE.validate_delivery(list(traces.values()), receipts, "json")


if __name__ == "__main__":
    unittest.main()
