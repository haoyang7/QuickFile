import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "Investigations/ax_frozen_nodes.py"
SPEC = importlib.util.spec_from_file_location("ax_frozen_nodes_tested", SOURCE)
NODES = importlib.util.module_from_spec(SPEC)
with mock.patch.object(sys, "path", [str(SOURCE.parent), *sys.path]):
    SPEC.loader.exec_module(NODES)


def totals(nodes):
    return f"Process 123: {len(nodes)} leaks for {sum(nodes.values())} total leaked bytes.\n"


def listing(nodes, kind="NSString"):
    return totals(nodes) + "\n" + "\n".join(
        f"Leak: {address:#x}  size={size}  zone: private-zone  {kind}  ObjC  private-image\n"
        "\tCall stack: private stack never published\n" for address, size in nodes.items())


def tree(nodes, cycle=False):
    result = totals(nodes)
    if cycle and nodes:
        items = list(nodes.items())
        result += "\nSTACK OF 1 INSTANCE OF 'ROOT CYCLE: NSString':\n0 private stack\n====\n"
        for index, (address, size) in enumerate(items):
            result += f"{' ' * (4 + index * 3)}{len(items) - index} (bytes) ROOT CYCLE: <NSString {address:#x}> [{size}]\n"
        address, size = items[0]
        result += f"{' ' * (4 + len(items) * 3)}CYCLE BACK TO <NSString {address:#x}> [{size}]\n"
    else:
        for address, size in nodes.items():
            result += f"\nSTACK OF 1 INSTANCE OF 'ROOT LEAK: NSString':\n0 private stack\n====\n    1 ({size} bytes) ROOT LEAK: <NSString {address:#x}> [{size}]\n"
    return result + "\nBinary Images:\nprivate images\n"


def heap(nodes):
    return f"All zones: {len(nodes)} nodes malloced\n" + "".join(
        f"{address:#x}: private-type ({size} bytes)\n" for address, size in nodes.items())


def history(events):
    return "malloc_history Report Version:  2.0\n" + "".join(
        f"{kind} {address:#x}-{address + size - 1:#x} [size={size}]: private stack\n" for kind, address, size in events)


def trace(address, size, roots):
    text = (f"Tracing: <private-type {address:#x}> [{size}]\n\nFound {roots} roots referencing: <private-type {address:#x}> [{size}]\n\n"
            "This is a reverse reference tree showing how the specified block is referenced.\n"
            "The top node is the specified block, the next level down are blocks that reference that, and so on.\n"
            "The number at the start of each line is the number of paths-to-roots going through that node.\n"
            "This reverse reference tree can be imported into Instruments using Import Sample Data to allow data mining.\n\n")
    if roots:
        text += f"    {roots} <private-type {address:#x}> [{size}]\n"
        text += "".join(f"      1 Region Stack thread {index} private {0x90000 + index * 16:#x}\n" for index in range(roots))
    return text


class Case:
    def __init__(self, root, before=None, after=None, first=1):
        self.graphs, self.records = root / "graphs", root / "records"
        self.graphs.mkdir(); self.records.mkdir()
        before = before or {}
        after = {0x2000: 48} if after is None else after
        self.points = {label: dict(before if index < first else after) for index, label in enumerate(NODES.HEAP_LABELS)}
        self.baseline_heap = {**after, **before}
        self.heap_diff = {}
        self.before_events = [("ALLOC", address, size) for address, size in self.baseline_heap.items()]
        self.after_events = list(self.before_events)
        self.calls = []
        self.failures = {}
        for label in NODES.HEAP_LABELS:
            (self.graphs / (label + ".memgraph")).write_bytes(("private graph " + label).encode())
            # A deliberately empty diff must not hide old allocations newly leaked.
            (self.graphs / (label + "-diff.txt")).write_text(listing({}))
        self.write_scans()
        (self.records / "process-cleanup.json").write_text(json.dumps({"processes_exited": True}))
        (self.records / "result.json").write_text(json.dumps({"mode": "heap-control", "scan_mode": "diagnostic", "coverage": "failed",
            "validation_errors": [{"stage": "added-10", "message": "private strict failure"}]}))

    def write_scans(self):
        (self.records / "scans.json").write_text(json.dumps([
            {"label": label, "leak_nodes": len(nodes), "leak_bytes": sum(nodes.values()), "exit_code": int(bool(nodes))}
            for label, nodes in self.points.items()]))

    def run(self, owner, kind, label, command, allowed=(0,)):
        self.calls.append((kind, label, command))
        owner.summary["tools"].append({"tool": kind, "label": label, "status": "complete", "return_code": 0, "cleanup_confirmed": True})
        failure = self.failures.get((kind, label))
        if isinstance(failure, Exception):
            if isinstance(failure, NODES.ExitUnconfirmed):
                owner.summary["tools"][-1].update(status="timeout", return_code=None, cleanup_confirmed=False)
                owner.summary["process_cleanup_confirmed"] = False
            raise failure
        if failure is not None:
            return failure
        if kind == "list":
            return listing(self.points[label])
        if kind == "tree":
            return tree(self.points[label], cycle=True)
        if kind == "heap":
            return heap(self.baseline_heap)
        if kind == "heap_diff":
            return heap(self.heap_diff)
        if kind == "history":
            return history(self.before_events if label == "baseline" else self.after_events)
        if kind == "trace":
            address = int(command[-2].split("=")[1], 16)
            size = self.baseline_heap[address] if label == "baseline" else self.points[label][address]
            return trace(address, size, 2 if label == "baseline" else 0)
        raise AssertionError("Unexpected tool")

    def compare(self, first_strict_growth=False):
        with mock.patch.object(NODES.Tools, "run", autospec=True, side_effect=self.run):
            result = NODES.compare(self.graphs, self.records, first_strict_growth=first_strict_growth)
        NODES.validate_summary(result)
        return result


