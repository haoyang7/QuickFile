import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

from test_ax_frozen_nodes import Case, NODES, listing


def prepare_live(case, mode="product"):
    scans = [{"label": label, "leak_nodes": len(case.points[label]),
              "leak_bytes": sum(case.points[label].values()), "exit_code": 1}
             for label in NODES.LIVE_LABELS]
    (case.records / "scans.json").write_text(json.dumps(scans))
    (case.records / "result.json").write_text(json.dumps({
        "mode": mode, "scan_mode": "live", "live_attribution": True, "coverage": "failed"}))
    for row in scans:
        (case.records / (row["label"] + "-live.stdout.txt")).write_text(listing(case.points[row["label"]]))
    selected = NODES.first_live_growth(scans)
    captures = [{"label": label, "status": "complete", "exit_code": 0,
                 "after_scan_ms": 3, "duration_ms": 20,
                 "stdout_sha256": hashlib.sha256((case.records / (label + "-live.stdout.txt")).read_bytes()).hexdigest(),
                 "graph_sha256": NODES.graph_hash(case.graphs / (label + ".memgraph"))}
                for label in (("baseline", selected) if selected else ("baseline",))]
    (case.records / "live-captures.json").write_text(json.dumps(captures))


def compare_live(case):
    with mock.patch.object(NODES.Tools, "run", autospec=True, side_effect=case.run):
        value = NODES.compare(case.graphs, case.records, live_pair=True)
    NODES.validate_summary(value)
    return value


