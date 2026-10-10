import pathlib
import contextlib
import importlib.util
import io
import itertools
import os
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
INVESTIGATIONS = ROOT / "Scripts/Investigations"
SPEC = importlib.util.spec_from_file_location("verify_ax_compatibility", INVESTIGATIONS / "verify-ax-compatibility.py")
PROBE = importlib.util.module_from_spec(SPEC)
with mock.patch.object(sys, "path", [str(INVESTIGATIONS), *sys.path]):
    SPEC.loader.exec_module(PROBE)
REPORT = sys.modules["ax_probe_report"]


class AXHeapDiagnosticTests(unittest.TestCase):
    @staticmethod
    def report(count=1, size=48, kind="NSMutableArray", stack="-[NSXPCConnection initWithMachServiceName:options:]"):
        return (f"Process 123: {count} leak{'s' if count != 1 else ''} for {size * count} total leaked bytes.\n"
                + "".join(f"\nLeak: 0x{index + 4096:x}  size={size}  zone: PrivateZone_0x4321   {kind}  ObjC  Foundation\n"
                          f"\tCall stack:\n0 Foundation 0x9999 {stack} + 8\n" for index in range(count)))

    def test_singular_and_plural_reports_retain_counts_without_raw_text(self):
        for count in (1, 3):
            result = REPORT.heap_diff_summary(self.report(count))
            self.assertEqual(result["status"], "complete")
            self.assertEqual(result["groups"], [{"type": "NSMutableArray", "size": 48, "count": count}])
            self.assertEqual(result["stack_matches"]["xpc_connection"], count)
            self.assertNotIn("0x", json.dumps(result))
            self.assertNotIn("PrivateZone", json.dumps(result))

    def test_unknown_types_stacks_and_malformed_reports_are_explicit(self):
        result = REPORT.heap_diff_summary(self.report(kind="/private/user/secret", stack="secret_symbol"))
        self.assertEqual(result["groups"][0]["type"], "unknown")
        self.assertEqual(result["unknown_stack_nodes"], 1)
        self.assertEqual(result["unverified_stack_nodes"], 1)
        self.assertNotIn("secret", json.dumps(result))
        self.assertEqual(REPORT.heap_diff_summary("unsupported output")["status"], "unavailable")
        malformed = self.report().replace("Leak: 0x1000", "Unexpected: 0x1000")
        self.assertEqual(REPORT.heap_diff_summary(malformed)["status"], "partial")
        self.assertEqual(REPORT.heap_diff_summary(malformed)["unparsed_nodes"], 1)
        self.assertEqual(REPORT.heap_diff_summary(self.report().replace("48 total", "49 total"))["status"], "partial")
        missing = REPORT.heap_diff_summary(self.report(stack="").replace("0 Foundation 0x9999  + 8", "stack unavailable"))
        self.assertEqual(missing["missing_stack_nodes"], 1)

    @staticmethod
    def summary(point):
        return {"schema": 4, "status": "partial", "checkpoints": [point],
                "symbols": [], "omitted_symbols": 0, "symbols_status": "partial",
                "cohorts_status": REPORT.cohort_status([point])}

    def test_public_validator_rejects_extra_fields_unbounded_values_and_text(self):
        point = REPORT.heap_diff_summary(self.report()) | {"label": "registered-10"}
        valid = self.summary(point)
        REPORT.validate_heap_diagnostics_summary(valid)
        for mutate in (
                lambda value: value.update(path="/private/secret"),
                lambda value: value.update(status="secret"),
                lambda value: value.update(schema=True),
                lambda value: value.update(schema=2),
                lambda value: value.update(status="complete"),
                lambda value: value["checkpoints"][0].update(new_bytes=10 ** 20),
                lambda value: value["checkpoints"][0].update(label="secret"),
                lambda value: value["checkpoints"][0].update(label="baseline"),
                lambda value: value["checkpoints"][0]["groups"][0].update(type="secret"),
                lambda value: value["checkpoints"][0]["stack_matches"].update(secret=1),
                lambda value: value["checkpoints"][0]["image_nodes"].update(secret=1),
                lambda value: value["checkpoints"][0].update(missing_stack_nodes=2),
                lambda value: value.update(cohorts_status="complete"),
                lambda value: value["checkpoints"][0]["allocation_cohorts"].update(address="0x1000"),
                lambda value: value["checkpoints"][0]["allocation_cohorts"].update(status="secret"),
                lambda value: value["checkpoints"][0]["allocation_cohorts"].update(unknown_nodes=True),
                lambda value: value["checkpoints"][0]["allocation_cohorts"].update(unknown_nodes=10 ** 20),
                lambda value: value["checkpoints"][0]["allocation_cohorts"].update(unknown_nodes=2),
                lambda value: value["checkpoints"][0]["allocation_cohorts"].update(status="complete"),
                lambda value: value.update(symbols_status="complete"),
                lambda value: value["checkpoints"][0].update(groups=point["groups"] * 33)):
            invalid = json.loads(json.dumps(valid))
            mutate(invalid)
            with self.assertRaises(ValueError):
                REPORT.validate_heap_diagnostics_summary(invalid)

    def resolver(self, symbol="-[NSXPCConnection initWithMachServiceName:options:]", start=0x9991):
        resolver = object.__new__(REPORT.SystemSymbols)
        resolver.cache = {}
        resolver.library = mock.Mock()
        resolver.library.method_getImplementation.return_value = start
        resolver.library.dlsym.return_value = start
        resolver.metadata = mock.Mock(return_value=(REPORT.HEAP_IMAGES["Foundation"][1], symbol, start))
        return resolver

    def test_symbols_require_matching_system_metadata_and_are_unordered_per_node(self):
        symbol = "-[NSXPCConnection initWithMachServiceName:options:]"
        resolver = self.resolver()
        counts = {}
        report = self.report().replace("0 Foundation 0x9999", "0 com.apple.Foundation 0x9999")
        report += f"1 com.apple.Foundation 0x9999 {symbol} + 8\n"
        result = REPORT.heap_diff_summary(report, resolver=resolver, symbol_counts=counts)
        self.assertEqual(counts, {("Foundation", symbol): 1})
        self.assertEqual(result["image_nodes"]["Foundation"], 1)
        self.assertEqual(result["unverified_stack_nodes"], 0)
        point = result | {"label": "registered-10"}
        summary = self.summary(point) | {"symbols": [{"image": "Foundation", "symbol": symbol,
                                                     "nodes": {"registered-10": 1}}]}
        with mock.patch.object(REPORT, "SystemSymbols", return_value=resolver):
            REPORT.validate_heap_diagnostics_summary(summary)
            # A syntactically plausible name still needs independent lookup.
            summary["symbols"][0]["symbol"] = "CustomerSecret"
            with self.assertRaises(ValueError):
                REPORT.validate_heap_diagnostics_summary(summary)

    def test_unverified_symbols_never_fall_back_to_report_text(self):
        symbol = "-[NSXPCConnection initWithMachServiceName:options:]"
        foundation = REPORT.HEAP_IMAGES["Foundation"][1]
        for metadata in (("/private/user/Foundation", symbol, 0x9991),
                         (foundation, "OtherSymbol", 0x9991), (foundation, symbol, 0x9990), None):
            with self.subTest(metadata=metadata):
                resolver = self.resolver()
                resolver.metadata.return_value = metadata
                counts = {}
                result = REPORT.heap_diff_summary(self.report(), resolver=resolver, symbol_counts=counts)
                self.assertEqual(counts, {})
                self.assertEqual(result["unverified_stack_nodes"], 1)
        for raw_symbol in ("private/path", "0x123456", "name " * 40, "Secret<Template>", "-[Secret token:]\nprivate"):
            with self.subTest(symbol=raw_symbol):
                resolver = self.resolver(raw_symbol)
                self.assertFalse(resolver.verified("Foundation", raw_symbol, 0x9999, 8))
                resolver.metadata.assert_not_called()
        resolver = self.resolver()
        self.assertFalse(resolver.verified("Foundation", symbol, 0x9999, 7))
        self.assertFalse(resolver.verified("PrivateFoundation", symbol, 0x9999, 8))

    @unittest.skipUnless(sys.platform == "darwin", "requires Apple system symbol metadata")
    def test_actual_system_symbol_lookup_at_collection_and_public_gate(self):
        resolver = REPORT.SystemSymbols()
        for image, symbol in (("CoreFoundation", "CFArrayCreate"),
                              ("Foundation", "-[NSXPCConnection initWithMachServiceName:options:]")):
            with self.subTest(symbol=symbol):
                address = resolver.lookup(image, symbol)
                self.assertIsNotNone(address)
                self.assertTrue(resolver.verified(image, symbol, address, 0))
                counts = {}
                report = self.report(stack=symbol).replace("Foundation 0x9999", f"{REPORT.HEAP_IMAGES[image][0]} 0x{address:x}").replace(" + 8", " + 0")
                point = REPORT.heap_diff_summary(report, resolver=resolver, symbol_counts=counts) | {"label": "added-10"}
                summary = self.summary(point) | {"symbols": [{"image": image, "symbol": symbol, "nodes": {"added-10": 1}}]}
                REPORT.validate_heap_diagnostics_summary(summary)

    def test_aggregation_has_a_global_row_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for label in REPORT.HEAP_LABELS:
                (root / f"{label}.memgraph").touch()
            report = "Process 123: 40 leaks for 820 total leaked bytes.\n" + "".join(
                f"\nLeak: 0x{index + 4096:x}  size={index}  zone: zone   unknown\n" for index in range(1, 41))
            with mock.patch.object(REPORT.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, report, "")):
                REPORT.collect_heap_diagnostics(root, root)
            summary = json.loads((root / "heap-diagnostics.json").read_text())
            REPORT.validate_heap_diagnostics_summary(summary)
            self.assertEqual(summary["status"], "partial")
            self.assertEqual(sum(len(point["groups"]) for point in summary["checkpoints"]), 32)
            self.assertLessEqual((root / "heap-diagnostics.json").stat().st_size, 16 * 1024)

    def test_symbol_dictionary_has_a_global_budget_and_checkpoint_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for label in REPORT.HEAP_LABELS:
                (root / f"{label}.memgraph").touch()
            report = self.report(stack="_function0") + "".join(
                f"{index} com.apple.Foundation 0x9999 _function{index} + 8\n" for index in range(1, 30))
            resolver = mock.Mock()
            with mock.patch.object(REPORT.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, report, "")), \
                    mock.patch.object(REPORT, "SystemSymbols", return_value=resolver):
                REPORT.collect_heap_diagnostics(root, root)
                summary = json.loads((root / "heap-diagnostics.json").read_text())
                REPORT.validate_heap_diagnostics_summary(summary)
            self.assertEqual(len(summary["symbols"]), 24)
            self.assertEqual(summary["omitted_symbols"], 6)
            self.assertEqual(summary["symbols_status"], "partial")
            self.assertEqual(summary["symbols"][0]["nodes"], dict.fromkeys(REPORT.HEAP_LABELS[1:], 1))
            self.assertLessEqual((root / "heap-diagnostics.json").stat().st_size, 16 * 1024)


