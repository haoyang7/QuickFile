"""The startup precondition cannot absorb growth from measured target cycles."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Investigations"))
import ax_startup_baseline as startup
import test_ax_compatibility as compatibility
PROBE = compatibility.PROBE


class StartupBaselineTests(unittest.TestCase):
    def exercise(self, values, *, duration=1, error=None):
        clock = [0.0]
        receipt = startup.empty()
        saved = []
        def measure(index, deadline):
            self.assertLess(clock[0], deadline)
            clock[0] += duration
            if index == error:
                raise RuntimeError("invalid scan or nonzero target activity")
            nodes = values[min(index, len(values) - 1)]
            signature = hashlib.sha256(str(nodes).encode()).hexdigest()
            return {"leak_nodes": nodes, "leak_bytes": nodes * 64,
                    "groups": [{"root_instances": 3}], "startup_signature": signature,
                    "stdout_sha256": hashlib.sha256(str(index).encode()).hexdigest()}
        def sleep(seconds):
            clock[0] += seconds
        with mock.patch.object(startup.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(startup.time, "sleep", side_effect=sleep):
            try:
                chosen = startup.settle(measure, lambda value: saved.append(copy.deepcopy(value)), receipt)
            except RuntimeError:
                chosen = None
        startup.validate(receipt)
        self.assertEqual(receipt, saved[-1])
        return receipt, chosen

    def test_zero_target_ramp_is_preserved_before_stable_baseline(self):
        receipt, chosen = self.exercise([279, 286, 286])
        self.assertEqual(receipt["status"], "observed-stable")
        self.assertEqual(receipt["probes"][0]["leak_nodes"], 279)
        self.assertGreaterEqual(receipt["probes"][-1]["elapsed_ms"], 20000)
        self.assertEqual(chosen["leak_nodes"], 286)
        self.assertEqual(chosen["stdout_sha256"], receipt["probes"][-1]["stdout_sha256"])

    def test_stable_pair_does_not_finish_before_observation_window(self):
        receipt, chosen = self.exercise([192, 192, 192, 192, 192, 288, 288, 288])
        self.assertEqual(chosen["leak_nodes"], 288)
        self.assertEqual(receipt["selected_index"], 7)

    def test_never_uses_largest_startup_value_as_baseline(self):
        receipt, chosen = self.exercise([288, 286])
        self.assertEqual(chosen["leak_nodes"], 286)
        self.assertEqual(receipt["probes"][0]["leak_nodes"], 288)

    def test_continuing_growth_exhausts_probe_budget_without_baseline(self):
        receipt, chosen = self.exercise(list(range(12)))
        self.assertIsNone(chosen)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(len(receipt["probes"]), 12)

    def test_equal_scan_completing_after_deadline_is_not_accepted(self):
        receipt, chosen = self.exercise([286], duration=14)
        self.assertIsNone(chosen)
        self.assertEqual(receipt["status"], "failed")

    def test_bad_probe_aborts_without_retry_or_discarding_previous_probes(self):
        receipt, chosen = self.exercise([286], error=2)
        self.assertIsNone(chosen)
        self.assertEqual(len(receipt["probes"]), 2)
        self.assertEqual(receipt["status"], "failed")

    def test_formal_one_node_one_byte_or_one_root_growth_still_fails(self):
        scan = compatibility.AXCompatibilityHeapValidationTests.scan
        base = scan(286, 18624)
        for later in (scan(287, 18624), scan(286, 18625),
                      base | {"groups": [{"root_type": "NSXPCConnection", "root_instances": 2}]}):
            with self.subTest(later=later), self.assertRaises(RuntimeError):
                PROBE.validate_product_scan(later, base)

    def test_receipt_rejects_false_stability_or_private_fields(self):
        valid, _ = self.exercise([286])
        mutations = [lambda v: v.update(selected_index=0),
                     lambda v: v["probes"][-2].update(signature_sha256="a" * 64),
                     lambda v: v["probes"][-1].update(elapsed_ms=40000),
                     lambda v: v["probes"][0].update(path="private"),
                     lambda v: v["policy"].update(consecutive_equal=True)]
        for change in mutations:
            value = copy.deepcopy(valid)
            change(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                startup.validate(value)

    def test_fingerprint_requires_complete_counts_and_detects_composition_change(self):
        from ax_composition import grouped_composition
        empty = {"leak_nodes": 0, "leak_bytes": 0, "groups": []}
        composition = grouped_composition("Process 1: 0 leaks for 0 total leaked bytes.\n")
        first = startup.fingerprint(empty, composition)
        changed = copy.deepcopy(composition)
        changed["type_counts"] = [{"type": "NSArray", "count": 1}]
        self.assertNotEqual(first, startup.fingerprint(empty, changed))
        with self.assertRaises(RuntimeError):
            startup.fingerprint(empty, composition | {"counts_status": "unavailable"})

    def test_new_protocol_refuses_other_investigation_modes_before_launch(self):
        import contextlib
        import io
        flags = ["--copy-lifetime", "--heap-control", "--system-baseline", "--settled-baseline-shadow",
                 "--heap-diagnostics", "--reference-validation", "--live-attribution", "--read-only"]
        base = ["probe", "--work-directory", "/unused", "--records-directory", "/unused-records",
                "--settle-startup-baseline"]
        for flag in flags:
            with self.subTest(flag=flag), mock.patch.object(sys, "argv", base + [flag]), \
                    mock.patch.object(PROBE.subprocess, "Popen") as launched, \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
                PROBE.main()
            self.assertEqual(failure.exception.code, 2)
            launched.assert_not_called()
