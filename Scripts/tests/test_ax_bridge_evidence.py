"""Synthetic bridge evidence: no captured addresses, symbols or graphs."""
import copy
from collections import Counter
from pathlib import Path
import runpy
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Investigations"))
import ax_bridge_evidence as bridge
from ax_frozen_nodes import EvidenceError, ExitUnconfirmed

P, M, NEW = 0x1000, 0x2000, 0x3000


def layout(target=M, size=48, contents=True):
    return (f"\nSCANNING <synthetic {P:#x}> [64]\nREFERENCES TO THIS: 1\n"
            f"   <synthetic {NEW:#x}> [64]    +40: {NEW + 40:#x}\n" +
            (f"CONTENTS:\n   +40: {P + 40:#x} --> <synthetic {target:#x}> [{size}]\n" if contents else ""))


def history(extra=""):
    return f"malloc_history Report Version:  2.0\nALLOC {P:#x}-{P + 63:#x} [size=64]: synthetic\n" + extra


def frozen_fixture(count=30):
    return {"status": "complete", "selection": "first-strict-growth", "baseline": {"graph_sha256": "a" * 64},
            "selected": {"graph_sha256": "b" * 64}, "tools": [{}] * count, "omitted_candidates": 0,
            "nodes": [{"baseline_presence": "present"}],
            "references": {"nodes": [{"id": 0, "checkpoint": "baseline", "size": 64},
                                       {"id": 1, "checkpoint": "baseline", "size": 48}],
                           "edges": [{"checkpoint": "baseline", "source": 0, "target": 1, "relation": "reverse_reference"}],
                           "views": [{"candidate": 0, "checkpoint": "baseline", "kind": "trace", "status": "complete", "nodes": [0, 1], "edges": [0]},
                                     {"candidate": 0, "checkpoint": "selected", "kind": "tree", "status": "complete", "nodes": [1], "edges": []}]}}


class FakeTools:
    def __init__(self, reports=None, fail=None, cleanup=True):
        self.summary = {"tools": [], "process_cleanup_confirmed": True}
        self.reports = reports or {}
        self.fail, self.cleanup = fail, cleanup

    def run(self, kind, label, argv, allowed=(0,)):
        index = len(self.summary["tools"])
        row = {"tool": kind, "label": label, "status": "complete", "return_code": 0, "cleanup_confirmed": True}
        self.summary["tools"].append(row)
        if index == self.fail:
            row.update(status="timeout", return_code=None, cleanup_confirmed=self.cleanup)
            self.summary["process_cleanup_confirmed"] = self.cleanup
            if not self.cleanup:
                raise ExitUnconfirmed()
            raise EvidenceError("tool_failed")
        defaults = {"heap": f"All zones: 1 nodes malloced\n{P:#x}: synthetic (64 bytes)\n", "history": history(), "layout": layout()}
        return self.reports.get((kind, label), defaults[kind])