class AXAllocationCohortTests(unittest.TestCase):
    @staticmethod
    def heap(nodes):
        return (f"All zones: {len(nodes)} nodes malloced - Sizes:\n"
                + "".join(f"0x{address:x}: private type ({size} bytes)\n" for address, size in nodes.items()))

    @staticmethod
    def history(events):
        return "malloc_history Report Version:  2.0\n" + "".join(
            f"{kind} 0x{address:x}-0x{address + size - 1:x} [size={size}]: private allocation stack\n"
            for kind, address, size in events)

    def test_complete_heap_lists_reject_missing_duplicate_and_malformed_rows(self):
        report = self.heap({0x1000: 48, 0x2000: 80})
        self.assertEqual(REPORT.heap_allocations(report), {0x1000: 48, 0x2000: 80})
        self.assertEqual(REPORT.heap_allocations(self.heap({})), {})
        for invalid in ("", report.replace("2 nodes", "3 nodes"),
                        report.replace("0x2000", "0x1000"), report.replace("(80 bytes)", "(truncated")):
            self.assertIsNone(REPORT.heap_allocations(invalid))
        with mock.patch.object(REPORT, "REPORT_BYTE_LIMIT", 10):
            self.assertIsNone(REPORT.heap_allocations(report))

    def test_histories_distinguish_same_generation_from_same_address_reuse(self):
        before = self.history([("ALLOC", 0x1000, 48)])
        # Reuse at the same address, size and allocation stack is a new generation.
        after = before + self.history([("FREE", 0x1000, 48), ("ALLOC", 0x1000, 48)]).split("\n", 1)[1]
        first = REPORT.allocation_history(before, [0x1000])[0x1000]
        second = REPORT.allocation_history(after, [0x1000])[0x1000]
        self.assertEqual(REPORT.allocation_generation(first, first, 48, 48), "preexisting_nodes")
        self.assertEqual(REPORT.allocation_generation(first, second, 48, 48), "new_allocation_nodes")
        self.assertIsNone(REPORT.allocation_generation(second, first, 48, 48))
        self.assertIsNone(REPORT.allocation_generation({}, first, 48, 48))
        self.assertIsNone(REPORT.allocation_generation(first, first, 80, 48))
        for invalid in ("", before[:-10], before.replace("size=48", "size=47"), before + "history truncated\n"):
            self.assertIsNone(REPORT.allocation_history(invalid, [0x1000]))
        with mock.patch.object(REPORT, "REPORT_BYTE_LIMIT", 10):
            self.assertIsNone(REPORT.allocation_history(before, [0x1000]))

    def collect(self, nodes, before, new, old_events=(), new_events=(), failure=None, clock=None):
        report = f"Process 123: {len(nodes)} leaks for {sum(nodes.values())} total leaked bytes.\n" + "".join(
            f"\nLeak: 0x{address:x}  size={size}  zone: private   unknown\n" for address, size in nodes.items())
        point = REPORT.heap_diff_summary(report) | {"label": "added-10"}
        commands = []

        def run(command, **kwargs):
            commands.append((command, kwargs))
            self.assertLessEqual(kwargs["timeout"], 15)
            if failure:
                raise failure
            if command[0] == "heap":
                output = self.heap(before if command[-1].endswith("baseline.memgraph") else new)
            else:
                self.assertLessEqual(len(command) - 2, REPORT.COHORT_ADDRESS_LIMIT)
                output = self.history(old_events if command[1].endswith("baseline.memgraph") else new_events)
            return subprocess.CompletedProcess(command, 0, output, "")

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(REPORT.subprocess, "run", side_effect=run), \
                mock.patch.object(REPORT.time, "monotonic", side_effect=clock or itertools.repeat(0)):
            REPORT.collect_allocation_cohorts(pathlib.Path(directory), [point], {"added-10": report})
        summary = AXHeapDiagnosticTests.summary(point)
        REPORT.validate_heap_diagnostics_summary(summary)
        self.assertNotIn("0x", json.dumps(summary))
        self.assertNotIn("private", json.dumps(summary))
        return point["allocation_cohorts"], commands

    def test_old_reachability_new_allocations_and_reuse_are_separate(self):
        old = [("ALLOC", 0x1000, 48), ("ALLOC", 0x2000, 80)]
        after = old + [("FREE", 0x2000, 80), ("ALLOC", 0x2000, 80)]
        result, commands = self.collect({0x1000: 48, 0x2000: 80, 0x3000: 96},
                                       {0x1000: 48, 0x2000: 80}, {0x2000: 80, 0x3000: 96}, old, after)
        self.assertEqual(result, {"status": "complete", "preexisting_nodes": 1,
                                  "new_allocation_nodes": 2, "unknown_nodes": 0})
        histories = [command for command, _ in commands if command[0] == "malloc_history"]
        self.assertEqual(histories[0][2:], histories[1][2:])

    def test_missing_history_or_disagreeing_heap_diff_never_certifies_identity(self):
        old = [("ALLOC", 0x1000, 48)]
        for new, before_history, after_history in (({}, (), ()), ({0x1000: 48}, old, old),
                                                  ({}, old, old + [("FREE", 0x1000, 48), ("ALLOC", 0x1000, 48)])):
            result, _ = self.collect({0x1000: 48}, {0x1000: 48}, new, before_history, after_history)
            self.assertEqual(result, REPORT.empty_cohorts(1))

    def test_tools_unavailable_timeout_and_shared_deadline_are_explicit(self):
        for failure in (OSError("unavailable"), subprocess.TimeoutExpired("heap", 15)):
            result, _ = self.collect({0x1000: 48}, {}, {0x1000: 48}, failure=failure)
            self.assertEqual(result, REPORT.empty_cohorts(1))
        result, commands = self.collect({0x1000: 48}, {}, {0x1000: 48}, clock=iter([0, 40, 46]))
        self.assertEqual(result, REPORT.empty_cohorts(1))
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0][1]["timeout"], 5)

    def test_address_budget_retains_unknown_nodes_and_zero_diff_needs_no_tools(self):
        nodes = {0x1000 + index: 48 for index in range(REPORT.COHORT_ADDRESS_LIMIT + 2)}
        result, _ = self.collect(nodes, {}, nodes)
        self.assertEqual(result, {"status": "partial", "preexisting_nodes": 0,
                                  "new_allocation_nodes": REPORT.COHORT_ADDRESS_LIMIT, "unknown_nodes": 2})
        result, commands = self.collect({}, {}, {})
        self.assertEqual(result, REPORT.empty_cohorts(0))
        self.assertEqual(commands, [])

    def test_oversized_public_summary_is_rejected_even_with_valid_symbols(self):
        points = [REPORT.heap_diff_summary(AXHeapDiagnosticTests.report()) | {"label": label}
                  for label in REPORT.HEAP_LABELS[1:]]
        summary = {"schema": 4, "status": "complete", "checkpoints": points,
                   "symbols": [{"image": "Foundation", "symbol": "_" + str(index) + "x" * 125,
                                "nodes": dict.fromkeys(REPORT.HEAP_LABELS[1:], 1)} for index in range(24)],
                   "omitted_symbols": 0, "symbols_status": "partial", "cohorts_status": "unavailable"}
        for point in points:
            point.update(status="partial", new_nodes=1_000_000_000, new_bytes=1_000_000_000,
                         classified_nodes=1_000_000_000, unknown_stack_nodes=1_000_000_000,
                         missing_stack_nodes=1_000_000_000, unverified_stack_nodes=1_000_000_000)
            point["allocation_cohorts"] = REPORT.empty_cohorts(1_000_000_000)
            point["image_nodes"] = dict.fromkeys(REPORT.HEAP_IMAGES, 1_000_000_000)
            point["stack_matches"] = dict.fromkeys(REPORT.HEAP_STACK_PATTERNS, 1_000_000_000)
            point["groups"] = [{"type": "NSMutableArray (Storage)", "size": 1_000_000_000, "count": 1_000_000_000}] * 5
        for symbol in summary["symbols"]:
            symbol["nodes"] = dict.fromkeys(REPORT.HEAP_LABELS[1:], 1_000_000_000)
        for point in points[:2]:
            point["groups"].append(point["groups"][0])
        summary["omitted_symbols"] = 1_000_000_000
        summary["status"] = "partial"
        with mock.patch.object(REPORT, "SystemSymbols", return_value=mock.Mock()):
            self.assertGreater(len(json.dumps(summary)), 16 * 1024)
            with self.assertRaises(ValueError):
                REPORT.validate_heap_diagnostics_summary(summary)


