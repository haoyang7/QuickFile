import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "Swift probe regression requires macOS")
class CreationTimingProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="quickfile-probe-test-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.executable = Path(cls.directory.name) / "ProbeSampleCases"
        scripts = Path(__file__).resolve().parents[1]
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library",
            str(scripts / "Investigations/CreationTimingProbeSample.swift"),
            str(scripts / "tests/fixtures/CreationTimingProbeSampleCases.swift"),
            "-o", str(cls.executable),
        ], check=True, capture_output=True, text=True, timeout=60)

    def check_sample(self, scenario, phase, validation_calls, cleanup_calls, output_exists):
        result = subprocess.run([str(self.executable), scenario], check=True,
                                capture_output=True, text=True, timeout=10)
        report = json.loads(result.stdout)
        self.assertEqual(len(report["measurements"]), 1)
        sample = report["measurements"][0]
        self.assertEqual(sample["sample"], 0)
        self.assertEqual(sample["traceID"], "owned-trace")
        self.assertEqual(sample["durationNS"], 50)
        self.assertEqual(report["remainingTicks"], 1)
        self.assertEqual(sample["success"], phase is None)
        self.assertEqual(sample.get("failurePhase"), phase)
        self.assertEqual(report["traceOutcome"],
                         "fixture-failed" if phase else "fixture-created-no-finder")
        self.assertEqual("failure" in sample, phase is not None)
        self.assertEqual(report["validationCalls"], validation_calls)
        self.assertEqual(report["cleanupCalls"], cleanup_calls)
        self.assertEqual(report["outputExists"], output_exists)

    def test_success_requires_validation_and_cleanup(self):
        self.check_sample("success", None, 1, 1, False)

    def test_creation_failure_is_one_failure_without_postprocessing(self):
        self.check_sample("creation-failure", "creation", 0, 0, False)

    def test_read_failure_is_not_recorded_as_success(self):
        self.check_sample("read-failure", "validation", 1, 0, True)

    def test_nonempty_output_is_rejected_without_deletion(self):
        self.check_sample("nonempty", "validation", 1, 0, True)

    def test_cleanup_failure_preserves_creation_duration_and_fails_trace(self):
        self.check_sample("cleanup-failure", "cleanup", 1, 1, True)


