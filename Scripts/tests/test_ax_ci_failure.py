"""Synthetic ordinary failure evidence; no captured addresses or process data."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Investigations"))
sys.path.insert(0, str(HERE))
import ax_ci_failure as evidence
from test_ax_frozen_nodes import listing, tree

TEMP = HERE.parents[1] / ".build/Temporary/ax-ci-failure-20261012"


class FailureEvidenceTests(unittest.TestCase):
    def setUp(self):
        TEMP.mkdir(parents=True, exist_ok=True)
        directory = tempfile.TemporaryDirectory(dir=TEMP, prefix="collector-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.records = self.root / "records"
        self.records.mkdir()
        self.scans = []
        for index, label in enumerate(evidence.LABELS):
            report = tree({0x1000: 64} if index == 0 else {0x1000: 64, 0x2000: 64}).replace("NSString", "NSXPCConnection")
            self.add_scan(label, report)
        self.write("scans.json", self.scans)
        self.write("result.json", {"coverage": "failed", "message": "private account secret"})
        self.write("failure-capture.json", {"status": "not_attempted", "exit_code": None, "after_label": None, "graph_sha256": None})
        self.write("process-cleanup.json", {"processes_exited": True, "errors": [],
            "host": {"exited": True, "errors": []}, "reader": {"exited": True, "errors": []}})

    def write(self, name, value):
        (self.records / name).write_bytes(evidence.encoded(value))

    def add_scan(self, label, report):
        raw = report.encode()
        (self.records / (label + "-original.stdout.txt")).write_bytes(raw)
        nodes, size = evidence.frozen.totals(report)
        groups = evidence.leak_groups(report)
        self.scans.append({"label": label, "exit_code": int(bool(nodes)), "leak_nodes": nodes, "leak_bytes": size,
            "groups": groups, "stdout_sha256": hashlib.sha256(raw).hexdigest(),
            "unclassified_nodes": nodes - sum(row["tree_nodes"] or 0 for row in groups),
            "destroyed_notification_stack_present": False, "host": {"private": "unpublished"}})

    def collect(self):
        value = evidence.collect(self.records)
        evidence.validate_public(value)
        return value

    def capture(self):
        graph = self.records / "terminal.memgraph"
        graph.write_bytes(b"synthetic private graph")
        value = {"status": "complete", "exit_code": 0, "after_label": "observer-exited",
                 "graph_sha256": hashlib.sha256(graph.read_bytes()).hexdigest()}
        self.write("failure-capture.json", value)
        return value

    def terminal(self, nodes=None, broken=None, exit_unconfirmed=False):
        self.capture()
        private = self.root / "private"
        private.mkdir(exist_ok=True)
        nodes = {0x1000: 64, 0x2000: 48} if nodes is None else nodes
        calls = []
        def run(owner, kind, label, command, allowed=(0,)):
            calls.append(kind)
            owner.summary["tools"].append({"tool": kind, "label": label, "status": "complete", "return_code": 1, "cleanup_confirmed": True})
            if exit_unconfirmed:
                owner.summary["tools"][-1].update(status="timeout", return_code=None, cleanup_confirmed=False)
                owner.summary["process_cleanup_confirmed"] = False
                raise evidence.ExitUnconfirmed()
            if kind == "list": return listing(nodes)
            return broken if broken is not None else tree(nodes, cycle=True)
        with mock.patch.object(evidence.frozen.Tools, "run", autospec=True, side_effect=run):
            value = evidence.terminal_snapshot(self.records, private, time.monotonic() + 30)
        evidence.validate_terminal(value)
        return value, calls

    def test_failed_original_scans_are_complete_evidence_with_growth_preserved(self):
        value = self.collect()
        self.assertEqual((value["status"], value["original_verdict"]), ("complete", "failed"))
        self.assertEqual(value["strict_growth_labels"], list(evidence.LABELS[1:]))
        self.assertEqual(value["terminal"]["status"], "not_attempted")
        self.assertTrue(all(row["binding"] == "matched" for row in value["original_scans"]))
        self.assertEqual((value["original_address_coverage"], value["generation"]), ("unavailable", "unknown"))
        for private in ("0x1000", "private account", "private stack", str(self.root), "host"):
            self.assertNotIn(private, evidence.encoded(value).decode())

    def test_missing_later_scans_keeps_earlier_failure(self):
        self.write("scans.json", self.scans[:2])
        value = self.collect()
        self.assertEqual(value["status"], "partial")
        self.assertEqual(value["strict_growth_labels"], ["registered-10"])
        self.assertEqual(value["original_scans"][0]["status"], "complete")
        self.assertEqual(value["original_verdict"], "failed")

    def test_hash_total_group_and_classification_mismatch_fail_closed(self):
        for key, replacement in (("stdout_sha256", "f" * 64), ("leak_nodes", 999), ("groups", []),
                                 ("unclassified_nodes", 1), ("destroyed_notification_stack_present", True)):
            changed = copy.deepcopy(self.scans)
            changed[1][key] = replacement
            self.write("scans.json", changed)
            with self.subTest(key=key):
                value = self.collect()
                self.assertEqual(value["original_scans"][1]["binding"], "mismatch")
                self.assertEqual(value["status"], "partial")
                self.assertEqual(value["original_verdict"], "failed")

    def test_bad_stdout_and_scan_sequence_preserve_original_verdict(self):
        (self.records / "baseline-original.stdout.txt").write_bytes(b"\xffprivate")
        value = self.collect()
        self.assertIn("scan_invalid", value["reasons"])
        self.write("scans.json", [self.scans[1], self.scans[0]])
        value = self.collect()
        self.assertIn("scans_unavailable", value["reasons"])
        self.assertEqual(value["original_verdict"], "failed")

    def test_group_budget_is_explicit_without_losing_totals(self):
        self.scans.clear()
        for label in evidence.LABELS:
            self.add_scan(label, tree({0x1000 + n * 0x100: 64 for n in range(65)}).replace("NSString", "NSXPCConnection"))
        self.write("scans.json", self.scans)
        value = self.collect()
        row = value["original_scans"][0]
        self.assertEqual((row["leak_nodes"], len(row["groups"]), row["omitted_groups"]), (65, 64, 1))
        self.assertEqual(row["binding"], "matched")
        self.assertEqual(value["status"], "partial")

    def test_fixture_exit_unconfirmed_keeps_original_scans_and_prevents_tools(self):
        self.write("process-cleanup.json", {"processes_exited": False, "errors": []})
        self.capture()
        with mock.patch.object(evidence, "run_owned") as owned:
            value = self.collect()
            owned.assert_not_called()
        self.assertFalse(value["fixture_cleanup_confirmed"])
        self.assertFalse(value["process_cleanup_confirmed"])
        self.assertEqual(value["original_verdict"], "failed")
        self.assertTrue(all(row["status"] == "complete" for row in value["original_scans"]))
        self.assertEqual(value["strict_growth_labels"], list(evidence.LABELS[1:]))

    def test_missing_capture_receipt_is_partial_even_with_complete_original_scans(self):
        (self.records / "failure-capture.json").unlink()
        self.scans.clear()
        for label in evidence.LABELS: self.add_scan(label, tree({}))
        self.write("scans.json", self.scans)
        self.write("result.json", {"coverage": "passed"})
        value = self.collect()
        self.assertEqual(value["status"], "partial")
        self.assertIn("capture_missing", value["reasons"])
        self.assertEqual(value["original_verdict"], "passed")
        self.assertTrue(all(row["status"] == "complete" for row in value["original_scans"]))

    def test_unsupported_is_bound_to_capability_not_zero_scans(self):
        (self.records / "scans.json").unlink()
        for reason in evidence.UNSUPPORTED:
            self.write("inputs.json", {"capabilities": {"status": reason if reason != "reader-not-trusted" else "enabled",
                       "enabled": reason == "reader-not-trusted"}, "reader_capabilities": {"trusted": reason != "reader-not-trusted"}})
            value = self.collect()
            self.assertEqual((value["status"], value["unsupported_reason"]), ("unsupported", reason))
            self.assertEqual(value["original_verdict"], "unsupported")
        self.write("inputs.json", {"capabilities": {"status": "enabled", "enabled": True}, "reader_capabilities": {"trusted": True}})
        self.assertEqual(self.collect()["status"], "partial")

    def test_empty_payloads_and_closed_public_vocabulary(self):
        for status in ("not_attempted", "unavailable"):
            evidence.validate_public(evidence.empty(status))
        value = self.collect()
        for mutation in (lambda v: v.update(raw="private"), lambda v: v["original_scans"][0]["groups"][0].update(root_type="private class"),
                         lambda v: v.update(strict_growth_labels=[]), lambda v: v.update(generation="same"),
                         lambda v: v["original_scans"][0].update(leak_bytes=True)):
            changed = copy.deepcopy(value); mutation(changed)
            with self.assertRaises(ValueError): evidence.validate_public(changed)

    def test_passed_result_cannot_mask_strict_failure(self):
        self.write("result.json", {"coverage": "passed"})
        value = self.collect()
        self.assertEqual(value["original_verdict"], "passed")
        self.assertEqual(value["status"], "partial")
        self.assertIn("result_mismatch", value["reasons"])

    def test_unrecognized_input_and_root_names_never_escape_public_projection(self):
        self.write("inputs.json", ["private malformed capability"])
        self.scans.clear()
        for label in evidence.LABELS:
            self.add_scan(label, tree({0x1000: 64}).replace("NSString", "PrivateCustomerClass"))
        self.write("scans.json", self.scans)
        value = self.collect()
        self.assertEqual(value["status"], "complete")
        self.assertEqual(value["strict_failure_labels"], list(evidence.LABELS))
        self.assertTrue(all(row["groups"][0]["root_type"] == "unknown" for row in value["original_scans"]))
        self.assertNotIn("PrivateCustomerClass", evidence.encoded(value).decode())

    def test_terminal_list_tree_use_one_hash_bound_later_snapshot(self):
        terminal, calls = self.terminal()
        self.assertEqual((terminal["status"], calls), ("complete", ["list", "tree"]))
        self.assertEqual([node["id"] for node in terminal["nodes"]], [0, 1])
        self.assertEqual(terminal["nodes"][1]["parent"], 0)
        self.assertEqual(terminal["back_edges"][0]["target"], 0)
        self.assertEqual((terminal["identity"], terminal["generation"]), ("snapshot-local", "unknown"))
        self.assertNotIn("0x", evidence.encoded(terminal).decode())

    def test_terminal_tree_mismatch_preserves_list_counts(self):
        terminal, _ = self.terminal(broken=tree({0x1000: 64}, cycle=True))
        self.assertEqual(terminal["status"], "partial")
        self.assertIn("tree_invalid", terminal["reasons"])
        self.assertEqual((terminal["leak_nodes"], terminal["omitted_nodes"]), (2, 2))
        self.assertEqual(terminal["nodes"], [])

    def test_terminal_root_leak_may_contain_a_descendant_cycle(self):
        public = self.collect()
        nodes = {0x1000: 64, 0x2000: 48, 0x3000: 32}
        report = ("Process 123: 3 leaks for 144 total leaked bytes.\n\n"
                  "STACK OF 1 INSTANCE OF 'ROOT LEAK: NSString':\nprivate stack\n====\n"
                  "    3 (144 bytes) ROOT LEAK: <NSString 0x1000> [64]\n"
                  "       2 (80 bytes) list --> <NSArray 0x2000> [48]\n"
                  "          1 (32 bytes) list --> <NSArray 0x3000> [32]\n"
                  "             CYCLE BACK TO <NSArray 0x2000> [48]\n\n"
                  "Binary Images:\nprivate images\n")
        terminal, calls = self.terminal(nodes=nodes, broken=report)
        self.assertEqual((terminal["status"], calls), ("complete", ["list", "tree"]))
        self.assertEqual(terminal["nodes"][0]["root_kind"], "leak")
        self.assertEqual(terminal["back_edges"], [{"source": 2, "target": 1, "label": "unlabeled"}])
        public["terminal"] = terminal
        evidence.validate_public(public)
        # A reference from the outer root into its descendant is not a back edge.
        invalid = copy.deepcopy(terminal)
        invalid["back_edges"][0].update(source=0, target=2)
        with self.assertRaises(ValueError): evidence.validate_terminal(invalid)

    def test_terminal_node_budget_avoids_second_tool(self):
        terminal, calls = self.terminal(nodes={0x1000 + n * 0x100: 64 for n in range(513)})
        self.assertEqual(calls, ["list"])
        self.assertEqual(terminal["omitted_nodes"], 513)
        self.assertIn("node_budget", terminal["reasons"])

    def test_terminal_unconfirmed_tool_exit_stops_followup(self):
        terminal, calls = self.terminal(exit_unconfirmed=True)
        self.assertEqual(calls, ["list"])
        self.assertFalse(terminal["process_cleanup_confirmed"])
        self.assertIn("process_exit_unconfirmed", terminal["reasons"])

    def test_failed_capture_preserves_six_scans_and_never_starts_worker(self):
        self.write("failure-capture.json", {"status": "failed", "exit_code": 255, "after_label": "observer-exited", "graph_sha256": None})
        with mock.patch.object(evidence, "run_owned") as run:
            value = self.collect(); run.assert_not_called()
        self.assertEqual(len(value["strict_growth_labels"]), 5)
        self.assertEqual(value["terminal"]["capture_exit_code"], 255)
        self.assertEqual(value["status"], "partial")

    def test_owned_worker_cleanup_controls_public_result(self):
        terminal, _ = self.terminal()
        def owned(command, log_path, environment, timeout):
            self.assertLessEqual(timeout, 32)
            (log_path.parent / "terminal.json").write_bytes(evidence.encoded(terminal))
            return {"status": "completed", "command_return_code": 0, "cleanup": {"complete": True}}
        with mock.patch.object(evidence, "run_owned", side_effect=owned): value = self.collect()
        self.assertEqual(value["status"], "complete")
        self.assertEqual(list(self.records.glob(".ax-ci-failure-*")), [])
        with mock.patch.object(evidence, "run_owned", return_value={"status": "timeout", "command_return_code": None, "cleanup": {"complete": False}}):
            value = self.collect()
        self.assertFalse(value["process_cleanup_confirmed"])
        self.assertEqual(value["original_verdict"], "failed")
        self.assertEqual(value["original_scans"][0]["status"], "complete")
        self.assertTrue(list(self.records.glob(".ax-ci-failure-*")))

    def test_graph_hash_change_rejects_terminal_before_tools(self):
        self.capture()
        (self.records / "terminal.memgraph").write_bytes(b"changed")
        private = self.root / "private"; private.mkdir()
        with mock.patch.object(evidence.frozen.Tools, "run") as run:
            value = evidence.terminal_snapshot(self.records, private, time.monotonic() + 30)
            run.assert_not_called()
        evidence.validate_terminal(value)
        self.assertIn("graph_changed", value["reasons"])

    def test_graph_and_edge_budgets_are_explicit(self):
        with mock.patch.object(evidence, "GRAPH_LIMIT", 1):
            terminal, calls = self.terminal()
        self.assertEqual(calls, [])
        self.assertIn("graph_budget", terminal["reasons"])
        # Each test owns a fresh tools directory; remove the unused first one.
        (self.root / "private/tools").rmdir()
        with mock.patch.object(evidence, "EDGE_LIMIT", 1):
            terminal, calls = self.terminal()
        self.assertEqual(calls, ["list", "tree"])
        self.assertEqual(terminal["omitted_edges"], 2)
        self.assertIn("edge_budget", terminal["reasons"])

    def test_worker_invalid_result_does_not_replace_original_evidence(self):
        self.capture()
        def owned(command, log_path, environment, timeout):
            (log_path.parent / "terminal.json").write_bytes(evidence.encoded({"raw": "private path"}))
            return {"status": "completed", "command_return_code": 0, "cleanup": {"complete": True}}
        with mock.patch.object(evidence, "run_owned", side_effect=owned): value = self.collect()
        self.assertEqual(value["status"], "partial")
        self.assertEqual(value["original_verdict"], "failed")
        self.assertEqual(value["strict_growth_labels"], list(evidence.LABELS[1:]))
        self.assertNotIn("private path", evidence.encoded(value).decode())
        self.assertEqual(list(self.records.glob(".ax-ci-failure-*")), [])

    def test_terminal_public_gate_rejects_cycles_unknown_fields_and_wrong_totals(self):
        terminal, _ = self.terminal()
        for mutate in (lambda v: v.update(leak_nodes=9), lambda v: v.update(address="0x1000"),
                       lambda v: v["nodes"][0].update(parent=1, root_kind=None),
                       lambda v: v["back_edges"][0].update(target=999),
                       lambda v: v["nodes"][0].update(type="PrivateName")):
            value = copy.deepcopy(terminal); mutate(value)
            with self.assertRaises(ValueError): evidence.validate_terminal(value)


if __name__ == "__main__":
    unittest.main()