class FrozenParserTests(unittest.TestCase):
    def test_absolute_list_requires_complete_unique_counts_and_bytes(self):
        nodes = {0x1000: 48, 0x2000: 80}
        self.assertEqual(NODES.parse_list(listing(nodes))[0], nodes)
        self.assertEqual(NODES.parse_list(listing({})), ({}, {}))
        for text in (listing(nodes).replace("size=80", "size=81"), listing(nodes).replace("0x2000", "0x1000"),
                     listing(nodes).replace("Leak: 0x2000", "Leak: broken"), listing(nodes) + totals(nodes),
                     listing(nodes).replace("2 leaks", "1 leak")):
            with self.subTest(text=text), self.assertRaises(ValueError):
                NODES.parse_list(text)
        self.assertEqual(set(NODES.parse_list(listing(nodes, "private user class"))[1].values()), {"unknown"})

    def test_default_cycle_membership_counts_one_top_root_and_back_edge(self):
        nodes = {0x1000: 384, 0x2000: 512, 0x3000: 256}
        mapping = NODES.parse_tree(tree(nodes, True), nodes)
        self.assertEqual(set(mapping), set(nodes))
        self.assertEqual(len({id(value) for value in mapping.values()}), 1)
        self.assertEqual(mapping[0x3000], {"status": "mapped", "root_kind": "cycle", "root_type": "NSString",
                                        "nodes": 3, "bytes": 1152, "cycle_back_edges": 1})
        wrapped = tree(nodes, True).replace("OF 'ROOT CYCLE: NSString'", "OF 'ROOT CYCLE: <NSString>'")
        self.assertEqual(NODES.parse_tree(wrapped, nodes), mapping)
        independent = NODES.parse_tree(tree(nodes), nodes)
        self.assertEqual(len({id(value) for value in independent.values()}), 3)
        self.assertTrue(all(value["nodes"] == 1 for value in independent.values()))

    def test_tree_rejects_duplicate_missing_unbound_back_edges_and_wrong_counts(self):
        nodes = {0x1000: 48, 0x2000: 80}
        text = tree(nodes, True)
        for changed in (text.replace("1 INSTANCE", "2 INSTANCES"), text.replace("2 (bytes)", "3 (bytes)"),
                        text.replace("0x2000", "0x1000"), text.replace("0x2000> [80]", "0x2000> [81]"),
                        text.replace("CYCLE BACK TO <NSString 0x1000>", "CYCLE BACK TO <NSString 0x9999>"),
                        text.replace("====", "???"), text.replace("ROOT CYCLE: <NSString 0x1000>", "ROOT LEAK: <NSString 0x1000>"),
                        text.replace("CYCLE BACK TO", "UNSUPPORTED REFERENCE"), text.replace("[80]\n", "[80]\nextra row\n")):
            with self.subTest(text=changed), self.assertRaises(ValueError):
                NODES.parse_tree(changed, nodes)
        with self.assertRaises(ValueError):
            NODES.parse_tree(tree({}), nodes)

    @staticmethod
    def aggregate_tree(separators=True):
        # Self-authored shape observed in multi-instance allocation-stack groups.
        nodes = {0x1000: 48, 0x2000: 80, 0x3000: 64, 0x4000: 32}
        separator = "      ----\n" if separators else "\n"
        text = totals(nodes) + "\nSTACK OF 2 INSTANCES OF 'ROOT CYCLE: <NSString>':\nprivate stack\n====\n"
        text += "    3 (0.19K) << TOTAL >>\n" + separator
        text += ("      2 (128 bytes) ROOT CYCLE: <NSString 0x1000> [48]\n"
                 "         1 (80 bytes) list --> <NSArray 0x2000> [80]\n"
                 "            CYCLE BACK TO <NSString 0x1000> [48]\n")
        text += separator + "      1 (64 bytes) ROOT CYCLE: <NSString 0x3000> [64]\n"
        text += ("\nSTACK OF 1 INSTANCE OF 'ROOT LEAK: NSString':\nprivate stack\n====\n"
                 "    1 (32 bytes) ROOT LEAK: <NSString 0x4000> [32]\n")
        return nodes, text

    def test_grouped_aggregate_preserves_each_root_and_membership(self):
        for separators in (False, True):
            nodes, text = self.aggregate_tree(separators)
            graph = NODES.parse_tree_graph(text, nodes)
            self.assertEqual(set(graph["members"]), set(nodes))
            self.assertEqual([root["summary"]["nodes"] for root in graph["roots"]], [2, 1, 1])
            self.assertEqual([root["summary"]["bytes"] for root in graph["roots"]], [128, 64, 32])
            self.assertEqual(graph["members"][0x2000]["parent"], 0x1000)
            self.assertEqual(graph["back_edges"], [{"source": 0x2000, "target": 0x1000, "label": "unlabeled", "root": 0}])

    def test_grouped_aggregate_rejects_counts_bad_separators_and_unknown_rows(self):
        nodes, text = self.aggregate_tree()
        for changed in (
            text.replace("3 (0.19K)", "4 (0.19K)"),
            text.replace("3 (0.19K)", "2 (0.19K)"),
            text.replace("2 INSTANCES", "3 INSTANCES"),
            text.replace("2 (128 bytes)", "1 (128 bytes)"),
            text.replace("      ----\n", "", 1),
            text.replace("      ----\n", "         ----\n", 1),
            text.replace("      ----\n", "      ----\n      ----\n", 1),
            text.replace("      ----\n", "      unknown separator\n", 1),
            text.replace("    1 (32 bytes)", "      ----\n    1 (32 bytes)"),
            text.replace("      1 (64 bytes)", "    3 (0.19K) << TOTAL >>\n      1 (64 bytes)"),
            text.replace("<NSString 0x3000> [64]", "<NSString 0x1000> [48]"),
            text.replace("CYCLE BACK TO <NSString 0x1000>", "CYCLE BACK TO <NSString 0x3000>"),
            text.replace("ROOT CYCLE: <NSString 0x3000>", "list --> ROOT CYCLE: <NSString 0x3000>"),
        ):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                NODES.parse_tree_graph(changed, nodes)

    def test_trace_accepts_exact_three_or_four_line_preamble_including_zero_roots(self):
        fourth = "This reverse reference tree can be imported into Instruments using Import Sample Data to allow data mining.\n"
        for roots in (0, 2):
            text = trace(0x1000, 48, roots)
            old = NODES.parse_trace_graph(text, 0x1000, 48)
            current = NODES.parse_trace_graph(text.replace(fourth, ""), 0x1000, 48)
            self.assertEqual(current, old)
            self.assertEqual(current["roots"], roots)
            self.assertEqual(current["target"], 0x1000)

    def test_trace_short_preamble_rejects_missing_duplicate_unknown_and_invalid_tree(self):
        fourth = "This reverse reference tree can be imported into Instruments using Import Sample Data to allow data mining.\n"
        text = trace(0x1000, 48, 2).replace(fourth, "")
        third = "The number at the start of each line is the number of paths-to-roots going through that node.\n"
        for changed in (
            text.replace(third, ""), text.replace(third, third * 2),
            text.replace(third, third + "unknown instruction\n"),
            text.replace(third, fourth + third), text.replace(third, third + fourth * 2),
            text.replace("    2 <", "    3 <"),
            text.replace("Found 2 roots", "Found 0 roots"),
            trace(0x1000, 48, 0).replace(fourth, "") + "    1 <private-type 0x1000> [48]\n",
            text.replace("[48]", "[64]"),
        ):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                NODES.parse_trace_graph(changed, 0x1000, 48)

    def test_trace_uses_tool_root_count_not_intermediate_region_rows(self):
        text = trace(0x1000, 48, 2) + "  1 Region private\n  1 Region private\n  1 Region Kernel Alloc Once private\n"
        self.assertEqual(NODES.trace_roots(text, 0x1000, 48), 2)
        self.assertEqual(NODES.trace_roots(trace(0x1000, 48, 0), 0x1000, 48), 0)
        for changed in (text.replace("0x1000", "0x2000"), text.replace("[48]", "[80]"), text + "Found 2 roots referencing: <private-type 0x1000> [48]\n",
                        text.replace("Found 2", "Found secret")):
            with self.assertRaises(ValueError):
                NODES.trace_roots(changed, 0x1000, 48)