class AXLiveAttributionTests(unittest.TestCase):
    def test_only_first_original_growth_is_selected_and_compact_identity_stays_unknown(self):
        for mode in ("heap-control", "product"):
            for label in NODES.LIVE_LABELS[1:]:
                with self.subTest(mode=mode, label=label), tempfile.TemporaryDirectory() as directory:
                    case = Case(Path(directory), {0x1000: 48}, {0x1000: 48, 0x2000: 80},
                                first=NODES.HEAP_LABELS.index(label))
                    prepare_live(case, mode)
                    value = compare_live(case)
                    self.assertEqual(value["schema"], 3)
                    self.assertEqual(value["selected_label"], label)
                    self.assertEqual(value["selection"], "live-pair")
                    self.assertEqual(value["status"], "partial")
                    self.assertEqual(value["nodes"][0]["baseline_presence"], "present")
                    self.assertEqual(value["nodes"][0]["history"]["classification"], "unknown")
                    self.assertIn("compact_history", value["reasons"])
                    self.assertEqual([point["label"] for point in value["checked_points"]], ["baseline", label])
                    self.assertEqual([point["label"] for point in value["live_scans"]], list(NODES.LIVE_LABELS))
                    self.assertNotIn("added-10", [call[1] for call in case.calls])
                    self.assertEqual(json.loads(NODES.encode_summary(value)), value)
                    self.assertNotIn("private", NODES.encode_summary(value).decode())

    def test_absent_baseline_allocation_can_be_new_but_retained_resized_address_cannot(self):
        for resized in (False, True):
            with self.subTest(resized=resized), tempfile.TemporaryDirectory() as directory:
                before = {0x1000: 48}
                after = {0x1000: 80} if resized else before | {0x2000: 80}
                case = Case(Path(directory), before, after, first=2)
                case.baseline_heap = before
                address = 0x1000 if resized else 0x2000
                case.heap_diff = {address: 80}
                case.before_events = [("ALLOC", 0x1000, 48)]
                case.after_events = case.before_events + ([("FREE", 0x1000, 48)] if resized else []) + [("ALLOC", address, 80)]
                prepare_live(case)
                value = compare_live(case)
                self.assertEqual(value["nodes"][0]["history"]["classification"], "unknown" if resized else "new_allocation")
                self.assertEqual(value["status"], "partial" if resized else "complete")

    def test_later_graph_mismatch_does_not_overwrite_original_counts_or_select_later_growth(self):
        for point in ("baseline", "registered-10"):
            with self.subTest(point=point), tempfile.TemporaryDirectory() as directory:
                case = Case(Path(directory), {0x1000: 48}, {0x1000: 48, 0x2000: 80}, first=2)
                prepare_live(case)
                original = (case.records / "scans.json").read_bytes()
                case.points[point] = {0x1000: 48, 0x3000: 32}
                case.baseline_heap[0x3000] = 32
                value = compare_live(case)
                self.assertEqual(value["status"], "partial")
                self.assertEqual(value["selected_label"], "registered-10")
                self.assertIn("live_snapshot_mismatch", value["reasons"])
                source = next(row for row in value["live_scans"] if row["label"] == point)
                self.assertEqual(source["leak_bytes"], 48 if point == "baseline" else 128)
                self.assertEqual((case.records / "scans.json").read_bytes(), original)

    def test_no_growth_captures_only_baseline_and_graph_disagreement_remains_partial(self):
        for mismatch in (False, True):
            with self.subTest(mismatch=mismatch), tempfile.TemporaryDirectory() as directory:
                case = Case(Path(directory), {0x1000: 48}, {0x1000: 48})
                prepare_live(case)
                if mismatch:
                    case.points["baseline"] = {}
                value = compare_live(case)
                self.assertEqual(value["selection"], "live-no-growth")
                self.assertEqual(value["status"], "partial" if mismatch else "complete")
                self.assertEqual([(kind, label) for kind, label, _ in case.calls], [("list", "baseline"), ("tree", "baseline")])
                with mock.patch.object(sys, "path", [str(Path(NODES.__file__).parent), *sys.path]):
                    import ax_bridge_evidence as bridge_module
                    bridge = bridge_module.collect(frozen=value, traces={}, baseline_heap=None,
                        before_graph=None, after_graph=None, tools=mock.Mock(summary={"tools": []}), reference_ids={})
                    bridge_module.validate_summary(bridge, value)
                self.assertEqual(bridge["status"], "partial" if mismatch else "not_needed")

    def test_auxiliary_disappearance_and_candidate_limit_are_explicit(self):
        for count in (0, 18):
            with self.subTest(count=count), tempfile.TemporaryDirectory() as directory:
                after = {0x2000 + index * 128: 48 for index in range(max(count, 1))}
                case = Case(Path(directory), {}, after, first=2)
                prepare_live(case)
                if not count:
                    case.points["registered-10"] = {}
                value = compare_live(case)
                self.assertEqual(value["status"], "partial")
                self.assertEqual(value["candidate_count"], count)
                self.assertEqual(value["omitted_candidates"], max(0, count - NODES.CANDIDATES))
                self.assertIn("candidate_limit" if count else "live_snapshot_mismatch", value["reasons"])

    def test_missing_tampered_or_unfinished_capture_never_launches_offline_tools(self):
        for failure in ("stdout", "totals", "graph", "capture", "timeout", "cleanup", "mode"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                case = Case(Path(directory), {}, {0x2000: 48}, first=2)
                prepare_live(case)
                if failure == "stdout":
                    (case.records / "baseline-live.stdout.txt").write_text("missing original totals")
                elif failure == "totals":
                    (case.records / "removed-30-live.stdout.txt").write_text(listing({}))
                elif failure == "graph":
                    (case.graphs / "baseline.memgraph").write_bytes(b"changed")
                elif failure in ("capture", "timeout"):
                    path = case.records / "live-captures.json"
                    rows = json.loads(path.read_text())
                    if failure == "capture":
                        rows[0]["stdout_sha256"] = "0" * 64
                    else:
                        rows[0].update(status="timeout", exit_code=None, graph_sha256=None)
                    path.write_text(json.dumps(rows))
                elif failure == "cleanup":
                    (case.records / "process-cleanup.json").write_text('{"processes_exited":false}')
                else:
                    (case.records / "result.json").write_text('{"mode":"product","scan_mode":"diagnostic"}')
                value = compare_live(case)
                self.assertEqual(value["status"], "unavailable")
                self.assertEqual(case.calls, [])

    def test_public_schema_rejects_unbound_hashes_private_fields_and_generation_overclaim(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory), {}, {0x2000: 48}, first=2)
            prepare_live(case)
            value = compare_live(case)
        for mutate in (
            lambda v: v["live_captures"][0].update(graph_sha256="0" * 64),
            lambda v: v["live_captures"][0].update(stdout_sha256="0" * 64),
            lambda v: v["live_captures"][0].update(after_scan_ms=-1),
            lambda v: v["live_scans"][1].update(label="removed-30"),
            lambda v: v["live_scans"][0].update(private="secret"),
            lambda v: v["nodes"][0]["history"].update(classification="preexisting"),
            lambda v: v["nodes"][0]["history"].update(classification="new_allocation"),
        ):
            changed = copy.deepcopy(value)
            mutate(changed)
            with self.assertRaises(ValueError):
                NODES.validate_summary(changed)


if __name__ == "__main__":
    unittest.main()