class AXCompatibilityPreflightTests(unittest.TestCase):
    def test_only_the_actual_reader_controls_accessibility_preflight(self):
        for host_trusted in (False, True):
            for reader_trusted in (False, True):
                with self.subTest(host=host_trusted, reader=reader_trusted):
                    host = {"enabled": True, "status": "enabled", "trusted": host_trusted}
                    reason = PROBE.preflight_reason(host, {"trusted": reader_trusted})
                    self.assertEqual(reason, None if reader_trusted else "reader-not-trusted")

    def test_unknown_images_and_reader_permission_are_distinct(self):
        host = {"enabled": False, "status": "unsupported-images"}
        self.assertEqual(PROBE.preflight_reason(host, {"trusted": True}), "unsupported-images")
        host = {"enabled": False, "status": "system-baseline"}
        self.assertEqual(PROBE.preflight_reason(host, {"trusted": False}, system_baseline=True), "reader-not-trusted")
        self.assertIsNone(PROBE.preflight_reason(host, {"trusted": True}, system_baseline=True))

    def test_installation_failures_and_invalid_reader_receipts_do_not_skip(self):
        for status in ("unsupported-call-site", "unsupported-array-methods", "non-system-methods", "disabled-at-startup"):
            with self.subTest(status=status), self.assertRaises(RuntimeError):
                PROBE.preflight_reason({"enabled": False, "status": status}, {"trusted": False})
        with self.assertRaises(RuntimeError):
            PROBE.preflight_reason({"enabled": True, "status": "enabled"}, {"trusted": "true"})
        with self.assertRaises(RuntimeError):
            PROBE.preflight_reason({"enabled": True, "status": "enabled"}, {"trusted": True}, system_baseline=True)