class FrozenComparisonTests(unittest.TestCase):
    def test_old_allocation_becomes_leaked_with_lost_external_roots_despite_empty_diff(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory))
            original = {name: (case.records / name).read_bytes() for name in ("scans.json", "result.json")}
            value = case.compare()
            self.assertEqual(value["status"], "complete")
            self.assertEqual(value["selection"], "first-new-leak")
            self.assertEqual(value["selected_label"], "added-10")
            self.assertEqual(value["baseline"]["leak_nodes"], 0)
            self.assertEqual(value["selected"]["leak_nodes"], 1)
            node = value["nodes"][0]
            self.assertEqual(node["history"]["classification"], "preexisting")
            self.assertEqual((node["baseline_external_roots"], node["selected_external_roots"]), (2, 0))
            self.assertEqual(node["baseline_tree"]["status"], "not_leaked")
            self.assertEqual(node["selected_tree"]["root_kind"], "cycle")
            self.assertEqual([name for kind, name, _ in case.calls if kind == "list"], ["baseline", "added-10"])
            histories = [command for kind, _, command in case.calls if kind == "history"]
            self.assertEqual(histories[0][2:], histories[1][2:])
            self.assertNotIn("private", NODES.encode_summary(value).decode())
            self.assertNotIn("0x2000", NODES.encode_summary(value).decode())
            self.assertEqual(original, {name: (case.records / name).read_bytes() for name in original})

    def test_equal_count_replacement_and_resized_address_are_selected(self):
        for before, after, resized in (({0x1000: 48}, {0x2000: 48}, 0), ({0x1000: 48}, {0x1000: 80}, 1)):
            with tempfile.TemporaryDirectory() as directory:
                case = Case(Path(directory), before, after, first=3)
                value = case.compare()
                self.assertEqual(value["selected_label"], "removed-10")
                self.assertEqual(value["comparison"]["resized_addresses"], resized)
                self.assertEqual(value["comparison"]["added_nodes"], 1 - resized)
                self.assertEqual(value["comparison"]["removed_nodes"], 1 - resized)
                self.assertEqual(len([call for call in case.calls if call[0] == "list"]), 4)

    def test_no_new_leak_reads_all_seven_lists_and_does_not_query_other_objects(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory), {0x1000: 48}, {0x1000: 48})
            value = case.compare()
            self.assertEqual(value["status"], "complete")
            self.assertEqual(value["selection"], "no-new-leak")
            self.assertIsNone(value["selected"])
            self.assertEqual(value["baseline"]["leak_nodes"], 1)
            self.assertEqual([(kind, label) for kind, label, _ in case.calls], [("list", label) for label in NODES.HEAP_LABELS])

    def test_missing_earlier_list_never_skips_to_first_later_growth(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory), first=3)
            case.failures[("list", "added-10")] = "partial private output"
            value = case.compare()
            self.assertEqual(value["status"], "unavailable")
            self.assertIsNone(value["selection"])
            self.assertEqual(len(case.calls), 2)
            self.assertIn("list_invalid", value["reasons"])

    def test_scan_totals_and_graph_hash_binding_reject_different_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory))
            case.failures[("list", "added-10")] = listing({0x2000: 80})
            value = case.compare()
            self.assertIn("list_invalid", value["reasons"])
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory))
            run = case.run
            def mutate(owner, kind, label, command, allowed=(0,)):
                output = run(owner, kind, label, command, allowed)
                if label == "added-10":
                    (case.graphs / "added-10.memgraph").write_bytes(b"changed graph")
                return output
            case.run = mutate
            value = case.compare()
            self.assertIn("graph_changed", value["reasons"])

    def test_aba_requires_history_and_heap_diff_agreement_size_mismatch_unknown(self):
        for agrees, requested in ((True, 48), (False, 48), (True, 47)):
            with tempfile.TemporaryDirectory() as directory:
                case = Case(Path(directory))
                case.before_events = [("ALLOC", 0x2000, requested)]
                case.after_events = case.before_events + [("FREE", 0x2000, requested), ("ALLOC", 0x2000, requested)]
                case.heap_diff = {0x2000: 48} if agrees else {}
                value = case.compare()
                self.assertEqual(value["nodes"][0]["history"]["classification"], "new_allocation" if agrees and requested == 48 else "unknown")
                self.assertEqual(value["status"], "complete" if agrees and requested == 48 else "partial")

    def test_missing_baseline_address_is_new_only_with_matching_heap_diff(self):
        for agrees in (True, False):
            with tempfile.TemporaryDirectory() as directory:
                case = Case(Path(directory))
                case.baseline_heap = {}; case.before_events = []
                case.heap_diff = {0x2000: 48} if agrees else {}
                value = case.compare()
                self.assertEqual(value["nodes"][0]["history"]["classification"], "new_allocation" if agrees else "unknown")
                self.assertEqual(value["nodes"][0]["baseline_presence"], "absent")
                self.assertIsNone(value["nodes"][0]["baseline_external_roots"])
                self.assertEqual(len([call for call in case.calls if call[:2] == ("trace", "baseline")]), 0)

    def test_candidate_budget_is_sixteen_and_histories_use_identical_addresses(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory), after={0x1000 + index * 128: 48 for index in range(18)}, first=6)
            value = case.compare()
            self.assertEqual(value["candidate_count"], 18)
            self.assertLessEqual(len(value["nodes"]), 16)
            self.assertEqual(len(value["nodes"]) + value["omitted_candidates"], 18)
            self.assertEqual(value["status"], "partial")
            self.assertIn("candidate_limit", value["reasons"])
            self.assertEqual(len(case.calls), 45)
            queries = [command[2:] for kind, _, command in case.calls if kind == "history"]
            self.assertEqual(queries[0], queries[1]); self.assertEqual(len(queries[0]), 16)
            self.assertLessEqual(len(NODES.encode_summary(value)), NODES.PUBLIC_LIMIT)

    def test_unknown_exit_stops_next_tool_but_preserves_comparison_and_strict(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory))
            original = (case.records / "result.json").read_bytes()
            case.failures[("tree", "baseline")] = NODES.ExitUnconfirmed()
            value = case.compare()
            self.assertEqual(len(case.calls), 3)
            self.assertEqual(value["comparison"]["added_nodes"], 1)
            self.assertFalse(value["process_cleanup_confirmed"])
            self.assertIn("process_exit_unconfirmed", value["reasons"])
            self.assertEqual((case.records / "result.json").read_bytes(), original)

    def test_parse_failure_keeps_other_bounded_evidence_without_claiming_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory))
            case.failures[("tree", "added-10")] = "private unknown tree"
            case.failures[("history", "baseline")] = "private unknown history"
            value = case.compare()
            self.assertEqual(value["status"], "partial")
            self.assertEqual(value["nodes"][0]["selected_tree"]["status"], "unavailable")
            self.assertEqual(value["nodes"][0]["selected_external_roots"], 0)
            self.assertIn("tree_invalid", value["reasons"])
            self.assertIn("history_unavailable", value["reasons"])

    def test_host_not_exited_and_bad_scan_order_do_not_start_tools(self):
        for kind in ("cleanup", "order", "boolean", "missing", "live", "product"):
            with tempfile.TemporaryDirectory() as directory:
                case = Case(Path(directory))
                if kind == "cleanup":
                    (case.records / "process-cleanup.json").write_text('{"processes_exited":false}')
                elif kind in ("live", "product"):
                    result = json.loads((case.records / "result.json").read_text())
                    result["scan_mode" if kind == "live" else "mode"] = kind
                    (case.records / "result.json").write_text(json.dumps(result))
                else:
                    points = json.loads((case.records / "scans.json").read_text())
                    if kind == "order": points.reverse()
                    if kind == "boolean": points[0]["leak_nodes"] = True
                    if kind == "missing": points.pop()
                    (case.records / "scans.json").write_text(json.dumps(points))
                value = case.compare()
                self.assertEqual(value["status"], "unavailable")
                self.assertEqual(case.calls, [])


