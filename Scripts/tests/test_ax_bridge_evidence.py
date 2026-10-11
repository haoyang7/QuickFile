"""Synthetic bridge evidence: no captured addresses, symbols or graphs."""
import copy
from collections import Counter
from pathlib import Path
import runpy
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

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
        selected = result["records"][0]["selected"]
        self.assertEqual({key: selected[key] for key in ("state", "type_bucket", "size", "tool_index")},
                         {"state": "other_allocation", "type_bucket": "unknown", "size": 96, "tool_index": 4})

    def test_anonymous_layout_replays_checked_pointer_arithmetic(self):
        report = layout().replace("synthetic", "private/path user@example secret_name")
        doc = bridge.layout_syntax(report, P, M, 64, 3, "a" * 64)
        bridge.validate_layout_syntax(doc, 3, "a" * 64)
        self.assertEqual(bridge.parse_layout(*bridge.decode_layout_syntax(doc))["state"], "original_target_address")
        import json
        encoded = json.dumps(doc)
        for secret in ("private", "path", "user@example", "secret_name", hex(P), hex(M), hex(NEW)):
            self.assertNotIn(secret, encoded)
        slots = [token for line in doc["lines"] for token in line if token[0] == "slot"]
        self.assertEqual(len(slots), 2)
        for broken in (report.replace(f"{P + 40:#x} -->", f"{P + 48:#x} -->"),
                       report.replace(f"+40: {NEW + 40:#x}", f"+40: {NEW + 48:#x}")):
            doc = bridge.layout_syntax(broken, P, M, 64, 3, "a" * 64)
            with self.assertRaises(ValueError):
                bridge.parse_layout(*bridge.decode_layout_syntax(doc))

    def test_layout_parser_error_codes_and_tool_failures(self):
        reports = ((layout(contents=False), "missing_contents"),
                   (layout().replace("CONTENTS:", "CONTENTS:\nunknown"), "unsupported_contents"),
                   (layout().replace(f"{P + 40:#x} -->", f"{P + 48:#x} -->"), "unbound_slot"))
        for report, error in reports:
            result, _ = self.collect(tools=FakeTools({("layout", "selected"): report}))
            selected = result["records"][0]["selected"]
            self.assertEqual(selected["parse_error"], error)
            self.assertEqual(selected["syntax"]["tool_index"], selected["tool_index"])
            self.assertEqual(selected["syntax"]["graph_sha256"], result["selected_graph_sha256"])
            self.assertEqual(result["status"], "partial")
        result, _ = self.collect(tools=FakeTools(fail=4))
        self.assertEqual(result["records"][0]["selected"]["parse_error"], "tool_unavailable")
        self.assertIsNone(result["records"][0]["selected"]["syntax"])

    def test_syntax_budget_is_explicit_and_preserves_original_evidence(self):
        # Whitespace is accepted by the parser, but exceeds the anonymous token budget.
        report = layout().replace("   +40:", " " * 2000 + "+40:")
        result, frozen = self.collect(tools=FakeTools({("layout", "selected"): report}))
        selected = result["records"][0]["selected"]
        self.assertEqual(selected["state"], "original_target_address")
        self.assertEqual(selected["parse_error"], "none")
        self.assertEqual(selected["syntax"]["status"], "truncated")
        self.assertEqual(result["status"], "partial")
        self.assertIn("syntax_truncated", result["reasons"])
        self.assertEqual(len(result["tools"]), 5)
        self.assertEqual(result["records"][0]["history"]["classification"], "same_generation")
        self.assertLessEqual(len(bridge.encode_summary(result, frozen)), bridge.PUBLIC_LIMIT)

    def test_syntax_validator_rejects_private_text_and_wrong_binding(self):
        result, frozen = self.collect()
        for mutation in (lambda d: d.update(tool_index=0), lambda d: d.update(graph_sha256="f" * 64),
                         lambda d: d.update(source=[3, 64]), lambda d: d.update(source=[1, 96]),
                         lambda d: d["lines"].append([["literal", "/private/path"]]),
                         lambda d: d["lines"].append([["address", P]])):
            bad = copy.deepcopy(result)
            mutation(bad["records"][0]["baseline"]["syntax"])
            with self.assertRaises(ValueError):
                bridge.validate_summary(bad, frozen)

    def test_anonymous_unknown_text_does_not_publish_numbers(self):
        doc = bridge.layout_syntax(layout() + "private/path[987654] +765432: account 654321\n", P, M, 64, 3, "a" * 64)
        bridge.validate_layout_syntax(doc, 3, "a" * 64)
        for line in doc["lines"]:
            for token in line:
                self.assertNotIn(token, (["number", 987654], ["number", 765432], ["number", 654321]))

    def test_anonymous_region_preserves_embedded_and_zero_addresses(self):
        incoming = f"   <synthetic {NEW:#x}> [64]    +40: {NEW + 40:#x}"
        for root in ("Region Stack 0x3000 0x4000", "Region Stack synthetic 0x0"):
            report = layout().replace(incoming, "   " + root)
            with self.assertRaises(ValueError) as original:
                bridge.parse_layout(report, P, M, 64)
            doc = bridge.layout_syntax(report, P, M, 64, 3, "a" * 64)
            bridge.validate_layout_syntax(doc, 3, "a" * 64)
            self.assertEqual(doc["status"], "complete")
            with self.assertRaises(ValueError) as replay:
                bridge.parse_layout(*bridge.decode_layout_syntax(doc))
            self.assertEqual(str(original.exception), str(replay.exception))
        # Zero is not forbidden by the existing heap-object incoming grammar.
        # Its verified +40 arithmetic must remain intact when preserving zero.
        report = layout().replace(incoming, "   <synthetic 0x0> [64]    +40: 0x28")
        doc = bridge.layout_syntax(report, P, M, 64, 3, "a" * 64)
        bridge.validate_layout_syntax(doc, 3, "a" * 64)
        self.assertEqual(bridge.parse_layout(report, P, M, 64), bridge.parse_layout(*bridge.decode_layout_syntax(doc)))

    def test_anonymous_unicode_rejection_conditions_survive(self):
        incoming = f"   <synthetic {NEW:#x}> [64]    +40: {NEW + 40:#x}"
        for char in ("\u200d", "\u2028", "\u2029", "\x85", "\u00a0", "\x0b", "\r"):
            for root in (f"Thread 1 worker{char}name $x25", f"Region Stack worker{char}name 0x4000"):
                with self.subTest(char=repr(char), kind=root.split()[0]):
                    report = layout().replace(incoming, "   " + root)
                    with self.assertRaises(ValueError) as original:
                        bridge.parse_layout(report, P, M, 64)
                    doc = bridge.layout_syntax(report, P, M, 64, 3, "a" * 64)
                    bridge.validate_layout_syntax(doc, 3, "a" * 64)
                    self.assertEqual(doc["status"], "complete")
                    with self.assertRaises(ValueError) as replay:
                        bridge.parse_layout(*bridge.decode_layout_syntax(doc))
                    self.assertEqual(str(original.exception), str(replay.exception))

    def test_anonymous_empty_thread_description_remains_rejected(self):
        report = layout().replace(f"   <synthetic {NEW:#x}> [64]    +40: {NEW + 40:#x}", "   Thread 1  $x25")
        with self.assertRaises(ValueError):
            bridge.parse_layout(report, P, M, 64)
        doc = bridge.layout_syntax(report, P, M, 64, 3, "a" * 64)
        bridge.validate_layout_syntax(doc, 3, "a" * 64)
        with self.assertRaises(ValueError):
            bridge.parse_layout(*bridge.decode_layout_syntax(doc))

    def test_region_angle_brackets_preserve_rejection(self):
        incoming = f"   <synthetic {NEW:#x}> [64]    +40: {NEW + 40:#x}"
        report = layout().replace(incoming, "   Region Stack <private_name> 0x4000")
        with self.assertRaises(ValueError) as original:
            bridge.parse_layout(report, P, M, 64)
        doc = bridge.layout_syntax(report, P, M, 64, 3, "a" * 64)
        bridge.validate_layout_syntax(doc, 3, "a" * 64)
        self.assertEqual(doc["status"], "complete")
        with self.assertRaises(ValueError) as replay:
            bridge.parse_layout(*bridge.decode_layout_syntax(doc))
        self.assertEqual(str(original.exception), str(replay.exception))

    def test_shortened_private_address_marks_syntax_unreplayable(self):
        incoming = f"   <synthetic {NEW:#x}> [64]    +40: {NEW + 40:#x}"
        root = "   Thread 1 " + "a" * 1010 + "0x123456789abcdef0 $x25"
        report = layout().replace(incoming, root)
        result, frozen = self.collect(tools=FakeTools({("layout", "selected"): report}))
        selected = result["records"][0]["selected"]
        self.assertEqual(selected["parse_error"], "unsupported_incoming_reference")
        self.assertEqual(selected["syntax"]["status"], "unreplayable")
        self.assertEqual(result["status"], "partial")
        self.assertIn("syntax_unreplayable", result["reasons"])
        self.assertEqual(len(result["tools"]), 5)
        self.assertEqual(result["records"][0]["history"]["classification"], "same_generation")
        self.assertLessEqual(len(bridge.encode_summary(result, frozen)), bridge.PUBLIC_LIMIT)

    def test_future_structural_distortion_is_detected(self):
        original_decode = bridge.decode_layout_syntax

        def distorted(doc):
            report, source, target, size = original_decode(doc)
            report = report.replace(f"{target:#x}> [48]", f"{target + 8:#x}> [96]")
            return report, source, target, size

        with patch.object(bridge, "decode_layout_syntax", side_effect=distorted):
            result, _ = self.collect()
        self.assertEqual(result["status"], "partial")
        self.assertIn("syntax_unreplayable", result["reasons"])
        for checkpoint in ("baseline", "selected"):
            evidence = result["records"][0][checkpoint]
            self.assertEqual(evidence["syntax"]["status"], "unreplayable")
            self.assertEqual(evidence["state"], "original_target_address")
            self.assertEqual(evidence["parse_error"], "none")
        # Only the explicitly anonymized type bucket is exempt from comparison.
        doc = bridge.layout_syntax(layout().replace("synthetic", "NSXPCConnection"), P, M, 64, 3, "a" * 64)
        self.assertEqual(doc["status"], "complete")

    def test_known_stack_metadata_is_bounded_and_not_reference_evidence(self):
        frame = "0x1234 (private-image) private_allocation_function"
        metadata = "\tCall stack: " + " | ".join([frame] * 100) + " \n"
        report = layout().replace("REFERENCES TO THIS:", metadata + "REFERENCES TO THIS:")
        result, frozen = self.collect(tools=FakeTools({("layout", "baseline"): report}))
        self.assertEqual(result["status"], "complete")
        evidence = result["records"][0]["baseline"]
        self.assertEqual(evidence["state"], "original_target_address")
        self.assertEqual(evidence["syntax"]["status"], "complete")
        self.assertIn([["stack_metadata", 0]], evidence["syntax"]["lines"])
        encoded = bridge.encode_summary(result, frozen)
        for secret in (b"private-image", b"private_allocation_function", b"0x1234"):
            self.assertNotIn(secret, encoded)
        self.assertEqual(bridge.parse_layout(*bridge.decode_layout_syntax(evidence["syntax"]))["state"], "original_target_address")

    def test_stack_metadata_position_count_and_grammar_are_strict(self):
        metadata = "\tCall stack: 0x1234 (private-image) private_function\n"
        reports = (layout().replace("CONTENTS:\n", "CONTENTS:\n" + metadata),
                   layout().replace("REFERENCES TO THIS: 1\n", "REFERENCES TO THIS: 2\n" + metadata),
                   layout().replace("REFERENCES TO THIS:", metadata * 2 + "REFERENCES TO THIS:"),
                   layout().replace("REFERENCES TO THIS:", "\tCall stack: unknown\nREFERENCES TO THIS:"),
                   layout().replace("REFERENCES TO THIS:", "unknown prefix\n" + metadata + "REFERENCES TO THIS:"),
                   layout().replace("REFERENCES TO THIS:", "\tCall stack: " + " | ".join(["0x1 (image) function"] * 257) + "\nREFERENCES TO THIS:"))
        for report in reports:
            with self.assertRaises(ValueError):
                bridge.parse_layout(report, P, M, 64)
        wrong_count = layout().replace("REFERENCES TO THIS: 1", metadata + "REFERENCES TO THIS: 2")
        with self.assertRaises(ValueError):
            bridge.parse_layout(wrong_count, P, M, 64)

    def test_stack_metadata_limit_counts_utf8_bytes(self):
        frame = "0x1 (image) " + "文" * 3500
        metadata = "\tCall stack: " + " | ".join([frame] * 6)
        metadata += " " * (65536 - len(metadata.encode("utf-8")))
        self.assertEqual(len(metadata.encode("utf-8")), 65536)
        self.assertLess(len(metadata), 65536)
        report = layout().replace("REFERENCES TO THIS:", metadata + "\nREFERENCES TO THIS:")
        result, _ = self.collect(tools=FakeTools({("layout", "baseline"): report}))
        self.assertEqual(result["status"], "complete")
        oversized = layout().replace("REFERENCES TO THIS:", metadata + " \nREFERENCES TO THIS:")
        with self.assertRaisesRegex(ValueError, "Incomplete incoming references"):
            bridge.parse_layout(oversized, P, M, 64)

    def test_thread_root_offset_is_bounded_by_scanned_source(self):
        incoming = f"   <synthetic {NEW:#x}> [64]    +40: {NEW + 40:#x}"
        for offset in (0, 40, 63):
            report = layout().replace(incoming, f"   Thread 1 private worker $x25 --> offset {offset}")
            self.assertEqual(bridge.parse_layout(report, P, M, 64)["state"], "original_target_address")
            doc = bridge.layout_syntax(report, P, M, 64, 3, "a" * 64)
            bridge.validate_layout_syntax(doc, 3, "a" * 64)
            self.assertEqual(doc["status"], "complete")
            self.assertEqual(bridge.parse_layout(*bridge.decode_layout_syntax(doc))["state"], "original_target_address")
        for offset in ("64", "1000000001", "-1", "0x10"):
            report = layout().replace(incoming, f"   Thread 1 private worker $x25 --> offset {offset}")
            with self.assertRaises(ValueError):
                bridge.parse_layout(report, P, M, 64)
        report = layout().replace(incoming, "   Thread 1 private worker $x25 --> offset 64")
        doc = bridge.layout_syntax(report, P, M, 64, 3, "a" * 64)
        self.assertEqual(doc["status"], "complete")
        with self.assertRaisesRegex(ValueError, "Unbound incoming reference"):
            bridge.parse_layout(*bridge.decode_layout_syntax(doc))

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

    def test_layout_thread_and_region_roots_are_only_incoming(self):
        incoming = ("   Thread 1  Synthetic worker (serial) $x10\n"
                    "   Thread 1  Synthetic worker (serial) $x25\n"
                    "   Region Stack thread 1 thread-specific-data key 22 0x4000\n")
        report = layout().replace("REFERENCES TO THIS: 1", "REFERENCES TO THIS: 3").replace(
            f"   <synthetic {NEW:#x}> [64]    +40: {NEW + 40:#x}\n", incoming)
        self.assertEqual(bridge.parse_layout(report, P, M, 64)["state"], "original_target_address")
        without_slot = report.replace(f"   +40: {P + 40:#x}", f"   +16: {P + 16:#x}")
        self.assertEqual(bridge.parse_layout(without_slot, P, M, 64),
                         {"state": "unreported", "type_bucket": None, "size": None})
        with self.assertRaises(ValueError):
            bridge.parse_layout(report.split("CONTENTS:")[0], P, M, 64)
        with self.assertRaises(ValueError):
            bridge.parse_layout(report.replace("CONTENTS:\n", "CONTENTS:\n" + incoming), P, M, 64)

    def test_layout_root_grammar_bounds(self):
        incoming = f"   <synthetic {NEW:#x}> [64]    +40: {NEW + 40:#x}"
        for root in ("Thread 0 worker $x0", "Thread 1000000000 worker $x30",
                     "Region Stack synthetic 0x4000 --> offset 16"):
            report = layout().replace(incoming, "   " + root)
            self.assertEqual(bridge.parse_layout(report, P, M, 64)["state"], "original_target_address")
        for root in ("Thread 1 worker $x31", "Thread 1 worker $rax", "Thread 1000000001 worker $x10",
                     "Thread 1 worker\t $x10", "Thread 1 worker\x01 $x10", "Thread 1  $x10",
                     "Thread 1 " + "w" * 1025 + " $x10", "Thread 1 worker $x10 extra",
                     "Region Stack synthetic", "Region Stack synthetic 0x4000junk",
                     "Region Stack synthetic 0x4000 extra", "Region Stack\tworker 0x4000",
                     "Region Stack worker\x01 0x4000", "Region Stack 0x3000 0x4000",
                     "Region Stack synthetic 0x4000 --> offset 1000000001", "Unknown root 0x4000"):
            with self.subTest(root=root), self.assertRaises(ValueError):
                bridge.parse_layout(layout().replace(incoming, "   " + root), P, M, 64)

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