class AXCompatibilityHeapValidationTests(unittest.TestCase):
    @staticmethod
    def scan(nodes=0, byte_count=0, root_type="NSXPCConnection", ax=False):
        return {"leak_nodes": nodes, "leak_bytes": byte_count,
                "destroyed_notification_stack_present": ax, "unclassified_nodes": 0,
                "groups": [{"root_type": root_type, "root_instances": 1, "tree_nodes": nodes}] if nodes else []}

    def test_zero_heap_and_stable_xpc_baseline_are_reported_separately(self):
        empty = self.scan()
        PROBE.validate_product_scan(empty)
        PROBE.validate_product_scan(empty, empty)
        baseline = self.scan(288, 18_816)
        PROBE.validate_product_scan(baseline)
        PROBE.validate_product_scan(self.scan(288, 18_816), baseline)
        self.assertEqual(baseline["leak_nodes"], 288)

    def test_target_ax_and_unclassified_or_unexpected_roots_fail(self):
        for value in (self.scan(1, 32, ax=True), self.scan(1, 32, root_type="__NSArrayM"),
                      self.scan() | {"unclassified_nodes": 1}):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                PROBE.validate_product_scan(value)

    def test_non_ax_growth_cannot_be_hidden_as_a_startup_baseline(self):
        baseline = self.scan(288, 18_816)
        for value in (self.scan(289, 18_816), self.scan(288, 18_832),
                      self.scan(288, 18_816) | {"groups": [{"root_type": "NSXPCConnection", "root_instances": 2}]}):
            with self.subTest(value=value), self.assertRaises(RuntimeError) as failure:
                PROBE.validate_product_scan(value, baseline)
            self.assertIn(f"baseline={baseline}", str(failure.exception))
            self.assertIn(f"current={value}", str(failure.exception))

    def test_real_leaks_cycle_label_is_parsed_as_its_class(self):
        text = "STACK OF 3 INSTANCES OF 'ROOT CYCLE: NSXPCConnection':\n  288 (18.4K) ROOT CYCLE: <NSXPCConnection>\n"
        groups = PROBE.leak_groups(text)
        self.assertEqual(groups[0]["root_type"], "NSXPCConnection")
        self.assertEqual(groups[0]["root_kind"], "CYCLE")
        entry = self.scan(288, 18_816) | {"groups": groups}
        PROBE.validate_product_scan(entry, entry)
        with self.assertRaises(RuntimeError):
            PROBE.validate_product_scan(entry | {"groups": PROBE.leak_groups(text.replace("NSXPCConnection", "UnexpectedConnection"))})