class BridgeTests(unittest.TestCase):
    def test_script_module_instance_uses_shared_tool_failures(self):
        script = Path(__file__).resolve().parents[1] / 'Investigations/ax_frozen_nodes.py'
        entry = runpy.run_path(str(script), run_name='ax_script_entry_fixture')
        self.assertIs(entry['EvidenceError'], EvidenceError)
        self.assertIs(entry['ExitUnconfirmed'], ExitUnconfirmed)
        with tempfile.TemporaryDirectory() as directory:
            tools = entry['Tools'](Path(directory) / 'private', {'tools': [], 'process_cleanup_confirmed': True}, time.monotonic() - 1)
            result, _ = self.collect(tools=tools)
            self.assertEqual(result['status'], 'partial')
            self.assertIn('deadline', result['reasons'])
            self.assertEqual(result['tools'], [])

    def collect(self, frozen=None, tools=None, traces=None):
        frozen = frozen or frozen_fixture()
        tools = tools or FakeTools()
        if traces is None:
            traces = {0: {"members": {P: {"size": 64}, M: {"size": 48}}, "slots": [{"source": P, "target": M, "offset": 40}]}}
        result = bridge.collect(frozen=frozen, tools=tools, traces=traces, baseline_heap={P: 64, M: 48},
                                before_graph="baseline.memgraph", after_graph="selected.memgraph", reference_ids={P: 0, M: 1})
        bridge.validate_summary(result, frozen)
        return result, frozen

    def test_original_target_and_same_generation(self):
        result, frozen = self.collect()
        self.assertEqual(result["status"], "complete")
        self.assertEqual(result["records"][0]["history"]["classification"], "same_generation")
        self.assertEqual(result["records"][0]["selected"]["state"], "original_target_address")
        self.assertEqual(len(result["tools"]), 5)
        encoded = bridge.encode_summary(result, frozen)
        self.assertLess(len(encoded), bridge.PUBLIC_LIMIT)
        for raw in (b"0x1000", b"synthetic", b"memgraph"):
            self.assertNotIn(raw, encoded)

    def test_new_target_is_only_bucketed(self):
        result, _ = self.collect(tools=FakeTools({("layout", "selected"): layout(NEW, 96)}))
        self.assertEqual(result["records"][0]["selected"], {"state": "other_allocation", "type_bucket": "unknown", "size": 96, "tool_index": 4})

    def test_conflicting_baseline_slot_cannot_be_complete(self):
        result, frozen = self.collect(tools=FakeTools({('layout', 'baseline'): layout(NEW, 96)}))
        self.assertEqual(result['status'], 'partial')
        self.assertIn('layout_conflict', result['reasons'])
        self.assertEqual(result['records'][0]['baseline']['state'], 'other_allocation')
        result.update(status='complete', reasons=[])
        with self.assertRaises(ValueError):
            bridge.validate_summary(result, frozen)

    def test_missing_contents_is_unknown(self):
        result, _ = self.collect(tools=FakeTools({("layout", "selected"): layout(contents=False)}))
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["records"][0]["selected"]["state"], "unavailable")

    def test_missing_slot_is_not_zero(self):
        report = layout().replace(f"   +40: {P + 40:#x}", f"   +16: {P + 16:#x}")
        result, _ = self.collect(tools=FakeTools({("layout", "selected"): report}))
        self.assertEqual(result["records"][0]["selected"]["state"], "unreported")
        self.assertIn("slot_unreported", result["reasons"])

    def test_incoming_not_outgoing_and_slot_binding(self):
        with self.assertRaises(ValueError):
            bridge.parse_layout(layout(contents=False), P, M, 64)
        with self.assertRaises(ValueError):
            bridge.parse_layout(layout().replace(f"{P + 40:#x} -->", f"{P + 48:#x} -->"), P, M, 64)
        with self.assertRaises(ValueError):
            bridge.parse_layout(layout().replace("CONTENTS:", "CONTENTS:\nunsupported"), P, M, 64)

    def test_reused_and_freed(self):
        free = f"FREE {P:#x}-{P + 63:#x} [size=64]: synthetic\n"
        alloc = f"ALLOC {P:#x}-{P + 63:#x} [size=64]: synthetic\n"
        result, _ = self.collect(tools=FakeTools({("history", "selected"): history(free + alloc)}))
        self.assertEqual(result["records"][0]["history"]["classification"], "reused")
        result, _ = self.collect(tools=FakeTools({("history", "selected"): history(free), ("heap", "selected"): "All zones: 0 nodes malloced\n"}))
        self.assertEqual(result["records"][0]["history"]["classification"], "freed")
        self.assertEqual(result["records"][0]["selected"]["state"], "not_present")
        self.assertIsNone(result["records"][0]["selected"]["tool_index"])
        self.assertEqual(result["status"], "complete")
        self.assertEqual(len(result["tools"]), 4)

    def test_inventory_absence_is_separate_from_history(self):
        result, frozen = self.collect(tools=FakeTools({("heap", "selected"): "All zones: 0 nodes malloced\n"}))
        self.assertEqual(result["records"][0]["selected"]["state"], "not_present")
        self.assertEqual(result["records"][0]["history"]["classification"], "unknown")
        self.assertEqual(result["status"], "partial")
        result["reasons"].append("heap_unavailable")
        with self.assertRaises(ValueError):
            bridge.validate_summary(result, frozen)
        result, _ = self.collect(tools=FakeTools({("heap", "selected"): "broken\n"}))
        self.assertEqual(result["records"][0]["selected"]["state"], "unavailable")

    def test_history_live_balance_contradictions(self):
        live = Counter({("ALLOC", 64): 1})
        dead = Counter({("ALLOC", 64): 1, ("FREE", 64): 1})
        for before, after, before_size, after_size in (
                (dead, dead, 64, 64), (live, dead, 64, 64),
                (live, live, 64, None), (live, live, 48, 64),
                (live, Counter({("ALLOC", 64): 2, ("FREE", 96): 1}), 64, 64)):
            self.assertEqual(bridge.history_evidence(before, after, before_size, after_size)["classification"], "unknown")
        free = f"FREE {P:#x}-{P + 63:#x} [size=64]: synthetic\n"
        result, _ = self.collect(tools=FakeTools({("history", "baseline"): history(free), ("history", "selected"): history(free)}))
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["records"][0]["history"]["classification"], "unknown")
        good, frozen = self.collect()
        good["records"][0]["history"].update(before_frees=1, after_frees=1)
        with self.assertRaises(ValueError):
            bridge.validate_summary(good, frozen)

    def test_layout_rejects_unknown_prefix_and_duplicate_header(self):
        for prefix in ("WARNING: unsupported\n", "REFERENCES TO THIS: 0\n", f"SCANNING <synthetic {P:#x}> [64]\n"):
            with self.assertRaises(ValueError):
                bridge.parse_layout(layout().replace("CONTENTS:", prefix + "CONTENTS:"), P, M, 64)
        with self.assertRaises(ValueError):
            bridge.parse_layout(layout().replace("REFERENCES TO THIS: 1", "REFERENCES TO THIS: 2"), P, M, 64)
        labelled = layout().replace(f"+40: {NEW + 40:#x}", f"+40: [capture] {NEW + 40:#x}")
        self.assertEqual(bridge.parse_layout(labelled, P, M, 64)["state"], "original_target_address")

    def test_missing_history_and_heap_cannot_confirm(self):
        for reports in ({("history", "selected"): "malloc_history Report Version:  2.0\nno stack logs found for 0x1000\n"},
                        {("heap", "selected"): "broken\n"}, {("history", "baseline"): "broken\n"}):
            result, _ = self.collect(tools=FakeTools(reports))
            self.assertEqual(result["records"][0]["history"]["classification"], "unknown")
            self.assertEqual(result["status"], "partial")

    def test_budget_before_any_additional_call(self):
        result, _ = self.collect(frozen=frozen_fixture(41))
        self.assertEqual(result["tools"], [])
        self.assertIn("tool_budget", result["reasons"])
        result, _ = self.collect(frozen=frozen_fixture(40))
        self.assertEqual(len(result["tools"]), 5)

    def test_failure_and_unconfirmed_cleanup(self):
        result, _ = self.collect(tools=FakeTools(fail=0))
        self.assertEqual(result["status"], "partial")
        self.assertEqual(len(result["tools"]), 5)
        result, _ = self.collect(tools=FakeTools(fail=0, cleanup=False))
        self.assertEqual(len(result["tools"]), 1)
        self.assertFalse(result["process_cleanup_confirmed"])
        self.assertIn("process_exit_unconfirmed", result["reasons"])

    def test_missing_trace_and_no_growth(self):
        result, _ = self.collect(traces={})
        self.assertEqual(result["status"], "partial")
        frozen = frozen_fixture()
        frozen.update(selection="no-strict-growth", selected=None)
        result, _ = self.collect(frozen=frozen)
        self.assertEqual(result["status"], "not_needed")
        frozen["status"] = "partial"
        result, _ = self.collect(frozen=frozen)
        self.assertIn("not_ready", result["reasons"])

    def test_privacy_and_lineage_validator(self):
        good, frozen = self.collect()
        changes = [lambda r: r.update(raw_address="0x1000"),
                   lambda r: r["records"][0]["selected"].update(type_bucket="private symbol"),
                   lambda r: r["records"][0].update(source_reference_id=P),
                   lambda r: r["records"][0]["selected"].update(tool_index=0),
                   lambda r: r.update(frozen_sha256="f" * 64),
                   lambda r: r["tools"][4].update(status="timeout"),
                   lambda r: r["records"][0].update(candidate_indices=[1])]
        for change in changes:
            bad = copy.deepcopy(good)
            change(bad)
            with self.assertRaises(ValueError):
                bridge.validate_summary(bad, frozen)
        changed_frozen = copy.deepcopy(frozen)
        changed_frozen["references"]["edges"][0]["source"] = 1
        bad = copy.deepcopy(good)
        bad["frozen_sha256"] = bridge.initial_summary(changed_frozen)["frozen_sha256"]
        with self.assertRaises(ValueError):
            bridge.validate_summary(bad, changed_frozen)

    def test_no_matching_structure_is_not_needed(self):
        result, _ = self.collect(traces={0: {"members": {}, "slots": []}})
        self.assertEqual(result["status"], "not_needed")
        self.assertEqual(result["tools"], [])

    def test_multiple_sources_and_ambiguous_target(self):
        def run(sources, ambiguous=False):
            frozen = frozen_fixture()
            refs = frozen["references"]
            refs["nodes"] = []
            refs["edges"] = []
            members, slots, ids = {}, [], {}
            inventory = {}
            for index in range(sources):
                source, target = P + index * 0x100, M + index * 0x100
                if ambiguous:
                    source = P
                ids.setdefault(source, len(ids))
                ids.setdefault(target, len(ids))
                inventory[source], inventory[target] = 64, 48
                members[source], members[target] = {"size": 64}, {"size": 48}
                slots.append({"source": source, "target": target, "offset": 40})
                for address, size in ((source, 64), (target, 48)):
                    node = {"id": ids[address], "checkpoint": "baseline", "size": size}
                    if node not in refs["nodes"]:
                        refs["nodes"].append(node)
                refs["edges"].append({"checkpoint": "baseline", "source": ids[source], "target": ids[target], "relation": "reverse_reference"})
            refs["views"][0].update(nodes=list(ids.values()), edges=list(range(sources)))
            refs["views"][1]["nodes"] = [ids[slot["target"]] for slot in slots]
            result = bridge.collect(frozen=frozen, traces={0: {"members": members, "slots": slots}},
                                    baseline_heap=inventory, before_graph="baseline.memgraph", after_graph="selected.memgraph",
                                    tools=FakeTools({("heap", "selected"): f"All zones: {len(inventory)} nodes malloced\n" +
                                                     "".join(f"{address:#x}: synthetic ({size} bytes)\n" for address, size in inventory.items())}), reference_ids=ids)
            bridge.validate_summary(result, frozen)
            return result
        result = run(3)
        self.assertEqual(len(result["records"]), 2)
        self.assertEqual(len(result["tools"]), 7)
        self.assertEqual(result["omitted_sources"], 1)
        self.assertIn("candidate_limit", result["reasons"])
        result = run(2, ambiguous=True)
        self.assertEqual(result["records"], [])
        self.assertEqual(result["omitted_sources"], 1)
        self.assertIn("ambiguous_bridge", result["reasons"])

    def test_upstream_shape_does_not_consume_source_budget(self):
        frozen = frozen_fixture()
        refs = frozen["references"]
        members = {P: {"size": 64}, M: {"size": 48}}
        slots = [{"source": P, "target": M, "offset": 40}]
        ids = {P: 0, M: 1}
        for index in range(3):
            source, target = 0x100 + index * 0x100, 0x4000 + index * 0x100
            source_id, target_id = 2 + index * 2, 3 + index * 2
            ids.update({source: source_id, target: target_id})
            members.update({source: {"size": 64}, target: {"size": 48}})
            slots.append({"source": source, "target": target, "offset": 40})
            refs["nodes"].extend([{"id": source_id, "checkpoint": "baseline", "size": 64},
                                  {"id": target_id, "checkpoint": "baseline", "size": 48}])
            refs["edges"].append({"checkpoint": "baseline", "source": source_id, "target": target_id, "relation": "reverse_reference"})
            refs["views"][0]["nodes"].extend([source_id, target_id])
            refs["views"][0]["edges"].append(len(refs["edges"]) - 1)
        result = bridge.collect(frozen=frozen, traces={0: {"members": members, "slots": slots}},
                                baseline_heap={address: member["size"] for address, member in members.items()},
                                before_graph="baseline.memgraph", after_graph="selected.memgraph",
                                tools=FakeTools(), reference_ids=ids)
        bridge.validate_summary(result, frozen)
        self.assertEqual(result["status"], "complete")
        self.assertEqual(len(result["records"]), 1)
        self.assertEqual(result["records"][0]["source_reference_id"], 0)
        self.assertEqual(result["omitted_sources"], 0)
        self.assertEqual(len(result["tools"]), 5)
        result["records"][0].update(source_reference_id=2, target_reference_id=3)
        with self.assertRaises(ValueError):
            bridge.validate_summary(result, frozen)

    def test_graph_changed_fail_closed(self):
        result, frozen = self.collect()
        bridge.fail_closed(result, "graph_changed")
        bridge.validate_summary(result, frozen)
        self.assertEqual(result["status"], "partial")


if __name__ == "__main__":
    unittest.main()