class ReferenceTests(unittest.TestCase):
    @staticmethod
    def xpc_tree(grouped=False):
        # Self-authored miniature syntax fixture; no external application data.
        nodes = {0x1000: 160, 0x2000: 320, 0x3000: 64, 0x4000: 48, 0x5000: 64}
        suffix = "  Protocol: NSAccessibilityRemoteUIElement  Connection: <private name> [no process]"
        text = totals(nodes)
        text += "\nSTACK OF 1 INSTANCE OF 'ROOT CYCLE: <NSXPCConnection>':\n0 private stack\n====\n" if grouped else "\n5 (656 bytes) << TOTAL >>\n"
        text += (f"    5 (656 bytes) ROOT CYCLE: <NSXPCConnection 0x1000> [160]{suffix}\n"
                 "       3 (432 bytes) _connection --> ROOT CYCLE: <xpc_connection_t 0x2000> [320]  <private name> [no process]\n"
                 "          1 (64 bytes) ROOT CYCLE: 0x3000 [64]\n"
                 "          1 (48 bytes) ROOT CYCLE: <__NSMallocBlock__ 0x4000> [48]  PrivateImage  private_block_invoke  0xabcdef\n"
                 f"             __strong [capture] --> CYCLE BACK TO <NSXPCConnection 0x1000> [160]{suffix}\n"
                 "       1 (64 bytes) _remoteObjectInterface --> <NSXPCInterface 0x5000> [64]  Protocol: NSAccessibilityRemoteUIElement\n")
        return nodes, text

    def test_both_real_tree_shapes_preserve_connections_and_cycle_endpoint_paths(self):
        for grouped in (False, True):
            nodes, text = self.xpc_tree(grouped)
            graph = NODES.parse_tree_graph(text, nodes)
            self.assertEqual(len(graph["members"]), 5)
            self.assertEqual(graph["members"][0x4000]["parent"], 0x2000)
            self.assertEqual(graph["back_edges"], [{"source": 0x4000, "target": 0x1000,
                              "label": "__strong [capture]", "root": 0}])
            selected = NODES.tree_reference_graph(graph, 0x5000)
            self.assertEqual(set(selected["members"]), {0x1000, 0x2000, 0x4000, 0x5000})
            self.assertEqual(len(selected["edges"]), 4)
            value = NODES.initial_summary()
            builder = NODES.References(value, nodes)
            view = NODES.reference_view(0, "selected", "tree")
            builder.add(selected, view)
            output = NODES.encode_summary(value).decode()
            for private in ("0x", "private", "PrivateImage", "block_invoke"):
                self.assertNotIn(private, output)
            self.assertIn("__strong [capture]", output)
            self.assertIn("NSAccessibilityRemoteUIElement", output)

    def test_back_reference_at_sibling_indent_belongs_to_parent_not_previous_child(self):
        nodes, text = self.xpc_tree()
        text = text.replace("             __strong [capture]", "          __strong [capture]")
        graph = NODES.parse_tree_graph(text, nodes)
        self.assertEqual(graph["back_edges"][0]["source"], 0x2000)
        self.assertEqual(graph["members"][0x5000]["parent"], 0x1000)

    def test_tree_unknown_names_are_buckets_and_unknown_syntax_fails_closed(self):
        nodes, text = self.xpc_tree()
        graph = NODES.parse_tree_graph(text.replace("NSAccessibilityRemoteUIElement", "PrivateProtocol").replace("_connection -->", "privateMember -->"), nodes)
        self.assertEqual(graph["members"][0x1000]["protocol"], "unknown")
        self.assertEqual(graph["members"][0x2000]["edge"], "unknown")
        for changed in (text.replace("5 (656 bytes) << TOTAL >>", "4 (656 bytes) << TOTAL >>"),
                        text.replace("[320]  <private name>", "[320] unknown-tail <private name>"),
                        text.replace("3 (432 bytes)", "4 (432 bytes)"),
                        text.replace("0x3000 [64]", "0x4000 [64]"),
                        text.replace("0x5000> [64]", "0x5000> [65]"),
                        text.replace("_connection -->", "unsupported relation -->"),
                        text + "unknown trailing row\n"):
            with self.subTest(text=changed), self.assertRaises(ValueError):
                NODES.parse_tree_graph(changed, nodes)
        no_protocol_back = text.replace("CYCLE BACK TO <NSXPCConnection 0x1000> [160]  Protocol: NSAccessibilityRemoteUIElement  Connection: <private name> [no process]",
                                        "CYCLE BACK TO <NSXPCConnection 0x1000> [160]")
        self.assertEqual(len(NODES.parse_tree_graph(no_protocol_back, nodes)["back_edges"]), 1)

    def test_reverse_paths_keep_intermediate_regions_and_slot_labels(self):
        text = trace(0x1000, 48, 2).split("    2 <", 1)[0]
        text += ("    2 <private-type 0x1000> [48]\n"
                 "      2 Region Kernel Alloc Once region + 64 0x90000\n"
                 "      + 1 <__NSMallocBlock__ 0x2000> [48] +16: __strong [capture] 0x2010\n"
                 "      + ! 1 Region Stack thread 1 private 0x90010\n"
                 "      + 1 Kernel Pointers Into User Space \n")
        graph = NODES.parse_trace_graph(text, 0x1000, 48)
        self.assertEqual((len(graph["members"]), len(graph["edges"]), graph["roots"]), (5, 4, 2))
        self.assertTrue(any(edge["label"] == "__strong [capture]" for edge in graph["edges"]))
        for changed in (text.replace("+16:", "+17:"), text.replace("      2 Region", "      3 Region"),
                        text.replace("+ ! 1 Region", "+ ! 2 Region"), text + "unparsed\n",
                        text.replace("Kernel Pointers Into User Space", "Unknown root")):
            with self.subTest(text=changed), self.assertRaises(ValueError):
                NODES.parse_trace_graph(changed, 0x1000, 48)
        zero = NODES.parse_trace_graph(trace(0x1000, 48, 0), 0x1000, 48)
        self.assertEqual((zero["roots"], zero["edges"]), (0, []))

    @staticmethod
    def slot_trace(target=0x1000, description="Private Root Kind", offset=16, slot=0x1000):
        prefix = trace(target, 48, 1).split("    1 <", 1)[0]
        return (prefix + f"    1 <private-type {target:#x}> [48]\n"
                f"      1 <{description}> +{offset}: __strong {slot:#x}\n")

    def test_addressless_root_uses_private_slot_identity_and_public_unknown_bucket(self):
        for description in ("Swift Metadata", "Swift metadata", "Swift HeapGenericLocalVariable", "Unlisted Private Type"):
            graph = NODES.parse_trace_graph(self.slot_trace(description=description), 0x1000, 48)
            slot = ("metadata-slot", 0x1000)
            self.assertEqual(set(graph["members"]), {0x1000, slot})
            self.assertEqual((graph["members"][slot]["size"], graph["members"][slot]["region"]), (0, "other"))
            self.assertEqual(graph["edges"], [{"source": slot, "target": 0x1000, "label": "__strong", "relation": "reverse_reference"}])
            value = NODES.initial_summary()
            builder = NODES.References(value, [0x1000])
            view = NODES.reference_view(0, "baseline", "trace")
            builder.add(graph, view)
            self.assertNotEqual(builder.ids[slot], builder.ids[0x1000])
            published = next(node for node in value["references"]["nodes"] if node["id"] == builder.ids[slot])
            self.assertEqual((published["type"], published["size"], published["region"]), ("unknown", 0, "other"))
            output = NODES.encode_summary(value).decode()
            for private in (description, "slot_binding", "0x1000", "metadata-slot"):
                self.assertNotIn(private, output)
        for offset in (0, NODES.INTEGER_LIMIT):
            NODES.parse_trace_graph(self.slot_trace(offset=offset), 0x1000, 48)

    def test_addressless_roots_keep_mixed_and_repeated_path_counts(self):
        mixed = self.slot_trace().replace("Found 1 root", "Found 2 root").replace("    1 <private-type", "    2 <private-type")
        mixed += "      1 Region Stack private 0x9000\n"
        graph = NODES.parse_trace_graph(mixed, 0x1000, 48)
        self.assertEqual((graph["roots"], len(graph["edges"])), (2, 2))
        prefix = trace(0x1000, 48, 2).split("    2 <", 1)[0]
        branch = ("      1 <PrivateReferrer 0x2000> [48] +8: __strong 0x2008\n"
                  "        1 <Private Root Kind> +16: __strong 0x7000\n")
        text = prefix + "    2 <private-type 0x1000> [48]\n" + branch * 2
        graph = NODES.parse_trace_graph(text, 0x1000, 48)
        self.assertEqual((graph["roots"], len(graph["members"]), len(graph["edges"])), (2, 3, 2))
        for changed in (
            text.replace("<Private Root Kind>", "<Different Private Type>", 1),
            text.replace("+16:", "+24:", 1),
            text.replace(branch, branch.replace("0x2000", "0x3000").replace("0x2008", "0x3008"), 1),
        ):
            with self.subTest(changed=changed), self.assertRaisesRegex(ValueError, "Conflicting trace object"):
                NODES.parse_trace_graph(changed, 0x1000, 48)

    def test_addressless_root_rejects_other_shapes_nonleaves_and_bad_bindings(self):
        text = self.slot_trace()
        for changed in (
            text.replace("<Private Root Kind>", "<>"), text.replace("<Private Root Kind>", "<   >"),
            text.replace("<Private Root Kind>", "<" + "X" * 1025 + ">"),
            text.replace("<Private Root Kind>", "<Private\tKind>"),
            text.replace("<Private Root Kind>", "<Private\x00Kind>"),
            text.replace("<Private Root Kind>", "<Private 0x1000>"),
            text.replace("<Private Root Kind>", "<Private<Type>>"),
            text.replace("+16:", "+1000000001:"), text.replace("+16:", "+00000000000:"),
            text.replace("+16:", "-16:"), text.replace("+16:", "+opaque:"),
            text.replace("__strong 0x1000", "__strong 0x0"),
            text.replace("__strong", "__weak"), text.replace("__strong", "privateLabel"),
            text.replace("__strong", "__strong [capture]"),
            text.replace("      1 <Private", "      2 <Private"),
            text.replace("      1 <Private", "       1 <Private"),
            text.replace("Found 1 root", "Found 0 root"),
            text.replace("    1 <private-type 0x1000> [48]\n", ""),
            text + "        1 Region Stack private 0x9000\n",
            text.rstrip() + " --> offset 8\n", text + "unparsed\n",
        ):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                NODES.parse_trace_graph(changed, 0x1000, 48)

    def test_slot_binding_conflicts_across_views_fail_without_public_mutation(self):
        value = NODES.initial_summary()
        builder = NODES.References(value, [0x1000, 0x2000])
        graph = NODES.parse_trace_graph(self.slot_trace(), 0x1000, 48)
        builder.add(graph, NODES.reference_view(0, "baseline", "trace"))
        before = copy.deepcopy(value)
        for text, target in ((self.slot_trace(offset=24), 0x1000),
                             (self.slot_trace(description="Other Kind"), 0x1000),
                             (self.slot_trace(target=0x2000), 0x2000)):
            changed = NODES.parse_trace_graph(text, target, 48)
            with self.assertRaisesRegex(ValueError, "Conflicting trace object"):
                builder.add(changed, NODES.reference_view(1, "baseline", "trace"))
            self.assertEqual(value, before)
        changed = NODES.parse_trace_graph(self.slot_trace(offset=24), 0x1000, 48)
        builder.add(changed, NODES.reference_view(0, "selected", "trace"))

    def test_slot_roots_pass_full_schema_without_changing_leak_root_classification(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory))
            case.failures[("trace", "baseline")] = self.slot_trace(target=0x2000)
            value = case.compare(first_strict_growth=True)
        self.assertEqual(value["status"], "complete")
        self.assertEqual(value["nodes"][0]["selected_tree"]["root_kind"], "cycle")
        self.assertEqual(value["nodes"][0]["baseline_external_roots"], 1)
        self.assertTrue(any(node["region"] == "other" and node["size"] == 0 for node in value["references"]["nodes"]))
        NODES.validate_summary(value)

    def test_shared_ids_do_not_claim_allocation_identity_or_discard_baseline_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            value = Case(Path(directory)).compare()
        refs = value["references"]
        self.assertEqual(refs["semantics"], "tool-reported")
        views = {(view["checkpoint"], view["kind"]): view for view in refs["views"]}
        self.assertEqual(views["baseline", "tree"]["status"], "not_leaked")
        self.assertEqual(views["baseline", "trace"]["status"], "complete")
        self.assertEqual(len(views["baseline", "trace"]["edges"]), 2)
        self.assertEqual(views["baseline", "trace"]["target"], views["selected", "tree"]["target"])
        self.assertEqual(len(views["selected", "trace"]["edges"]), 0)

    def test_reference_limits_are_atomic_and_preserve_selected_cycle_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(NODES, "REFERENCE_NODES", 1):
                value = Case(Path(directory)).compare()
        self.assertEqual(value["status"], "partial")
        self.assertIn("references_budget", value["reasons"])
        views = {(view["checkpoint"], view["kind"]): view for view in value["references"]["views"]}
        self.assertEqual(views["selected", "tree"]["status"], "complete")
        self.assertEqual(views["baseline", "trace"]["status"], "budget_exceeded")
        self.assertEqual(len(value["references"]["nodes"]), 1)
        NODES.validate_summary(value)

    def test_public_gate_rejects_arbitrary_reference_data_dangling_ids_and_false_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            value = Case(Path(directory)).compare()
        edits = [lambda v: v["references"].update(semantics="ARC ownership"),
                 lambda v: v["references"]["nodes"][0].update(type="PrivateClass"),
                 lambda v: v["references"]["nodes"][0].update(protocol="PrivateProtocol"),
                 lambda v: v["references"]["nodes"][0].update(id="0x1000"),
                 lambda v: v["references"]["edges"][0].update(source=999),
                 lambda v: v["references"]["edges"][0].update(label="PrivateLabel"),
                 lambda v: v["references"]["views"].pop(),
                 lambda v: v["references"]["views"][1].update(target=999)]
        for edit in edits:
            bad = copy.deepcopy(value); edit(bad)
            with self.assertRaises(ValueError): NODES.validate_summary(bad)

    def test_reference_target_root_summary_and_all_back_edges_are_bound(self):
        with tempfile.TemporaryDirectory() as directory:
            value = Case(Path(directory)).compare(first_strict_growth=True)
        changed = copy.deepcopy(value)
        changed["nodes"][0]["size"] = 777
        with self.assertRaises(ValueError): NODES.validate_summary(changed)
        changed = copy.deepcopy(value)
        for view in changed["references"]["views"]:
            view["edges"] = [index for index in view["edges"] if changed["references"]["edges"][index]["relation"] != "cycle_back"]
        NODES.prune_references(changed)
        with self.assertRaises(ValueError): NODES.validate_summary(changed)
        changed = copy.deepcopy(value)
        root = next(node for node in changed["references"]["nodes"] if node["tree"] is not None)
        root["tree"]["bytes"] += 1
        with self.assertRaises(ValueError): NODES.validate_summary(changed)

    def test_byte_budget_removes_reverse_views_before_selected_cycle(self):
        with tempfile.TemporaryDirectory() as directory:
            value = Case(Path(directory)).compare()
        full_size = len(NODES.encode_summary(value))
        with mock.patch.object(NODES, "PUBLIC_LIMIT", full_size - 100):
            NODES.bound_summary(value)
            NODES.validate_summary(value)
            self.assertLessEqual(len(NODES.encode_summary(value)), NODES.PUBLIC_LIMIT)
        selected = next(view for view in value["references"]["views"] if view["kind"] == "tree" and view["checkpoint"] == "selected")
        baseline = next(view for view in value["references"]["views"] if view["kind"] == "trace" and view["checkpoint"] == "baseline")
        self.assertEqual((selected["status"], baseline["status"]), ("complete", "budget_exceeded"))
        self.assertIn("summary_budget", value["reasons"])

    def test_repeated_back_relations_keep_multiplicity_after_enum_redaction(self):
        nodes, text = self.xpc_tree()
        back = next(line for line in text.splitlines() if "CYCLE BACK TO" in line)
        graph = NODES.parse_tree_graph(text.replace(back, back + "\n" + back), nodes)
        self.assertEqual(graph["roots"][0]["summary"]["cycle_back_edges"], 2)
        value = NODES.initial_summary(); builder = NODES.References(value, nodes)
        builder.add(NODES.tree_reference_graph(graph, 0x5000), NODES.reference_view(0, "selected", "tree"))
        edges = [edge for edge in value["references"]["edges"] if edge["relation"] == "cycle_back"]
        self.assertEqual([edge["count"] for edge in edges], [2])