class AXCompatibilityNotificationTests(unittest.TestCase):
    def test_extra_application_notifications_do_not_hide_per_button_coverage(self):
        receipt = {"notifications": 200, "all_notifications": 204, "unmatched_notifications": 4,
                   "tracked_buttons": 100, "target_notification_counts": [[1, 1] for _ in range(100)]}
        PROBE.validate_notifications(receipt, 100)
        # The aggregate still equals 200: a missing delivery cannot be replaced by
        # a duplicate from another observer or by application-level notifications.
        for deliveries in ([[0, 2]], [[1, 1], [1, 0]]):
            invalid = receipt | {"target_notification_counts": deliveries + [[1, 1]] * (100 - len(deliveries))}
            with self.subTest(deliveries=deliveries), self.assertRaises(RuntimeError):
                PROBE.validate_notifications(invalid, 100)
        with self.assertRaises(RuntimeError):
            PROBE.validate_notifications(receipt | {"all_notifications": 205}, 100)

    def test_read_only_tracks_all_buttons_without_any_notification(self):
        receipt = {"notifications": 0, "all_notifications": 0, "unmatched_notifications": 0,
                   "tracked_buttons": 100, "target_notification_counts": [[] for _ in range(100)]}
        PROBE.validate_notifications(receipt, 100, read_only=True)


