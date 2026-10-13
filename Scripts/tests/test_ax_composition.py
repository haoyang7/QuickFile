"""Self-authored grouped reports and pure composition invariants."""
import copy
import hashlib
from pathlib import Path
import re
import sys
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Investigations"))
sys.path.insert(0, str(HERE))
import ax_composition as composition
import ax_ci_failure as ci_evidence
from test_ax_frozen_nodes import listing, tree


def grouped(nodes, size, lines, instances=1, kind="NSMutableArray", marker="ROOT LEAK", frame=0):
    return (f"Process 123: {nodes} leaks for {size} total leaked bytes.\n\n"
            f"STACK OF {instances} INSTANCES OF '{marker}: {kind}':\n"
            f"0 synthetic-image 0x1234 synthetic_function + {frame}\n====\n" + lines + "\n")


def array_report():
    return grouped(3, 144, "    3 (144 bytes) ROOT LEAK: NSMutableArray\n"
        "       2 (96 bytes) NSMutableArray (Storage)\n          1 (80 bytes) CFData")


class CompositionTests(unittest.TestCase):
    def parse(self, report):
        value = composition.grouped_composition(report)
        composition.validate_grouped_composition(value)
        return value

    def test_grouped_subtree_subtraction_recovers_48_16_80_not_144_96_80(self):
        value = self.parse(array_report())
        self.assertEqual(value["counts_status"], "complete")
        self.assertEqual(value["type_counts"], [{"type": "NSMutableArray", "count": 1},
            {"type": "NSMutableArray (Storage)", "count": 1}, {"type": "unknown", "count": 1}])
        self.assertEqual(value["exact_size_histogram"], [{"type": "NSMutableArray", "size": 48, "count": 1},
            {"type": "NSMutableArray (Storage)", "size": 16, "count": 1}, {"type": "unknown", "size": 80, "count": 1}])
        self.assertEqual(value["status"], "partial")
        self.assertEqual(value["unknown_type_nodes"], 1)

    def test_multiple_instances_preserve_aggregate_bytes_without_splitting(self):
        value = self.parse(grouped(3, 144, "    3 (144 bytes) ROOT LEAK: NSMutableArray", instances=3))
        self.assertEqual(value["type_counts"], [{"type": "NSMutableArray", "count": 3}])
        self.assertEqual(value["exact_size_histogram"], [])
        self.assertEqual(value["size_unknown_nodes"], 3)
        self.assertEqual(value["unresolved_sizes"], [{"type": "NSMutableArray", "count": 3,
            "bytes_min": 144, "bytes_max": 144, "reason": "multiple_instances"}])

    def test_rounded_bytes_only_produce_conservative_bounds(self):
        value = self.parse(grouped(2, 96, "    2 (0.1K) ROOT LEAK: NSMutableArray\n       1 (48 bytes) NSString"))
        self.assertEqual(value["type_counts"], [{"type": "NSMutableArray", "count": 1}, {"type": "NSString", "count": 1}])
        self.assertEqual(value["exact_size_histogram"], [{"type": "NSString", "size": 48, "count": 1}])
        self.assertEqual(value["unresolved_sizes"], [{"type": "NSMutableArray", "count": 1,
            "bytes_min": 1, "bytes_max": 48, "reason": "rounded_subtree"}])

    def test_total_multiple_roots_reference_labels_and_backcycle_conserve(self):
        body = ("    5 (272 bytes) << TOTAL >>\n      ----\n"
            "      3 (144 bytes) ROOT CYCLE: NSXPCConnection\n"
            "         2 (96 bytes) _connection --> NSArray\n"
            "            1 (80 bytes) list --> NSData\n"
            "               __strong [capture] --> CYCLE BACK TO NSXPCConnection\n      ----\n"
            "      2 (128 bytes) ROOT CYCLE: NSXPCConnection\n"
            "         1 (80 bytes) NSData\n            CYCLE BACK TO NSXPCConnection")
        value = self.parse(grouped(5, 272, body, instances=2, kind="NSXPCConnection", marker="ROOT CYCLE"))
        self.assertEqual(value["status"], "complete")
        self.assertEqual(value["type_counts"], [{"type": "NSArray", "count": 1}, {"type": "NSData", "count": 2}, {"type": "NSXPCConnection", "count": 2}])
        self.assertEqual(sum(row["size"] * row["count"] for row in value["exact_size_histogram"]), 272)
        report = "Process 123: 5 leaks for 272 total leaked bytes.\n" + body + "\n"
        self.assertEqual(self.parse(report)["type_counts"], value["type_counts"])

    def test_observed_grouped_cycle_markers_on_descendants_are_not_extra_roots(self):
        # Structure observed in an owned native leaks --groupByType report.
        # Its rounded top label cannot provide an exact individual size.
        body = ("    3 (1.12K) ROOT CYCLE: calloc in make_cycle\n"
                "       2 (768 bytes) ROOT CYCLE: calloc in make_cycle\n"
                "          1 (256 bytes) ROOT CYCLE: calloc in make_cycle\n"
                "             CYCLE BACK TO calloc in make_cycle")
        report = grouped(3, 1152, body, kind="calloc in make_cycle", marker="ROOT CYCLE")
        value = self.parse(report)
        self.assertEqual(value["counts_status"], "complete")
        self.assertEqual(value["type_counts"], [{"type": "unknown", "count": 3}])
        self.assertEqual(value["exact_size_histogram"], [{"type": "unknown", "size": 256, "count": 1},
                                                      {"type": "unknown", "size": 512, "count": 1}])
        self.assertEqual(value["unresolved_sizes"], [{"type": "unknown", "count": 1,
            "bytes_min": 1, "bytes_max": 384, "reason": "rounded_subtree"}])
        self.assertEqual((value["size_unknown_nodes"], value["omitted_nodes"]), (1, 0))
        self.assertEqual(value["reasons"], ["unknown_type", "size_unresolved"])
        for invalid in (report.replace("1 INSTANCES", "3 INSTANCES"),
                        report.replace("       2 (768 bytes) ROOT CYCLE", "       2 (768 bytes) ROOT LEAK"),
                        report.replace("CYCLE BACK TO calloc in make_cycle", "CYCLE BACK TO unrelated")):
            with self.subTest(report=invalid):
                self.assertEqual(self.parse(invalid)["reasons"], ["invalid_report"])

    def test_nested_cycle_marker_after_reference_label_preserves_type_and_byte_counts(self):
        # Mac26 anonymous tree evidence confirms this reference/marker order.
        body = ("    3 (528 bytes) ROOT CYCLE: NSXPCConnection\n"
                "       2 (368 bytes) _connection --> ROOT CYCLE: xpc_connection_t\n"
                "          1 (48 bytes) ROOT CYCLE: __NSMallocBlock__\n"
                "             __strong [capture] --> CYCLE BACK TO NSXPCConnection")
        value = self.parse(grouped(3, 528, body, kind="NSXPCConnection", marker="ROOT CYCLE"))
        self.assertEqual(value["status"], "complete")
        self.assertEqual(value["type_counts"], [{"type": "NSXPCConnection", "count": 1},
            {"type": "__NSMallocBlock__", "count": 1}, {"type": "xpc_connection_t", "count": 1}])
        self.assertEqual(sum(row["size"] * row["count"] for row in value["exact_size_histogram"]), 528)

    def test_unknown_names_are_bucketed_and_private_material_never_published(self):
        text = grouped(1, 48, "    1 (48 bytes) ROOT LEAK: PrivateCustomerType", kind="PrivateCustomerType")
        value = self.parse(text)
        self.assertEqual(value["exact_size_histogram"], [{"type": "unknown", "size": 48, "count": 1}])
        payload = composition.encoded(value).decode()
        for secret in ("PrivateCustomerType", "0x1234", "synthetic_function", "Process", "synthetic-image"):
            self.assertNotIn(secret, payload)

    def test_observed_anonymous_objc_origin_shape_can_be_replayed_privately(self):
        # The reported bytes and names are opaque: this replays only the origin
        # grammar from a diagnostic fragment, not an equivalent complete tree.
        line = "                225 (opaque5.opaque6) opaque7 in -[NSXPCInterface opaque8:opaque9:]"
        fragment = composition._failure_fragment([line])
        decoded, _, _ = composition.parser_evidence.decode_document(fragment["evidence"]["documents"][0])
        for row in (line, decoded.rstrip("\n")):
            name = re.fullmatch(r" +225 \([^()]+\) (.+)", row)[1]
            self.assertEqual(composition._name(name), name)
            self.assertNotIn(name, composition.TYPES)

    def test_objc_origin_stays_unknown_and_preserves_type_counts_and_exact_bytes(self):
        for sign in ("-", "+"):
            origin = f"PrivateAllocator in {sign}[NSXPCInterface privateSelector:privateArgument:]"
            value = self.parse(array_report().replace("CFData", origin))
            self.assertEqual(value["type_counts"], [{"type": "NSMutableArray", "count": 1},
                {"type": "NSMutableArray (Storage)", "count": 1}, {"type": "unknown", "count": 1}])
            self.assertEqual(value["exact_size_histogram"], [{"type": "NSMutableArray", "size": 48, "count": 1},
                {"type": "NSMutableArray (Storage)", "size": 16, "count": 1}, {"type": "unknown", "size": 80, "count": 1}])
            self.assertEqual((value["counts_status"], value["reasons"], value["failure_fragment"]),
                             ("complete", ["unknown_type"], None))
            for private in ("PrivateAllocator", "NSXPCInterface", "privateSelector", "privateArgument"):
                self.assertNotIn(private, composition.encoded(value).decode())
            self.assertLessEqual(len(composition.encoded(value)), composition.PUBLIC_LIMIT)

    def test_objc_origin_aggregate_never_divides_subtree_bytes_into_instance_sizes(self):
        value = self.parse(grouped(226, 10848,
            "    226 (10848 bytes) ROOT LEAK: NSMutableArray\n"
            "       225 (10800 bytes) PrivateAllocator in -[PrivateClass privateSelector:]"))
        self.assertEqual(value["type_counts"], [{"type": "NSMutableArray", "count": 1}, {"type": "unknown", "count": 225}])
        self.assertEqual(value["exact_size_histogram"], [{"type": "NSMutableArray", "size": 48, "count": 1}])
        self.assertEqual(value["unresolved_sizes"], [{"type": "unknown", "count": 225,
            "bytes_min": 10800, "bytes_max": 10800, "reason": "multiple_instances"}])
        self.assertEqual((value["unknown_type_nodes"], value["size_unknown_nodes"]), (225, 225))

    def test_objc_origin_allowance_rejects_unobserved_syntax_addresses_and_bad_geometry(self):
        valid = "PrivateAllocator in -[PrivateClass privateSelector:privateArgument:]"
        invalid_names = (
            valid + " suffix", valid[:-1], valid.replace("PrivateAllocator", "allocator/path"),
            valid.replace("-[", "["), valid.replace("privateSelector:", "privateSelector::"),
            valid.replace("privateArgument:", "privateArgument"), valid.replace("PrivateClass", "0xdeadbeef"),
            valid.replace("privateSelector", "a" * 257), valid + " --> NSString", valid + "\t",
            "PrivateClass privateSelector:", "PrivateAllocator in -[PrivateClass privateSelector]",
        )
        for name in invalid_names:
            with self.subTest(name=name):
                value = self.parse(array_report().replace("CFData", name))
                self.assertEqual((value["counts_status"], value["reasons"]), ("unavailable", ["invalid_report"]))
                self.assertLessEqual(len(composition.encoded(value)), composition.PUBLIC_LIMIT)
        report = array_report().replace("CFData", valid).replace("          1 (80", "           1 (80")
        self.assertEqual(self.parse(report)["failure_stage"], "tree_shape")

    def test_full_grammar_rejects_prefix_duplicate_headers_unparsed_and_bad_counts(self):
        valid = array_report()
        suffix = valid.split("\n\n", 1)[1]
        for text in (valid.replace("STACK OF", "unparsed prefix\nSTACK OF", 1),
                     valid.replace("====", "missing boundary"), valid.replace("====", "====\n===="),
                     valid.replace("1 (80 bytes)", "2 (80 bytes)"), valid.replace("3 (144 bytes)", "4 (144 bytes)"),
                     valid.replace("1 INSTANCES", "2 INSTANCES"), valid + "unparsed suffix\n",
                     valid.replace("144 bytes) ROOT", "143 bytes) ROOT"),
                     valid.replace("          1 (80", "           1 (80"),
                     valid.replace("CFData", "CFData 0x1234"),
                     "Process 123: 6 leaks for 288 total leaked bytes.\n\n" + suffix + suffix):
            with self.subTest(text=text):
                value = self.parse(text)
                self.assertEqual((value["status"], value["counts_status"]), ("unavailable", "unavailable"))
                self.assertEqual(value["type_counts"], [])

    def test_failure_stage_is_fixed_and_identifies_rejected_structure(self):
        valid = array_report()
        reports = {
            "header": valid.replace("====", "missing boundary"),
            "tree_shape": valid.replace("          1 (80", "           1 (80"),
            "child_marker": valid.replace("2 (96 bytes) NSMutableArray", "2 (96 bytes) ROOT LEAK: NSMutableArray"),
            "backref": valid + "             CYCLE BACK TO unknown_target\n",
            "byte_bounds": valid.replace("1 (80 bytes)", "1 (145 bytes)"),
            "totals": valid.replace("3 leaks for", "4 leaks for"),
        }
        for stage, report in reports.items():
            with self.subTest(stage=stage):
                value = self.parse(report)
                self.assertEqual((value["schema"], value["failure_stage"], value["reasons"]),
                                 (3, stage, ["invalid_report"]))
                self.assertEqual(value["type_counts"], [])
                for invalid in (None, "private/path", "0x1234", 42):
                    bad = copy.deepcopy(value); bad["failure_stage"] = invalid
                    with self.assertRaises(ValueError): composition.validate_grouped_composition(bad)
        with mock.patch.object(composition, "RAW_LIMIT", 1):
            self.assertEqual(self.parse(valid)["failure_stage"], "budget")
        nodes = self.parse("Process 123: 513 leaks for 513 total leaked bytes.\n")
        self.assertEqual((nodes["reasons"], nodes["failure_stage"]), (["node_budget"], "budget"))
        for value in (self.parse(valid), composition.empty_grouped(), composition.empty_grouped("summary_budget")):
            self.assertIsNone(value["failure_stage"])
            value["failure_stage"] = "header"
            with self.assertRaises(ValueError): composition.validate_grouped_composition(value)

    def test_tree_shape_fragment_uses_reviewed_codec_without_private_text(self):
        report = array_report().replace("NSMutableArray", "CustomerTemplate")
        report = report.replace("CFData", "SecretCustomerType 0xdeadbeefcafebabe /Users/private/customer")
        value = self.parse(report)
        fragment = value["failure_fragment"]
        self.assertEqual((value["failure_stage"], value["counts_status"]), ("tree_shape", "unavailable"))
        self.assertEqual((fragment["kind"], fragment["equivalence"], fragment["offender_index"]),
                         ("diagnostic-only", "non-equivalent-fragment", 2))
        doc = fragment["evidence"]["documents"][0]
        self.assertEqual(len(doc["lines"]), 3)
        self.assertTrue(any(token[0] == "address" for token in doc["lines"][-1]))
        decoded, nodes, target = composition.parser_evidence.decode_document(doc)
        payload = composition.encoded(value).decode()
        for private in ("CustomerTemplate", "SecretCustomerType", "deadbeefcafebabe", "/Users/private/customer"):
            self.assertNotIn(private, payload)
            self.assertNotIn(private, decoded)
        self.assertEqual((nodes, target, value["type_counts"]), ({}, None, []))
        self.assertLessEqual(len(composition.encoded(fragment)), composition.FRAGMENT_LIMIT)
        self.assertLessEqual(len(composition.encoded(value)), composition.PUBLIC_LIMIT)
        pid_report = grouped(1, 48, "    1 (48 bytes) ROOT LEAK: NSMutableArray\nProcess 987654321: private_name")
        pid_value = self.parse(pid_report)
        self.assertNotIn("987654321", composition.encoded(pid_value).decode())
        self.assertIn(["pid", 0], pid_value["failure_fragment"]["evidence"]["documents"][0]["lines"][-1])

    def test_fragment_replays_offender_whitespace_without_claiming_full_tree_equivalence(self):
        report = array_report().replace("          1 (80", "\t1 (80")
        value = self.parse(report)
        fragment = value["failure_fragment"]
        doc = fragment["evidence"]["documents"][0]
        decoded, _, _ = composition.parser_evidence.decode_document(doc)
        offender = decoded.splitlines()[fragment["offender_index"]]
        self.assertTrue(offender.startswith("\t"))
        # A local row-shape replay only: byte labels and unknown names are opaque,
        # and this deliberately does not replay a complete tree or its totals.
        for line in ("\t1 (80 bytes) CFData", offender):
            with self.assertRaises(ValueError):
                composition._group_tree([line], None, None, None, 144, [])
        self.assertIsNone(self.parse(array_report())["failure_fragment"])
        self.assertIsNone(self.parse(report.replace("====", "bad boundary"))["failure_fragment"])

    def test_fragment_public_gate_rejects_extra_text_metadata_and_excess_lines(self):
        value = self.parse(array_report().replace("          1 (80", "\t1 (80"))
        mutations = (
            lambda f: f.update(raw="private"),
            lambda f: f.update(codec_context="actual-baseline"),
            lambda f: f.update(offender_index=True),
            lambda f: f["evidence"]["documents"][0].update(graph_sha256="1" * 64),
            lambda f: f["evidence"]["documents"][0].update(raw="private"),
            lambda f: f["evidence"]["documents"][0]["lines"][-1].append(["word", "PrivateCustomerType"]),
            lambda f: f["evidence"]["documents"][0]["lines"].append([]),
            lambda f: f["evidence"]["documents"][0]["lines"][-1].extend([["word", "ROOT"]] * 400),
        )
        for mutation in mutations:
            bad = copy.deepcopy(value); mutation(bad["failure_fragment"])
            with self.assertRaises(ValueError): composition.validate_grouped_composition(bad)
        success = self.parse(array_report()); success["failure_fragment"] = value["failure_fragment"]
        with self.assertRaises(ValueError): composition.validate_grouped_composition(success)

    def test_fragment_budget_omits_whole_fragment_and_preserves_original_scan_evidence(self):
        report = array_report().replace("          1 (80", "\t1 (80")
        raw = report.encode()
        groups = ci_evidence.leak_groups(report)
        entry = {"label": "baseline", "stdout_sha256": hashlib.sha256(raw).hexdigest(), "exit_code": 1,
                 "leak_nodes": 3, "leak_bytes": 144, "groups": groups,
                 "unclassified_nodes": 0, "destroyed_notification_stack_present": False}
        ordinary = ci_evidence.scan_summary("baseline", entry, raw)
        with mock.patch.object(composition, "FRAGMENT_LIMIT", 1):
            bounded = ci_evidence.scan_summary("baseline", entry, raw)
        self.assertIsNotNone(ordinary["composition"]["failure_fragment"])
        self.assertIsNone(bounded["composition"]["failure_fragment"])
        self.assertEqual((bounded["status"], bounded["binding"]), ("complete", "matched"))
        ordinary.pop("composition"); bounded.pop("composition")
        self.assertEqual(ordinary, bounded)
        for suffix in (" ROOT" * 1000, "a" * (composition.parser_evidence.LINE_LENGTH_LIMIT + 1)):
            oversized = self.parse(array_report().replace("CFData", "CFData " + suffix))
            self.assertEqual((oversized["failure_stage"], oversized["reasons"]), ("tree_shape", ["invalid_report"]))
            self.assertIsNone(oversized["failure_fragment"])

    def test_count_byte_and_budget_conservation(self):
        reports = [grouped(1, size, f"    1 ({size} bytes) ROOT LEAK: NSString", kind="NSString", frame=size)
                   for size in range(1, 257)]
        full = "Process 123: 256 leaks for 32896 total leaked bytes.\n\n" + "\n".join(report.split("\n\n", 1)[1] for report in reports)
        value = self.parse(full)
        self.assertEqual(value["counts_status"], "complete")
        self.assertEqual(value["total_nodes"], 256)
        self.assertEqual(value["omitted_nodes"], 128)
        self.assertEqual(value["status"], "partial")
        require_budget = self.parse("Process 123: 513 leaks for 513 total leaked bytes.\n")
        self.assertEqual(require_budget["reasons"], ["node_budget"])
        self.assertEqual((require_budget["type_counts"], require_budget["omitted_nodes"]), ([], 513))

    def test_histogram_preserves_unknown_and_bounded_omissions(self):
        nodes = [{"type": "NSString", "size": size} for size in range(1, 257)]
        value = composition.histogram_nodes(nodes)
        self.assertEqual(value["total_bytes"], 32896)
        self.assertEqual(value["omitted_nodes"], 128)
        self.assertEqual(sum(row["size"] * row["count"] for row in value["buckets"]) + value["omitted_bytes"], 32896)
        all_omitted = composition.histogram_nodes([{"type": "private type", "size": 1}] * 513)
        self.assertEqual((all_omitted["unknown_type_nodes"], all_omitted["omitted_nodes"], all_omitted["buckets"]), (513, 513, []))

    def test_snapshot_list_tree_binding_and_root_count(self):
        nodes = {0x1000: 64, 0x2000: 48}
        value = composition.histogram_snapshot(listing(nodes), tree(nodes, cycle=True))
        composition.validate_snapshot(value)
        self.assertEqual((value["status"], value["root_count"], value["leak_nodes"], value["leak_bytes"]), ("complete", 1, 2, 112))
        self.assertEqual(composition.histogram_snapshot(listing(nodes), tree({0x1000: 64}))["status"], "unavailable")

    def test_signed_net_counts_have_no_allocation_generation_claim(self):
        before = self.parse(grouped(2, 96, "    2 (96 bytes) ROOT LEAK: NSMutableArray", instances=2))
        after = self.parse(grouped(1, 48, "    1 (48 bytes) ROOT LEAK: NSString", kind="NSString"))
        value = composition.composition_delta(before, after)
        composition.validate_composition_delta(value, before, after)
        self.assertEqual(value["changes"], [{"type": "NSMutableArray", "count_delta": -2}, {"type": "NSString", "count_delta": 1}])
        self.assertEqual((value["net_nodes"], value["generation"]), (-1, "unknown"))
        self.assertEqual(composition.composition_delta(composition.empty_grouped(), after)["status"], "unavailable")
        value["changes"][1]["count_delta"] = True
        with self.assertRaises(ValueError): composition.validate_composition_delta(value, before, after)

    def test_public_validation_rejects_private_fields_false_totals_and_boolean_counts(self):
        value = self.parse(array_report())
        for mutation in (lambda v: v.update(raw="private"), lambda v: v.update(total_nodes=4),
                         lambda v: v.update(unknown_type_nodes=True),
                         lambda v: v["exact_size_histogram"][0].update(size=144),
                         lambda v: v["type_counts"][0].update(type="PrivateCustomerType")):
            bad = copy.deepcopy(value); mutation(bad)
            with self.assertRaises(ValueError): composition.validate_grouped_composition(bad)
        histogram = composition.histogram_nodes([{"type": "NSString", "size": 48}])
        histogram["omitted_bytes"] = 1
        with self.assertRaises(ValueError): composition.validate_histogram(histogram)


if __name__ == "__main__":
    unittest.main()