class StrictGrowthTests(unittest.TestCase):
    def test_strict_selection_skips_equal_totals_replacement_but_keeps_first_growth(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory), {0x1000: 48}, {0x2000: 48})
            for label in NODES.HEAP_LABELS[3:]: case.points[label][0x3000] = 48
            case.baseline_heap[0x3000] = 48
            case.before_events.append(("ALLOC", 0x3000, 48)); case.after_events = list(case.before_events)
            case.write_scans()
            value = case.compare(first_strict_growth=True)
            self.assertEqual(value["selection"], "first-strict-growth")
            self.assertEqual(value["selected_label"], "removed-10")
            self.assertEqual(len(value["checked_points"]), 4)
            self.assertEqual(value["status"], "complete")

    def test_no_strict_growth_still_checks_baseline_tree_and_all_lists(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory), {0x1000: 48}, {0x2000: 48})
            value = case.compare(first_strict_growth=True)
            self.assertEqual(value["selection"], "no-strict-growth")
            self.assertEqual(value["baseline_roots"]["status"], "complete")
            self.assertEqual(value["baseline_roots"]["roots"][0]["nodes"], 1)
            self.assertEqual([(kind, label) for kind, label, _ in case.calls], [("list", label) for label in NODES.HEAP_LABELS] + [("tree", "baseline")])
            self.assertEqual(value["references"]["status"], "not_needed")
            for edit in (lambda v: v["checked_points"][1].update(leak_nodes=2),
                         lambda v: v["checked_points"][1].update(leak_bytes=49),
                         lambda v: v["baseline_roots"].update(status="not_requested", roots=[]),
                         lambda v: v["tools"].pop()):
                bad = copy.deepcopy(value); edit(bad)
                with self.assertRaises(ValueError): NODES.validate_summary(bad)

    def test_no_strict_growth_unknown_baseline_tree_is_partial(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory), {0x1000: 48}, {0x1000: 48})
            case.failures[("tree", "baseline")] = "private unsupported grammar"
            value = case.compare(first_strict_growth=True)
            self.assertEqual(value["status"], "partial")
            self.assertEqual(value["baseline_roots"]["status"], "unavailable")
            self.assertIn("tree_invalid", value["reasons"])

    def test_product_mode_is_only_accepted_by_strict_growth_option(self):
        for strict in (False, True):
            with tempfile.TemporaryDirectory() as directory:
                case = Case(Path(directory), {0x1000: 48}, {0x1000: 48})
                (case.records / "result.json").write_text(json.dumps({"mode": "product", "scan_mode": "diagnostic"}))
                value = case.compare(first_strict_growth=strict)
                self.assertEqual(value["status"], "complete" if strict else "unavailable")

    def test_cli_option_selects_strict_growth_without_changing_strict_result(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); case = Case(root, {0x1000: 48}, {0x2000: 48})
            original = (case.records / "result.json").read_bytes()
            with mock.patch.object(NODES.Tools, "run", autospec=True, side_effect=case.run), contextlib.redirect_stdout(io.StringIO()):
                code = NODES.main(["--graph-directory", str(case.graphs), "--records-directory", str(case.records), "--first-strict-growth"])
            self.assertEqual(code, 0)
            self.assertEqual(json.loads((case.records / "frozen-nodes.json").read_text())["selection"], "no-strict-growth")
            self.assertEqual((case.records / "result.json").read_bytes(), original)