class AXCompatibilityLifecycleTests(unittest.TestCase):
    """Inject process/scan results while exercising the real runner protocol."""

    def exercise_runner(self, *, failed_scan=None, invalid_notifications=False,
                        system_baseline=False, insufficient_compensation=False, ownership_trace=False,
                        heap_diagnostics=False, unavailable_cohorts=False):
        with tempfile.TemporaryDirectory(prefix="ax-protocol-") as directory:
            temporary = pathlib.Path(directory).resolve()
            work = temporary / "fixture"
            records = temporary / "records"
            state = work / "state"
            host_state = {"pid": 1234, "sequence": 0, "buttons": 0, "allocatedButtons": 0,
                          "destroyedButtons": 0, "compensations": 0, "mutableCompensations": 0}
            if ownership_trace:
                host_state["ownership"] = {"duplicateLiveAddresses": 0, "offMainHits": 0, "created": 1, "live": 1}
            notifications = {"notifications": 60, "all_notifications": 60, "unmatched_notifications": 0,
                             "tracked_buttons": 30, "target_notification_counts": [[1, 1] for _ in range(30)]}
            if invalid_notifications == "missing-count":
                del notifications["notifications"]
            elif invalid_notifications:
                notifications["target_notification_counts"][0] = [0, 2]
            scan_labels = (["baseline", "removed-10", "removed-30", "observer-exited"] if system_baseline else
                           ["baseline", "registered-10", "removed-10", "removed-20", "removed-30", "observer-exited"])
            if heap_diagnostics:
                scan_labels.insert(1, "added-10")
            scanned = []
            commands = []
            processes = []

            class FixtureProcess:
                returncode = None

                def __init__(self, command, **_kwargs):
                    self.is_reader = pathlib.Path(command[0]).name == "ax-reader"
                    if not self.is_reader:
                        environment = _kwargs["env"]
                        assert environment["MallocStackLoggingNoCompact"] == "1"
                        assert ("MallocStackLogging" in environment) == (not heap_diagnostics)
                    self.pid = 1235 if self.is_reader else 1234
                    processes.append(self)

                def poll(self):
                    return self.returncode

                def wait(self, timeout):
                    self.returncode = 0
                    if self.is_reader:
                        PROBE.write_json(state / "reader-completed.json", notifications)
                    return 0

            def run(command, **_kwargs):
                commands.append(command)
                output = ""
                if "--capabilities" in command:
                    capability = {"trusted": True} if pathlib.Path(command[0]).name == "ax-reader" else {
                        "enabled": not system_baseline, "status": "system-baseline" if system_baseline else "enabled",
                        "images": {"AppKit": "synthetic", "CoreFoundation": "synthetic"}}
                    output = json.dumps(capability)
                elif command[0] == "heap" and unavailable_cohorts:
                    raise OSError("allocation tool unavailable")
                elif command[0] == "leaks":
                    capture = next((value for value in command if value.startswith("--outputGraph=")), None)
                    if capture:
                        self.assertIn("--fullStackHistory", command)
                        pathlib.Path(capture.split("=", 1)[1]).touch()
                        return subprocess.CompletedProcess(command, 0, "", "")
                    if "--list" in command:
                        self.assertTrue(all(process.returncode == 0 for process in processes))
                        if unavailable_cohorts:
                            return subprocess.CompletedProcess(command, 1, AXHeapDiagnosticTests.report(), "")
                        return subprocess.CompletedProcess(command, 0, "Process 1234: 0 leaks for 0 total leaked bytes.\n", "")
                    label = scan_labels[len(scanned)]
                    scanned.append(label)
                    if label in ("added-10", "registered-10"):
                        reader_command = json.loads((state / "reader-command.json").read_text())
                        self.assertEqual(reader_command["sequence"], 2 if label == "registered-10" else 1)
                        self.assertEqual(host_state["destroyedButtons"], 0)
                    nodes, size = (287, 18_768) if label == failed_scan else (280, 18_416)
                    output = (f"Process 1234: {nodes} leaks for {size} total leaked bytes.\n"
                              "STACK OF 3 INSTANCES OF 'ROOT CYCLE: NSXPCConnection':\n"
                              f"  {nodes} ({size} bytes) ROOT CYCLE: NSXPCConnection\n")
                return subprocess.CompletedProcess(command, 1 if command[0] == "leaks" else 0, output, "")

            def wait_json(path, predicate, _processes):
                if path.name == "reader-ready.json":
                    command = json.loads((state / "reader-command.json").read_text())
                    receipt = {"sequence": command["sequence"], "buttons": host_state["buttons"],
                               "registrations": host_state["buttons"] * 2,
                               "notifications": host_state["destroyedButtons"] * 2}
                else:
                    command_path = state / "command.json"
                    if command_path.exists():
                        command = json.loads(command_path.read_text())
                        host_state.update(sequence=command["sequence"], action=command["action"])
                        if command["action"] == "add":
                            host_state["buttons"] = 10
                            host_state["allocatedButtons"] += 10
                        elif command["action"] == "remove":
                            host_state["buttons"] = 0
                            host_state["destroyedButtons"] += 10
                            if not system_baseline:
                                host_state["compensations"] += 20
                                host_state["mutableCompensations"] += 10
                                if insufficient_compensation and host_state["destroyedButtons"] == 30:
                                    host_state["compensations"] -= 1
                    receipt = dict(host_state)
                self.assertTrue(predicate(receipt))
                return receipt

            # The real source hashes are retained; only the allowed work root and
            # external processes/time are substituted. No GUI or AX is invoked.
            class ProbeRoot:
                def __truediv__(self, child):
                    return temporary if child == ".build/Temporary" else ROOT / child

            arguments = ["verify-ax-compatibility.py", "--work-directory", str(work), "--records-directory", str(records)]
            if system_baseline:
                arguments.append("--system-baseline")
            if ownership_trace:
                arguments.append("--ownership-trace")
            if heap_diagnostics:
                arguments.append("--heap-diagnostics")
            with mock.patch.object(sys, "argv", arguments), mock.patch.object(PROBE, "ROOT", ProbeRoot()), \
                    mock.patch.object(PROBE.subprocess, "run", side_effect=run), \
                    mock.patch.object(PROBE.subprocess, "Popen", side_effect=FixtureProcess), \
                    mock.patch.object(PROBE, "wait_json", side_effect=wait_json), \
                    mock.patch.object(PROBE.os, "uname", return_value=mock.Mock(machine="arm64")), \
                    mock.patch.object(PROBE, "disassemble_symbols", return_value={"source": "owned mock"}) as disassembled, \
                    mock.patch.object(PROBE.time, "sleep"), \
                    mock.patch.object(PROBE.time, "monotonic", side_effect=itertools.count(step=0.25)), \
                    contextlib.redirect_stdout(io.StringIO()):
                exit_code = PROBE.main()
            summary = json.loads((records / "result.json").read_text())
            self.assertEqual(scanned, scan_labels)
            self.assertEqual(json.loads((records / "notifications.json").read_text()), notifications)
            self.assertTrue((state / "stop-reader").exists())
            self.assertTrue((state / "quit").exists())
            self.assertTrue(all(process.returncode == 0 for process in processes))
            self.assertEqual(summary["scans"][0]["label"], "baseline")
            scans = json.loads((records / "scans.json").read_text())
            if heap_diagnostics:
                diagnostic = json.loads((records / "heap-diagnostics.json").read_text())
                REPORT.validate_heap_diagnostics_summary(diagnostic)
                self.assertEqual(diagnostic["status"], "complete")
                self.assertEqual(diagnostic["cohorts_status"], "unavailable" if unavailable_cohorts else "complete")
                live_scans = [command for command in commands if command[0] == "leaks" and command[-1] == "1234"]
                self.assertEqual(len(live_scans), len(scan_labels))
                self.assertTrue(all(any(value.startswith("--outputGraph=") for value in command) for command in live_scans))
                self.assertEqual([point["label"] for point in diagnostic["checkpoints"]], list(REPORT.HEAP_LABELS[1:]))
            self.assertEqual(scans[0]["host"]["allocatedButtons"], 0)
            self.assertEqual(scans[-1]["host"]["destroyedButtons"], 30)
            if system_baseline:
                self.assertEqual(summary["instrumented"], ownership_trace)
                host_build = next(command for command in commands if "-fobjc-arc" in command)
                self.assertEqual("-DQUICKFILE_AX_OWNERSHIP_PROBE=1" in host_build, ownership_trace)
                self.assertTrue(all(command[-1] == "1234" for command in commands if command[0] == "leaks"))
                if ownership_trace:
                    disassembled.assert_called_once_with(state, work, records)
                    self.assertEqual(summary["ownership"], host_state["ownership"])
                else:
                    disassembled.assert_not_called()
            if not system_baseline:
                registered = next(scan for scan in scans if scan["label"] == "registered-10")
                self.assertEqual(registered["host"]["allocatedButtons"], 10)
                self.assertEqual(registered["host"]["destroyedButtons"], 0)
            if exit_code:
                self.assertEqual(json.loads((records / "validation-errors.json").read_text()), summary["validation_errors"])
            return exit_code, summary

    def test_stable_heap_completes_every_lifecycle_checkpoint(self):
        exit_code, summary = self.exercise_runner()
        self.assertEqual(exit_code, 0)
        self.assertEqual(summary["coverage"], "passed")
        self.assertEqual(summary["ax_leak_nodes"], 0)
        self.assertNotIn("validation_errors", summary)

    def test_diagnostics_capture_once_per_stage_and_preserve_heap_failure(self):
        for stage in ("added-10", "registered-10"):
            with self.subTest(stage=stage):
                exit_code, summary = self.exercise_runner(failed_scan=stage, heap_diagnostics=True)
                self.assertEqual(exit_code, 1)
                self.assertEqual(summary["coverage"], "failed")
                self.assertIsNone(summary["ax_leak_nodes"])
                self.assertEqual([error["stage"] for error in summary["validation_errors"]], [stage])

    def test_allocation_tool_failure_does_not_replace_product_exit_code(self):
        for stage in (None, "registered-10"):
            with self.subTest(stage=stage):
                exit_code, summary = self.exercise_runner(failed_scan=stage, heap_diagnostics=True, unavailable_cohorts=True)
                self.assertEqual(exit_code, int(stage is not None))
                self.assertEqual(summary["coverage"], "failed" if stage else "passed")

    def test_intermediate_growth_still_fails_after_heap_returns_to_baseline(self):
        for label in ("registered-10", "removed-10", "removed-20", "removed-30", "observer-exited"):
            with self.subTest(label=label):
                exit_code, summary = self.exercise_runner(failed_scan=label)
                self.assertEqual(exit_code, 1)
                self.assertEqual(summary["coverage"], "failed")
                self.assertIsNone(summary["ax_leak_nodes"])
                self.assertEqual([error["stage"] for error in summary["validation_errors"]], [label])

    def test_heap_failure_does_not_skip_per_button_notification_validation(self):
        exit_code, summary = self.exercise_runner(failed_scan="removed-30", invalid_notifications=True)
        self.assertEqual(exit_code, 1)
        self.assertEqual([error["stage"] for error in summary["validation_errors"]], ["removed-30", "notifications"])

    def test_invalid_notifications_preserve_the_exit_scan_and_fail_both_modes(self):
        for baseline in (False, True):
            for invalid in (True, "missing-count"):
                with self.subTest(system_baseline=baseline, invalid=invalid):
                    exit_code, summary = self.exercise_runner(invalid_notifications=invalid, system_baseline=baseline)
                    self.assertEqual(exit_code, 1)
                    self.assertEqual(summary["coverage"], "failed")
                    self.assertEqual([error["stage"] for error in summary["validation_errors"]], ["notifications"])

    def test_system_baseline_still_measures_growth_without_claiming_product_coverage(self):
        for ownership_trace in (False, True):
            with self.subTest(ownership_trace=ownership_trace):
                exit_code, summary = self.exercise_runner(failed_scan="removed-30", system_baseline=True,
                                                         ownership_trace=ownership_trace)
                self.assertEqual(exit_code, 0)
                self.assertEqual(summary["coverage"], "measured")
                self.assertFalse(summary["product_compensation_enabled"])
                self.assertNotIn("are separate trials", summary["scope"])
                if ownership_trace:
                    self.assertIn("ownership tracking and heap scans use the same instrumented host", summary["scope"])
                    self.assertIn("an uninstrumented heap control requires a separate run", summary["scope"])
                else:
                    self.assertIn("heap scans use an uninstrumented host", summary["scope"])
                    self.assertIn("ownership tracking requires a separate run", summary["scope"])

    def test_insufficient_compensation_preserves_evidence_and_fails(self):
        exit_code, summary = self.exercise_runner(insufficient_compensation=True)
        self.assertEqual(exit_code, 1)
        self.assertEqual(summary["coverage"], "failed")
        self.assertEqual(summary["ordinary_compensations"], 29)
        self.assertEqual([error["stage"] for error in summary["validation_errors"]], ["compensation-branches"])


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "requires macOS SDK")
class AXCompatibilityCopyTests(unittest.TestCase):
    def run_fixture(self, reject_image=False, disable_environment=False, disable_argument=False):
        with tempfile.TemporaryDirectory(prefix="ax-copy-") as directory:
            work = pathlib.Path(directory)
            source = ROOT / "QuickFileApp/AXCompatibility.m"
            if reject_image:
                contents = source.read_text()
                for expected in ("{0x93,0x4e,0x31,0x29", "{0xb6,0xb4,0xbd,0xad"):
                    self.assertEqual(contents.count(expected), 1)
                    contents = contents.replace(expected, "{0x00" + expected[5:])
                source = work / "UnsupportedImage.m"
                source.write_text(contents)
            binary = work / "copy-tests"
            subprocess.run([
                "xcrun", "clang", "-fno-objc-arc", "-O2", "-framework", "AppKit",
                "-I", str(ROOT / "QuickFileApp"), str(source),
                str(ROOT / "Scripts/tests/fixtures/AXCompatibilityCopies.m"),
                "-o", str(binary),
            ], check=True, capture_output=True, text=True, timeout=60)
            environment = dict(os.environ)
            environment.pop("QUICKFILE_DISABLE_AX_COMPATIBILITY", None)
            arguments = [str(binary)]
            if disable_environment:
                environment["QUICKFILE_DISABLE_AX_COMPATIBILITY"] = "1"
            if disable_argument:
                arguments.append("--disable-ax-compatibility")
            if reject_image or disable_environment or disable_argument:
                arguments.append("--expect-disabled")
            result = subprocess.run(arguments, env=environment, check=True, capture_output=True,
                                    text=True, timeout=30)
            self.assertIn("2000 concurrent copy/mutableCopy ownership checks passed", result.stdout)
            if reject_image:
                self.assertIn("compatibility=0", result.stdout)
            if disable_environment or disable_argument:
                self.assertIn("compatibility=0", result.stdout)
                self.assertIn("status=disabled-at-startup", result.stdout)

    def test_startup_environment_can_disable_compensation(self):
        self.run_fixture(disable_environment=True)

    def test_startup_argument_can_disable_compensation(self):
        self.run_fixture(disable_argument=True)

    def test_real_destroyed_notifications_cover_both_compensation_branches(self):
        temporary_root = ROOT / ".build/Temporary"
        temporary_root.mkdir(parents=True, exist_ok=True)
        parent = pathlib.Path(tempfile.gettempdir()).resolve()
        if not parent.is_relative_to(temporary_root):
            parent = temporary_root
        with tempfile.TemporaryDirectory(prefix="ax-notifications-", dir=parent) as directory:
            work = pathlib.Path(directory)
            records = pathlib.Path(os.environ.get("QUICKFILE_AX_TEST_RECORDS", work / "records"))
            result = subprocess.run([
                sys.executable, str(ROOT / "Scripts/Investigations/verify-ax-compatibility.py"),
                "--work-directory", str(work / "fixture"), "--records-directory", str(records)
            ], capture_output=True, text=True, timeout=300)
            if result.returncode == 77:
                self.skipTest("AX notification coverage unavailable: " + result.stdout.strip())
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            receipt = json.loads((records / "result.json").read_text())
            self.assertEqual(receipt["coverage"], "passed")
            self.assertEqual(receipt["notifications"], 60)
            self.assertGreaterEqual(receipt["ordinary_compensations"], 30)
            self.assertGreaterEqual(receipt["mutable_compensations"], 30)
            self.assertEqual(receipt["ax_leak_nodes"], 0)
            self.assertLessEqual(receipt["leak_nodes"], receipt["baseline_leak_nodes"])
            self.assertLessEqual(receipt["leak_bytes"], receipt["baseline_leak_bytes"])

    def test_unrelated_copy_ownership_and_concurrency(self):
        self.run_fixture()

    def test_unknown_system_image_does_not_enable_patch(self):
        self.run_fixture(reject_image=True)
