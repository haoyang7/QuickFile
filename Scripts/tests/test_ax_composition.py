"""Self-authored grouped reports and pure composition invariants."""
import copy
from pathlib import Path
import sys
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Investigations"))
sys.path.insert(0, str(HERE))
import ax_composition as composition
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

    def test_unknown_names_are_bucketed_and_private_material_never_published(self):
        text = grouped(1, 48, "    1 (48 bytes) ROOT LEAK: PrivateCustomerType", kind="PrivateCustomerType")
        value = self.parse(text)
        self.assertEqual(value["exact_size_histogram"], [{"type": "unknown", "size": 48, "count": 1}])
        payload = composition.encoded(value).decode()
        for secret in ("PrivateCustomerType", "0x1234", "synthetic_function", "Process", "synthetic-image"):
            self.assertNotIn(secret, payload)

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