class FrozenToolTests(unittest.TestCase):
    def tool(self, root, deadline=None):
        summary = NODES.initial_summary()
        return NODES.Tools(root / "outputs", summary, time.monotonic() + 90 if deadline is None else deadline), summary

    def test_stdout_is_file_bounded_and_even_whitespace_stderr_is_rejected(self):
        for stderr in (False, True):
            with tempfile.TemporaryDirectory() as directory:
                tool, summary = self.tool(Path(directory))
                child = mock.Mock(); child.wait.return_value = 0
                def spawn(command, **kwargs):
                    self.assertNotIn("capture_output", kwargs)
                    self.assertNotEqual(kwargs["stdout"], subprocess.PIPE)
                    kwargs["stdout"].write(b"bounded output")
                    if stderr: kwargs["stderr"].write(b" \n")
                    kwargs["stdout"].flush(); kwargs["stderr"].flush()
                    return child
                with mock.patch.object(NODES.subprocess, "Popen", side_effect=spawn):
                    if stderr:
                        with self.assertRaises(NODES.EvidenceError): tool.run("list", "baseline", ["tool"])
                    else:
                        self.assertEqual(tool.run("list", "baseline", ["tool"]), "bounded output")
                self.assertTrue(summary["process_cleanup_confirmed"])

    def test_total_deadline_stops_before_spawn_and_single_tool_reserves_reaping(self):
        with tempfile.TemporaryDirectory() as directory:
            tool, summary = self.tool(Path(directory), time.monotonic() - 1)
            with mock.patch.object(NODES.subprocess, "Popen") as spawn, self.assertRaises(NODES.EvidenceError) as caught:
                tool.run("list", "baseline", ["tool"])
            self.assertEqual(caught.exception.reason, "deadline"); spawn.assert_not_called()
            self.assertEqual(summary["tools"], [])
        with tempfile.TemporaryDirectory() as directory:
            tool, summary = self.tool(Path(directory))
            child = mock.Mock(); child.wait.side_effect = [subprocess.TimeoutExpired("tool", 13), -9]
            with mock.patch.object(NODES.subprocess, "Popen", return_value=child), self.assertRaises(NODES.EvidenceError):
                tool.run("list", "baseline", ["tool"])
            self.assertLessEqual(child.wait.call_args_list[0].kwargs["timeout"], 13)
            self.assertLessEqual(child.wait.call_args_list[1].kwargs["timeout"], 2)
            child.kill.assert_called_once()
            self.assertEqual(summary["tools"][0]["status"], "timeout")
            self.assertTrue(summary["process_cleanup_confirmed"])

    def test_spawn_failure_and_unconfirmed_wait_are_distinct(self):
        with tempfile.TemporaryDirectory() as directory:
            tool, summary = self.tool(Path(directory))
            with mock.patch.object(NODES.subprocess, "Popen", side_effect=OSError("private path")), self.assertRaises(NODES.EvidenceError):
                tool.run("list", "baseline", ["tool"])
            self.assertTrue(summary["process_cleanup_confirmed"])
            self.assertEqual(summary["tools"][0]["status"], "spawn_failed")
        with tempfile.TemporaryDirectory() as directory:
            tool, summary = self.tool(Path(directory))
            child = mock.Mock(); child.wait.side_effect = subprocess.TimeoutExpired("private path", 1)
            with mock.patch.object(NODES.subprocess, "Popen", return_value=child), self.assertRaises(NODES.ExitUnconfirmed):
                tool.run("list", "baseline", ["tool"])
            self.assertFalse(summary["process_cleanup_confirmed"])

    def test_output_limit_is_checked_before_read_and_nonregular_inputs_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "large"; path.write_bytes(b"x" * 17)
            with self.assertRaises(ValueError): NODES.read_bytes(path, 16)
            link = root / "link"; link.symlink_to(path)
            with self.assertRaises(ValueError): NODES.read_bytes(link)
            with self.assertRaises(ValueError): NODES.read_bytes(root)

    def test_preexec_failure_without_returned_handle_is_exit_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            tool, summary = self.tool(Path(directory))
            with mock.patch.object(NODES.subprocess, "Popen", side_effect=subprocess.SubprocessError("private preexec failure")), self.assertRaises(NODES.ExitUnconfirmed):
                tool.run("list", "baseline", ["tool"])
            self.assertFalse(summary["process_cleanup_confirmed"])

    def test_oversized_actual_tool_file_and_nonzero_exit_remain_failures(self):
        for too_big in (True, False):
            with tempfile.TemporaryDirectory() as directory:
                tool, summary = self.tool(Path(directory))
                child = mock.Mock(); child.wait.return_value = 0 if too_big else 2
                def spawn(command, **kwargs):
                    kwargs["stdout"].write(b"x" * 17); kwargs["stdout"].flush()
                    return child
                with mock.patch.object(NODES, "RAW_LIMIT", 16), mock.patch.object(NODES.subprocess, "Popen", side_effect=spawn), self.assertRaises(NODES.EvidenceError):
                    tool.run("list", "baseline", ["tool"])
                self.assertEqual(summary["tools"][0]["status"], "output_limit" if too_big else "exit_failed")
                self.assertTrue(summary["process_cleanup_confirmed"])