@unittest.skipUnless(sys.platform == "darwin", "Swift probe regression requires macOS")
class CreationTimingProbeEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="quickfile-probe-evidence-test-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.executable = Path(cls.directory.name) / "ProbeEvidenceCases"
        cls.flag_executable = Path(cls.directory.name) / "ProbeEvidenceCasesEnabled"
        scripts = Path(__file__).resolve().parents[1]
        command = [
            "xcrun", "swiftc", "-parse-as-library",
            str(scripts.parent / "Shared/CreationTiming.swift"),
            str(scripts / "Investigations/CreationTimingProbeSample.swift"),
            str(scripts / "tests/fixtures/CreationTimingProbeEvidenceCases.swift"),
        ]
        subprocess.run(command + ["-o", str(cls.executable)],
                       check=True, capture_output=True, text=True, timeout=60)
        subprocess.run(command + ["-D", "QUICKFILE_CREATION_TIMING", "-o", str(cls.flag_executable)],
                       check=True, capture_output=True, text=True, timeout=60)

    def inspect(self, scenario, status, environment=None):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("QUICKFILE_CREATION_TIMING")}
        env.update(environment or {})
        result = subprocess.run([str(self.executable), scenario], check=True,
                                capture_output=True, text=True, timeout=10, env=env)
        report = json.loads(result.stdout)
        evidence = report["measurement"]["traceEvidence"]
        self.assertEqual(evidence["status"], status)
        self.assertEqual(report["evidenceFailure"], status not in ("not-requested", "verified"))
        # Invalid evidence must never reclassify the successful file operation.
        creation_succeeded = not scenario.startswith("failure-") and scenario not in ("failed-creation", "recorder-valid-failure")
        self.assertEqual(report["measurement"]["success"], creation_succeeded)
        self.assertEqual(report["measurement"]["durationNS"], 50)
        self.assertEqual(report["traceOutcome"], "fixture-created-no-finder" if creation_succeeded else "fixture-failed")
        return report

    def test_disabled_tracing_does_not_require_or_read_evidence(self):
        report = self.inspect("disabled", "not-requested")
        self.assertEqual(report["readCount"], 0)
        self.assertNotIn("valid", report["measurement"]["traceEvidence"])

    def test_complete_success_trace_is_verified(self):
        self.inspect("valid", "verified")

    def test_failed_creation_envelope_does_not_claim_complete_operation_evidence(self):
        report = self.inspect("failed-creation", "failure-envelope-only")
        evidence = report["measurement"]["traceEvidence"]
        self.assertTrue(evidence["envelopeValid"])
        self.assertFalse(evidence["valid"])
        self.assertFalse(evidence["complete"])

    def test_failed_creation_requires_probe_begin_even_for_envelope_validation(self):
        self.inspect("failure-missing-probe-begin", "invalid")

    def test_failure_envelope_rejects_incomplete_preflight_spans(self):
        for scenario in ("failure-missing-destination-end", "failure-missing-template-end",
                         "failure-missing-writer-end", "failure-missing-writer-result", "failure-reordered-writer"):
            with self.subTest(scenario=scenario):
                self.inspect(scenario, "invalid")

    def test_complete_writer_failure_remains_partial_operation_evidence(self):
        self.inspect("failure-writer-preflight", "failure-envelope-only")

    def test_missing_and_unstarted_requested_traces_are_rejected(self):
        for scenario in ("missing", "requested-unavailable"):
            with self.subTest(scenario=scenario):
                self.inspect(scenario, "unavailable")

    def test_signposts_require_independent_validation(self):
        self.inspect("external-signposts", "external-validation-required")

    def test_malformed_and_mismatched_traces_are_rejected(self):
        for scenario in ("malformed", "wrong-id", "wrong-pid", "wrong-kind", "wrong-outcome"):
            with self.subTest(scenario=scenario):
                self.inspect(scenario, "invalid")

    def test_incomplete_overflowed_or_reordered_traces_are_rejected(self):
        for scenario in ("dropped", "negative-dropped", "missing-end", "missing-phase",
                         "wrong-phase-order", "nonmonotonic", "extra-bookmark",
                         "duplicate-writer-end", "orphan-scope-stop", "unknown-phase"):
            with self.subTest(scenario=scenario):
                self.inspect(scenario, "invalid")

    def test_missing_unclosed_mismatched_or_lossy_receipts_are_rejected(self):
        for scenario in ("legacy-json", "receipt-missing", "receipt-malformed", "receipt-unclosed",
                         "receipt-wrong-pid", "receipt-wrong-session", "receipt-wrong-version",
                         "receipt-dropped", "receipt-failed", "receipt-incomplete", "receipt-negative",
                         "receipt-zero-sequence", "receipt-forged-sequence", "receipt-path-escape"):
            with self.subTest(scenario=scenario):
                report = self.inspect(scenario, "invalid")
                if scenario == "receipt-dropped":
                    self.assertEqual(report["measurement"]["traceEvidence"]["droppedReports"], 1)
                if scenario == "receipt-failed":
                    self.assertEqual(report["measurement"]["traceEvidence"]["failedReports"], 1)

    def test_real_recorder_write_failure_is_visible_after_flush(self):
        with tempfile.TemporaryDirectory() as directory:
            blocked = Path(directory) / "regular-file"
            blocked.write_text("sentinel")
            self.inspect("recorder-write-failure", "unavailable",
                         {"QUICKFILE_CREATION_TIMING_DIR": str(blocked)})
            self.assertEqual(blocked.read_text(), "sentinel")

    def test_real_recorder_overflow_is_rejected_after_flush(self):
        with tempfile.TemporaryDirectory() as directory:
            report = self.inspect("recorder-overflow", "invalid",
                                  {"QUICKFILE_CREATION_TIMING_DIR": directory})
            self.assertGreater(report["measurement"]["traceEvidence"]["droppedEvents"], 0)
            self.assertEqual(len(list(Path(directory).glob("*.json"))), 1)

    def test_real_recorder_failure_report_is_labelled_envelope_only(self):
        with tempfile.TemporaryDirectory() as directory:
            self.inspect("recorder-valid-failure", "failure-envelope-only",
                         {"QUICKFILE_CREATION_TIMING_DIR": directory})

    def test_real_recorder_remains_disabled_by_default(self):
        report = self.inspect("recorder-disabled", "not-requested")
        self.assertFalse(report["recorderRequested"])

    def test_compile_time_request_is_not_mistaken_for_disabled_tracing(self):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("QUICKFILE_CREATION_TIMING")}
        result = subprocess.run([str(self.flag_executable), "recorder-compile-request"], check=True,
                                capture_output=True, text=True, timeout=10, env=env)
        report = json.loads(result.stdout)
        self.assertTrue(report["recorderRequested"])
        self.assertTrue(report["evidenceFailure"])
        self.assertIn(report["measurement"]["traceEvidence"]["status"],
                      ("unavailable", "external-validation-required"))
        self.assertTrue(report["measurement"]["success"])

    def test_deterministic_bookmarks_are_confined_to_owned_grants(self):
        result = subprocess.run([str(self.executable), "owned-bookmark-codec"], check=True,
                                capture_output=True, text=True, timeout=10)
        report = json.loads(result.stdout)
        self.assertTrue(report["deterministic"])
        self.assertTrue(report["ownedRoundTrip"])
        self.assertEqual(report["token"], "quickfile-owned-bookmark-v1:0")
        self.assertEqual(report["outsideSentinel"], "untouched")
        self.assertEqual(report["rejected"], sorted([
            "outside-encode", "arbitrary-path-token", "out-of-range", "negative-index",
            "noncanonical-index", "symlink-escape-decode", "symlink-escape-encode",
        ]))


if __name__ == "__main__":
    unittest.main()