class FrozenPublicGateTests(unittest.TestCase):
    @staticmethod
    def no_new():
        value = NODES.initial_summary()
        value.update(status="complete", selection="no-new-leak",
                     baseline={"leak_nodes": 3, "leak_bytes": 300, "graph_sha256": "0" * 64},
                     checked_points=[{"label": label, "leak_nodes": 3, "leak_bytes": 300} for label in NODES.HEAP_LABELS],
                     tools=[{"tool": "list", "label": label, "status": "complete", "return_code": 0, "cleanup_confirmed": True}
                            for label in NODES.HEAP_LABELS])
        return value

    def test_candidate_conservation_includes_resized_and_partial_omissions(self):
        with tempfile.TemporaryDirectory() as directory:
            value = Case(Path(directory)).compare()
        for status in ("complete", "partial"):
            bad = copy.deepcopy(value)
            bad["selected"].update(leak_nodes=2, leak_bytes=96)
            bad["checked_points"][-1].update(leak_nodes=2, leak_bytes=96)
            bad["comparison"].update(added_nodes=2, added_bytes=96)
            bad["status"] = status
            if status == "partial": bad["reasons"] = ["candidate_limit"]
            with self.subTest(status=status), self.assertRaises(ValueError):
                NODES.validate_summary(bad)
            if status == "partial":
                bad.update(candidate_count=2, omitted_candidates=1)
                NODES.validate_summary(bad)
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory), {0x1000: 48}, {0x1000: 80})
            case.baseline_heap = {0x1000: 48}
            case.heap_diff = {0x1000: 80}
            case.before_events = [("ALLOC", 0x1000, 48)]
            case.after_events = case.before_events + [("FREE", 0x1000, 48), ("ALLOC", 0x1000, 80)]
            resized = case.compare()
        self.assertEqual(resized["status"], "complete")
        self.assertEqual((resized["candidate_count"], resized["comparison"]["added_nodes"], resized["comparison"]["resized_addresses"]), (1, 0, 1))
        resized.update(status="partial", nodes=[], candidate_count=0, reasons=["deadline"])
        with self.assertRaises(ValueError): NODES.validate_summary(resized)
        resized.update(candidate_count=1, omitted_candidates=1)
        resized["references"] = {**NODES.empty_references(), "status": "partial"}
        NODES.validate_summary(resized)

    def test_complete_no_new_requires_exact_seven_list_receipts(self):
        value = self.no_new()
        NODES.validate_summary(value)
        invalid = [[], value["tools"][::-1], value["tools"] + [value["tools"][0]]]
        invalid += [value["tools"][:index] + value["tools"][index + 1:] for index in range(7)]
        duplicate = copy.deepcopy(value["tools"]); duplicate[-1] = duplicate[0]
        invalid.append(duplicate)
        for tools in invalid:
            bad = copy.deepcopy(value); bad["tools"] = tools
            with self.subTest(tools=tools), self.assertRaises(ValueError):
                NODES.validate_summary(bad)

    def test_complete_first_new_requires_each_actual_tool_and_presence_dependent_trace(self):
        for presence in ("present", "absent", "mixed"):
            with tempfile.TemporaryDirectory() as directory:
                after = {0x2000: 48, 0x3000: 80} if presence == "mixed" else {0x2000: 48}
                case = Case(Path(directory), after=after, first=3)
                if presence != "present":
                    del case.baseline_heap[0x2000]
                    case.heap_diff = {0x2000: 48}
                    case.before_events = [("ALLOC", address, size) for address, size in case.baseline_heap.items()]
                value = case.compare()
            self.assertEqual(value["status"], "complete")
            expected = [("list", label) for label in NODES.HEAP_LABELS[:4]]
            expected += [("tree", "baseline"), ("tree", "removed-10"), ("heap", "baseline"),
                         ("heap_diff", "removed-10"), ("history", "baseline"), ("history", "removed-10")]
            for node in value["nodes"]:
                if node["baseline_presence"] == "present": expected.append(("trace", "baseline"))
                expected.append(("trace", "removed-10"))
            self.assertEqual([(tool["tool"], tool["label"]) for tool in value["tools"]], expected)
            invalid = [[], value["tools"][::-1], value["tools"] + [value["tools"][-1]]]
            invalid += [value["tools"][:index] + value["tools"][index + 1:] for index in range(len(value["tools"]))]
            wrong_label = copy.deepcopy(value["tools"]); wrong_label[-1]["label"] = "observer-exited"
            invalid.append(wrong_label)
            for tools in invalid:
                bad = copy.deepcopy(value); bad["tools"] = tools
                with self.subTest(presence=presence, tools=tools), self.assertRaises(ValueError):
                    NODES.validate_summary(bad)

    def test_partial_allows_incomplete_tools_but_not_contradictory_candidate_count(self):
        with tempfile.TemporaryDirectory() as directory:
            value = Case(Path(directory)).compare()
        value.update(status="partial", tools=[], reasons=["deadline"])
        NODES.validate_summary(value)
        value.update(candidate_count=2, omitted_candidates=1)
        with self.assertRaises(ValueError): NODES.validate_summary(value)

    def test_minimal_no_new_fixture_and_public_malicious_values(self):
        value = self.no_new(); NODES.validate_summary(value)
        changes = [lambda v: v.update(path="private"), lambda v: v.update(schema=True),
                   lambda v: v.update(status="private"), lambda v: v.update(selection="private"),
                   lambda v: v.update(process_cleanup_confirmed=1), lambda v: v.update(reasons=["private"]),
                   lambda v: v["baseline"].update(graph_sha256="/private/path"),
                   lambda v: v["baseline"].update(leak_nodes=True), lambda v: v.update(candidate_count=1),
                   lambda v: v.update(status="partial"), lambda v: v.update(reasons=["deadline"])]
        for change in changes:
            bad = copy.deepcopy(value); change(bad)
            with self.subTest(value=bad), self.assertRaises(ValueError): NODES.validate_summary(bad)

    def test_nested_fields_and_false_complete_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            value = Case(Path(directory)).compare()
        changes = [lambda v: v["nodes"][0].update(address="0x2000"), lambda v: v["nodes"][0].update(type="private"),
                   lambda v: v["nodes"][0]["history"].update(classification="old so harmless"),
                   lambda v: v["nodes"][0]["selected_tree"].update(root_type="private"),
                   lambda v: v["nodes"][0]["history"].update(classification="unknown"),
                   lambda v: v["tools"][0].update(command="private"), lambda v: v["tools"][0].update(return_code=True),
                   lambda v: v["comparison"].update(added_nodes=999)]
        for change in changes:
            bad = copy.deepcopy(value); change(bad)
            with self.assertRaises(ValueError): NODES.validate_summary(bad)

    def test_cli_exit_matches_status_preserves_strict_and_never_prints_raw(self):
        for complete in (True, False):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory); case = Case(root)
                if not complete: case.failures[("tree", "added-10")] = "private raw tree"
                output = io.StringIO()
                with mock.patch.object(NODES.Tools, "run", autospec=True, side_effect=case.run), contextlib.redirect_stdout(output):
                    code = NODES.main(["--graph-directory", str(case.graphs), "--records-directory", str(case.records)])
                self.assertEqual(code, 0 if complete else 1)
                data = (case.records / "frozen-nodes.json").read_bytes()
                self.assertLessEqual(len(data), NODES.PUBLIC_LIMIT)
                NODES.validate_summary(json.loads(data))
                self.assertNotIn("private", output.getvalue())
                self.assertNotIn(str(root), output.getvalue())
                self.assertEqual(json.loads((case.records / "result.json").read_text())["coverage"], "failed")

    def test_actual_serialization_budget_trims_nodes_and_reports_partial(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); case = Case(root, after={0x1000 + index * 128: 48 for index in range(16)})
            with mock.patch.object(NODES.Tools, "run", autospec=True, side_effect=case.run), mock.patch.object(NODES, "PUBLIC_LIMIT", 12000), contextlib.redirect_stdout(io.StringIO()):
                code = NODES.main(["--graph-directory", str(case.graphs), "--records-directory", str(case.records)])
            data = (case.records / "frozen-nodes.json").read_bytes()
            self.assertLessEqual(len(data), 12000)
            value = json.loads(data)
            self.assertEqual(code, 1)
            self.assertEqual(value["status"], "partial")
            self.assertIn("summary_budget", value["reasons"])
            self.assertEqual(len(value["nodes"]) + value["omitted_candidates"], 16)


if __name__ == "__main__":
    unittest.main()
