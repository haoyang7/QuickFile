import pathlib
import contextlib
import copy
import hashlib
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
EXTERNAL = sys.modules["ax_external_receipt"]
PROCESSES = sys.modules["ax_process"]
with mock.patch.object(sys, "path", [str(INVESTIGATIONS), *sys.path]):
    import ax_lifecycle_acceptance as LIFECYCLE


def notification_records(work, copy_lifetime=False):
    configured = os.environ.get("QUICKFILE_AX_TEST_RECORDS")
    if configured is None:
        return work / "records"
    records = pathlib.Path(configured)
    return records.with_name(records.name + "-copy-lifetime") if copy_lifetime else records


class AXCompatibilityRecordDirectoryTests(unittest.TestCase):
    def test_configured_modes_have_independent_directories_in_either_order(self):
        for order in ((False, True), (True, False)):
            with self.subTest(order=order), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                configured = root / "records"
                with mock.patch.dict(os.environ, {"QUICKFILE_AX_TEST_RECORDS": str(configured)}):
                    paths = [notification_records(root / "fixture", copy_lifetime=mode) for mode in order]
                for path in paths:
                    path.mkdir(parents=True, exist_ok=False)
                self.assertEqual(set(paths), {configured, root / "records-copy-lifetime"})

    def test_default_records_remain_inside_each_independent_fixture_directory(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            for mode in (False, True):
                work = pathlib.Path("fixture-lifetime" if mode else "fixture-product")
                self.assertEqual(notification_records(work, copy_lifetime=mode), work / "records")


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
    def test_malloc_scribble_requires_product_scan_modes_and_the_original_window(self):
        for options in (("--malloc-scribble", "off", "--system-baseline"),
                        ("--malloc-scribble", "on", "--copy-lifetime"),
                        ("--malloc-scribble", "on", "--heap-diagnostics", "--system-baseline"),
                        ("--malloc-scribble", "on", "--heap-diagnostics", "--copy-lifetime"),
                        ("--malloc-scribble", "off", "--read-only"),
                        ("--malloc-scribble", "off", "--ownership-trace"),
                        ("--malloc-scribble", "off", "--balance-copies"),
                        ("--malloc-scribble", "on", "--cycles", "2"),
                        ("--malloc-scribble", "on", "--heap-control", "--idle-seconds", "10")):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                work = pathlib.Path(directory) / "unused"
                arguments = ["probe", "--work-directory", str(work), "--records-directory", str(work), *options]
                with mock.patch.object(sys, "argv", arguments), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as failure:
                        PROBE.main()
                self.assertEqual(failure.exception.code, 2)
                self.assertFalse(work.exists())

    def test_malloc_scribble_public_receipt_rejects_extra_data_and_unconfirmed_processes(self):
        for setting, expected in (("off", "unset"), ("on", "1")):
            valid = {"requested": setting, "host": expected, "reader": expected}
            PROBE.validate_malloc_scribble_receipt(valid, setting)
            for invalid in (valid | {"host": "other"}, valid | {"reader": "missing"},
                            valid | {"host": None}, valid | {"reader": True},
                            valid | {"path": "/private/secret"}, valid | {"requested": "other"}):
                with self.subTest(setting=setting, invalid=invalid), self.assertRaises(RuntimeError):
                    PROBE.validate_malloc_scribble_receipt(invalid, setting)

    def test_copy_lifetime_is_an_independent_product_probe(self):
        for option in ("--system-baseline", "--heap-diagnostics", "--heap-control", "--ownership-trace", "--read-only",
                       "--balance-copies"):
            with self.subTest(option=option), tempfile.TemporaryDirectory() as directory:
                work = pathlib.Path(directory) / "unused"
                arguments = ["probe", "--work-directory", str(work), "--records-directory", str(work),
                             "--copy-lifetime", option]
                with mock.patch.object(sys, "argv", arguments), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as failure:
                        PROBE.main()
                self.assertEqual(failure.exception.code, 2)
                self.assertFalse(work.exists())

    def test_heap_control_requires_diagnostics_and_the_original_product_window(self):
        for options in (("--heap-control",), ("--heap-control", "--heap-diagnostics", "--system-baseline"),
                        ("--heap-control", "--heap-diagnostics", "--read-only"),
                        ("--heap-control", "--heap-diagnostics", "--cycles", "2")):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                work = pathlib.Path(directory) / "unused"
                arguments = ["probe", "--work-directory", str(work), "--records-directory", str(work), *options]
                with mock.patch.object(sys, "argv", arguments), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as failure:
                        PROBE.main()
                self.assertEqual(failure.exception.code, 2)
                self.assertFalse(work.exists())

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
                      self.scan(288, 18_816) | {"groups": [{"root_type": "NSXPCConnection", "root_instances": 2, "tree_nodes": 288}]}):
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


class AXGroupedTotalTests(unittest.TestCase):
    @staticmethod
    def reports():
        # Self-authored shape shared with the composition multi-root regression.
        grouped = ("Process 123: 5 leaks for 272 total leaked bytes.\n\n"
            "STACK OF 2 INSTANCES OF 'ROOT CYCLE: NSXPCConnection':\n"
            "0 synthetic-image 0x1234 synthetic_function + 0\n====\n"
            "    5 (272 bytes) << TOTAL >>\n      ----\n"
            "      3 (144 bytes) ROOT CYCLE: NSXPCConnection\n"
            "         2 (96 bytes) _connection --> NSArray\n"
            "            1 (80 bytes) list --> NSData\n"
            "               __strong [capture] --> CYCLE BACK TO NSXPCConnection\n      ----\n"
            "      2 (128 bytes) ROOT CYCLE: NSXPCConnection\n"
            "         1 (80 bytes) NSData\n            CYCLE BACK TO NSXPCConnection\n")
        listed = "Process 123: 5 leaks for 272 total leaked bytes.\n"
        for index, (kind, size) in enumerate((("NSXPCConnection", 48), ("NSArray", 16),
                                             ("NSData", 80), ("NSXPCConnection", 48), ("NSData", 80))):
            listed += (f"\nLeak: {0x1000 + index * 0x100:#x}  size={size}  zone: private-zone   {kind}\n"
                       "\tCall stack: \n0 synthetic-image 0x1234 synthetic_function + 0\n")
        return grouped, listed

    @staticmethod
    def scan(report, nodes=5, size=272):
        groups = REPORT.leak_groups(report)
        return {"leak_nodes": nodes, "leak_bytes": size, "groups": groups,
                "unclassified_nodes": nodes - sum(group["tree_nodes"] or 0 for group in groups),
                "destroyed_notification_stack_present": False}

    def test_live_and_terminal_total_conserve_nodes_roots_and_stack_identity(self):
        grouped, listed = self.reports()
        scan = self.scan(grouped)
        PROBE.validate_product_scan(scan, scan)
        self.assertEqual(scan["unclassified_nodes"], 0)
        self.assertEqual(scan["groups"], [{"root_instances": 2, "root_type": "NSXPCConnection",
            "root_kind": "CYCLE", "tree_nodes": 5, "display_size": "272 bytes", "destroyed_return_offsets": []}])
        roots = REPORT.terminal_roots(grouped, 5)
        self.assertEqual((roots[0]["instances"], roots[0]["tree_nodes"]), (2, 5))
        self.assertEqual(roots[0]["private_stack"], (((0, "synthetic-image", 0x1234, "synthetic_function", 0),), 0))
        resolver = mock.Mock()
        with mock.patch.object(REPORT.ax_system_images, "report_images", return_value=[]):
            value = REPORT.terminal_snapshot_summary(grouped, listed, resolver)
        self.assertEqual((value["parsing_status"], value["root_instances"], value["leak_nodes"]), ("complete", 2, 5))
        self.assertEqual(value["root_groups"][0]["stack"]["filtered_frames"], 1)
        self.assertEqual(value["root_groups"][0]["stack"]["frames"], [])
        resolver.verified.assert_not_called()

    def test_total_rejects_bad_headers_subtrees_instances_and_unknown_syntax(self):
        grouped, listed = self.reports()
        mutations = (("5 leaks for 272", "5 leaks for 273"),
                     ("5 (272 bytes) << TOTAL >>", "6 (272 bytes) << TOTAL >>"),
                     ("5 (272 bytes) << TOTAL >>", "5 (273 bytes) << TOTAL >>"),
                     ("2 INSTANCES", "3 INSTANCES"),
                     ("3 (144 bytes)", "4 (144 bytes)"),
                     ("2 (96 bytes)", "3 (96 bytes)"),
                     ("1 (80 bytes) list", "1 (97 bytes) list"),
                     ("      2 (128 bytes)", "       2 (128 bytes)"),
                     ("ROOT CYCLE: NSXPCConnection\n         1", "ROOT CYCLE: UnknownConnection\n         1"),
                     ("<< TOTAL >>", "<< UNKNOWN >>"),
                     ("\n====\n", "\n"),
                     ("CYCLE BACK TO NSXPCConnection", "CYCLE BACK TO unknown"))
        for old, new in mutations:
            report = grouped.replace(old, new)
            with self.subTest(old=old, new=new):
                with self.assertRaises(RuntimeError):
                    PROBE.validate_product_scan(self.scan(report))
                with self.assertRaises(ValueError):
                    REPORT.terminal_roots(report, 5)
                self.assertEqual(REPORT.terminal_snapshot_summary(report, listed, mock.Mock())["parsing_status"], "unavailable")
        for report in (grouped[:grouped.rindex("      ----")], grouped + "      ----\n", grouped + "unknown\n"):
            with self.subTest(report=report), self.assertRaises(RuntimeError):
                PROBE.validate_product_scan(self.scan(report))

    def test_rounded_total_uses_combined_self_byte_bounds(self):
        from ax_composition import grouped_composition
        grouped, listed = self.reports()
        rounded = grouped.replace("3 (144 bytes)", "3 (1K)")
        for size in (225, 272):
            report = rounded.replace("272", str(size))
            with self.subTest(valid_size=size):
                self.assertEqual(grouped_composition(report)["counts_status"], "complete")
                scan = self.scan(report, 5, size)
                PROBE.validate_product_scan(scan, scan)
                self.assertEqual(REPORT.terminal_roots(report, 5)[0]["tree_nodes"], 5)
        with mock.patch.object(REPORT.ax_system_images, "report_images", return_value=[]):
            self.assertEqual(REPORT.terminal_snapshot_summary(rounded, listed, mock.Mock())["parsing_status"], "complete")
        for size in (200, 224):
            report = rounded.replace("272", str(size))
            with self.subTest(invalid_size=size):
                self.assertEqual(grouped_composition(report)["counts_status"], "unavailable")
                with self.assertRaises(RuntimeError):
                    PROBE.validate_product_scan(self.scan(report, 5, size))
                with self.assertRaises(ValueError):
                    REPORT.terminal_roots(report, 5)
        false_list = listed.replace("272", "200").replace("size=80", "size=44")
        self.assertEqual(REPORT.terminal_snapshot_summary(rounded.replace("272", "200"), false_list,
                                                        mock.Mock())["parsing_status"], "unavailable")
        # A second uncertain group cannot compensate for an impossible first
        # group's own-byte interval, even if the report-wide bounds overlap.
        invalid_group = rounded.replace("272 bytes", "200 bytes").replace("5 leaks for 272", "6 leaks for 320")
        invalid_group += ("\nSTACK OF 1 INSTANCE OF 'ROOT CYCLE: NSXPCConnection':\n"
                          "0 synthetic-image 0x1250 extra_function + 0\n====\n"
                          "    1 (1K) << TOTAL >>\n      1 (1K) ROOT CYCLE: NSXPCConnection\n")
        with self.assertRaises(RuntimeError):
            PROBE.validate_product_scan(self.scan(invalid_group, 6, 320))
        with self.assertRaises(ValueError):
            REPORT.terminal_roots(invalid_group, 6)
        # Here each group's interval is nonempty. The combined minimum of
        # 225 + 48 must still fit the report total across both STACK groups.
        multi = rounded.replace("272 bytes", "1K") + (
            "\nSTACK OF 1 INSTANCE OF 'ROOT CYCLE: NSXPCConnection':\n"
            "0 synthetic-image 0x1250 extra_function + 0\n====\n"
            "    1 (48 bytes) ROOT CYCLE: NSXPCConnection\n")
        for size, valid in ((250, False), (273, True)):
            report = multi.replace("5 leaks for 272", f"6 leaks for {size}")
            with self.subTest(multiple_group_size=size):
                self.assertEqual(grouped_composition(report)["counts_status"], "complete" if valid else "unavailable")
                if valid:
                    PROBE.validate_product_scan(self.scan(report, 6, size))
                    self.assertEqual(len(REPORT.terminal_roots(report, 6)), 2)
                else:
                    with self.assertRaises(RuntimeError):
                        PROBE.validate_product_scan(self.scan(report, 6, size))
                    with self.assertRaises(ValueError):
                        REPORT.terminal_roots(report, 6)

    def test_invalid_total_with_zero_report_totals_is_not_an_empty_scan(self):
        grouped, _ = self.reports()
        report = grouped.replace("5 leaks for 272", "0 leaks for 0")
        scan = self.scan(report, 0, 0)
        self.assertEqual(scan["unclassified_nodes"], 0)
        self.assertIsNone(scan["groups"][0]["tree_nodes"])
        with self.assertRaises(RuntimeError):
            PROBE.validate_product_scan(scan)
        with self.assertRaises(ValueError):
            REPORT.terminal_roots(report, 0)
        PROBE.validate_product_scan(self.scan("Process 123: 0 leaks for 0 total leaked bytes.\n", 0, 0))

    def test_recursive_rounded_subtrees_must_fit_each_ancestor(self):
        from ax_composition import grouped_composition
        # The first root needs 80 + 30 descendant bytes and two own bytes.
        # Its rounded sibling must not hide the impossible 100-byte subtree.
        report = ("Process 123: 5 leaks for 200 total leaked bytes.\n\n"
            "STACK OF 2 INSTANCES OF 'ROOT CYCLE: NSXPCConnection':\n"
            "0 synthetic-image 0x1234 synthetic_function + 0\n====\n"
            "    5 (200 bytes) << TOTAL >>\n"
            "      4 (100 bytes) ROOT CYCLE: NSXPCConnection\n"
            "         2 (1K) NSArray\n            1 (80 bytes) NSData\n"
            "         1 (30 bytes) NSMutableArray\n"
            "      1 (1K) ROOT CYCLE: NSXPCConnection\n")
        for root_bytes in (100, 111, 112, 113):
            for display in ("200 bytes", "1K"):
                candidate = report.replace("4 (100 bytes)", f"4 ({root_bytes} bytes)").replace(
                    "5 (200 bytes)", f"5 ({display})")
                with self.subTest(root_bytes=root_bytes, display=display):
                    if root_bytes < 112:
                        value = grouped_composition(candidate)
                        self.assertEqual((value["counts_status"], value["failure_stage"]), ("unavailable", "byte_bounds"))
                        with self.assertRaises(RuntimeError):
                            PROBE.validate_product_scan(self.scan(candidate, 5, 200))
                        with self.assertRaises(ValueError):
                            REPORT.terminal_roots(candidate, 5)
                    else:
                        value = grouped_composition(candidate)
                        self.assertEqual(value["counts_status"], "complete")
                        root_sizes = [row for row in value["exact_size_histogram"] + value["unresolved_sizes"]
                                      if row["type"] == "NSXPCConnection"]
                        self.assertIn({"type": "NSXPCConnection", "size": 1, "count": 1} if root_bytes == 112 else
                                      {"type": "NSXPCConnection", "count": 1, "bytes_min": 1, "bytes_max": 2,
                                       "reason": "rounded_subtree"}, root_sizes)
                        scan = self.scan(candidate, 5, 200)
                        PROBE.validate_product_scan(scan, scan)
                        self.assertEqual(scan["groups"][0]["display_size"], display)
                        root = REPORT.terminal_roots(candidate, 5)[0]
                        self.assertEqual((root["instances"], root["tree_nodes"]), (2, 5))
                        self.assertEqual(root["private_stack"], (((0, "synthetic-image", 0x1234, "synthetic_function", 0),), 0))
        listed = "Process 123: 5 leaks for 200 total leaked bytes.\n"
        for index, (kind, size) in enumerate((("NSXPCConnection", 1), ("NSArray", 1), ("NSData", 80),
                                             ("NSMutableArray", 30), ("NSXPCConnection", 88))):
            listed += (f"\nLeak: {0x1000 + index * 0x100:#x}  size={size}  zone: private-zone   {kind}\n"
                       "\tCall stack: \n0 synthetic-image 0x1234 synthetic_function + 0\n")
        with mock.patch.object(REPORT.ax_system_images, "report_images", return_value=[]):
            for size, status in ((100, "unavailable"), (112, "complete")):
                candidate = report.replace("4 (100 bytes)", f"4 ({size} bytes)")
                self.assertEqual(REPORT.terminal_snapshot_summary(candidate, listed, mock.Mock())["parsing_status"], status)

    def test_recursive_bounds_cover_non_total_groups_in_a_mixed_report(self):
        report = ("Process 123: 6 leaks for 200 total leaked bytes.\n\n"
            "STACK OF 1 INSTANCE OF 'ROOT CYCLE: NSXPCConnection':\n"
            "0 synthetic-image 0x1234 synthetic_function + 0\n====\n"
            "    5 (112 bytes) ROOT CYCLE: NSXPCConnection\n"
            "       3 (1K) NSArray\n          2 (1K) NSString\n"
            "             1 (80 bytes) NSData\n       1 (30 bytes) NSMutableArray\n\n"
            "STACK OF 1 INSTANCE OF 'ROOT CYCLE: NSXPCConnection':\n"
            "0 synthetic-image 0x1250 extra_function + 0\n====\n"
            "    1 (1K) << TOTAL >>\n      1 (1K) ROOT CYCLE: NSXPCConnection\n")
        with self.assertRaises(RuntimeError):
            PROBE.validate_product_scan(self.scan(report, 6, 200))
        with self.assertRaises(ValueError):
            REPORT.terminal_roots(report, 6)
        valid = report.replace("112 bytes", "113 bytes")
        scan = self.scan(valid, 6, 200)
        PROBE.validate_product_scan(scan, scan)
        self.assertEqual([group["display_size"] for group in scan["groups"]], ["113 bytes", "1K"])
        self.assertEqual([root["tree_nodes"] for root in REPORT.terminal_roots(valid, 6)], [5, 1])

    def test_multiple_total_groups_require_global_nodes_and_bytes(self):
        grouped, listed = self.reports()
        extra = ("\nSTACK OF 1 INSTANCE OF 'ROOT CYCLE: NSXPCConnection':\n"
                 "0 synthetic-image 0x1250 extra_function + 0\n====\n"
                 "    1 (48 bytes) << TOTAL >>\n"
                 "      1 (48 bytes) ROOT CYCLE: NSXPCConnection\n")
        grouped = grouped.replace("5 leaks for 272", "6 leaks for 320") + extra
        listed = listed.replace("5 leaks for 272", "6 leaks for 320") + (
            "\nLeak: 0x2000  size=48  zone: private-zone   NSXPCConnection\n"
            "\tCall stack: \n0 synthetic-image 0x1250 extra_function + 0\n")
        scan = self.scan(grouped, 6, 320)
        PROBE.validate_product_scan(scan, scan)
        self.assertEqual([root["tree_nodes"] for root in REPORT.terminal_roots(grouped, 6)], [5, 1])
        with mock.patch.object(REPORT.ax_system_images, "report_images", return_value=[]):
            self.assertEqual(REPORT.terminal_snapshot_summary(grouped, listed, mock.Mock())["parsing_status"], "complete")
        invalid = [grouped.replace("6 leaks for 320", "6 leaks for 321"),
                   grouped.replace("6 leaks for 320", "7 leaks for 320"),
                   grouped.replace("1 (48 bytes) << TOTAL >>", "2 (48 bytes) << TOTAL >>"),
                   grouped.replace("1 INSTANCE OF", "2 INSTANCES OF"),
                   grouped.replace("      1 (48 bytes)", "       1 (48 bytes)"),
                   grouped + "unknown\n"]
        for report in invalid:
            with self.subTest(report=report):
                scan = self.scan(report, 6, 321)
                with self.assertRaises(RuntimeError):
                    PROBE.validate_product_scan(scan, scan)
                with self.assertRaises(ValueError):
                    REPORT.terminal_roots(report, 6)
                # The list agrees with the false 321-byte header. Grouped trees
                # must independently reject it before declaring parsing complete.
                false_list = listed.replace("6 leaks for 320", "6 leaks for 321").replace("0x2000  size=48", "0x2000  size=49")
                self.assertEqual(REPORT.terminal_snapshot_summary(report, false_list, mock.Mock())["parsing_status"], "unavailable")
        mixed = grouped.replace("    1 (48 bytes) << TOTAL >>\n      1", "    1")
        PROBE.validate_product_scan(self.scan(mixed, 6, 320))
        with self.assertRaises(RuntimeError):
            PROBE.validate_product_scan(self.scan(mixed.replace("6 leaks for 320", "6 leaks for 321"), 6, 321))

    def test_total_multiple_stacks_binary_images_and_destroyed_offsets(self):
        report, _ = self.reports()
        extra = ("\nSTACK OF 1 INSTANCE OF 'ROOT CYCLE: NSXPCConnection':\n"
                 f"0 synthetic-image 0x1234 {REPORT.DESTROYED} + 4\n====\n"
                 "    1 (48 bytes) ROOT CYCLE: NSXPCConnection\n")
        report = report.replace("5 leaks for 272", "6 leaks for 320") + extra
        baseline = self.scan(report, 6, 320)
        self.assertEqual([group["tree_nodes"] for group in baseline["groups"]], [5, 1])
        self.assertEqual(baseline["groups"][1]["destroyed_return_offsets"], [4])
        self.assertEqual(sum(root["instances"] for root in REPORT.terminal_roots(report, 6)), 3)
        self.assertEqual(REPORT.leak_groups(report + "\nBinary Images:\nprivate-data\n"), baseline["groups"])


class AXCompatibilityNotificationTests(unittest.TestCase):
    def test_heap_control_requires_strict_zero_host_and_reader_counts(self):
        host = dict.fromkeys(("buttons", "allocatedButtons", "destroyedButtons", "compensations", "mutableCompensations"), 0)
        reader = dict.fromkeys(("buttons", "registrations", "notifications", "all_notifications",
                                "unmatched_notifications", "tracked_buttons"), 0) | {"target_notification_counts": []}
        PROBE.validate_control_host(host)
        PROBE.validate_control_reader(reader)
        PROBE.validate_control_reader({key: value for key, value in reader.items()
                                      if key not in ("buttons", "registrations")}, completed=True)
        for validator, receipt in ((PROBE.validate_control_host, host), (PROBE.validate_control_reader, reader)):
            for key in receipt:
                for value in (None, True, 1, -1):
                    with self.subTest(key=key, value=value), self.assertRaises(RuntimeError):
                        validator(receipt | {key: value})
                invalid = receipt.copy()
                del invalid[key]
                with self.subTest(missing=key), self.assertRaises(RuntimeError):
                    validator(invalid)

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


class AXCompatibilityCopyLifetimeTests(unittest.TestCase):
    @staticmethod
    def receipt(count=10):
        return {"destroyedButtons": count, "compensations": count * 2, "mutableCompensations": count,
                "copyLifetime": {"ordinary": count, "mutable": count, "liveOrdinary": 0, "liveMutable": 0, "invalid": 0}}

    def test_both_branches_match_destruction_and_compensation_at_every_checkpoint(self):
        for count in (0, 10, 20, 30):
            PROBE.validate_copy_lifetime_host(self.receipt(count))
        PROBE.validate_copy_lifetime_host(self.receipt(30), 30)
        with self.assertRaises(RuntimeError):
            PROBE.validate_copy_lifetime_host(self.receipt(20), 30)
        for key, value in (("destroyedButtons", 9), ("compensations", 19), ("mutableCompensations", 9)):
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                PROBE.validate_copy_lifetime_host(self.receipt() | {key: value})
        for key in ("ordinary", "mutable", "liveOrdinary", "liveMutable", "invalid"):
            receipt = self.receipt()
            receipt["copyLifetime"][key] += 1
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                PROBE.validate_copy_lifetime_host(receipt)

    def test_missing_and_noninteger_counts_are_rejected(self):
        for lifetime in (None, [], 0):
            with self.subTest(lifetime=lifetime), self.assertRaises(RuntimeError):
                PROBE.validate_copy_lifetime_host(self.receipt() | {"copyLifetime": lifetime})
        missing = self.receipt()
        del missing["copyLifetime"]
        with self.assertRaises(RuntimeError):
            PROBE.validate_copy_lifetime_host(missing)
        for container in ("host", "copyLifetime"):
            keys = self.receipt()["copyLifetime"].keys() if container == "copyLifetime" else (
                "destroyedButtons", "compensations", "mutableCompensations")
            for key in keys:
                for value in (None, True, 1.0, -1, "0"):
                    receipt = self.receipt()
                    target = receipt["copyLifetime"] if container == "copyLifetime" else receipt
                    target[key] = value
                    with self.subTest(container=container, key=key, value=value), self.assertRaises(RuntimeError):
                        PROBE.validate_copy_lifetime_host(receipt)
                receipt = self.receipt()
                target = receipt["copyLifetime"] if container == "copyLifetime" else receipt
                del target[key]
                with self.subTest(container=container, missing=key), self.assertRaises(RuntimeError):
                    PROBE.validate_copy_lifetime_host(receipt)


class AXTerminalSnapshotTests(unittest.TestCase):
    def setUp(self):
        # Pure parser tests never compile or query a native shared cache.
        patch = mock.patch.object(REPORT.ax_system_images, "shared_cache_images", return_value=None)
        self.cache_lookup = patch.start()
        self.addCleanup(patch.stop)

    def test_other_root_images_use_report_ranges_and_fresh_local_uuid_at_each_gate(self):
        identifier = "12345678-1234-1234-1234-123456789ABC"
        image = {"basename": "libsystem_pthread.dylib", "uuid": identifier}
        grouped, listed = self.reports()
        table = f" 0x1000 - 0x10ff +private-label (1) <{identifier}> /private/untrusted-path\n"
        grouped = grouped.replace("private-data\n", table)
        catalog = {identifier: image}
        with mock.patch.object(REPORT.ax_system_images, "loaded_system_images", return_value=catalog) as load:
            value = self.summary((grouped, listed))
            self.assertEqual(load.call_count, 1)
            with mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()):
                REPORT.validate_terminal_snapshot(value)
            self.assertEqual(load.call_count, 2)  # No reuse of the collection catalog at the output gate.
        identity = value["root_groups"][0]["other_image_identity"]
        self.assertEqual(identity, {"status": "complete", "frames": [{"index": 2, **image}],
                                   "reason_counts": dict.fromkeys(REPORT.ax_system_images.REASONS, 0)})
        baseline = self.summary()
        self.assertEqual(value["root_groups"][0]["stack"], baseline["root_groups"][0]["stack"])
        self.assertEqual(value["allocation_groups"], baseline["allocation_groups"])
        self.assertEqual(value["status"], "partial")
        for private in ("private", "secret", "0x", "path", "address"):
            self.assertNotIn(private, json.dumps(value))
        for invalid in (None, {}, {identifier: {"basename": "Other", "uuid": identifier}}):
            changed = json.loads(json.dumps(value))
            with mock.patch.object(REPORT.ax_system_images, "loaded_system_images", return_value=invalid), \
                    mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()):
                REPORT.validate_terminal_snapshot(changed)
            identity = changed["root_groups"][0]["other_image_identity"]
            self.assertEqual(identity["frames"], [])
            reason = "local_catalog_unavailable" if invalid is None else "uuid_not_verified"
            self.assertEqual(identity["reason_counts"][reason], 1)
            self.assertEqual(identity["status"], "partial")
        mutations = [lambda v: v.update(status="complete"),
                     lambda v: v["root_groups"][0]["other_image_identity"]["frames"][0].update(index=True),
                     lambda v: v["root_groups"][0]["other_image_identity"]["frames"][0].update(index=0),
                     lambda v: v["root_groups"][0]["other_image_identity"]["frames"][0].update(basename="/private/secret"),
                     lambda v: v["root_groups"][0]["other_image_identity"]["frames"][0].update(uuid="secret"),
                     lambda v: v["root_groups"][0]["other_image_identity"].update(path="secret"),
                     lambda v: v["root_groups"][0]["other_image_identity"]["reason_counts"].update(secret=0)]
        for mutate in mutations:
            changed = json.loads(json.dumps(value)); mutate(changed)
            original = json.loads(json.dumps(changed))
            with mock.patch.object(REPORT.ax_system_images, "loaded_system_images", return_value=catalog) as load, \
                    mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()), self.assertRaises(ValueError):
                REPORT.validate_terminal_snapshot(changed)
            load.assert_not_called()
            self.assertEqual(changed, original)

    @classmethod
    def image_reports(cls):
        first = "12345678-1234-1234-1234-123456789ABC"
        second = "22345678-1234-1234-1234-123456789ABC"
        catalog = {first: {"basename": "libsystem_pthread.dylib", "uuid": first},
                   second: {"basename": "libsystem_kernel.dylib", "uuid": second}}
        grouped, listed = cls.reports()
        grouped = grouped.replace("2 private-fixture 0x1000 secret_caller + 4",
                                  "3 private-fixture 0x2000 secret_caller + 4\n2 private-fixture 0x1000 secret_caller + 4")
        table = (f" 0x1000 - 0x10ff private (1) <{first}> /private/path\n"
                 f" 0x2000 - 0x20ff private (1) <{second}> /private/path\n")
        return (grouped.replace("private-data\n", table), listed), catalog

    @staticmethod
    def without_image_identity(value):
        result = json.loads(json.dumps(value))
        for row in result["root_groups"]:
            row.pop("other_image_identity")
        return result

    def test_collection_keeps_terminal_evidence_when_second_catalog_is_unavailable_or_partial(self):
        reports, catalog = self.image_reports()
        with mock.patch.object(REPORT.ax_system_images, "loaded_system_images", return_value=catalog):
            baseline = self.summary(reports)
        partial = {key: catalog[key] for key in list(catalog)[:1]}
        for fresh in (None, partial):
            with self.subTest(fresh=fresh), tempfile.TemporaryDirectory() as directory:
                records = pathlib.Path(directory)
                capture = REPORT.empty_terminal_snapshot()
                capture.update(capture_status="complete", capture_exit_code=0)
                outputs = [subprocess.CompletedProcess([], 1, text, "") for text in reports]
                with mock.patch.object(REPORT.subprocess, "run", side_effect=outputs), \
                        mock.patch.object(REPORT.ax_system_images, "loaded_system_images", side_effect=[catalog, fresh]) as load, \
                        mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()):
                    value = REPORT.collect_terminal_snapshot(records / "terminal.memgraph", records, capture)
                self.assertEqual(load.call_count, 2)  # Once for extraction, once for this entire output gate.
                self.assertEqual(json.loads((records / "terminal-snapshot.json").read_text()), value)
                self.assertEqual(self.without_image_identity(value), self.without_image_identity(baseline))
                identity = value["root_groups"][0]["other_image_identity"]
                self.assertEqual(identity["frames"], [] if fresh is None else [{"index": 2, **next(iter(partial.values()))}])
                reason = "local_catalog_unavailable" if fresh is None else "uuid_not_verified"
                self.assertEqual(identity["reason_counts"][reason], 2 if fresh is None else 1)
                self.assertEqual(identity["status"], "partial")

    def test_collection_saves_old_terminal_before_fatal_worker_cleanup_and_never_starts_next_helper(self):
        reports, catalog = self.image_reports()
        images = REPORT.ax_system_images
        with mock.patch.object(images, "loaded_system_images", return_value=catalog):
            baseline = self.summary(reports)
        for failed_call in (1, 2):
            with self.subTest(failed_call=failed_call), tempfile.TemporaryDirectory() as directory:
                records = pathlib.Path(directory)
                capture = REPORT.empty_terminal_snapshot()
                capture.update(capture_status="complete", capture_exit_code=0)
                outputs = [subprocess.CompletedProcess([], 1, text, "") for text in reports]
                calls = []
                original_error = images.ImageWorkerCleanupError()
                def load(path):
                    calls.append(path)
                    if len(calls) == failed_call:
                        images.write_worker_cleanup(path, False)
                        raise original_error
                    return catalog
                with mock.patch.object(REPORT.subprocess, "run", side_effect=outputs), \
                        mock.patch.object(images, "loaded_system_images", side_effect=load), \
                        mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()), \
                        self.assertRaises(images.ImageWorkerCleanupError) as raised:
                    REPORT.collect_terminal_snapshot(records / "terminal.memgraph", records, capture)
                self.assertIs(raised.exception, original_error)
                self.assertEqual(len(calls), failed_call)
                value = json.loads((records / "terminal-snapshot.json").read_text())
                self.assertEqual(self.without_image_identity(value), self.without_image_identity(baseline))
                identity = value["root_groups"][0]["other_image_identity"]
                self.assertEqual(identity["frames"], [])
                self.assertEqual(identity["reason_counts"]["local_catalog_unavailable"], 2)
                self.assertFalse(images.worker_cleanup_confirmed(records / "terminal-image-worker.json"))

    def test_collection_artifact_cleanup_failure_saves_safe_old_terminal_and_confirmed_exit(self):
        reports, catalog = self.image_reports()
        images = REPORT.ax_system_images
        with mock.patch.object(images, "loaded_system_images", return_value=catalog):
            baseline = self.summary(reports)
        for fail_during_gate in (False, True):
            with self.subTest(fail_during_gate=fail_during_gate), tempfile.TemporaryDirectory() as directory:
                records = pathlib.Path(directory)
                capture = REPORT.empty_terminal_snapshot()
                capture.update(capture_status="complete", capture_exit_code=0)
                calls = []
                def run(command, log, environment, timeout):
                    calls.append(command)
                    log.write_text("")
                    pathlib.Path(command[-1]).write_text(json.dumps({"schema": 1, "images": list(catalog.values())}))
                    return {"status": "completed", "return_code": 0, "cleanup": {"complete": True}}
                remove = shutil.rmtree
                def clean(path):
                    if len(calls) == (2 if fail_during_gate else 1):
                        raise PermissionError(13, "/private/secret")
                    remove(path)
                with mock.patch.object(images, "WORKER_ROOT", records), \
                        mock.patch.object(images.ax_process, "run_owned", side_effect=run), \
                        mock.patch.object(images.shutil, "rmtree", side_effect=clean), \
                        mock.patch.object(REPORT.subprocess, "run", side_effect=[subprocess.CompletedProcess([], 1, text, "") for text in reports]), \
                        mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()), \
                        self.assertRaises(images.ImageWorkerArtifactError) as raised:
                    REPORT.collect_terminal_snapshot(records / "terminal.memgraph", records, capture)
                self.assertNotIn("private", str(raised.exception))
                self.assertEqual(len(calls), 2 if fail_during_gate else 1)
                self.assertEqual(images.worker_cleanup_state(records / "terminal-image-worker.json"), (True, False))
                self.assertEqual(len(list(records.glob("ax-system-images-*"))), 1)
                value = json.loads((records / "terminal-snapshot.json").read_text())
                self.assertEqual(self.without_image_identity(value), self.without_image_identity(baseline))
                self.assertEqual(value["root_groups"][0]["other_image_identity"]["frames"], [])

    def test_collection_initial_receipt_write_failure_still_saves_terminal_without_retry(self):
        reports, _ = self.image_reports()
        images = REPORT.ax_system_images
        write = pathlib.Path.write_text
        writes = []
        def save(path, data, *args, **kwargs):
            if path.name == "terminal-image-worker.json":
                writes.append(path)
                raise PermissionError(13, "/private/secret")
            return write(path, data, *args, **kwargs)
        with tempfile.TemporaryDirectory() as directory:
            records = pathlib.Path(directory)
            capture = REPORT.empty_terminal_snapshot()
            capture.update(capture_status="complete", capture_exit_code=0)
            with mock.patch.object(pathlib.Path, "write_text", new=save), \
                    mock.patch.object(images, "loaded_system_images") as load, \
                    mock.patch.object(REPORT.subprocess, "run", side_effect=[subprocess.CompletedProcess([], 1, text, "") for text in reports]), \
                    mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()), self.assertRaises(images.ImageWorkerArtifactError) as raised:
                REPORT.collect_terminal_snapshot(records / "terminal.memgraph", records, capture)
            load.assert_not_called()
            self.assertEqual(len(writes), 1)
            self.assertNotIn("private", str(raised.exception))
            value = json.loads((records / "terminal-snapshot.json").read_text())
            self.assertEqual((value["leak_nodes"], value["leak_bytes"]), (2, 144))
            self.assertEqual(value["root_groups"][0]["other_image_identity"]["frames"], [])

    def test_unconfirmed_cleanup_never_bypasses_structure_or_symbol_gate(self):
        reports, catalog = self.image_reports()
        images = REPORT.ax_system_images
        with mock.patch.object(images, "loaded_system_images", return_value=catalog):
            baseline = self.summary(reports)
        with tempfile.TemporaryDirectory() as directory:
            receipt = pathlib.Path(directory) / "cleanup.json"
            images.write_worker_cleanup(receipt, False)
            for mutation in (lambda value: value.update(private="secret"),
                             lambda value: value["root_groups"][0]["other_image_identity"]["frames"][0].update(basename="/private/secret"),
                             lambda value: value["root_groups"][0]["stack"]["frames"][0].update(symbol="/private/secret")):
                value = json.loads(json.dumps(baseline)); mutation(value)
                before = json.dumps(value)
                with mock.patch.object(images, "loaded_system_images") as load, \
                        mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()), self.assertRaises(ValueError):
                    REPORT.validate_terminal_snapshot(value, receipt)
                load.assert_not_called()
                self.assertEqual(json.dumps(value), before)

    def test_other_root_images_keep_bounded_failure_reasons_separate_from_stack_coverage(self):
        images = REPORT.ax_system_images
        identifier = "12345678-1234-1234-1234-123456789ABC"
        frame = (2, "secret", 0x1000, "arbitrary_symbol", 7)
        for ranges, catalog, reason in ((None, {}, "report_images_invalid"), ([], {}, "report_range_missing"),
                ([(0x1000, 0x10ff, None)], {}, "report_uuid_ambiguous"),
                ([(0x1000, 0x10ff, identifier)], None, "local_catalog_unavailable"),
                ([(0x1000, 0x10ff, identifier)], {}, "uuid_not_verified")):
            with mock.patch.object(images, "loaded_system_images", return_value=catalog) as load:
                value = REPORT.terminal_other_images([frame], {"ranges": ranges}, [96])
                self.assertEqual(value["frames"], [])
                self.assertEqual(value["status"], "partial")
                self.assertEqual(value["reason_counts"], dict.fromkeys(images.REASONS, 0) | {reason: 1})
                self.assertEqual(load.call_count, int(reason in ("local_catalog_unavailable", "uuid_not_verified")))
        with mock.patch.object(images, "loaded_system_images") as load:
            value = REPORT.terminal_other_images([frame], {"ranges": None}, [0])
            self.assertEqual(value["reason_counts"]["budget_omitted"], 1)
            load.assert_not_called()
        grouped, listed = self.reports()
        frames = "\n".join(f"{i} secret 0x1000 symbol + 4" for i in range(100))
        start = grouped.index("\n", grouped.index("STACK OF "))
        grouped = grouped[:start + 1] + frames + grouped[grouped.index("\n====\n"):]
        value = self.summary((grouped, listed))
        why = value["root_groups"][0]["other_image_identity"]["reason_counts"]
        self.assertEqual((why["report_images_invalid"], why["budget_omitted"]), (96, 4))
        with mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()):
            REPORT.validate_terminal_snapshot(value)
        why.update(report_images_invalid=97, budget_omitted=3)
        with mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()), self.assertRaises(ValueError):
            REPORT.validate_terminal_snapshot(value)

    def test_terminal_cli_rejects_incompatible_modes_before_building(self):
        invalid = [[], ["--prepare-external-fixture"], ["--malloc-scribble", "off"],
                   ["--malloc-scribble", "on", "--external-startup-receipt", "--prepared-fixture-directory", "prepared"],
                   ["--malloc-scribble", "off", "--external-startup-receipt", "--prepared-fixture-directory", "prepared", "--heap-diagnostics"],
                   ["--malloc-scribble", "off", "--external-startup-receipt", "--prepared-fixture-directory", "prepared", "--copy-lifetime"]]
        for extra in invalid:
            arguments = ["probe", "--terminal-origin", "--work-directory", "unused", "--records-directory", "unused", *extra]
            with mock.patch.object(sys, "argv", arguments), mock.patch.object(PROBE.subprocess, "run") as run, \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                PROBE.main()
            self.assertEqual(error.exception.code, 2)
            run.assert_not_called()

    @staticmethod
    def reports():
        # Generic grouped/list syntax observed in a non-AX root/child fixture.
        # NSXPC symbol text is synthetic; no macOS 26 raw format is assumed.
        frames = ["0 com.apple.Foundation 0x9999 -[NSXPCConnection initWithMachServiceName:options:] + 8",
                  "1 com.apple.Foundation 0x9999 -[NSXPCConnection initWithMachServiceName:options:] + 8",
                  "2 private-fixture 0x1000 secret_caller + 4"]
        totals = "Process 123: 2 leaks for 144 total leaked bytes.\n"
        grouped = (totals + "\nSTACK OF 1 INSTANCE OF 'ROOT LEAK: NSMutableArray':\n"
            + "\n".join(reversed(frames)) + "\n====\n    2 (144 bytes) ROOT LEAK: NSMutableArray\n"
              "       1 (96 bytes) private-child\n\nBinary Images:\nprivate-data\n")
        listed = (totals + "\nLeak: 0x1000  size=48  zone: PrivateZone_0x4321   NSMutableArray  ObjC  Foundation\n"
            "\tCall stack: \n" + "\n".join(frames) + "\n\n"
            "Leak: 0x2000  size=96  zone: PrivateZone_0x4321   private-child  C  private-image\n"
            "\tCall stack: \n0 com.apple.CoreFoundation 0x8888 CFDataCreate + 8\n\nBinary Images:\nprivate-data\n")
        return grouped, listed

    @staticmethod
    def many_group_reports(group_count=96):
        # Distinct private groups, each with three nodes; no system lookup is used.
        groups = [("NSArray" if index < 40 else "NSXPCConnection" if index == 40 else "private-type",
                   16 * (index + 1)) for index in range(group_count)]
        totals = f"Process 123: {3 * group_count} leaks for {3 * sum(size for _, size in groups)} total leaked bytes.\n"
        frame = "0 private-image 0x9999 secret_caller + 4\n"
        grouped = (totals + "\nSTACK OF 3 INSTANCES OF 'ROOT CYCLE: NSXPCConnection':\n" + frame
                   + f"\n====\n    {3 * group_count} (bytes) ROOT CYCLE: NSXPCConnection\n")
        listed = totals
        for index, (kind, size) in enumerate(groups):
            for instance in range(3):
                listed += (f"\nLeak: {0x1000 + 16 * (3 * index + instance):#x}  size={size}  zone: private-zone   {kind}\n"
                           "\tCall stack: \n" + frame)
        return grouped, listed

    @staticmethod
    def resolver():
        resolver = mock.Mock()
        resolver.verified.side_effect = lambda image, symbol, *_: REPORT.public_system_symbol(image, symbol)
        resolver.lookup.return_value = 0x1000
        return resolver

    @classmethod
    def summary(cls, reports=None, resolver=None):
        value = REPORT.terminal_snapshot_summary(*(reports or cls.reports()), resolver or cls.resolver())
        value.update(capture_status="complete", capture_exit_code=0, analysis_status="complete",
                     tool_exit_codes={"grouped": 1, "list": 1})
        value["status"] = value["stacks_status"] if value["parsing_status"] == "complete" else "unavailable"
        return value

    def test_root_stack_order_repeats_and_list_counts_are_independent(self):
        resolver = self.resolver()
        value = self.summary(resolver=resolver)
        with mock.patch.object(REPORT, "SystemSymbols", return_value=resolver):
            REPORT.validate_terminal_snapshot(value)
        self.assertEqual((value["leak_nodes"], value["leak_bytes"], value["root_instances"]), (2, 144, 1))
        self.assertEqual(value["parsing_status"], "complete")
        self.assertEqual(value["stacks_status"], "partial")
        root = value["root_groups"][0]
        self.assertEqual(root["type"], "NSMutableArray")
        self.assertEqual([frame["index"] for frame in root["stack"]["frames"]], [0, 1])
        self.assertEqual(root["stack"]["frames"][0]["symbol"], root["stack"]["frames"][1]["symbol"])
        self.assertEqual(root["stack"]["filtered_frames"], 1)
        self.assertEqual(root["reported_image_counts"], dict.fromkeys(REPORT.HEAP_IMAGES, 0) | {"Foundation": 2, "other": 1})
        self.assertEqual(root["reported_filtered_reason_counts"], {"known_image_excluded": 0, "unrecognized_image": 1})
        self.assertEqual([(row["type"], row["size"], row["count"]) for row in value["allocation_groups"]],
                         [("NSMutableArray", 48, 1), ("unknown", 96, 1)])
        text = json.dumps(value)
        for private in ("0x", "private", "secret", "zone", "address", "preexisting", "new_allocation"):
            self.assertNotIn(private, text)
        self.assertEqual(resolver.verified.call_count, 5)

    def test_root_image_buckets_describe_report_labels_without_verifying_them(self):
        grouped, listed = self.reports()
        labels = [label for image, (reported, _) in REPORT.HEAP_IMAGES.items() for label in (image, reported)]
        labels += ["/private/secret-image", "Foundation.secret"]
        frames = "\n".join(f"{index} {label} 0x9999 secret_symbol + 4" for index, label in enumerate(labels))
        start = grouped.index("\n", grouped.index("STACK OF "))
        grouped = grouped[:start + 1] + frames + grouped[grouped.index("\n====\n"):]
        resolver = self.resolver()
        resolver.verified.side_effect = None
        resolver.verified.return_value = False
        value = self.summary((grouped, listed), resolver)
        root = value["root_groups"][0]
        self.assertEqual(root["reported_image_counts"], dict.fromkeys((*REPORT.HEAP_IMAGES, "other"), 2))
        self.assertEqual(root["reported_filtered_reason_counts"], {"known_image_excluded": 6, "unrecognized_image": 2})
        self.assertEqual(root["stack"]["filtered_frames"], 8)
        self.assertEqual(root["stack"]["unverified_frames"], 8)
        self.assertEqual(root["stack"]["frames"], [])
        self.assertEqual(resolver.verified.call_count, 11)  # Eight eligible root labels, three list frames.
        with mock.patch.object(REPORT, "SystemSymbols", return_value=resolver):
            REPORT.validate_terminal_snapshot(value)
        resolver.lookup.assert_not_called()
        for private in ("private", "secret", "0x", "zone"):
            self.assertNotIn(private, json.dumps(value))

    def test_type_ledger_covers_all_nodes_before_group_truncation(self):
        resolver = self.resolver()
        value = self.summary(self.many_group_reports(), resolver)
        with mock.patch.object(REPORT, "SystemSymbols", return_value=resolver):
            REPORT.validate_terminal_snapshot(value)
        self.assertEqual((len(value["allocation_groups"]), value["omitted_allocation_groups"]), (96, 0))
        self.assertEqual(value["status"], "partial")
        self.assertEqual(value["root_groups"][0]["instances"], 3)
        self.assertEqual(value["root_groups"][0]["reported_image_counts"]["other"], 1)  # Frames are not instance-weighted.
        totals = value["allocation_type_totals"]
        self.assertEqual(set(totals), {*REPORT.HEAP_TYPES, "unknown"})
        self.assertEqual(totals["NSArray"], {"nodes": 120, "bytes": 3 * 16 * sum(range(1, 41)),
            "retained_nodes": 120, "retained_bytes": 3 * 16 * sum(range(1, 41)),
            "omitted_nodes": 0, "omitted_bytes": 0})
        self.assertEqual(totals["NSXPCConnection"], {"nodes": 3, "bytes": 3 * 16 * 41,
            "retained_nodes": 3, "retained_bytes": 3 * 16 * 41, "omitted_nodes": 0, "omitted_bytes": 0})
        self.assertEqual((totals["unknown"]["nodes"], totals["unknown"]["bytes"]), (165, 3 * 16 * sum(range(42, 97))))
        self.assertEqual(sum(row["nodes"] for row in totals.values()), value["leak_nodes"])
        self.assertEqual(sum(row["bytes"] for row in totals.values()), value["leak_bytes"])
        self.assertEqual(sum(row["omitted_nodes"] for row in totals.values()), 0)
        self.assertEqual(sum(row["omitted_bytes"] for row in totals.values()), 0)
        resolver.verified.assert_not_called()
        for private in ("private", "secret", "0x", "zone"):
            self.assertNotIn(private, json.dumps(value))

        truncated = self.summary(self.many_group_reports(128), resolver)
        with mock.patch.object(REPORT, "SystemSymbols", return_value=resolver):
            REPORT.validate_terminal_snapshot(truncated)
        self.assertEqual((len(truncated["allocation_groups"]), truncated["omitted_allocation_groups"]), (96, 32))
        self.assertEqual(truncated["allocation_groups"], value["allocation_groups"])
        self.assertEqual(truncated["allocation_type_totals"]["unknown"], {
            "nodes": 3 * 87, "bytes": 3 * 16 * sum(range(42, 129)),
            "retained_nodes": 3 * 55, "retained_bytes": 3 * 16 * sum(range(42, 97)),
            "omitted_nodes": 96, "omitted_bytes": 3 * 16 * sum(range(97, 129))})
        self.assertEqual(sum(row["nodes"] for row in truncated["allocation_type_totals"].values()), truncated["leak_nodes"])
        self.assertEqual(sum(row["bytes"] for row in truncated["allocation_type_totals"].values()), truncated["leak_bytes"])

    def test_empty_and_unavailable_ledgers_cannot_claim_missing_evidence_is_zero(self):
        empty = "Process 123: 0 leaks for 0 total leaked bytes.\n"
        value = self.summary((empty, empty))
        with mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()):
            REPORT.validate_terminal_snapshot(value)
        self.assertTrue(all(count == 0 for counts in value["allocation_type_totals"].values() for count in counts.values()))
        grouped, listed = self.reports()
        unavailable = self.summary((grouped, listed.replace("size=96", "size=95")))
        self.assertIsNone(unavailable["allocation_type_totals"])
        unavailable["allocation_type_totals"] = value["allocation_type_totals"]
        with mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()), self.assertRaises(ValueError):
            REPORT.validate_terminal_snapshot(unavailable)

    def test_public_gate_rejects_bucket_and_ledger_corruption_without_raw_error_text(self):
        valid = self.summary()
        mutations = [lambda v: v.update(schema=1), lambda v: v.update(allocation_type_totals=None),
            lambda v: v["allocation_type_totals"].pop("unknown"),
            lambda v: v["allocation_type_totals"].update({"/private/secret": {}}),
            lambda v: v["allocation_type_totals"]["unknown"].update({"/private/secret": 0}),
            lambda v: v["allocation_type_totals"]["unknown"].update(nodes=True),
            lambda v: v["allocation_type_totals"]["unknown"].update(omitted_nodes=-1),
            lambda v: v["allocation_type_totals"]["unknown"].update(bytes="/private/secret"),
            lambda v: v["allocation_type_totals"]["unknown"].update(retained_bytes=95),
            lambda v: v["allocation_type_totals"]["unknown"].update(omitted_bytes=1),
            lambda v: v["allocation_type_totals"]["unknown"].update(nodes=2, omitted_nodes=1),
            lambda v: v["root_groups"][0].update(reported_image_counts=[]),
            lambda v: v["root_groups"][0]["reported_image_counts"].pop("other"),
            lambda v: v["root_groups"][0]["reported_image_counts"].update({"/private/secret": 0}),
            lambda v: v["root_groups"][0]["reported_image_counts"].update(other=True),
            lambda v: v["root_groups"][0]["reported_image_counts"].update(other=-1),
            lambda v: v["root_groups"][0]["reported_image_counts"].update(Foundation=1, AppKit=1),
            lambda v: v["root_groups"][0]["reported_filtered_reason_counts"].update(known_image_excluded=1),
            lambda v: v["root_groups"][0]["reported_filtered_reason_counts"].update(unrecognized_image="/private/secret"),
            lambda v: v["root_groups"][0]["reported_filtered_reason_counts"].update({"/private/secret": 0})]
        for index, mutate in enumerate(mutations):
            value = json.loads(json.dumps(valid))
            mutate(value)
            with self.subTest(mutation=index), mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()), \
                    self.assertRaisesRegex(ValueError, "^Invalid bounded terminal snapshot$"):
                REPORT.validate_terminal_snapshot(value)
        for omitted in (0, 97, True):
            value = self.summary(self.many_group_reports(128))
            value["omitted_allocation_groups"] = omitted
            with mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()), self.assertRaises(ValueError):
                REPORT.validate_terminal_snapshot(value)

    def test_duplicate_missing_and_disagreeing_reports_fail_closed(self):
        grouped, listed = self.reports()
        variants = [
            (grouped.replace("144 total", "145 total"), listed),
            (grouped.replace("ROOT LEAK: NSMutableArray\n", "ROOT LEAK: NSData\n"), listed),
            (grouped.replace("STACK OF 1 INSTANCE", "STACK OF 3 INSTANCES"), listed),
            (grouped.replace("    2 (144 bytes)", "    1 (144 bytes)"), listed),
            (grouped, listed.replace("Leak: 0x2000", "Leak: 0x1000")),
            (grouped, listed.replace("size=96", "size=95")),
            (grouped, listed.replace("Leak: 0x2000", "Unsupported: 0x2000")),
            (grouped.replace("1 com.apple.Foundation", "0 com.apple.Foundation"), listed),
            (grouped + grouped, listed),
        ]
        for reports in variants:
            with self.subTest(reports=variants.index(reports)):
                value = self.summary(reports)
                self.assertEqual(value["parsing_status"], "unavailable")
                self.assertEqual(value["root_groups"], [])

    def test_multiple_root_headers_keep_their_own_stacks(self):
        grouped, listed = self.reports()
        grouped = grouped.replace("    2 (144 bytes)", "    1 (48 bytes)").replace(
            "       1 (96 bytes) private-child\n", "\nSTACK OF 1 INSTANCE OF 'ROOT CYCLE: NSXPCConnection':\n"
            "0 com.apple.CoreFoundation 0x8888 CFDataCreate + 8\n====\n"
            "    1 (96 bytes) ROOT CYCLE: NSXPCConnection\n")
        value = self.summary((grouped, listed))
        self.assertEqual(value["root_instances"], 2)
        self.assertEqual([row["type"] for row in value["root_groups"]], ["NSMutableArray", "NSXPCConnection"])
        self.assertEqual(value["root_groups"][1]["stack"]["frames"],
                         [{"index": 0, "image": "CoreFoundation", "symbol": "CFDataCreate"}])
        self.assertNotEqual(value["root_groups"][0]["stack"]["frames"], value["root_groups"][1]["stack"]["frames"])

    def test_stack_gaps_unknown_lines_and_missing_stack_do_not_claim_coverage(self):
        grouped, listed = self.reports()
        for changed in (grouped.replace("1 com.apple.Foundation 0x9999 -[NSXPCConnection initWithMachServiceName:options:] + 8\n", ""),
                        grouped.replace("2 private-fixture 0x1000 secret_caller + 4", "truncated stack")):
            value = self.summary((changed, listed))
            stack = value["root_groups"][0]["stack"]
            self.assertEqual(value["status"], "partial")
            self.assertTrue(stack["missing_frames"] or stack["unparsed_lines"])
        frames, unparsed = REPORT.terminal_frames("stack unavailable")
        self.assertEqual(REPORT.terminal_stack(frames, unparsed, self.resolver(), [96])["status"], "missing")

    def test_each_frame_requires_independent_verification_and_shared_budget(self):
        resolver = self.resolver()
        resolver.verified.side_effect = lambda image, *_: image == "CoreFoundation"
        value = self.summary(resolver=resolver)
        self.assertEqual(value["root_groups"][0]["stack"]["unverified_frames"], 2)
        self.assertEqual(value["root_groups"][0]["stack"]["frames"], [])
        with mock.patch.object(REPORT, "TERMINAL_FRAME_LIMIT", 1):
            value = self.summary()
        rows = value["root_groups"] + value["allocation_groups"]
        self.assertEqual(sum(len(row["stack"]["frames"]) for row in rows), 1)
        self.assertEqual(sum(row["stack"]["budget_omitted_frames"] for row in rows), 4)
        self.assertEqual(value["status"], "partial")
        resolver = self.resolver()
        resolver.verified.side_effect = None
        resolver.verified.return_value = False
        with mock.patch.object(REPORT, "TERMINAL_FRAME_LIMIT", 1):
            value = self.summary(resolver=resolver)
        self.assertEqual(resolver.verified.call_count, 1)
        self.assertEqual(sum(row["stack"]["unverified_frames"] for row in value["root_groups"] + value["allocation_groups"]), 1)

    def test_group_and_input_budgets_are_explicit(self):
        with mock.patch.object(REPORT, "TERMINAL_GROUP_LIMIT", 1):
            value = self.summary()
        self.assertEqual(value["omitted_allocation_groups"], 1)
        self.assertEqual(value["status"], "partial")
        with mock.patch.object(REPORT, "REPORT_BYTE_LIMIT", 1):
            self.assertEqual(self.summary()["status"], "unavailable")

    def test_96_groups_share_96_symbol_attempts_including_failures(self):
        reports = tuple(text.replace("0 private-image 0x9999 secret_caller + 4",
            "0 com.apple.Foundation 0x9999 NSAllocateObject + 4") for text in self.many_group_reports())
        for verified in (True, False):
            resolver = self.resolver()
            resolver.verified.side_effect = None
            resolver.verified.return_value = verified
            value = self.summary(reports, resolver)
            self.assertEqual((len(value["allocation_groups"]), value["omitted_allocation_groups"]), (96, 0))
            self.assertEqual(resolver.verified.call_count, 96)
            rows = value["root_groups"] + value["allocation_groups"]
            self.assertEqual(sum(row["stack"]["budget_omitted_frames"] for row in rows), 1)
            self.assertEqual(sum(row["stack"]["unverified_frames"] for row in rows), 0 if verified else 96)
            with mock.patch.object(REPORT, "SystemSymbols", return_value=resolver):
                REPORT.validate_terminal_snapshot(value)
            self.assertEqual(resolver.lookup.call_count, 96 if verified else 0)

    @classmethod
    def large_public_summary(cls):
        value = cls.summary(cls.many_group_reports())
        budget = [96]
        for row in value["allocation_groups"]:
            row["stack"] = REPORT.terminal_stack(((0, "com.apple.Foundation", 0x9999, "A" * 128, 0),),
                                                 0, cls.resolver(), budget)
        root = value["root_groups"][0]
        for _ in range(15):
            extra = json.loads(json.dumps(root))
            extra["tree_nodes"] = 3
            value["root_groups"].append(extra)
        root["tree_nodes"] -= 45
        value["root_instances"] = 48
        return value

    def test_default_json_64k_limit_is_not_increased_with_group_cap(self):
        value = self.large_public_summary()
        image = {"basename": "A" * 96, "uuid": "11111111-1111-1111-1111-111111111111"}
        for root in value["root_groups"]:
            root["reported_image_counts"]["other"] = 6
            root["reported_filtered_reason_counts"]["unrecognized_image"] = 6
            root["stack"].update(reported_frames=6, omitted_frames=6, filtered_frames=6)
            identity = root["other_image_identity"]
            identity.update(status="complete", frames=[{"index": index, **image} for index in range(6)],
                            reason_counts=dict.fromkeys(identity["reason_counts"], 0))
        self.assertGreater(len(json.dumps(value).encode()), 65536)
        with mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()), \
                mock.patch.object(REPORT.ax_system_images, "loaded_system_images") as catalog, \
                mock.patch.object(REPORT.json, "dumps", wraps=json.dumps) as encode, \
                self.assertRaisesRegex(ValueError, "^Invalid bounded terminal snapshot$"):
            REPORT.validate_terminal_snapshot(value)
        encode.assert_called_once_with(value)
        catalog.assert_not_called()

    def test_public_gate_rechecks_symbols_and_counts_without_raw_output(self):
        valid = self.summary()
        mutations = [lambda v: v.update(private="secret"), lambda v: v.update(status="complete"),
                     lambda v: v.update(root_instances=2), lambda v: v.update(leak_bytes=145),
                     lambda v: v["root_groups"][0].update(type="secret"),
                     lambda v: v["root_groups"][0]["stack"].update(omitted_frames=0),
                     lambda v: v["root_groups"][0]["stack"]["frames"][0].update(symbol="/private/secret"),
                     lambda v: v["root_groups"][0]["stack"]["frames"][0].update(index=True),
                     lambda v: v["tool_exit_codes"].update(grouped=2)]
        for mutate in mutations:
            value = json.loads(json.dumps(valid))
            mutate(value)
            with mock.patch.object(REPORT, "SystemSymbols", return_value=self.resolver()), self.assertRaises(ValueError):
                REPORT.validate_terminal_snapshot(value)
        resolver = self.resolver()
        resolver.lookup.return_value = None
        with mock.patch.object(REPORT, "SystemSymbols", return_value=resolver), self.assertRaises(ValueError):
            REPORT.validate_terminal_snapshot(valid)

    def test_capture_timeout_and_offline_tool_failures_are_bounded_receipts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            graph = root / "terminal.memgraph"
            with mock.patch.object(REPORT.subprocess, "run", side_effect=subprocess.TimeoutExpired("leaks", 60)):
                capture = REPORT.capture_terminal_snapshot(123, graph)
            self.assertEqual(capture["capture_status"], "timeout")
            with mock.patch.object(REPORT.subprocess, "run") as run:
                value = REPORT.collect_terminal_snapshot(graph, root, capture)
            run.assert_not_called()
            self.assertEqual(value["status"], "unavailable")
            capture.update(capture_status="complete", capture_exit_code=0)
            grouped, listed = self.reports()
            for fail in ("timeout", "code"):
                returns = [subprocess.CompletedProcess([], 1, grouped, "")]
                returns.append(subprocess.TimeoutExpired("leaks", 1) if fail == "timeout" else
                               subprocess.CompletedProcess([], 2, "private-error", "secret"))
                with mock.patch.object(REPORT.subprocess, "run", side_effect=returns) as run:
                    value = REPORT.collect_terminal_snapshot(graph, root, capture)
                self.assertEqual(value["tool_exit_codes"]["grouped"], 1)
                self.assertEqual(value["analysis_status"], "timeout" if fail == "timeout" else "failed")
                self.assertEqual(value["status"], "unavailable")
                self.assertEqual(run.call_count, 2)
                self.assertLessEqual(run.call_args.kwargs["timeout"], REPORT.TERMINAL_SECONDS)
                self.assertNotIn("secret", (root / "terminal-snapshot.json").read_text())
            with mock.patch.object(REPORT.time, "monotonic", side_effect=[0, 0, REPORT.TERMINAL_SECONDS + 1]), \
                    mock.patch.object(REPORT.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, grouped, "")) as run:
                value = REPORT.collect_terminal_snapshot(graph, root, capture)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(value["analysis_status"], "timeout")
            self.assertEqual(value["tool_exit_codes"], {"grouped": 1, "list": None})


class AXPureAppKitControlTests(unittest.TestCase):
    @staticmethod
    def manifest(mode, hashes):
        sources = (["QuickFileApp/AXCompatibility.m", "QuickFileApp/AXCompatibility.h"] if mode == "patched" else [])
        sources += ["Scripts/tests/fixtures/AXCompatibilityNotifications.m", "Scripts/tests/fixtures/AXCompatibilityReader.swift"]
        return {"schema": 2, "build_mode": mode,
                "sources": {name: PROBE.hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources},
                "executables": hashes, "build_evidence": {
                    "link_inputs": {"host": [sources[-2]] + (["AXCompatibility.o"] if mode == "patched" else []),
                                    "reader": [sources[-1]]},
                    "production_ax_symbol_counts": {"host": 4 if mode == "patched" else 0, "reader": 0}}}

    def test_empty_control_cli_rejects_incompatible_or_implicit_modes(self):
        measured = ["--heap-control", "--external-startup-receipt", "--prepared-fixture-directory", "prepared", "--malloc-scribble", "off"]
        invalid = [[], ["--heap-control"], measured[:-1] + ["on"], measured[1:]]
        invalid += [measured + [flag] for flag in ("--terminal-origin", "--heap-diagnostics", "--system-baseline", "--copy-lifetime", "--read-only", "--ownership-trace")]
        invalid += [["--prepare-external-fixture", flag] for flag in ("--heap-control", "--terminal-origin", "--heap-diagnostics")]
        for mode, extra in itertools.product(("patched", "pure-appkit"), invalid):
            with self.subTest(mode=mode, extra=extra), mock.patch.object(sys, "argv", ["probe", "--empty-control-mode", mode,
                    "--work-directory", "unused", "--records-directory", "unused", *extra]), \
                    mock.patch.object(PROBE.subprocess, "run") as run, contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                PROBE.main()
            self.assertEqual(error.exception.code, 2)
            run.assert_not_called()

    def test_prepare_builds_only_declared_inputs_and_audits_both_executables(self):
        exports = ["_QuickFileInstallAXCompatibility", "_QuickFileAXCompatibilityStatus", "_QuickFileAXCompensatedCopies", "_QuickFileAXCompensatedMutableCopies"]
        for mode, bad_symbols in itertools.product(("patched", "pure-appkit"), (None, "host", "reader", "empty")):
            with self.subTest(mode=mode, bad_symbols=bad_symbols), tempfile.TemporaryDirectory() as directory:
                temporary = pathlib.Path(directory).resolve()
                work, records = temporary / "fixture", temporary / "records"
                class ProbeRoot:
                    def __truediv__(self, child):
                        return temporary if child == ".build/Temporary" else ROOT / child
                commands = []
                def run(command, **kwargs):
                    commands.append(command)
                    output = ""
                    if "-o" in command:
                        path = pathlib.Path(command[command.index("-o") + 1])
                        path.write_bytes((mode + path.name).encode())
                        path.chmod(0o700)
                    if "nm" in command:
                        role = "reader" if command[-1].endswith("ax-reader") else "host"
                        symbols = exports if role == "host" and mode == "patched" else []
                        if role == bad_symbols:
                            symbols = [] if symbols else ["_QuickFileAXUnexpected"]
                        output = "\n".join(["_main", *symbols]) if bad_symbols != "empty" else ""
                    return subprocess.CompletedProcess(command, 0, output, "")
                with mock.patch.object(PROBE, "ROOT", ProbeRoot()), mock.patch.object(PROBE.subprocess, "run", side_effect=run), \
                        mock.patch.object(PROBE.subprocess, "Popen") as start, contextlib.redirect_stdout(io.StringIO()), \
                        mock.patch.object(sys, "argv", ["probe", "--prepare-external-fixture", "--empty-control-mode", mode,
                            "--work-directory", str(work), "--records-directory", str(records)]):
                    if bad_symbols:
                        with self.assertRaises(RuntimeError):
                            PROBE.main()
                        self.assertFalse((work / "fixture-build.json").exists())
                    else:
                        self.assertEqual(PROBE.main(), 0)
                        manifest = EXTERNAL.load_prepared_build(work, self.manifest(mode, {})["sources"], mode)
                        self.assertEqual(manifest, self.manifest(mode, EXTERNAL.fixture_hashes(work)))
                        self.assertEqual(sum("nm" in command for command in commands), 2)
                start.assert_not_called()
                self.assertFalse(any("--capabilities" in command or "-DQUICKFILE_AX_MALLOC_RECEIPT" in command for command in commands))
                host = next(command for command in commands if "-fobjc-arc" in command)
                self.assertIn("-DQUICKFILE_AX_EMPTY_CONTROL", host)
                self.assertEqual("-DQUICKFILE_AX_PURE_APPKIT_CONTROL" in host, mode == "pure-appkit")
                self.assertEqual(any("-fno-objc-arc" in command for command in commands), mode == "patched")
                if mode == "pure-appkit":
                    self.assertFalse(any("QuickFileApp" in str(part) or str(part).endswith("AXCompatibility.o") for command in commands for part in command))

    def test_prepared_modes_source_hashes_link_inputs_and_bytes_cannot_be_interchanged(self):
        for mode in ("patched", "pure-appkit"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                prepared = pathlib.Path(directory)
                for role, name in EXTERNAL.EXECUTABLES.items():
                    path = prepared / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes((mode + role).encode())
                    path.chmod(0o700)
                valid = self.manifest(mode, EXTERNAL.fixture_hashes(prepared))
                manifest_path = prepared / "fixture-build.json"
                PROBE.write_json(manifest_path, valid)
                for wrong_mode in ("ordinary", "pure-appkit" if mode == "patched" else "patched"):
                    with self.assertRaises(RuntimeError):
                        EXTERNAL.load_prepared_fixture(prepared, valid["sources"], wrong_mode)
                changes = [lambda value: value.update(private="/private/secret"),
                    lambda value: value["sources"].update({"/private/secret": "0" * 64}),
                    lambda value: value["build_evidence"]["link_inputs"]["host"].append("/private/secret.o"),
                    lambda value: value["build_evidence"]["production_ax_symbol_counts"].update(reader=1),
                    lambda value: value["build_evidence"]["production_ax_symbol_counts"].update(host=True),
                    lambda value: value["build_evidence"]["production_ax_symbol_counts"].update(host=1)]
                for change in changes:
                    value = json.loads(json.dumps(valid))
                    change(value)
                    PROBE.write_json(manifest_path, value)
                    with self.assertRaises(RuntimeError) as error:
                        EXTERNAL.load_prepared_fixture(prepared, valid["sources"], mode)
                    self.assertNotIn("secret", str(error.exception))
                PROBE.write_json(manifest_path, valid)
                for role, name in EXTERNAL.EXECUTABLES.items():
                    path = prepared / name
                    previous = path.read_bytes()
                    path.write_bytes(b"changed")
                    with self.assertRaises(RuntimeError):
                        EXTERNAL.load_prepared_fixture(prepared, valid["sources"], mode)
                    path.write_bytes(previous)

    def test_capability_identity_is_explicit_and_never_inferred_from_zero_counts(self):
        for mode in ("patched", "pure-appkit"):
            valid = {"empty_control_mode": mode, "enabled": mode == "patched", "status": "enabled" if mode == "patched" else mode}
            self.assertIsNone(PROBE.preflight_reason(valid, {"trusted": True}, empty_control_mode=mode))
            self.assertEqual(PROBE.preflight_reason(valid, {"trusted": False}, empty_control_mode=mode), "reader-not-trusted")
            for changed in (dict(valid, empty_control_mode="wrong"), dict(valid, enabled=not valid["enabled"]),
                            dict(valid, enabled=int(valid["enabled"])), dict(valid, status="system-baseline"), None, [], "private-secret"):
                with self.assertRaises(RuntimeError):
                    PROBE.preflight_reason(changed, {"trusted": True}, empty_control_mode=mode)
        with self.assertRaises(RuntimeError):
            PROBE.preflight_reason({"enabled": False, "status": "pure-appkit"}, {"trusted": True})


class AXInstallGateTests(unittest.TestCase):
    @staticmethod
    def state(mode):
        imp = "replacement" if mode == "installed" else "saved"
        return {"mode": mode, "preflight_completed": True, "gate_calls": 1, "copy_imp": imp, "mutable_copy_imp": imp}

    @staticmethod
    def manifest(hashes):
        return {"schema": 3, "build_mode": "install-gate", "executables": hashes,
            "sources": {name: PROBE.hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in EXTERNAL.fixture_sources("install-gate")},
            "build_evidence": {"link_inputs": {"host": [EXTERNAL.FIXTURE_SOURCES[0], "AXCompatibility.o"], "reader": [EXTERNAL.FIXTURE_SOURCES[1]]},
                "compile_definitions": {"production": ["QUICKFILE_AX_INSTALL_PROBE"], "host": ["QUICKFILE_AX_INSTALL_PROBE"], "reader": []},
                "gate_symbol_present": {"host": True, "reader": False}}}

    def test_gate_requires_real_preflight_and_current_method_state(self):
        for mode in EXTERNAL.INSTALL_MODES:
            state = self.state(mode)
            cap = {"enabled": mode == "installed", "status": "enabled" if mode == "installed" else "probe-preflight-only", "install_probe": state}
            self.assertIsNone(PROBE.preflight_reason(cap, {"trusted": True}, install_gate=mode))
            self.assertEqual(PROBE.preflight_reason(cap, {"trusted": False}, install_gate=mode), "reader-not-trusted")
            invalid = [None, dict(state, gate_calls=True), dict(state, gate_calls=0), dict(state, gate_calls=2),
                dict(state, preflight_completed=False), dict(state, preflight_completed=1), dict(state, private="secret"),
                dict(state, copy_imp="other"), dict(state, mutable_copy_imp="unavailable"), dict(state, mode="secret"),
                dict(state, copy_imp="saved" if mode == "installed" else "replacement")]
            for value in invalid:
                with self.assertRaises(RuntimeError):
                    PROBE.preflight_reason(dict(cap, install_probe=value), {"trusted": True}, install_gate=mode)
            for status in ("unsupported-images", "unsupported-architecture", "disabled-at-startup"):
                with self.assertRaises(RuntimeError):
                    PROBE.preflight_reason(dict(cap, status=status), {"trusted": True}, install_gate=mode)
            with self.assertRaises(RuntimeError):
                PROBE.preflight_reason(dict(cap, enabled=not cap["enabled"]), {"trusted": True}, install_gate=mode)

    def test_gate_cli_rejects_incompatible_modes_before_launch(self):
        measured = ["--heap-control", "--external-startup-receipt", "--prepared-fixture-directory", "unused", "--malloc-scribble", "off"]
        invalid = [[], measured[1:], measured[:-1] + ["on"]]
        invalid += [measured + [flag] for flag in ("--terminal-origin", "--system-baseline", "--copy-lifetime", "--prepare-external-fixture")]
        invalid += [measured + ["--empty-control-mode", "patched"]]
        arguments = [["--install-gate", mode, *extra] for mode, extra in itertools.product(EXTERNAL.INSTALL_MODES, invalid)]
        arguments += [["--prepare-install-gate-fixture", *extra] for extra in (["--empty-control-mode", "pure-appkit"], ["--install-gate", "installed"], ["--malloc-scribble", "off"], ["--heap-control"])]
        for extra in arguments:
            with self.subTest(extra=extra), mock.patch.object(sys, "argv", ["probe", "--work-directory", "unused", "--records-directory", "unused", *extra]), \
                    mock.patch.object(PROBE.subprocess, "run") as run, contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                PROBE.main()
            self.assertEqual(error.exception.code, 2)
            run.assert_not_called()

    def test_probe_build_manifest_binds_macros_sources_and_both_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = pathlib.Path(directory).resolve()
            work, records = temporary / "fixture", temporary / "records"
            class ProbeRoot:
                def __truediv__(self, child):
                    return temporary if child == ".build/Temporary" else ROOT / child
            commands = []
            def run(command, **kwargs):
                commands.append(command)
                if "-o" in command:
                    path = pathlib.Path(command[command.index("-o") + 1]); path.write_bytes(path.name.encode()); path.chmod(0o700)
                symbols = "_main\n" + ("_QuickFileAXInstallProbeGate\n" if not command[-1].endswith("ax-reader") else "")
                return subprocess.CompletedProcess(command, 0, symbols if "nm" in command else "", "")
            with mock.patch.object(PROBE, "ROOT", ProbeRoot()), mock.patch.object(PROBE.subprocess, "run", side_effect=run), \
                    mock.patch.object(PROBE.subprocess, "Popen") as start, contextlib.redirect_stdout(io.StringIO()), \
                    mock.patch.object(sys, "argv", ["probe", "--prepare-install-gate-fixture", "--work-directory", str(work), "--records-directory", str(records)]):
                self.assertEqual(PROBE.main(), 0)
            start.assert_not_called()
            expected = self.manifest(EXTERNAL.fixture_hashes(work))
            self.assertEqual(EXTERNAL.load_prepared_build(work, expected["sources"], "install-gate"), expected)
            for command in commands:
                if "-fobjc-arc" in command or "-fno-objc-arc" in command:
                    self.assertIn("-DQUICKFILE_AX_INSTALL_PROBE", command)
                self.assertNotIn("-DQUICKFILE_AX_MALLOC_RECEIPT", command)
                if "swiftc" in command:
                    self.assertNotIn("-DQUICKFILE_AX_INSTALL_PROBE", command)
            for wrong in ("ordinary", "patched", "pure-appkit"):
                with self.assertRaises(RuntimeError):
                    EXTERNAL.load_prepared_build(work, expected["sources"], wrong)
            for mutate in (lambda v: v.update(schema=2), lambda v: v["build_evidence"]["compile_definitions"].update(production=[]),
                    lambda v: v["build_evidence"]["compile_definitions"].update(reader=["QUICKFILE_AX_INSTALL_PROBE"]),
                    lambda v: v["build_evidence"]["gate_symbol_present"].update(host=False),
                    lambda v: v["build_evidence"]["gate_symbol_present"].update(host=1),
                    lambda v: v["build_evidence"]["link_inputs"]["host"].append("secret.o"),
                    lambda v: v["sources"].pop("QuickFileApp/AXCompatibility.m")):
                value = json.loads(json.dumps(expected)); mutate(value); PROBE.write_json(work / "fixture-build.json", value)
                with self.assertRaises(RuntimeError):
                    EXTERNAL.load_prepared_build(work, expected["sources"], "install-gate")
            PROBE.write_json(work / "fixture-build.json", expected)
            for name in EXTERNAL.EXECUTABLES.values():
                path = work / name; original = path.read_bytes(); path.write_bytes(b"drift")
                with self.assertRaises(RuntimeError):
                    EXTERNAL.load_prepared_build(work, expected["sources"], "install-gate")
                path.write_bytes(original)


class AXSettledBaselineShadowTests(unittest.TestCase):
    def test_capture_timeout_and_unverified_early_activity_are_retained(self):
        temporary_root = ROOT / ".build/Temporary/ax-composition-shadow-20261012"
        temporary_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="ax-shadow-capture-", dir=temporary_root) as directory:
            root = pathlib.Path(directory)
            shadow = PROBE.SettledBaselineShadow(root, root / "graphs")
            shadow.pid = 123
            (root / "baseline-original.stdout.txt").write_bytes(b"baseline")
            source = {"label": "baseline", "host": {key: 0 for key in ("buttons", "allocatedButtons", "destroyedButtons", "compensations", "mutableCompensations")},
                      "stdout_sha256": hashlib.sha256(b"baseline").hexdigest()}
            shadow.capture("auxiliary-original-baseline", {**source, "stdout_sha256": "mismatch"})
            first = shadow.data["captures"][-1]
            self.assertEqual(first["status"], "failed")
            self.assertIsNone(first["host_activity_zero"])
            with mock.patch.object(PROBE, "capture_terminal_snapshot", return_value={"capture_status": "timeout", "capture_exit_code": None}) as capture, \
                    mock.patch.object(PROBE.time, "monotonic", side_effect=[0, 15.1]):
                shadow.capture("auxiliary-original-baseline", source)
            self.assertEqual(capture.call_args.kwargs["timeout"], 15)
            second = shadow.data["captures"][-1]
            self.assertEqual(second["status"], "failed")
            self.assertEqual(second["capture_status"], "timeout")
            self.assertEqual(second["end_monotonic"] - second["start_monotonic"], 15.1)
            self.assertTrue(second["host_activity_zero"])
            self.assertIsNone(second["graph_sha256"])

    def exercise(self, counts, timeout=False, capture_seconds=0, probe_seconds=0, include_late=False):
        temporary_root = ROOT / ".build/Temporary/ax-composition-shadow-20261012"
        temporary_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="ax-shadow-", dir=temporary_root) as directory:
            root = pathlib.Path(directory)
            shadow = PROBE.SettledBaselineShadow(root, root / "graphs")
            clock = [0.0]
            def now():
                return clock[0]
            def sleep(seconds):
                clock[0] += seconds
            host = {key: 0 for key in ("buttons", "allocatedButtons", "destroyedButtons", "compensations", "mutableCompensations")}
            reader = {key: 0 for key in ("buttons", "registrations", "notifications", "all_notifications", "unmatched_notifications", "tracked_buttons")}
            reader["target_notification_counts"] = []
            (root / "baseline-original.stdout.txt").write_bytes(b"baseline")
            baseline = {"label": "baseline", "host": host, "stdout_sha256": hashlib.sha256(b"baseline").hexdigest()}
            def capture(pid, graph, timeout):
                self.assertEqual(timeout, 15)
                clock[0] += capture_seconds
                graph.write_bytes(b"graph")
                return {"capture_status": "complete", "capture_exit_code": 0}
            sequence = iter(counts)
            def scan(command, **kwargs):
                self.assertLessEqual(kwargs["timeout"], 5)
                if timeout:
                    clock[0] += kwargs["timeout"]
                    raise subprocess.TimeoutExpired(command, kwargs["timeout"])
                clock[0] += probe_seconds
                n = next(sequence)
                return subprocess.CompletedProcess(command, 1,
                    f"{n} leaks for {n * 100} total leaked bytes.\nSTACK OF {n} INSTANCES OF 'ROOT CYCLE: NSXPCConnection':\n  {n} ({n * 100} bytes) ROOT CYCLE: NSXPCConnection\n", "")
            with mock.patch.object(PROBE.time, "monotonic", side_effect=now), \
                    mock.patch.object(PROBE.time, "sleep", side_effect=sleep), \
                    mock.patch.object(PROBE, "capture_terminal_snapshot", side_effect=capture), \
                    mock.patch.object(PROBE.subprocess, "run", side_effect=scan):
                shadow.settle(123, baseline, lambda timeout: dict(host), reader)
                if include_late:
                    shadow.capture("auxiliary-late", shadow.data["probes"][-1])
            for before, after in zip(shadow.data["probes"], shadow.data["probes"][1:]):
                self.assertGreaterEqual(after["start_monotonic"] - before["end_monotonic"], 2)
            probe_ends = [row["end_monotonic"] for row in shadow.data["probes"]]
            if probe_ends:
                self.assertLessEqual(max(probe_ends) - shadow.data["settling_started_monotonic"], 15)
            return shadow.data

    def test_graph_captures_have_independent_budget_from_idle_probes(self):
        data = self.exercise([2, 2], capture_seconds=14, probe_seconds=4, include_late=True)
        self.assertEqual(data["settling_policy"]["graph_capture_timeout_seconds"], 15)
        self.assertEqual(data["chosen_index"], 1)
        self.assertEqual(data["settling_started_monotonic"], 14)
        self.assertEqual([row["start_monotonic"] for row in data["probes"]], [14, 20])
        self.assertEqual([row["end_monotonic"] for row in data["captures"]], [14, 38, 52])
        self.assertTrue(all(row["status"] == "complete" for row in data["captures"]))
        self.assertTrue(all(row["host_activity_zero"] for row in data["captures"][:2]))

    def test_two_roots_are_valid_and_growth_requires_a_new_equal_pair(self):
        self.assertEqual(self.exercise([2, 2])["chosen_index"], 1)
        self.assertEqual(self.exercise([2, 3, 3])["chosen_index"], 2)

    def test_probe_budget_and_timeout_do_not_select_candidate(self):
        for data in (self.exercise([1, 2, 3, 4, 5, 6]), self.exercise([], timeout=True)):
            self.assertEqual(data["status"], "not_settled")
            self.assertIsNone(data["chosen_index"])
            self.assertEqual(len(data["captures"]), 1)

    def test_original_baseline_classification_cannot_be_hidden_by_candidate(self):
        temporary_root = ROOT / ".build/Temporary/ax-composition-shadow-20261012"
        temporary_root.mkdir(parents=True, exist_ok=True)
        for invalid in ("unclassified_nodes", "destroyed_notification_stack_present", "root_type"):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory(prefix="ax-shadow-", dir=temporary_root) as directory:
                root = pathlib.Path(directory)
                shadow = PROBE.SettledBaselineShadow(root, root / "graphs")
                candidate = {"label": "candidate", "leak_nodes": 3, "leak_bytes": 300,
                    "unclassified_nodes": 0, "destroyed_notification_stack_present": False,
                    "groups": [{"root_type": "NSXPCConnection", "root_instances": 3}]}
                baseline = {**candidate, "label": "baseline"}
                if invalid == "root_type":
                    baseline["groups"] = [{"root_type": "Unexpected", "root_instances": 3}]
                else:
                    baseline[invalid] = 1 if invalid == "unclassified_nodes" else True
                scans = [baseline] + [{**candidate, "label": str(index)} for index in range(5)]
                shadow.data.update(chosen_index=0, probes=[candidate])
                shadow.finish(scans, [{"stage": "baseline", "message": "classification failed"}], False)
                self.assertEqual(shadow.data["original_strict_verdict"], "failed")
                self.assertEqual(shadow.data["candidate_hypothetical_verdict"], "failed")

    def test_conflicting_cli_modes_fail_before_launch(self):
        base = ["probe", "--work-directory", "/unused", "--records-directory", "/unused-records", "--settled-baseline-shadow",
                "--external-startup-receipt", "--prepared-fixture-directory", "/unused-prepared", "--malloc-scribble", "off"]
        for flag in ("--heap-diagnostics", "--reference-validation", "--live-attribution", "--terminal-origin", "--copy-lifetime",
                     "--system-baseline", "--ci-failure-evidence", "--read-only", "--prepare-external-fixture", "--reference-idle"):
            with self.subTest(flag=flag), mock.patch.object(sys, "argv", base + [flag]), \
                    mock.patch.object(PROBE.subprocess, "Popen") as launched, contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as error:
                PROBE.main()
            self.assertEqual(error.exception.code, 2)
            launched.assert_not_called()


class AXCompatibilityLifecycleTests(unittest.TestCase):
    """Inject process/scan results while exercising the real runner protocol."""

    def exercise_runner(self, *, failed_scan=None, invalid_notifications=False,
                        system_baseline=False, insufficient_compensation=False, ownership_trace=False,
                        heap_diagnostics=False, unavailable_cohorts=False, heap_control=False,
                        invalid_control_host=None, invalid_control_reader=None,
                        copy_lifetime=False, invalid_copy_lifetime=None,
                        malloc_scribble=None, invalid_allocator=None, external_receipt=False, binary_drift=False,
                        terminal_origin=False, terminal_timeout=False, empty_control_mode=None,
                        cleanup_failure=None, ls_failure=False, install_gate=None, invalid_install_gate=None,
                        startup_error=None, hash_io_failure=None, live_attribution=False, live_capture_failure=None,
                        reference_validation=False, reference_idle=False, ci_failure_evidence=False,
                        ci_capture_failed=False, settled_shadow=False, shadow_capture_failed=False, shadow_timeout=False,
                        settled_startup=False, startup_scan_durations=()):
        with tempfile.TemporaryDirectory(prefix="ax-protocol-") as directory:
            temporary = pathlib.Path(directory).resolve()
            work = temporary / "fixture"
            records = temporary / "records"
            state = work / "state"
            host_state = {"pid": 1234, "sequence": 0, "buttons": 0, "allocatedButtons": 0,
                          "destroyedButtons": 0, "compensations": 0, "mutableCompensations": 0}
            if install_gate:
                host_state["install_probe"] = AXInstallGateTests.state(install_gate)
            if ownership_trace:
                host_state["ownership"] = {"duplicateLiveAddresses": 0, "offMainHits": 0, "created": 1, "live": 1}
            notifications = {"notifications": 60, "all_notifications": 60, "unmatched_notifications": 0,
                             "tracked_buttons": 30, "target_notification_counts": [[1, 1] for _ in range(30)]}
            if heap_control:
                notifications = {"notifications": 0, "all_notifications": 0, "unmatched_notifications": 0,
                                 "tracked_buttons": 0, "target_notification_counts": []}
            if invalid_notifications == "missing-count":
                del notifications["notifications"]
            elif invalid_notifications:
                if heap_control:
                    notifications["all_notifications"] = notifications["unmatched_notifications"] = 1
                else:
                    notifications["target_notification_counts"][0] = [0, 2]
            scan_labels = (["baseline", "removed-10", "removed-30", "observer-exited"] if system_baseline else
                           ["baseline", "registered-10", "removed-10", "removed-20", "removed-30", "observer-exited"])
            if heap_diagnostics:
                scan_labels.insert(1, "added-10")
            if copy_lifetime:
                scan_labels = []
            scanned = []
            commands = []
            processes = []
            protocol = []
            real_settle = PROBE.ax_startup_baseline.settle
            clock = [0.0]
            startup_timeouts = []
            counter = itertools.count(step=0.25)
            def monotonic():
                if not settled_startup:
                    return next(counter)
                clock[0] += 0.01
                return clock[0]
            def sleep(seconds):
                if settled_startup:
                    clock[0] += seconds
            def settle(*args):
                baseline = real_settle(*args)
                scanned.append("baseline")
                protocol.append(("scan", "baseline"))
                return baseline

            class FixtureProcess:
                returncode = None

                def __init__(self, command, **_kwargs):
                    self.args = command
                    self.is_reader = pathlib.Path(command[0]).name == "ax-reader"
                    self.environment = _kwargs.get("env")
                    if install_gate:
                        assert self.environment[EXTERNAL.INSTALL_ENV] == install_gate
                    if malloc_scribble:
                        assert ("MallocScribble" in self.environment) == (malloc_scribble == "on")
                        if malloc_scribble == "on":
                            assert self.environment["MallocScribble"] == "1"
                        if self.is_reader and not reference_validation:
                            for key in ("MallocStackLogging", "MallocStackLoggingNoCompact"):
                                assert self.environment.get(key) == os.environ.get(key)
                    elif self.is_reader:
                        assert self.environment is None
                    if reference_validation:
                        assert self.environment.get("MallocStackLogging") is None
                        assert self.environment["MallocStackLoggingNoCompact"] == "1"
                    if not self.is_reader:
                        environment = _kwargs["env"]
                        assert environment["MallocStackLoggingNoCompact"] == "1"
                        assert ("MallocStackLogging" in environment) == (not heap_diagnostics)
                        if not heap_diagnostics:
                            assert environment["MallocStackLogging"] == "1"
                    self.pid = 1235 if self.is_reader else 1234
                    processes.append(self)

                def poll(self):
                    return self.returncode

                def wait(self, timeout):
                    role = "reader" if self.is_reader else "host"
                    failure = (cleanup_failure or {}).get(role)
                    if failure and (failure == "stuck" or not getattr(self, "killed", False)):
                        raise subprocess.TimeoutExpired("original-reader-wait" if self.is_reader else "host-wait", timeout)
                    self.returncode = 0
                    if external_receipt and binary_drift and not self.is_reader:
                        target = prepared / EXTERNAL.EXECUTABLES["host"] if binary_drift == "prepared" else pathlib.Path(self.args[0])
                        target.write_bytes(b"changed after measurement")
                    if self.is_reader:
                        PROBE.write_json(state / "reader-completed.json", notifications)
                    return 0

                def terminate(self):
                    self.terminated = True

                def kill(self):
                    self.killed = True

            def run(command, **_kwargs):
                commands.append(command)
                output = ""
                if command[0].endswith("/lsregister") and ls_failure:
                    raise subprocess.TimeoutExpired("private-ls", 15)
                if "--capabilities" in command:
                    capability = {"trusted": True} if pathlib.Path(command[0]).name == "ax-reader" else {
                        "enabled": not system_baseline, "status": "system-baseline" if system_baseline else "enabled",
                        "images": {"AppKit": "synthetic", "CoreFoundation": "synthetic"}}
                    if empty_control_mode and pathlib.Path(command[0]).name != "ax-reader":
                        capability.update(empty_control_mode=empty_control_mode, enabled=empty_control_mode == "patched",
                                          status="enabled" if empty_control_mode == "patched" else "pure-appkit")
                    if install_gate and pathlib.Path(command[0]).name != "ax-reader":
                        capability.update(enabled=install_gate == "installed", status="enabled" if install_gate == "installed" else "probe-preflight-only", install_probe=AXInstallGateTests.state(install_gate))
                    output = json.dumps(capability)
                elif command[0] == "heap" and unavailable_cohorts:
                    raise OSError("allocation tool unavailable")
                elif command[0] == "leaks":
                    if settled_startup and not scanned:
                        self.assertEqual(host_state["allocatedButtons"], 0)
                        self.assertEqual(host_state["destroyedButtons"], 0)
                        self.assertEqual(host_state["compensations"], 0)
                        duration = startup_scan_durations[min(len(startup_timeouts), len(startup_scan_durations) - 1)] if startup_scan_durations else 0
                        self.assertGreaterEqual(_kwargs["timeout"], duration)
                        self.assertLessEqual(_kwargs["timeout"], 40)
                        if startup_timeouts: self.assertLess(_kwargs["timeout"], startup_timeouts[-1])
                        startup_timeouts.append(_kwargs["timeout"])
                        clock[0] += duration
                        return subprocess.CompletedProcess(command, 0,
                            "Process 1234: 0 leaks for 0 total leaked bytes.\n", "")
                    capture = next((value for value in command if value.startswith("--outputGraph=")), None)
                    if capture:
                        self.assertEqual("--fullStackHistory" in command, heap_diagnostics)
                        if settled_shadow:
                            self.assertEqual(_kwargs["timeout"], 15)
                            label = pathlib.Path(capture.split("=", 1)[1]).stem
                            if label != "auxiliary-late":
                                self.assertEqual(scanned, ["baseline"])
                                self.assertEqual(host_state["allocatedButtons"], 0)
                                self.assertEqual(host_state["compensations"], 0)
                            else:
                                self.assertEqual(scanned, scan_labels)
                            if shadow_capture_failed:
                                return subprocess.CompletedProcess(command, 2, "", "private capture failure")
                        if live_attribution:
                            self.assertIn(scanned[-1], ("baseline", failed_scan))
                            self.assertEqual(pathlib.Path(capture.split("=", 1)[1]).stem, scanned[-1])
                            if live_capture_failure == "timeout":
                                raise subprocess.TimeoutExpired("auxiliary capture", 60)
                            if live_capture_failure == "failed":
                                return subprocess.CompletedProcess(command, 2, "", "private failure")
                        if terminal_origin or ci_failure_evidence:
                            self.assertEqual(scanned, scan_labels)
                            self.assertEqual(processes[0].poll(), None)
                            self.assertEqual(processes[1].poll(), 0)
                            if ci_failure_evidence:
                                self.assertEqual(_kwargs["timeout"], 15)
                                if ci_capture_failed:
                                    return subprocess.CompletedProcess(command, 2, "", "private capture failure")
                            if terminal_timeout:
                                raise subprocess.TimeoutExpired("terminal capture", 60)
                        pathlib.Path(capture.split("=", 1)[1]).touch()
                        return subprocess.CompletedProcess(command, 0, "", "")
                    if terminal_origin and command[-1].endswith("terminal.memgraph"):
                        self.assertTrue(all(process.returncode == 0 for process in processes))
                        return subprocess.CompletedProcess(command, 0, "Process 1234: 0 leaks for 0 total leaked bytes.\n", "")
                    if "--list" in command:
                        self.assertTrue(all(process.returncode == 0 for process in processes))
                        if unavailable_cohorts:
                            return subprocess.CompletedProcess(command, 1, AXHeapDiagnosticTests.report(), "")
                        return subprocess.CompletedProcess(command, 0, "Process 1234: 0 leaks for 0 total leaked bytes.\n", "")
                    if settled_shadow and _kwargs["timeout"] <= 5:
                        if shadow_timeout:
                            raise subprocess.TimeoutExpired(command, _kwargs["timeout"])
                        self.assertEqual(scanned, ["baseline"])
                        self.assertEqual(host_state["allocatedButtons"], 0)
                        self.assertEqual(host_state["compensations"], 0)
                        return subprocess.CompletedProcess(command, 1,
                            "Process 1234: 287 leaks for 18768 total leaked bytes.\n"
                            "STACK OF 3 INSTANCES OF 'ROOT CYCLE: NSXPCConnection':\n"
                            "  287 (18768 bytes) ROOT CYCLE: NSXPCConnection\n", "")
                    label = scan_labels[len(scanned)]
                    scanned.append(label)
                    protocol.append(("scan", label))
                    if label in ("added-10", "registered-10"):
                        reader_command = json.loads((state / "reader-command.json").read_text())
                        self.assertEqual(reader_command["sequence"], 2 if label == "registered-10" and not reference_idle else 1)
                        self.assertEqual(host_state["destroyedButtons"], 0)
                    nodes, size = (287, 18_768) if label == failed_scan else (280, 18_416)
                    if settled_startup and label != failed_scan:
                        return subprocess.CompletedProcess(command, 0,
                            "Process 1234: 0 leaks for 0 total leaked bytes.\n", "")
                    output = (f"Process 1234: {nodes} leaks for {size} total leaked bytes.\n"
                              "STACK OF 3 INSTANCES OF 'ROOT CYCLE: NSXPCConnection':\n"
                              f"  {nodes} ({size} bytes) ROOT CYCLE: NSXPCConnection\n")
                return subprocess.CompletedProcess(command, 1 if command[0] == "leaks" else 0, output, "")

            def wait_json(path, predicate, _processes, **kwargs):
                if path.name == "reader-ready.json":
                    command = json.loads((state / "reader-command.json").read_text())
                    receipt = {"sequence": command["sequence"], "buttons": host_state["buttons"],
                               "registrations": host_state["buttons"] * 2,
                               "notifications": host_state["destroyedButtons"] * 2,
                               "all_notifications": host_state["destroyedButtons"] * 2,
                               "unmatched_notifications": 0,
                               "tracked_buttons": host_state["allocatedButtons"],
                               "target_notification_counts": [] if heap_control else [[1, 1]] * host_state["allocatedButtons"]}
                    protocol.append(("observe", command["sequence"]))
                    if invalid_control_reader and command["sequence"] == invalid_control_reader[0]:
                        receipt[invalid_control_reader[1]] = 1
                else:
                    command_path = state / "command.json"
                    if command_path.exists():
                        command = json.loads(command_path.read_text())
                        protocol.append(("command", command["action"]))
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
                    if copy_lifetime:
                        count = host_state["destroyedButtons"]
                        receipt["copyLifetime"] = {"ordinary": count, "mutable": count, "liveOrdinary": 0,
                                                   "liveMutable": 0, "invalid": 0}
                        if invalid_copy_lifetime and receipt["sequence"] == invalid_copy_lifetime[0]:
                            key, value = invalid_copy_lifetime[1:]
                            if key is None:
                                del receipt["copyLifetime"]
                            else:
                                receipt["copyLifetime"][key] = value
                    if invalid_control_host and receipt["sequence"] == invalid_control_host[0]:
                        receipt[invalid_control_host[1]] = 1
                if install_gate and path.name == "ready.json" and invalid_install_gate and receipt["sequence"] == invalid_install_gate[0]:
                    receipt["install_probe"] = invalid_install_gate[1]
                if malloc_scribble and not external_receipt:
                    process = next(process for process in processes
                                   if process.is_reader == (path.name == "reader-ready.json"))
                    value = process.environment.get("MallocScribble")
                    receipt["malloc_scribble"] = "unset" if value is None else "1" if value == "1" else "other"
                    if invalid_allocator and invalid_allocator[0] == ("reader" if process.is_reader else "host"):
                        if invalid_allocator[1] is None:
                            del receipt["malloc_scribble"]
                        else:
                            receipt["malloc_scribble"] = invalid_allocator[1]
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
            if heap_control:
                arguments.append("--heap-control")
            if copy_lifetime:
                arguments.append("--copy-lifetime")
            if ci_failure_evidence:
                arguments.append("--ci-failure-evidence")
            if settled_startup:
                arguments.append("--settle-startup-baseline")
            if malloc_scribble:
                arguments.extend(["--malloc-scribble", malloc_scribble])
            if terminal_origin:
                arguments.append("--terminal-origin")
            if settled_shadow:
                arguments.append("--settled-baseline-shadow")
            if live_attribution:
                arguments.append("--live-attribution")
            if reference_validation:
                arguments.append("--reference-validation")
            if reference_idle:
                arguments.append("--reference-idle")
            if install_gate:
                arguments.extend(["--install-gate", install_gate])
            if empty_control_mode:
                arguments.extend(["--empty-control-mode", empty_control_mode])
            def startup_metadata(pid):
                process = next(process for process in processes if process.pid == pid)
                role = "reader" if process.is_reader else "host"
                if invalid_allocator and invalid_allocator[0] == role:
                    if startup_error is not None:
                        raise startup_error
                    raise RuntimeError("Owned child startup environment unavailable")
                return (os.fsencode(process.args[0]), [os.fsencode(process.args[0])],
                        {os.fsencode(key): os.fsencode(value) for key, value in process.environment.items()})

            hash_io_error = PermissionError(13, "private-hash-error", "/private/secret")
            propagated_hash_error = None
            require_hashes = PROBE.require_fixture_hashes

            def require_fixture_hashes(directory, expected):
                if hash_io_failure and scanned == scan_labels:
                    phase = "complete" if processes[0].returncode is None else "final"
                    target = "prepared" if directory == prepared else "working"
                    if hash_io_failure == (phase, target):
                        raise hash_io_error
                return require_hashes(directory, expected)

            if external_receipt:
                prepared = temporary / "prepared"
                for role, name in EXTERNAL.EXECUTABLES.items():
                    path = prepared / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(role.encode())
                    path.chmod(0o700)
                sources = ["QuickFileApp/AXCompatibility.m", "QuickFileApp/AXCompatibility.h",
                           "Scripts/tests/fixtures/AXCompatibilityNotifications.m", "Scripts/tests/fixtures/AXCompatibilityReader.swift"]
                PROBE.write_json(prepared / "fixture-build.json", {"schema": 1, "build_mode": "ordinary",
                    "sources": {name: PROBE.hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources},
                    "executables": EXTERNAL.fixture_hashes(prepared)})
                if empty_control_mode:
                    PROBE.write_json(prepared / "fixture-build.json", AXPureAppKitControlTests.manifest(empty_control_mode, EXTERNAL.fixture_hashes(prepared)))
                if install_gate:
                    PROBE.write_json(prepared / "fixture-build.json", AXInstallGateTests.manifest(EXTERNAL.fixture_hashes(prepared)))
                arguments.extend(["--external-startup-receipt", "--prepared-fixture-directory", str(prepared)])
            with mock.patch.object(EXTERNAL, "read_procargs", side_effect=startup_metadata) as startup_reads, \
                    mock.patch.object(PROBE.ax_startup_baseline, "settle", side_effect=settle), \
                    mock.patch.object(PROBE, "read_procargs", side_effect=startup_metadata), \
                    mock.patch.object(PROBE, "require_fixture_hashes", side_effect=require_fixture_hashes), \
                    mock.patch.object(sys, "argv", arguments), mock.patch.object(PROBE, "ROOT", ProbeRoot()), \
                    mock.patch.object(PROBE.subprocess, "run", side_effect=run), \
                    mock.patch.object(PROBE.subprocess, "Popen", side_effect=FixtureProcess), \
                    mock.patch.object(PROBE, "wait_json", side_effect=wait_json), \
                    mock.patch.object(PROBE.os, "uname", return_value=mock.Mock(machine="arm64")), \
                    mock.patch.object(PROBE, "disassemble_symbols", return_value={"source": "owned mock"}) as disassembled, \
                    mock.patch.object(PROBE.time, "sleep", side_effect=sleep), \
                    mock.patch.object(PROBE.time, "monotonic", side_effect=monotonic), \
                    contextlib.redirect_stdout(io.StringIO()):
                try:
                    exit_code = PROBE.main()
                except subprocess.TimeoutExpired as error:
                    if not cleanup_failure or "reader" not in cleanup_failure:
                        raise
                    self.assertEqual(error.cmd, "original-reader-wait")
                    exit_code = 1
                except ValueError as error:
                    if error is not startup_error:
                        raise
                    exit_code = 1
                except PermissionError as error:
                    if error is not hash_io_error or not hash_io_failure:
                        raise
                    propagated_hash_error = error
                    exit_code = 1
            summary = json.loads((records / "result.json").read_text())
            if settled_shadow:
                receipt = json.loads((records / "settled-baseline-shadow.json").read_text())
                self.assertEqual(scanned, scan_labels)
                self.assertEqual(len(scanned), 6)
                self.assertEqual(receipt["status"], "not_settled" if shadow_timeout else "observed-stable")
                self.assertEqual(receipt["chosen_index"], None if shadow_timeout else 1)
                self.assertEqual(len(receipt["captures"]), 2 if shadow_timeout else 3)
                self.assertLessEqual(receipt["baseline_finished_monotonic"], receipt["settling_started_monotonic"])
                self.assertLessEqual(receipt["baseline_finished_monotonic"], receipt["captures"][0]["start_monotonic"])
                self.assertLessEqual(receipt["captures"][0]["end_monotonic"], receipt["settling_started_monotonic"])
                for capture in receipt["captures"][:-1]:
                    self.assertLessEqual(capture["end_monotonic"], receipt["first_measurement_cycle_monotonic"])
                self.assertLessEqual(receipt["first_measurement_cycle_monotonic"], receipt["last_original_scan_finished_monotonic"])
                self.assertLessEqual(receipt["last_original_scan_finished_monotonic"], receipt["captures"][-1]["start_monotonic"])
                self.assertEqual(receipt["original_strict_verdict"], "failed" if failed_scan or invalid_notifications or insufficient_compensation else "passed")
                self.assertEqual(receipt["candidate_hypothetical_verdict"], "unavailable" if shadow_capture_failed or shadow_timeout else "failed" if invalid_notifications or insufficient_compensation else "passed")
                self.assertEqual(receipt["environments"]["host"]["MallocStackLogging"], "1")
                self.assertEqual(receipt["environments"]["host"]["MallocStackLoggingNoCompact"], "1")
                for row in json.loads((records / "scans.json").read_text()):
                    self.assertEqual(row["stdout_sha256"], hashlib.sha256((records / (row["label"] + "-original.stdout.txt")).read_bytes()).hexdigest())
                self.assertTrue(summary["cleanup"]["processes_exited"])
                if reference_idle:
                    self.assertEqual([p for p in protocol if p[0] == "observe"], [("observe", 1)])
            self.assertEqual([call.args[0] for call in startup_reads.call_args_list],
                             [process.pid for process in processes] if external_receipt else [])
            if isinstance(startup_error, ValueError):
                failures = json.loads((records / "startup-failures.json").read_text())
                EXTERNAL.validate_startup_failures(failures)
                self.assertEqual(failures, [
                    {"stage": "external-startup-" + invalid_allocator[0], "reason": "unclassified", "errno": None},
                    {"stage": "external-startup-final", "reason": "receipt_incomplete", "errno": None}])
                self.assertNotIn("private", json.dumps(failures))
                self.assertEqual(scanned, [])
                self.assertTrue(summary["cleanup"]["processes_exited"])
                self.assertTrue(summary["cleanup"]["primary_exception"])
                self.assertTrue(all(process.returncode == 0 for process in processes))
                self.assertTrue(any(command[0].endswith("/lsregister") for command in commands))
                return exit_code, summary
            if cleanup_failure:
                cleanup = json.loads((records / "process-cleanup.json").read_text())
                self.assertEqual(summary["cleanup"], cleanup)
                self.assertTrue(any(command[0].endswith("/lsregister") for command in commands))
                self.assertTrue((state / "quit").exists())
                for role, failure in cleanup_failure.items():
                    self.assertTrue(cleanup[role]["terminate_sent"])
                    self.assertTrue(cleanup[role]["kill_sent"])
                    self.assertEqual(cleanup[role]["exited"], failure != "stuck")
                if "reader" in cleanup_failure:
                    self.assertTrue(cleanup["primary_exception"])
                    self.assertEqual(scanned, scan_labels[:-1])
                else:
                    self.assertEqual(scanned, scan_labels)
                if external_receipt:
                    final_receipt = json.loads((records / "external-startup.json").read_text())
                    self.assertEqual(final_receipt["binary_reuse_verified"], cleanup["processes_exited"])
                if terminal_origin and not cleanup["processes_exited"]:
                    self.assertFalse(any(command[0] == "leaks" and command[-1].endswith("terminal.memgraph") for command in commands))
                    self.assertEqual(json.loads((records / "terminal-snapshot.json").read_text())["parsing_status"], "unavailable")
                self.assertNotIn("private-ls", json.dumps(cleanup))
                return exit_code, summary
            self.assertEqual(scanned, scan_labels)
            self.assertEqual(json.loads((records / "notifications.json").read_text()), notifications)
            self.assertTrue((state / "stop-reader").exists())
            self.assertTrue((state / "quit").exists())
            self.assertTrue(all(process.returncode == 0 for process in processes))
            if not copy_lifetime:
                self.assertEqual(summary["scans"][0]["label"], "baseline")
            scans = [] if copy_lifetime else json.loads((records / "scans.json").read_text())
            if install_gate and not invalid_install_gate:
                for scan in scans:
                    EXTERNAL.validate_install_gate_state(scan["host"]["install_probe"], install_gate)
            if hash_io_failure:
                phase, target = hash_io_failure
                self.assertEqual(type(hash_io_error), PermissionError)
                self.assertEqual(hash_io_error.errno, 13)
                self.assertIs(propagated_hash_error, hash_io_error if phase == "complete" else None)
                failures = json.loads((records / "startup-failures.json").read_text())
                EXTERNAL.validate_startup_failures(failures)
                self.assertEqual(failures, [{"stage": "external-startup-" + phase,
                    "reason": target + "_hash", "errno": 13}])
                self.assertNotIn("private", json.dumps(failures))
                self.assertEqual(summary["cleanup"]["primary_exception"], phase == "complete")
                self.assertEqual(summary["cleanup"]["errors"], [] if phase == "complete" else ["external_receipt"])
                self.assertTrue(summary["cleanup"]["processes_exited"])
                self.assertTrue(any(command[0].endswith("/lsregister") for command in commands))
                self.assertEqual([row["stage"] for row in summary["validation_errors"]],
                    ([failed_scan] if failed_scan else []) + ["execution" if phase == "complete" else "cleanup"])
                counts = REPORT.validation_failure_counts(summary)
                self.assertEqual(counts["allocator_environment"], 0)
                self.assertEqual(counts["other"], 1)
                self.assertEqual(counts["heap_baseline"], int(failed_scan is not None))
                self.assertEqual(len(scans), 6)
                return exit_code, summary
            if external_receipt:
                self.assertFalse(any("clang" in command or "swiftc" in command or "codesign" in command for command in commands))
                if not binary_drift:
                    self.assertEqual(EXTERNAL.fixture_hashes(work), EXTERNAL.fixture_hashes(prepared))
                receipt = json.loads((records / "external-startup.json").read_text())
                failures = json.loads((records / "startup-failures.json").read_text())
                EXTERNAL.validate_startup_failures(failures)
                self.assertEqual(len(failures), 3 if invalid_allocator else 1 if binary_drift else 0)
                if invalid_allocator:
                    self.assertEqual(failures[0], EXTERNAL.startup_failure("external-startup-" + invalid_allocator[0],
                        startup_error if startup_error is not None else RuntimeError("unknown")))
                    self.assertEqual([row["reason"] for row in failures[1:]], ["receipt_incomplete"] * 2)
                    self.assertEqual([row["stage"] for row in failures[1:]], list(EXTERNAL.STARTUP_STAGES[2:]))
                    self.assertEqual(REPORT.validation_failure_counts(summary)["allocator_environment"], 3)
                    self.assertTrue(any(row["message"] == str(startup_error or RuntimeError("Owned child startup environment unavailable"))
                        for row in summary["validation_errors"]))
                elif binary_drift:
                    self.assertEqual(failures, [{"stage": "external-startup-final",
                        "reason": "prepared_hash" if binary_drift == "prepared" else "working_hash", "errno": None}])
                if not invalid_allocator and not binary_drift:
                    EXTERNAL.validate_external_receipt(receipt, malloc_scribble, EXTERNAL.fixture_hashes(prepared), install_gate)
            else:
                product_build = next(command for command in commands if "-fno-objc-arc" in command)
                host_build = next(command for command in commands if "-fobjc-arc" in command)
                reader_build = next(command for command in commands if "swiftc" in command)
                for build in (host_build, reader_build):
                    self.assertEqual("-DQUICKFILE_AX_MALLOC_RECEIPT" in build, malloc_scribble is not None)
            if malloc_scribble:
                self.assertEqual(summary["malloc_scribble"], json.loads((records / "malloc-scribble.json").read_text()))
                if not invalid_allocator:
                    PROBE.validate_malloc_scribble_receipt(summary["malloc_scribble"], malloc_scribble)
            else:
                self.assertNotIn("malloc_scribble", summary)
                self.assertFalse((records / "malloc-scribble.json").exists())
            if not external_receipt:
                for build in (product_build, host_build):
                    self.assertEqual("-DQUICKFILE_AX_COPY_LIFETIME" in build, copy_lifetime)
            if heap_diagnostics:
                diagnostic = json.loads((records / "heap-diagnostics.json").read_text())
                REPORT.validate_heap_diagnostics_summary(diagnostic)
                self.assertEqual(diagnostic["status"], "complete")
                self.assertEqual(diagnostic["cohorts_status"], "unavailable" if unavailable_cohorts else "complete")
                live_scans = [command for command in commands if command[0] == "leaks" and command[-1] == "1234"]
                self.assertEqual(len(live_scans), len(scan_labels))
                self.assertTrue(all(any(value.startswith("--outputGraph=") for value in command) for command in live_scans))
                decoded = [command[-1] for command in commands if command[0] == "leaks" and "--groupByType" in command]
                self.assertEqual(decoded, [str(work / "heap" / (label + ".memgraph")) for label in scan_labels])
                self.assertEqual([point["label"] for point in diagnostic["checkpoints"]], list(REPORT.HEAP_LABELS[1:]))
            elif terminal_origin:
                terminal = json.loads((records / "terminal-snapshot.json").read_text())
                REPORT.validate_terminal_snapshot(terminal)
                self.assertEqual(terminal["capture_status"], "timeout" if terminal_timeout else "complete")
                self.assertEqual(terminal["status"], "unavailable" if terminal_timeout else "complete")
                self.assertFalse((records / "heap-diagnostics.json").exists())
                live_scans = [command for command in commands if command[0] == "leaks" and command[-1] == "1234"]
                self.assertEqual(len(live_scans), 7)
                self.assertTrue(all(command == ["leaks", "--noContent", "--groupByType", "--nosources", "--fullStacks", "1234"]
                                    for command in live_scans[:6]))
                self.assertEqual(sum(command[0] == "leaks" and command[-1].endswith("terminal.memgraph") for command in commands),
                                 0 if terminal_timeout else 2)
            else:
                self.assertFalse((records / "heap-diagnostics.json").exists())
                self.assertEqual((work / "heap").exists(), live_attribution)
                self.assertFalse(any(command[0] == "heap" for command in commands))
                for scan_command in (command for command in commands if command[0] == "leaks" and not any(arg.startswith("--outputGraph=") for arg in command)):
                    self.assertEqual(scan_command, ["leaks", "--noContent", "--groupByType", "--nosources", "--fullStacks", "1234"])
                if ci_failure_evidence:
                    captured = json.loads((records / "failure-capture.json").read_text())
                    expected = "failed" if ci_capture_failed else "timeout" if terminal_timeout else "complete"
                    self.assertEqual(captured["status"], expected if failed_scan else "not_attempted")
                    captures = [command for command in commands if any(arg.startswith("--outputGraph=") for arg in command)]
                    self.assertEqual(len(captures), int(failed_scan is not None))
                    if failed_scan:
                        self.assertEqual(captured["after_label"], "observer-exited")
                        self.assertEqual(captured["graph_sha256"], None if terminal_timeout or ci_capture_failed else hashlib.sha256(b"").hexdigest())
                    for row in scans:
                        payload = (records / (row["label"] + "-original.stdout.txt")).read_bytes()
                        self.assertEqual(row["stdout_sha256"], hashlib.sha256(payload).hexdigest())
                if live_attribution:
                    captures = json.loads((records / "live-captures.json").read_text())
                    self.assertEqual([row["label"] for row in captures], ["baseline"] + ([failed_scan] if failed_scan else []))
                    self.assertEqual(len(scan_labels), 6)
                    for row in captures:
                        self.assertEqual(row["status"], live_capture_failure or "complete")
                        self.assertEqual(row["stdout_sha256"], hashlib.sha256((records / (row["label"] + "-live.stdout.txt")).read_bytes()).hexdigest())
            if not copy_lifetime:
                self.assertEqual(scans[0]["host"]["allocatedButtons"], 0)
                self.assertEqual(scans[-1]["host"]["destroyedButtons"], 0 if heap_control else 30)
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
            if not system_baseline and not copy_lifetime:
                registered = next(scan for scan in scans if scan["label"] == "registered-10")
                self.assertEqual(registered["host"]["allocatedButtons"], 0 if heap_control else 10)
                self.assertEqual(registered["host"]["destroyedButtons"], 0)
            if not system_baseline and not copy_lifetime:
                add, remove = ("checkpoint", "checkpoint") if heap_control else ("add", "remove")
                expected_protocol = [
                    ("observe", 1), ("command", "checkpoint"), ("scan", "baseline"),
                    ("command", add), *([("scan", "added-10")] if heap_diagnostics else []), ("observe", 2),
                    ("command", "checkpoint"), ("scan", "registered-10"),
                    ("command", remove), ("observe", 3), ("scan", "removed-10"),
                    ("command", add), ("observe", 4), ("command", remove), ("observe", 5), ("scan", "removed-20"),
                    ("command", add), ("observe", 6), ("command", remove), ("observe", 7), ("scan", "removed-30"),
                    ("command", "checkpoint"), ("scan", "observer-exited")]
                if reference_idle:
                    expected_protocol = [item for item in expected_protocol if item[0] != "observe" or item[1] == 1]
                if settled_shadow:
                    expected_protocol[3:3] = [("command", "checkpoint")] * (1 if shadow_timeout else 2)
                if settled_startup:
                    receipt = summary["startup_baseline"]
                    self.assertEqual(receipt["status"], "observed-stable")
                    expected_protocol[1:2] = [("command", "checkpoint")] * len(receipt["probes"])
                    self.assertEqual(scans[0]["stdout_sha256"], receipt["probes"][-1]["stdout_sha256"])
                    self.assertEqual(scans[0]["host"]["allocatedButtons"], 0)
                self.assertEqual(protocol, expected_protocol)
            if reference_validation:
                receipt = json.loads((records / "reference-validation-input.json").read_text())
                self.assertEqual([row["label"] for row in receipt["checkpoint_windows"]], list(REPORT.HEAP_LABELS))
                self.assertTrue(all(row["end_monotonic"] >= row["start_monotonic"] for row in receipt["checkpoint_windows"]))
                self.assertEqual(receipt["environments"], dict.fromkeys(("host", "reader"), {
                    "malloc_stack_logging": "unset", "malloc_stack_logging_no_compact": "1"}))
                self.assertEqual(summary["reader_mode"], "initial-query-only" if reference_idle else "subscribed")
            if heap_diagnostics or malloc_scribble:
                self.assertEqual(summary["mode"], "heap-control" if heap_control else "product")
                self.assertEqual(summary["scan_mode"], "diagnostic" if heap_diagnostics else "live")
            if heap_control:
                for scan in scans:
                    PROBE.validate_control_host(scan["host"])
                self.assertEqual(summary["ordinary_compensations"], 0)
                self.assertEqual(summary["mutable_compensations"], 0)
                self.assertEqual(summary["notifications"], notifications.get("notifications"))
            if copy_lifetime:
                self.assertFalse(any(command[0] == "leaks" for command in commands))
                self.assertFalse((records / "scans.json").exists())
                self.assertFalse(list(records.glob("*-leaks.txt")))
                self.assertEqual(protocol, [
                    ("observe", 1), ("command", "checkpoint"), ("command", "add"), ("observe", 2),
                    ("command", "checkpoint"), ("command", "remove"), ("observe", 3),
                    ("command", "add"), ("observe", 4), ("command", "remove"), ("observe", 5),
                    ("command", "add"), ("observe", 6), ("command", "remove"), ("observe", 7),
                    ("command", "checkpoint")])
                hosts = json.loads((records / "copy-lifetime-hosts.json").read_text())
                self.assertEqual([host["sequence"] for host in hosts], list(range(10)))
                self.assertEqual([host.get("action") for host in hosts],
                                 [None, "checkpoint", "add", "checkpoint", "remove", "add", "remove", "add", "remove", "checkpoint"])
                self.assertEqual(hosts[0]["allocatedButtons"], 0)
                self.assertEqual(hosts[-1]["destroyedButtons"], 30)
                self.assertEqual(summary["mode"], "copy-lifetime")
                self.assertIs(summary["instrumented"], True)
                self.assertEqual(summary["copy_lifetime"], hosts[-1].get("copyLifetime"))
                self.assertTrue(all("copyLifetime" in checkpoint for checkpoint in summary["checkpoints"]))
                self.assertEqual(summary["idle_seconds"], 2)
                for key in ("ax_leak_nodes", "baseline_leak_nodes", "baseline_leak_bytes", "leak_nodes", "leak_bytes", "scans"):
                    self.assertNotIn(key, summary)
                if invalid_copy_lifetime:
                    sequence, key, value = invalid_copy_lifetime
                    if key is None:
                        self.assertNotIn("copyLifetime", hosts[sequence])
                    else:
                        self.assertEqual(hosts[sequence]["copyLifetime"][key], value)
            else:
                self.assertFalse((records / "copy-lifetime-hosts.json").exists())
            if exit_code:
                self.assertEqual(json.loads((records / "validation-errors.json").read_text()), summary["validation_errors"])
            return exit_code, summary

    def test_cleanup_kills_each_stuck_process_without_masking_initial_failure(self):
        for failures in ({"reader": "kill", "host": "kill"}, {"reader": "stuck", "host": "stuck"}):
            code, summary = self.exercise_runner(cleanup_failure=failures, ls_failure=True,
                malloc_scribble="off", external_receipt=True, failed_scan="registered-10")
            self.assertEqual(code, 1)
            self.assertEqual(summary["coverage"], "failed")
            self.assertTrue(any(error["stage"] == "registered-10" for error in summary["validation_errors"]))
            self.assertIn("launch_services", summary["cleanup"]["errors"])

    def test_terminal_analysis_waits_for_confirmed_exit_and_keeps_strict_failure(self):
        code, summary = self.exercise_runner(cleanup_failure={"host": "stuck"},
            malloc_scribble="off", external_receipt=True, terminal_origin=True, failed_scan="registered-10")
        self.assertEqual(code, 1)
        self.assertFalse(summary["cleanup"]["processes_exited"])
        self.assertTrue(any(error["stage"] == "registered-10" for error in summary["validation_errors"]))
        code, summary = self.exercise_runner(cleanup_failure={"host": "kill"})
        self.assertEqual(code, 0)
        self.assertTrue(summary["cleanup"]["processes_exited"])

    def test_external_startup_reuses_bytes_and_preserves_live_protocol_and_strict_failures(self):
        for setting, control, failure in itertools.product(("off", "on"), (False, True), (None, "registered-10")):
            with self.subTest(setting=setting, control=control, failure=failure):
                code, summary = self.exercise_runner(external_receipt=True, malloc_scribble=setting,
                                                     heap_control=control, failed_scan=failure)
                self.assertEqual(code, int(failure is not None))
                self.assertEqual(summary["receipt_mode"], "external-startup")

    def test_install_gate_actual_hosts_keep_protocol_and_do_not_reuse_capability_state(self):
        for mode, failed_scan in itertools.product(EXTERNAL.INSTALL_MODES, (None, "registered-10")):
            code, summary = self.exercise_runner(install_gate=mode, external_receipt=True, malloc_scribble="off", heap_control=True, failed_scan=failed_scan)
            self.assertEqual(code, int(failed_scan is not None))
            self.assertEqual(summary["install_gate"], mode)
            self.assertEqual(summary["product_compensation_enabled"], mode == "installed")
            self.assertEqual(len(summary["scans"]), 6)
        for mode, sequence, value in itertools.product(EXTERNAL.INSTALL_MODES, (0, 3, 9), (None, {"mode": "secret"})):
            code, summary = self.exercise_runner(install_gate=mode, external_receipt=True, malloc_scribble="off", heap_control=True,
                                                invalid_install_gate=(sequence, value))
            self.assertEqual(code, 1)
            self.assertEqual(len(summary["scans"]), 6)
            self.assertIn("install-gate-host-" + str(sequence), [row["stage"] for row in summary["validation_errors"]])

    def test_install_gate_frozen_hosts_reuse_bytes_and_preserve_each_strict_checkpoint(self):
        for mode, failure in itertools.product(EXTERNAL.INSTALL_MODES, (None, "added-10", "registered-10", "removed-20")):
            with self.subTest(mode=mode, failure=failure):
                code, result = self.exercise_runner(install_gate=mode, external_receipt=True,
                    malloc_scribble="off", heap_control=True, heap_diagnostics=True, failed_scan=failure)
                self.assertEqual(code, int(failure is not None))
                self.assertEqual(result["receipt_mode"], "external-startup")
                self.assertEqual(result["scan_mode"], "diagnostic")
                self.assertEqual(result["install_gate"], mode)
                self.assertEqual([scan["label"] for scan in result["scans"]], list(REPORT.HEAP_LABELS))
                if failure:
                    self.assertEqual([row["stage"] for row in result["validation_errors"]], [failure])
        for mode in EXTERNAL.INSTALL_MODES:
            code, result = self.exercise_runner(install_gate=mode, external_receipt=True,
                malloc_scribble="off", heap_control=True, heap_diagnostics=True, binary_drift=True)
            self.assertEqual(code, 1)
            self.assertEqual([row["stage"] for row in result["validation_errors"]], ["external-startup-final"])

    def test_reference_cases_keep_seven_scans_and_each_strict_failure(self):
        cases = ((False, None, False), (True, None, False),
                 (True, "pure-appkit", False), (True, "pure-appkit", True))
        for (control, empty, idle), failure in itertools.product(cases, (None, "added-10", "registered-10", "removed-20")):
            with self.subTest(control=control, empty=empty, idle=idle, failure=failure):
                code, result = self.exercise_runner(external_receipt=True, malloc_scribble="off",
                    heap_diagnostics=True, heap_control=control, empty_control_mode=empty,
                    reference_validation=True, reference_idle=idle, failed_scan=failure)
                self.assertEqual(code, int(failure is not None))
                self.assertEqual([scan["label"] for scan in result["scans"]], list(REPORT.HEAP_LABELS))
                self.assertEqual(result["reader_mode"], "initial-query-only" if idle else "subscribed")
                if failure:
                    self.assertEqual([row["stage"] for row in result["validation_errors"]], [failure])

    def test_reference_modes_reject_conflicts_before_process_launch(self):
        base = ["probe", "--work-directory", "unused", "--records-directory", "unused-records",
            "--reference-validation", "--heap-diagnostics", "--external-startup-receipt",
            "--prepared-fixture-directory", "unused-prepared", "--malloc-scribble", "off"]
        variants = [base + extra for extra in (["--live-attribution"], ["--install-gate", "installed"],
            ["--empty-control-mode", "patched"], ["--reference-idle"], ["--terminal-origin"],
            ["--prepare-external-fixture"], ["--reference-idle", "--heap-control"],
            ["--reference-idle", "--empty-control-mode", "pure-appkit"])]
        variants += [[item for item in base if item != "--heap-diagnostics"],
                     ["probe", "--work-directory", "unused", "--records-directory", "unused-records", "--reference-idle"]]
        for arguments in variants:
            with self.subTest(arguments=arguments), mock.patch.object(sys, "argv", arguments), \
                    mock.patch.object(PROBE.subprocess, "run") as run, mock.patch.object(PROBE.subprocess, "Popen") as spawn, \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as outcome:
                PROBE.main()
            self.assertEqual(outcome.exception.code, 2)
            run.assert_not_called()
            spawn.assert_not_called()

    def test_slow_startup_scan_uses_remaining_total_budget(self):
        code, result = self.exercise_runner(settled_startup=True, startup_scan_durations=(13, 1))
        self.assertEqual(code, 0)
        receipt = result['startup_baseline']
        self.assertGreaterEqual(receipt['probes'][0]['elapsed_ms'], 13000)
        self.assertGreaterEqual(receipt['probes'][-1]['elapsed_ms'], 20000)
        self.assertLess(receipt['probes'][-1]['elapsed_ms'], 40000)

    def test_settled_startup_finishes_before_targets_and_retains_later_failures(self):
        for failure in (None, "registered-10", "removed-20", "observer-exited"):
            with self.subTest(failure=failure):
                code, result = self.exercise_runner(settled_startup=True, ci_failure_evidence=True, failed_scan=failure)
                self.assertEqual(code, int(failure is not None))
                self.assertEqual(len(result["scans"]), 6)
                self.assertEqual(result["notifications"], 60)
                self.assertEqual(result["destroyed_buttons"], 30)
                self.assertEqual(result["ordinary_compensations"], 30)
                self.assertEqual(result["mutable_compensations"], 30)
                self.assertTrue(result["cleanup"]["processes_exited"])

    def test_ci_failure_capture_follows_original_scans_and_preserves_failure(self):
        for failure, timeout in itertools.product((None, "registered-10", "removed-20"), (False, True)):
            with self.subTest(failure=failure, timeout=timeout):
                code, result = self.exercise_runner(ci_failure_evidence=True, failed_scan=failure,
                                                    terminal_timeout=timeout)
                self.assertEqual(code, int(failure is not None))
                self.assertEqual(len(result["scans"]), 6)
                self.assertEqual(result["notifications"], 60)
                self.assertTrue(result["cleanup"]["processes_exited"])

    def test_ci_capture_tool_failure_keeps_original_strict_failure_and_cleanup(self):
        code, result = self.exercise_runner(ci_failure_evidence=True, failed_scan="removed-20", ci_capture_failed=True)
        self.assertEqual(code, 1)
        self.assertEqual([row["stage"] for row in result["validation_errors"]], ["removed-20"])
        self.assertEqual(len(result["scans"]), 6)
        self.assertEqual(result["notifications"], 60)
        self.assertTrue(result["cleanup"]["processes_exited"])

    def test_ci_failure_capture_rejects_measurement_mode_conflicts_before_launch(self):
        base = ["probe", "--work-directory", "unused", "--records-directory", "unused-records", "--ci-failure-evidence"]
        for extra in (["--system-baseline"], ["--heap-diagnostics"], ["--copy-lifetime"],
                      ["--live-attribution"], ["--malloc-scribble", "off"], ["--empty-control-mode", "pure-appkit"],
                      ["--terminal-origin"], ["--prepare-external-fixture"]):
            with self.subTest(extra=extra), mock.patch.object(sys, "argv", base + extra), \
                    mock.patch.object(PROBE.subprocess, "run") as run, mock.patch.object(PROBE.subprocess, "Popen") as spawn, \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as outcome:
                PROBE.main()
            self.assertEqual(outcome.exception.code, 2)
            run.assert_not_called()
            spawn.assert_not_called()

    def test_settled_shadow_preserves_original_strict_failure_and_cleanup(self):
        for failure, capture_failure in itertools.product((None, "registered-10"), (False, True)):
            with self.subTest(failure=failure, capture_failure=capture_failure):
                code, summary = self.exercise_runner(malloc_scribble="off", external_receipt=True,
                    settled_shadow=True, failed_scan=failure, shadow_capture_failed=capture_failure)
                self.assertEqual(code, int(failure is not None))
                self.assertEqual(summary["baseline_leak_nodes"], 280)

    def test_settled_shadow_timeout_retains_strict_failure(self):
        code, _ = self.exercise_runner(malloc_scribble="off", external_receipt=True,
            settled_shadow=True, failed_scan="registered-10", shadow_timeout=True)
        self.assertEqual(code, 1)

    def test_settled_shadow_hypothesis_requires_notifications_and_compensation(self):
        for kwargs in ({"invalid_notifications": True}, {"insufficient_compensation": True}):
            code, _ = self.exercise_runner(malloc_scribble="off", external_receipt=True, settled_shadow=True, **kwargs)
            self.assertEqual(code, 1)

    def test_settled_shadow_pure_idle_queries_only_once(self):
        self.exercise_runner(malloc_scribble="off", external_receipt=True,
            heap_control=True, empty_control_mode="pure-appkit", settled_shadow=True, reference_idle=True)

    def test_live_attribution_keeps_six_original_scans_and_strict_failures(self):
        for control, failure, capture_failure in itertools.product((False, True), (None, "registered-10", "removed-20"), (None, "timeout", "failed")):
            with self.subTest(control=control, failure=failure, capture_failure=capture_failure):
                code, result = self.exercise_runner(external_receipt=True, malloc_scribble="off", heap_control=control,
                    live_attribution=True, failed_scan=failure, live_capture_failure=capture_failure)
                self.assertEqual(code, int(failure is not None))
                self.assertEqual(result["scan_mode"], "live")
                self.assertTrue(result["live_attribution"])

    def test_live_attribution_rejects_conflicting_cli_before_launch(self):
        base = ["probe", "--work-directory", "unused", "--records-directory", "unused-records",
                "--live-attribution", "--external-startup-receipt",
                "--prepared-fixture-directory", "unused-prepared", "--malloc-scribble", "off"]
        variants = [["--heap-diagnostics"], ["--terminal-origin"], ["--install-gate", "installed"],
                    ["--empty-control-mode", "patched"], ["--prepare-external-fixture"],
                    ["--prepare-install-gate-fixture"], ["--system-baseline"], ["--copy-lifetime"],
                    ["--ownership-trace"], ["--read-only"], ["--malloc-scribble", "on"]]
        for extra in variants:
            with self.subTest(extra=extra), mock.patch.object(sys, "argv", base + extra), \
                    mock.patch.object(PROBE.subprocess, "run") as run, \
                    mock.patch.object(PROBE.subprocess, "Popen") as spawn, \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as outcome:
                PROBE.main()
            self.assertEqual(outcome.exception.code, 2)
            run.assert_not_called()
            spawn.assert_not_called()

    def test_external_frozen_scans_require_the_complete_install_gate_contract(self):
        valid = ["probe", "--work-directory", "unused", "--records-directory", "unused-records",
            "--external-startup-receipt", "--prepared-fixture-directory", "unused-prepared",
            "--malloc-scribble", "off", "--heap-control", "--heap-diagnostics", "--install-gate", "installed"]
        variants = [valid[:-2], valid[:-2] + ["--empty-control-mode", "pure-appkit"],
                    [value if value != "off" else "on" for value in valid],
                    [value for value in valid if value != "--heap-control"],
                    valid + ["--terminal-origin"]]
        for arguments in variants:
            with self.subTest(arguments=arguments), mock.patch.object(sys, "argv", arguments), \
                    mock.patch.object(PROBE.subprocess, "run") as run, \
                    mock.patch.object(PROBE.subprocess, "Popen") as start, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    PROBE.main()
                self.assertEqual(error.exception.code, 2)
                run.assert_not_called()
                start.assert_not_called()

    def test_initial_startup_failure_keeps_role_errno_all_scans_and_heap_failure(self):
        for role, error in itertools.product(("host", "reader"), (
                EXTERNAL.StartupReceiptError("sysctl_procargs", "private original failure", 13),
                EXTERNAL.StartupReceiptError("parse_environment", "private malformed environment"),
                RuntimeError("private unclassified failure"))):
            code, result = self.exercise_runner(external_receipt=True, malloc_scribble="off", heap_control=True,
                install_gate="installed", invalid_allocator=(role, "missing"), startup_error=error, failed_scan="registered-10")
            self.assertEqual(code, 1)
            self.assertEqual(len(result["scans"]), 6)
            self.assertEqual(REPORT.validation_failure_counts(result)["heap_baseline"], 1)

    def test_unknown_non_runtime_startup_failure_keeps_original_abort_and_cleanup(self):
        for role in ("host", "reader"):
            code, result = self.exercise_runner(external_receipt=True, malloc_scribble="off", heap_control=True,
                invalid_allocator=(role, "missing"), startup_error=ValueError("private unexpected exception"))
            self.assertEqual(code, 1)
            self.assertEqual(result["coverage"], "failed")
            self.assertEqual(REPORT.validation_failure_counts(result)["other"], 1)

    def test_pure_and_patched_empty_controls_keep_six_scans_and_transient_strict_failures(self):
        for mode, failure in itertools.product(("patched", "pure-appkit"), (None, "registered-10", "removed-20")):
            with self.subTest(mode=mode, failure=failure):
                code, summary = self.exercise_runner(empty_control_mode=mode, external_receipt=True,
                    malloc_scribble="off", heap_control=True, failed_scan=failure)
                self.assertEqual(code, int(failure is not None))
                self.assertEqual(summary["coverage"], "failed" if failure else "measured")
                self.assertEqual(summary["empty_control_mode"], mode)
                self.assertEqual(summary["product_compensation_enabled"], mode == "patched")
                self.assertEqual(len(summary["scans"]), 6)
                if failure:
                    self.assertEqual([row["stage"] for row in summary["validation_errors"]], [failure])
        for mode, invalid in itertools.product(("patched", "pure-appkit"),
                ({"invalid_control_host": (5, "allocatedButtons")}, {"invalid_control_reader": (3, "registrations")}, {"invalid_notifications": True})):
            code, summary = self.exercise_runner(empty_control_mode=mode, external_receipt=True,
                malloc_scribble="off", heap_control=True, **invalid)
            self.assertEqual(code, 1)
            self.assertEqual(len(summary["scans"]), 6)

    def test_external_executable_drift_after_measurement_remains_fatal(self):
        for target in (True, "prepared"):
            code, summary = self.exercise_runner(external_receipt=True, malloc_scribble="off", binary_drift=target)
            self.assertEqual(code, 1)
            self.assertEqual(summary["coverage"], "failed")
            self.assertIn("external-startup-final", [error["stage"] for error in summary["validation_errors"]])

    def test_external_hash_io_failure_keeps_original_exception_and_failure_category(self):
        for phase, target in itertools.product(("complete", "final"), ("prepared", "working")):
            with self.subTest(phase=phase, target=target):
                code, summary = self.exercise_runner(external_receipt=True, malloc_scribble="off",
                    hash_io_failure=(phase, target), failed_scan="registered-10")
                self.assertEqual(code, 1)
                self.assertEqual(summary["coverage"], "failed")
                self.assertEqual(len(summary["scans"]), 6)

    def test_unreadable_external_environment_fails_and_retains_all_later_scans(self):
        for role in ("host", "reader"):
            code, summary = self.exercise_runner(external_receipt=True, malloc_scribble="off",
                                                 invalid_allocator=(role, None))
            self.assertEqual(code, 1)
            self.assertEqual(len(summary["scans"]), 6)
            self.assertEqual(summary["coverage"], "failed")

    def test_malloc_scribble_overrides_inherited_state_in_both_actual_processes(self):
        for setting, control, diagnostic in itertools.product(("off", "on"), (False, True), (False, True)):
            with self.subTest(setting=setting, control=control, diagnostic=diagnostic), mock.patch.dict(os.environ, {"MallocScribble": "inherited"}):
                exit_code, summary = self.exercise_runner(heap_diagnostics=diagnostic, heap_control=control, malloc_scribble=setting)
                self.assertEqual(exit_code, 0)
                expected = "unset" if setting == "off" else "1"
                self.assertEqual(summary["malloc_scribble"], {"requested": setting, "host": expected, "reader": expected})
                self.assertEqual(len(summary["scans"]), 7 if diagnostic else 6)

    def test_malloc_scribble_keeps_strict_heap_failures_and_all_later_checkpoints(self):
        for setting, control, diagnostic in itertools.product(("off", "on"), (False, True), (False, True)):
            with self.subTest(setting=setting, control=control, diagnostic=diagnostic):
                exit_code, summary = self.exercise_runner(heap_diagnostics=diagnostic, heap_control=control,
                    malloc_scribble=setting, failed_scan="registered-10")
                self.assertEqual(exit_code, 1)
                self.assertEqual([error["stage"] for error in summary["validation_errors"]], ["registered-10"])

    def test_missing_or_mismatched_actual_allocator_receipts_fail_without_losing_later_evidence(self):
        for role, value, diagnostic in itertools.product(("host", "reader"), (None, "1", "/private/secret", True), (False, True)):
            with self.subTest(role=role, value=value, diagnostic=diagnostic):
                exit_code, summary = self.exercise_runner(heap_diagnostics=diagnostic, malloc_scribble="off",
                                                         invalid_allocator=(role, value))
                self.assertEqual(exit_code, 1)
                self.assertEqual([error["stage"] for error in summary["validation_errors"]], ["malloc-scribble"])
                self.assertNotIn("/private/secret", json.dumps(summary["malloc_scribble"]))

    def test_copy_lifetime_covers_thirty_copies_per_branch_without_heap_sampling(self):
        exit_code, summary = self.exercise_runner(copy_lifetime=True)
        self.assertEqual(exit_code, 0)
        self.assertEqual(summary["coverage"], "passed")
        self.assertEqual(summary["copy_lifetime"], AXCompatibilityCopyLifetimeTests.receipt(30)["copyLifetime"])
        self.assertIn("weak targets cannot be acquired", summary["scope"])
        self.assertIn("does not establish completed object destruction", summary["scope"])
        exit_code, summary = self.exercise_runner(failed_scan="removed-10")
        self.assertEqual(exit_code, 1)
        self.assertEqual(summary["coverage"], "failed")
        self.assertEqual([error["stage"] for error in summary["validation_errors"]], ["removed-10"])

    def test_copy_lifetime_early_failures_survive_later_nil_and_complete_all_evidence(self):
        for sequence, key, value in ((0, None, None), (4, "liveOrdinary", 1), (4, "liveMutable", 1),
                                     (4, "invalid", 1), (5, "ordinary", 9), (5, "mutable", True),
                                     (9, "ordinary", 29)):
            with self.subTest(sequence=sequence, key=key):
                exit_code, summary = self.exercise_runner(copy_lifetime=True,
                                                         invalid_copy_lifetime=(sequence, key, value))
                self.assertEqual(exit_code, 1)
                self.assertEqual(summary["coverage"], "failed")
                self.assertEqual([error["stage"] for error in summary["validation_errors"]],
                                 [f"copy-lifetime-host-{sequence}"])
                self.assertNotIn("ax_leak_nodes", summary)
                if sequence != 9:
                    self.assertEqual(summary["copy_lifetime"], AXCompatibilityCopyLifetimeTests.receipt(30)["copyLifetime"])

    def test_copy_lifetime_notification_failures_preserve_final_host_evidence(self):
        for invalid in (True, "missing-count"):
            with self.subTest(invalid=invalid):
                exit_code, summary = self.exercise_runner(copy_lifetime=True, invalid_notifications=invalid)
                self.assertEqual(exit_code, 1)
                self.assertEqual(summary["coverage"], "failed")
                self.assertEqual([error["stage"] for error in summary["validation_errors"]], ["notifications"])
                self.assertEqual(summary["copy_lifetime"], AXCompatibilityCopyLifetimeTests.receipt(30)["copyLifetime"])

    def test_heap_control_measures_seven_empty_scans_without_product_coverage(self):
        exit_code, summary = self.exercise_runner(heap_diagnostics=True, heap_control=True)
        self.assertEqual(exit_code, 0)
        self.assertEqual(summary["coverage"], "measured")
        self.assertEqual(summary["destroyed_buttons"], 0)
        self.assertEqual(summary["notification_receipt"]["tracked_buttons"], 0)
        self.assertEqual([scan["label"] for scan in summary["scans"]], list(REPORT.HEAP_LABELS))
        self.assertIn("no product destruction coverage", summary["scope"])

    def test_heap_control_preserves_every_strict_growth_failure_after_recovery(self):
        for stage in REPORT.HEAP_LABELS[1:]:
            with self.subTest(stage=stage):
                exit_code, summary = self.exercise_runner(heap_diagnostics=True, heap_control=True, failed_scan=stage)
                self.assertEqual(exit_code, 1)
                self.assertEqual(summary["coverage"], "failed")
                self.assertEqual([error["stage"] for error in summary["validation_errors"]], [stage])

    def test_heap_control_rejects_transient_targets_and_any_reader_notifications(self):
        for options, stage in (({"invalid_control_host": (5, "allocatedButtons")}, "control-host-5"),
                               ({"invalid_control_reader": (3, "registrations")}, "control-reader-3"),
                               ({"invalid_control_reader": (4, "all_notifications")}, "control-reader-4"),
                               ({"invalid_notifications": True}, "notifications")):
            with self.subTest(options=options):
                exit_code, summary = self.exercise_runner(heap_diagnostics=True, heap_control=True, **options)
                self.assertEqual(exit_code, 1)
                self.assertEqual(summary["coverage"], "failed")
                self.assertEqual([error["stage"] for error in summary["validation_errors"]], [stage])

    def test_stable_heap_completes_every_lifecycle_checkpoint(self):
        exit_code, summary = self.exercise_runner()
        self.assertEqual(exit_code, 0)
        self.assertEqual(summary["coverage"], "passed")
        self.assertEqual(summary["ax_leak_nodes"], 0)
        self.assertNotIn("validation_errors", summary)
        self.assertNotIn("mode", summary)
        self.assertNotIn("scan_mode", summary)
        self.assertNotIn("instrumented", summary)
        self.assertNotIn("copy_lifetime", summary)

    def test_diagnostics_capture_once_per_stage_and_preserve_heap_failure(self):
        for stage in ("added-10", "registered-10"):
            with self.subTest(stage=stage):
                exit_code, summary = self.exercise_runner(failed_scan=stage, heap_diagnostics=True)
                self.assertEqual(exit_code, 1)
                self.assertEqual(summary["coverage"], "failed")
                self.assertIsNone(summary["ax_leak_nodes"])
                self.assertEqual([error["stage"] for error in summary["validation_errors"]], [stage])

    def test_terminal_origin_follows_six_live_scans_and_preserves_strict_failures(self):
        for failed in (None, "registered-10"):
            for timeout in (False, True):
                with self.subTest(failed=failed, timeout=timeout):
                    code, summary = self.exercise_runner(failed_scan=failed, terminal_origin=True, terminal_timeout=timeout,
                                                        external_receipt=True, malloc_scribble="off")
                    self.assertEqual(code, int(failed is not None))
                    self.assertEqual(summary["coverage"], "failed" if failed else "passed")

    def test_image_worker_cleanup_failure_retains_strict_and_primary_errors(self):
        collect = PROBE.collect_terminal_snapshot
        def fail_after_saving(graph, records, capture):
            value = collect(graph, records, capture)
            self.assertEqual(json.loads((records / "terminal-snapshot.json").read_text()), value)
            REPORT.ax_system_images.write_worker_cleanup(records / "terminal-image-worker.json",
                error_type is REPORT.ax_system_images.ImageWorkerArtifactError, False)
            raise error_type()
        for error_type, reader_failure in itertools.product(
                (REPORT.ax_system_images.ImageWorkerCleanupError, REPORT.ax_system_images.ImageWorkerArtifactError), (None, {"reader": "kill"})):
            with self.subTest(error_type=error_type.__name__, reader_failure=reader_failure), \
                    mock.patch.object(PROBE, "collect_terminal_snapshot", side_effect=fail_after_saving) as collection:
                code, summary = self.exercise_runner(failed_scan="registered-10", terminal_origin=True,
                    external_receipt=True, malloc_scribble="off", cleanup_failure=reader_failure)
            collection.assert_called_once()
            self.assertEqual(code, 1)
            self.assertEqual(summary["coverage"], "failed")
            self.assertIn("registered-10", [error["stage"] for error in summary["validation_errors"]])
            self.assertIn("terminal_snapshot", summary["cleanup"]["errors"])
            self.assertEqual(summary["cleanup"]["primary_exception"], reader_failure is not None)
            self.assertEqual(sum(error["stage"] == "execution" for error in summary["validation_errors"]), int(reader_failure is not None))
            self.assertTrue(summary["cleanup"]["processes_exited"])

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


class AXTerminalCacheIdentityTests(unittest.TestCase):
    def setUp(self):
        self.reports, self.catalog = AXTerminalSnapshotTests.image_reports()
        self.images = REPORT.ax_system_images
        with mock.patch.object(self.images, "loaded_system_images", return_value=self.catalog):
            self.terminal = AXTerminalSnapshotTests.summary(self.reports)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.records = pathlib.Path(temporary.name)
        self.cleanup = self.records / "terminal-image-worker.json"
        self.images.write_worker_cleanup(self.cleanup, True)
        PROBE.write_json(self.records / "terminal-snapshot.json", self.terminal)

    def packet(self, identifiers):
        return {"schema": 1, "mode": "lookup", "status": "complete", "active_cache_uuid": "33333333-3333-3333-3333-333333333333",
                "requests": len(identifiers), "setup_calls": 1, "measurement_calls": 1, "callbacks": 3000,
                "measurement_closed": True, "result": [{"request_index": i, "reason": "verified", **self.catalog[value]}
                                                       for i, value in enumerate(identifiers)]}

    def collect(self):
        def lookup(identifiers, cleanup):
            self.assertEqual(json.loads((self.records / "terminal-snapshot.json").read_text()), self.terminal)
            return self.packet(identifiers)
        with mock.patch.object(self.images, "shared_cache_images", side_effect=lookup):
            REPORT.collect_terminal_cache_identity(self.records, self.terminal, self.reports[0])
        return json.loads((self.records / "terminal-cache-images.json").read_text())

    def test_separate_identity_binds_report_frames_and_final_terminal_without_repairing_loaded(self):
        packet = self.collect()
        self.assertEqual([(row["root_index"], row["index"]) for row in packet["bindings"]], [(0, 2), (0, 3)])
        terminal = json.loads(json.dumps(self.terminal))
        identity = terminal["root_groups"][0]["other_image_identity"]
        identity["frames"] = []; identity["reason_counts"]["local_catalog_unavailable"] = 2; identity["status"] = "partial"
        before = json.dumps(terminal, sort_keys=True)
        with mock.patch.object(self.images, "shared_cache_images", side_effect=lambda identifiers, _: self.packet(identifiers)) as query:
            value = REPORT.recheck_terminal_cache_identity(self.records, terminal, self.cleanup)
        query.assert_called_once()
        self.assertEqual(value["status"], "complete")
        self.assertEqual(len(value["frames"]), 2)
        self.assertEqual(value["terminal_sha256"], REPORT.terminal_cache_identity(terminal)["terminal_sha256"])
        self.assertEqual(before, json.dumps(terminal, sort_keys=True))
        self.assertNotIn("private", json.dumps(value))

    def test_bad_binding_hash_root_frame_uuid_and_private_packet_are_rejected_before_fresh_query(self):
        original = self.collect()
        mutations = [lambda v: v.update(private="secret"), lambda v: v.update(schema=True),
                     lambda v: v.update(terminal_sha256="0" * 64), lambda v: v.update(grouped_sha256="0" * 64),
                     lambda v: v["bindings"][0].update(root_index=1), lambda v: v["bindings"][0].update(root_index=False),
                     lambda v: v["bindings"][0].update(index=3), lambda v: v["bindings"][0].update(uuid=v["bindings"][1]["uuid"]),
                     lambda v: v["bindings"].reverse(), lambda v: v["reason_counts"].update(private=1),
                     lambda v: v["lookup"]["result"][0].update(basename="/private/secret")]
        before = json.dumps(self.terminal, sort_keys=True)
        for change in mutations:
            packet = json.loads(json.dumps(original)); change(packet)
            PROBE.write_json(self.records / "terminal-cache-images.json", packet)
            with mock.patch.object(self.images, "shared_cache_images") as query:
                value = REPORT.recheck_terminal_cache_identity(self.records, self.terminal, self.cleanup)
            query.assert_not_called()
            self.assertEqual(value["status"], "unavailable")
            self.assertEqual(value["frames"], [])
            self.assertNotIn("private", json.dumps(value))
        PROBE.write_json(self.records / "terminal-cache-images.json", original)
        (self.records / "terminal-cache-grouped.txt").write_text(self.reports[0] + "extra")
        with mock.patch.object(self.images, "shared_cache_images") as query:
            self.assertEqual(REPORT.recheck_terminal_cache_identity(self.records, self.terminal, self.cleanup)["frames"], [])
        query.assert_not_called()
        self.assertEqual(before, json.dumps(self.terminal, sort_keys=True))

    def test_fresh_cache_change_missing_uuid_or_basename_change_never_publishes_old_identity(self):
        packet = self.collect()
        for failure in ("unavailable", "cache", "duplicate", "basename"):
            fresh = json.loads(json.dumps(packet["lookup"]))
            if failure == "unavailable":
                fresh = None
            elif failure == "cache":
                fresh["active_cache_uuid"] = "44444444-4444-4444-4444-444444444444"
            elif failure == "duplicate":
                fresh["result"][0] = {"request_index": 0, "reason": "uuid_duplicate"}
            else:
                fresh["result"][0]["basename"] = "Changed"
            with mock.patch.object(self.images, "shared_cache_images", return_value=fresh):
                value = REPORT.recheck_terminal_cache_identity(self.records, self.terminal, self.cleanup)
            self.assertEqual(len(value["frames"]), 0 if failure in ("unavailable", "cache") else 1)
            self.assertEqual(value["reason_counts"][{"unavailable": "lookup_unavailable", "cache": "cache_changed",
                "duplicate": "uuid_duplicate", "basename": "identity_changed"}[failure]], 2 if failure in ("unavailable", "cache") else 1)
            if failure in ("unavailable", "cache"):
                self.assertIsNone(value["active_cache_uuid"])

    def test_request_dedup_and_frame_budget_do_not_change_old_summary_or_symbol_budget(self):
        grouped, listed = self.reports
        grouped = grouped.replace("3 private-fixture 0x2000 secret_caller + 4\n2 private-fixture 0x1000 secret_caller + 4",
            "\n".join(f"{i} private-fixture 0x1000 secret_caller + 4" for i in reversed(range(2, 104))))
        with mock.patch.object(self.images, "loaded_system_images", return_value=self.catalog):
            terminal = AXTerminalSnapshotTests.summary((grouped, listed))
        PROBE.write_json(self.records / "terminal-snapshot.json", terminal)
        before = json.dumps(terminal, sort_keys=True)
        with mock.patch.object(self.images, "shared_cache_images", side_effect=lambda ids, _: self.packet(ids)) as query:
            REPORT.collect_terminal_cache_identity(self.records, terminal, grouped)
            value = REPORT.recheck_terminal_cache_identity(self.records, terminal, self.cleanup)
        self.assertEqual([len(call.args[0]) for call in query.call_args_list], [1, 1])
        self.assertEqual(len(value["frames"]), 96)
        self.assertEqual(value["reason_counts"]["budget_omitted"], 6)
        self.assertLessEqual(len(json.dumps(value, indent=2).encode()), 24576)
        self.assertEqual(before, json.dumps(terminal, sort_keys=True))
        path = self.records / "terminal-cache-images.json"
        packet = json.loads(path.read_text())
        packet["lookup"]["result"][0]["basename"] = "A" * 96
        PROBE.write_json(path, packet)
        with mock.patch.object(self.images, "shared_cache_images", return_value=packet["lookup"]):
            bounded = REPORT.recheck_terminal_cache_identity(self.records, terminal, self.cleanup)
        unbounded = json.loads(json.dumps(value))
        for frame in unbounded["frames"]:
            frame["basename"] = "A" * 96
        self.assertGreater(len(json.dumps({"trials": [{"terminal_cache_image_identity": unbounded}]}, indent=2).encode()), 24576)
        self.assertEqual(bounded["frames"], [])
        self.assertEqual(bounded["reason_counts"]["output_budget"], 1)
        self.assertEqual(before, json.dumps(terminal, sort_keys=True))

    def test_real_collector_uses_stdout_and_saves_old_terminal_before_optional_cleanup_failure(self):
        capture = REPORT.empty_terminal_snapshot(); capture.update(capture_status="complete", capture_exit_code=0)
        for kind in (None, self.images.ImageWorkerCleanupError, self.images.ImageWorkerArtifactError):
            def lookup(ids, cleanup):
                saved = json.loads((self.records / "terminal-snapshot.json").read_text())
                self.assertEqual(AXTerminalSnapshotTests.without_image_identity(saved), AXTerminalSnapshotTests.without_image_identity(self.terminal))
                if kind:
                    raise kind() from OSError("/private/secret")
                return self.packet(ids)
            with mock.patch.object(REPORT.subprocess, "run", side_effect=[subprocess.CompletedProcess([], 1, text, "PRIVATE_STDERR") for text in self.reports]), \
                    mock.patch.object(REPORT, "SystemSymbols", return_value=AXTerminalSnapshotTests.resolver()), \
                    mock.patch.object(self.images, "loaded_system_images", return_value=self.catalog), \
                    mock.patch.object(self.images, "shared_cache_images", side_effect=lookup):
                if kind:
                    with self.assertRaises(kind):
                        REPORT.collect_terminal_snapshot(self.records / "terminal.memgraph", self.records, capture)
                else:
                    REPORT.collect_terminal_snapshot(self.records / "terminal.memgraph", self.records, capture)
            self.assertEqual((self.records / "terminal-cache-grouped.txt").read_text(), self.reports[0])
            self.assertIn("PRIVATE_STDERR", (self.records / "terminal-grouped.txt").read_text())
            self.assertEqual(json.loads((self.records / "terminal-snapshot.json").read_text())["schema"], 3)


class AXMallocScribbleWorkflowTests(unittest.TestCase):
    @classmethod
    def live_summary(cls):
        value = cls.frozen_summary(first_strict_growth=True)
        labels = [label for label in REPORT.HEAP_LABELS if label != "added-10"]
        source_hash = hashlib.sha256(b"Process 123: 3 leaks for 300 total leaked bytes.\n").hexdigest()
        value.update(schema=3, selection="live-no-growth",
            live_scans=[{"label": label, "leak_nodes": 3, "leak_bytes": 300,
                         "stdout_sha256": source_hash} for label in labels],
            live_captures=[{"label": "baseline", "status": "complete", "exit_code": 0,
                            "after_scan_ms": 3, "duration_ms": 20, "stdout_sha256": source_hash,
                            "graph_sha256": value["baseline"]["graph_sha256"]}])
        value["checked_points"] = value["checked_points"][:1]
        value["tools"] = [value["tools"][0], value["tools"][-1]]
        return value

    @staticmethod
    def frozen_summary(*, first_strict_growth=False, selected_label=None, byte_growth=False, new_nodes=1):
        if selected_label is not None:
            # Reuse the parser's synthetic tool reports to produce its complete
            # reference contract without invoking native leaks or AX fixtures.
            spec = importlib.util.spec_from_file_location("ax_frozen_workflow_fixture", ROOT / "Scripts/tests/test_ax_frozen_nodes.py")
            fixtures = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(fixtures)
            with tempfile.TemporaryDirectory(prefix="ax-frozen-workflow-") as directory:
                before = {0x1000: 124, 0x2000: 128}
                after = {0x1000: 124, 0x2000: 176} if byte_growth else before | {0x3000 + index * 128: 48 for index in range(new_nodes)}
                case = fixtures.Case(pathlib.Path(directory), before=before, after=after,
                                     first=REPORT.HEAP_LABELS.index(selected_label))
                if byte_growth:
                    case.baseline_heap = dict(before)
                    case.heap_diff = {0x2000: 176}
                    case.before_events = [("ALLOC", address, size) for address, size in before.items()]
                    case.after_events = case.before_events + [("FREE", 0x2000, 128), ("ALLOC", 0x2000, 176)]
                return case.compare(first_strict_growth=first_strict_growth)
        with mock.patch.object(sys, "path", [str(INVESTIGATIONS), *sys.path]):
            from ax_frozen_nodes import initial_summary
        value = initial_summary()
        value.update(status="complete", selection="no-strict-growth" if first_strict_growth else "no-new-leak",
            baseline={"leak_nodes": 3, "leak_bytes": 300, "graph_sha256": "0" * 64},
            checked_points=[{"label": label, "leak_nodes": 3, "leak_bytes": 300} for label in REPORT.HEAP_LABELS],
            tools=[{"tool": "list", "label": label, "status": "complete", "return_code": 1,
                    "cleanup_confirmed": True} for label in REPORT.HEAP_LABELS])
        if first_strict_growth:
            value["baseline_roots"] = {"status": "complete", "roots": [{"root_kind": "leak", "root_type": "unknown",
                "protocol": "none", "nodes": 3, "bytes": 300, "cycle_back_edges": 0}]}
            value["tools"].append({"tool": "tree", "label": "baseline", "status": "complete", "return_code": 0,
                                   "cleanup_confirmed": True})
        return value

    @staticmethod
    def workflow_script(step):
        workflow = (ROOT / ".github/workflows/ax-system-baseline.yml").read_text()
        block = workflow.split(f"      - name: {step}\n", 1)[1]
        script = block.split("          python3 - <<'PY'\n", 1)[1].split("          PY\n", 1)[0]
        return "\n".join(line[10:] for line in script.splitlines())

    def test_live_attribution_identity_requires_explicit_defaults_and_two_ordinary_cases(self):
        script = self.workflow_script("Verify investigation identity")
        environment = {"AX_LIVE_ATTRIBUTION": "true", "AX_FROZEN_CONTROL": "false", "AX_SCAN_MODE": "diagnostic",
                       "AX_RECEIPT_MODE": "internal", "AX_TERMINAL_ORIGIN": "false", "MALLOC_SCRIBBLE_EXPERIMENT": "false",
                       "AX_HEAP_DIAGNOSTICS": "false", "CAUSAL_PROBE": "false",
                       "AX_PURE_APPKIT_CONTROL": "false", "AX_INSTALL_GATE_CONTROL": "false"}
        outputs = {('sw_vers', '-productVersion'): '26.6.2', ('sw_vers', '-buildVersion'): '25G83',
                   ('uname', '-m'): 'arm64', ('xcodebuild', '-version'): 'Xcode 26.3\nBuild version 17C529',
                   ('git', 'rev-parse', 'HEAD'): '1' * 40}
        variants = [None, ("AX_SCAN_MODE", "live"), ("AX_RECEIPT_MODE", "external-startup")]
        variants += [(key, "true") for key in ("AX_TERMINAL_ORIGIN", "MALLOC_SCRIBBLE_EXPERIMENT",
            "AX_HEAP_DIAGNOSTICS", "CAUSAL_PROBE", "AX_PURE_APPKIT_CONTROL", "AX_INSTALL_GATE_CONTROL", "AX_FROZEN_CONTROL")]
        for variant in variants:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory) / "records"
                code = script.replace("pathlib.Path('.build/Temporary/ax-heap-diagnostics')", f"pathlib.Path({str(root)!r})")
                with mock.patch.dict(os.environ, environment | (dict([variant]) if variant else {})), \
                        contextlib.redirect_stdout(io.StringIO()), \
                        mock.patch.object(subprocess, "check_output", side_effect=lambda command, **_: outputs[tuple(command)]) as query:
                    if variant:
                        with self.assertRaises(AssertionError):
                            exec(compile(code, "ax-system-baseline.yml", "exec"), {})
                        query.assert_not_called()
                    else:
                        exec(compile(code, "ax-system-baseline.yml", "exec"), {})
                        summary = json.loads((root / "summary.json").read_text())
                        self.assertEqual(summary["expected_trials"], 2)
                        self.assertTrue(summary["identity"]["live_attribution"])
                        self.assertEqual(summary["identity"]["scan_mode"], "live")
                        self.assertEqual(summary["identity"]["receipt_mode"], "external-startup")

    def test_live_attribution_workflow_binds_evidence_and_preserves_strict_failures(self):
        for failure in (None, "strict", "stdout", "capture", "private", "host-exit", "missing", "cleanup", "timeout"):
            with self.subTest(failure=failure):
                value = self.live_summary()
                if failure == "private":
                    value["live_captures"][0]["raw"] = "secret"
                invocations, summary = self.run_measurement(enabled=False, scan_mode="live", receipt_mode="external-startup",
                    live_attribution=True, frozen_summary=value,
                    first_failure="strict" if failure == "strict" else None,
                    frozen_failure=failure if failure not in (None, "strict") else None)
                self.assertEqual(invocations, [("off", "control")] if failure == "cleanup" else [("off", "control"), ("off", "product")])
                self.assertEqual(summary["strict_checks_passed"], failure != "strict")
                self.assertEqual(summary["frozen_node_checks_passed"], failure in (None, "strict"))
                if failure in (None, "strict"):
                    self.assertTrue(summary["trials"][0]["frozen_nodes_available"])
                    self.assertEqual(summary["trials"][0]["frozen_nodes"]["schema"], 3)

    def test_native_smoke_requires_identity_and_explicit_cleanup_output(self):
        workflow = (ROOT / ".github/workflows/ax-system-baseline.yml").read_text()
        identity = workflow.split("      - name: Verify investigation identity\n", 1)[1].split("      - name:", 1)[0]
        measurement = workflow.split("      - name: Measure matched cases with strict heap checks\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("id: ax_identity", identity)
        self.assertIn("id: ax_measure", measurement)
        self.assertIn("if: steps.ax_identity.outcome == 'success'", measurement)
        native = workflow.split("      - name: Verify live capture CLI with an owned process\n", 1)[1].split("      - name:", 1)[0]
        condition = next(line.strip()[4:] for line in native.splitlines() if line.strip().startswith("if: "))
        for live, identity_outcome, smoke_output in itertools.product((False, True), ("success", "failure", "skipped"), ("", "false", "true")):
            expression = condition.replace("always()", "True").replace("inputs.live_attribution", repr(live))
            expression = expression.replace("steps.ax_identity.outcome", repr(identity_outcome))
            expression = expression.replace("steps.ax_measure.outputs.smoke_safe", repr(smoke_output)).replace("&&", "and")
            self.assertEqual(eval(expression, {"__builtins__": {}}),
                             live and identity_outcome == "success" and smoke_output == "true")

    def test_native_smoke_cleanup_output_is_independent_of_strict_and_capture_verdicts(self):
        for failure in (None, "strict", "capture-tool", "host-exit", "missing", "cleanup", "node-inner-cleanup", "node-tool-cleanup",
                        "runner-cleanup", "bridge-cleanup", "bridge-missing", "build", "build-timeout", "prepared-manifest"):
            with self.subTest(failure=failure):
                value = self.live_summary()
                options = {}
                if failure in ("strict", "build", "build-timeout", "prepared-manifest"):
                    options["first_failure"] = failure
                elif failure == "runner-cleanup":
                    options["first_failure"] = "cleanup"
                elif failure in ("bridge-cleanup", "bridge-missing"):
                    options["bridge_failure"] = failure.removeprefix("bridge-")
                elif failure:
                    options["frozen_failure"] = failure
                if failure == "capture-tool":
                    value.update(status="unavailable", selection=None, baseline=None, checked_points=[], tools=[],
                                 baseline_roots={"status": "not_requested", "roots": []}, reasons=["input_invalid"])
                    value["live_captures"][0].update(status="failed", exit_code=255, graph_sha256=None,
                                                    error_signals=["unclassified"])
                elif failure == "node-inner-cleanup":
                    value.update(status="partial", process_cleanup_confirmed=False, reasons=["process_exit_unconfirmed"])
                elif failure == "node-tool-cleanup":
                    value.update(status="partial", reasons=["process_exit_unconfirmed"])
                    value["tools"][0].update(status="timeout", return_code=None, cleanup_confirmed=False)
                self.run_measurement(enabled=False, scan_mode="live", receipt_mode="external-startup",
                    live_attribution=True, frozen_summary=value,
                    expected_smoke_safe=failure in (None, "strict", "capture-tool"), **options)

    def test_frozen_control_rejects_conflicting_modes_before_starting_tools(self):
        script = self.workflow_script("Verify investigation identity")
        environment = {"AX_FROZEN_CONTROL": "true", "AX_SCAN_MODE": "diagnostic", "AX_RECEIPT_MODE": "internal",
                       "AX_TERMINAL_ORIGIN": "false", "MALLOC_SCRIBBLE_EXPERIMENT": "false",
                       "AX_HEAP_DIAGNOSTICS": "false", "CAUSAL_PROBE": "false",
                       "AX_PURE_APPKIT_CONTROL": "false", "AX_INSTALL_GATE_CONTROL": "false"}
        outputs = {('sw_vers', '-productVersion'): '26.6.2', ('sw_vers', '-buildVersion'): '25G83',
                   ('uname', '-m'): 'arm64', ('xcodebuild', '-version'): 'Xcode 26.3\nBuild version 17C529',
                   ('git', 'rev-parse', 'HEAD'): '1' * 40}
        variants = [None, ("AX_SCAN_MODE", "live"), ("AX_RECEIPT_MODE", "external-startup")]
        variants += [(key, "true") for key in ("AX_TERMINAL_ORIGIN", "MALLOC_SCRIBBLE_EXPERIMENT",
            "AX_HEAP_DIAGNOSTICS", "CAUSAL_PROBE", "AX_PURE_APPKIT_CONTROL", "AX_INSTALL_GATE_CONTROL")]
        for variant in variants:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory) / "records"
                code = script.replace("pathlib.Path('.build/Temporary/ax-heap-diagnostics')", f"pathlib.Path({str(root)!r})")
                with mock.patch.dict(os.environ, environment | (dict([variant]) if variant else {})), \
                        contextlib.redirect_stdout(io.StringIO()), \
                        mock.patch.object(subprocess, "check_output", side_effect=lambda command, **_: outputs[tuple(command)]) as query:
                    if variant:
                        with self.assertRaises(AssertionError):
                            exec(compile(code, "ax-system-baseline.yml", "exec"), {})
                        query.assert_not_called()
                    else:
                        exec(compile(code, "ax-system-baseline.yml", "exec"), {})
                        summary = json.loads((root / "summary.json").read_text())
                        self.assertEqual(summary["expected_trials"], 1)
                        self.assertTrue(summary["identity"]["frozen_control"])
                        self.assertEqual(summary["identity"]["scan_mode"], "diagnostic")

    def test_frozen_control_preserves_strict_failure_and_gates_offline_evidence(self):
        no_growth = self.frozen_summary()
        for failure in (None, "strict", "host-exit", "missing", "private", "counts", "timeout", "cleanup",
                        "early-count", "early-bytes"):
            with self.subTest(failure=failure):
                value = json.loads(json.dumps(no_growth))
                if failure == "private":
                    value["private"] = "/private/secret"
                if failure == "counts":
                    value["baseline"]["leak_nodes"] = 4
                scan_change = None
                if failure in ("early-count", "early-bytes"):
                    key = "leak_nodes" if failure == "early-count" else "leak_bytes"
                    value["baseline"][key] -= 1
                    scan_change = lambda scan: scan.update({key: value["baseline"][key]})
                strict_failure = failure in ("strict", "early-count", "early-bytes")
                invocations, summary = self.run_measurement(enabled=False, frozen_control=True,
                    frozen_summary=value, first_failure="strict" if strict_failure else None,
                    first_scan_change=scan_change,
                    frozen_failure=failure if failure != "strict" else None)
                self.assertEqual(invocations, [(None, "control")])
                self.assertEqual(summary["strict_checks_passed"], not strict_failure)
                self.assertEqual(summary["frozen_node_checks_passed"], failure in (None, "strict"))
                trial = summary["trials"][0]
                self.assertEqual(trial["frozen_nodes_available"], failure in (None, "strict", "timeout", "cleanup"))
                if failure == "host-exit":
                    self.assertNotIn("frozen_node_process_run", trial)

    def test_frozen_control_rejects_selection_after_an_earlier_growth_point(self):
        with mock.patch.object(sys, "path", [str(INVESTIGATIONS), *sys.path]):
            from ax_frozen_nodes import validate_summary
        value = self.frozen_summary(selected_label="removed-10")
        validate_summary(value)
        _, summary = self.run_measurement(enabled=False, frozen_control=True, frozen_summary=value,
            first_failure="strict", frozen_failure="earlier-growth",
            first_scan_change=lambda scan: scan.update(leak_nodes=2, leak_bytes=252))
        self.assertFalse(summary["strict_checks_passed"])
        self.assertFalse(summary["frozen_node_checks_passed"])
        self.assertFalse(summary["trials"][0]["frozen_nodes_available"])

    def test_bridge_sidecar_is_independently_gated_without_rewriting_strict_results(self):
        for failure in (None, 'private', 'hash', 'partial', 'missing', 'oversized', 'symlink', 'encoding', 'cleanup'):
            with self.subTest(failure=failure):
                value = self.frozen_summary(first_strict_growth=True, selected_label='added-10')
                def match_scans(scans):
                    for index, scan in enumerate(scans):
                        point = value['baseline'] if index == 0 else value['selected']
                        scan.update({key: point[key] for key in ('leak_nodes', 'leak_bytes')})
                _, summary = self.run_measurement(enabled=False, first_strict_growth=True,
                    frozen_summary=value, first_failure='strict', first_scans_change=match_scans, bridge_failure=failure)
                first = summary['trials'][0]
                self.assertFalse(summary['strict_checks_passed'])
                self.assertTrue(first['frozen_node_checks_passed'])
                self.assertEqual(first['bridge_checks_passed'], failure is None)
                self.assertEqual(summary['bridge_checks_passed'], failure is None)
                self.assertEqual(first['bridge_evidence_available'], failure in (None, 'partial', 'cleanup'))
                self.assertEqual(len(summary['trials']), 1 if failure == 'cleanup' else 10)
                self.assertNotIn('/private/secret', json.dumps(summary))

    def test_first_strict_growth_identity_requires_heap_diagnostics_without_scribble(self):
        script = self.workflow_script("Verify investigation identity")
        outputs = {('sw_vers', '-productVersion'): '26.6.2', ('sw_vers', '-buildVersion'): '25G83',
                   ('uname', '-m'): 'arm64', ('xcodebuild', '-version'): 'Xcode 26.3\nBuild version 17C529',
                   ('git', 'rev-parse', 'HEAD'): '1' * 40}
        for heap, scribble in itertools.product((False, True), repeat=2):
            with self.subTest(heap=heap, scribble=scribble), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory) / "records"
                code = script.replace("pathlib.Path('.build/Temporary/ax-heap-diagnostics')", f"pathlib.Path({str(root)!r})")
                environment = {"AX_SCAN_MODE": "diagnostic", "AX_RECEIPT_MODE": "internal", "AX_TERMINAL_ORIGIN": "false",
                    "AX_FROZEN_CONTROL": "false", "AX_PURE_APPKIT_CONTROL": "false", "AX_INSTALL_GATE_CONTROL": "false",
                    "CAUSAL_PROBE": "false", "AX_HEAP_DIAGNOSTICS": str(heap).lower(),
                    "MALLOC_SCRIBBLE_EXPERIMENT": str(scribble).lower()}
                with mock.patch.dict(os.environ, environment), contextlib.redirect_stdout(io.StringIO()), \
                        mock.patch.object(subprocess, "check_output", side_effect=lambda command, **_: outputs[tuple(command)]):
                    exec(compile(code, "ax-system-baseline.yml", "exec"), {})
                identity = json.loads((root / "summary.json").read_text())["identity"]
                if heap and not scribble:
                    self.assertEqual(identity["frozen_node_selection"], "first-strict-growth")
                else:
                    self.assertNotIn("frozen_node_selection", identity)
        _, ordinary = self.run_measurement(enabled=False)
        self.assertNotIn("frozen_node_selection", ordinary["identity"])
        self.assertNotIn("frozen_node_checks_passed", ordinary)

    def test_first_strict_growth_runs_both_members_of_all_five_pairs_without_growth(self):
        invocations, summary = self.run_measurement(enabled=False, first_strict_growth=True)
        expected = [(None, mode) for pair in range(1, 6)
                    for mode in (("control", "product") if pair % 2 else ("product", "control"))]
        self.assertEqual(invocations, expected)
        self.assertTrue(summary["strict_checks_passed"])
        self.assertTrue(summary["frozen_node_checks_passed"])
        for trial in summary["trials"]:
            self.assertTrue(trial["frozen_nodes_available"])
            self.assertTrue(trial["frozen_node_checks_passed"])
            self.assertEqual(trial["frozen_nodes"]["selection"], "no-strict-growth")
            self.assertIsNone(trial["frozen_nodes"]["selected_label"])
            self.assertEqual(trial["frozen_node_process_run"]["return_code"], 0)

    def test_parser_failure_evidence_requires_matching_graph_and_successful_tool(self):
        with mock.patch.object(sys, "path", [str(INVESTIGATIONS), *sys.path]):
            from ax_parser_evidence import Collector
        value = self.frozen_summary(first_strict_growth=True)
        value.update(status="partial", reasons=["tree_invalid"],
                     baseline_roots={"status": "unavailable", "roots": []})
        collector = Collector()
        collector.record("tree", "baseline", 7, "0" * 64,
            "Process 123: 3 leaks for 300 total leaked bytes.\n/private/secret unsupported\n",
            ValueError("Unsupported tree row"), nodes={0x1000: 100, 0x2000: 100, 0x3000: 100})
        for failure in (None, "private", "hash", "index", "tool", "label", "graph-changed", "oversized", "symlink", "missing", "exists"):
            with self.subTest(failure=failure):
                frozen = copy.deepcopy(value)
                if failure == "graph-changed":
                    frozen["reasons"].append("graph_changed")
                invocations, summary = self.run_measurement(enabled=False, first_strict_growth=True,
                    first_failure="strict", frozen_summary=frozen,
                    parser_evidence=collector.value, parser_failure=failure)
                self.assertEqual(len(invocations), 10)
                self.assertFalse(summary["strict_checks_passed"])
                self.assertFalse(summary["frozen_node_checks_passed"])
                first = summary["trials"][0]
                self.assertEqual(first["parser_evidence_available"], failure is None)
                if failure is None:
                    self.assertEqual(first["parser_evidence"]["documents"], 1)

    def test_parser_artifact_gate_rejects_unbound_modified_and_nonregular_files(self):
        with mock.patch.object(sys, "path", [str(INVESTIGATIONS), *sys.path]):
            from ax_parser_evidence import encode_evidence
        script = self.workflow_script("Gate anonymous parser evidence")
        payload = encode_evidence({"schema": 1, "status": "complete", "documents": [], "omitted_documents": 0})
        for mode, failure in itertools.product(("control", "product", "installed", "preflight-only"),
                (None, "unbound", "modified", "symlink", "directory", "missing", "oversized")):
            with self.subTest(mode=mode, failure=failure), tempfile.TemporaryDirectory(prefix="ax-parser-gate-") as directory:
                root = pathlib.Path(directory)
                name = f"parser-evidence-trial-1-{mode}.json"
                path = root / name
                path.write_bytes(payload)
                receipt = {"parser_evidence_available": True, "parser_evidence": {
                    "file": name, "sha256": hashlib.sha256(payload).hexdigest(), "bytes": len(payload),
                    "status": "complete", "documents": 0}}
                if failure == "unbound":
                    receipt["parser_evidence_available"] = False
                if failure == "modified":
                    path.write_bytes(payload + b" ")
                if failure in ("symlink", "directory", "missing"):
                    path.unlink()
                if failure == "symlink":
                    target = root / "private.json"
                    target.write_bytes(payload)
                    path.symlink_to(target)
                if failure == "directory":
                    path.mkdir()
                    (path / "private.txt").write_text("private")
                if failure == "oversized":
                    path.write_bytes(b" " * (2 * 1024 * 1024 + 1))
                PROBE.write_json(root / "summary.json", {"trials": [receipt]})
                output = root / "github-output"
                code = script.replace("pathlib.Path('.build/Temporary/ax-heap-diagnostics')", f"pathlib.Path({str(root)!r})")
                with mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}), \
                        mock.patch.object(sys, "path", list(sys.path)):
                    if failure:
                        with self.assertRaises((SystemExit, ValueError)):
                            exec(compile(code, "ax-system-baseline.yml", "exec"), {})
                        self.assertFalse(output.exists())
                    else:
                        exec(compile(code, "ax-system-baseline.yml", "exec"), {})
                        self.assertEqual(output.read_text(), "safe=true\n")

    def test_successful_baseline_syntax_requires_its_complete_reference_view(self):
        with mock.patch.object(sys, "path", [str(INVESTIGATIONS), *sys.path]):
            from ax_parser_evidence import Collector
        for complete in (True, False):
            with self.subTest(complete=complete):
                value = self.frozen_summary(first_strict_growth=True, selected_label="added-10")
                index = next(i for i, t in enumerate(value["tools"]) if (t["tool"], t["label"]) == ("trace", "baseline"))
                collector = Collector()
                collector.record("trace", "baseline", index, value["baseline"]["graph_sha256"],
                    "Tracing: <__NSMallocBlock__ 0x3000> [48]\n", None, target=(0x3000, 48))
                if not complete:
                    value.update(status="partial", reasons=["references_invalid"])
                    value["references"]["status"] = "partial"
                    view = next(v for v in value["references"]["views"] if (v["kind"], v["checkpoint"]) == ("trace", "baseline"))
                    view.update(status="unavailable", root=None, target=None, nodes=[], edges=[])
                _, summary = self.run_measurement(enabled=False, first_strict_growth=True, first_failure="strict",
                    frozen_summary=value, parser_evidence=collector.value,
                    first_scan_change=lambda scan: scan.update(leak_nodes=2, leak_bytes=252))
                first = summary["trials"][0]
                self.assertTrue(first["frozen_nodes_available"])
                self.assertEqual(first["parser_evidence_available"], complete)
                self.assertEqual(first["frozen_node_checks_passed"], complete)
                self.assertFalse(summary["strict_checks_passed"])

    def test_first_strict_growth_complete_diagnostics_preserve_the_original_strict_failure(self):
        for byte_growth in (False, True):
            with self.subTest(byte_growth=byte_growth):
                value = self.frozen_summary(first_strict_growth=True, selected_label="added-10", byte_growth=byte_growth)
                def scans_change(scans):
                    scans[0].update(leak_nodes=2, leak_bytes=252)
                    if byte_growth:
                        for scan in scans[1:]:
                            scan.update(leak_nodes=2)
                _, summary = self.run_measurement(enabled=False, first_strict_growth=True, first_failure="strict",
                    frozen_summary=value, first_scans_change=scans_change)
                self.assertFalse(summary["strict_checks_passed"])
                self.assertTrue(summary["frozen_node_checks_passed"])
                first = summary["trials"][0]
                self.assertEqual(first["return_code"], 1)
                self.assertEqual(first["validation_failure_counts"]["heap_baseline"], 1)
                self.assertEqual(first["validation_failure_counts"]["notifications"], 1)
                self.assertEqual(first["frozen_nodes"]["selected_label"], "added-10")
                self.assertTrue(first["frozen_node_checks_passed"])

    def test_first_strict_growth_failures_keep_strict_results_and_continue_only_after_cleanup(self):
        for failure in ("missing", "partial", "mismatched", "missing-selection", "timeout", "host-exit", "cleanup"):
            with self.subTest(failure=failure):
                value = self.frozen_summary(first_strict_growth=True)
                if failure == "partial":
                    value.update(status="partial", reasons=["tree_invalid"])
                    value["tools"][-1]["status"] = "output_invalid"
                if failure == "mismatched":
                    value["baseline"]["leak_bytes"] = 400
                    value["baseline_roots"]["roots"][0]["bytes"] = 400
                    for point in value["checked_points"]:
                        point["leak_bytes"] = 400
                if failure == "missing-selection":
                    value.update(status="partial", selection=None, reasons=["list_invalid"])
                invocations, summary = self.run_measurement(enabled=False, first_strict_growth=True,
                    frozen_summary=value, frozen_failure=failure)
                self.assertTrue(summary["strict_checks_passed"])
                self.assertFalse(summary["frozen_node_checks_passed"])
                self.assertFalse(summary["trials"][0]["frozen_node_checks_passed"])
                if failure == "cleanup":
                    self.assertEqual(invocations, [(None, "control")])
                    self.assertFalse(summary["completed"])
                else:
                    self.assertEqual(len(invocations), 10)
                    self.assertTrue(all(trial["frozen_node_checks_passed"] for trial in summary["trials"][1:]))
                if failure == "host-exit":
                    self.assertNotIn("frozen_node_process_run", summary["trials"][0])
                self.assertEqual(summary["trials"][0]["frozen_nodes_available"], failure in ("partial", "timeout", "cleanup"))
        _, summary = self.run_measurement(enabled=False, first_strict_growth=True, first_failure="cleanup")
        self.assertFalse(summary["completed"])
        self.assertNotIn("frozen_node_process_run", summary["trials"][0])

    def test_first_strict_growth_rejects_delayed_growth_and_false_no_growth(self):
        for kind in ("delayed-growth", "false-no-growth"):
            with self.subTest(kind=kind):
                if kind == "delayed-growth":
                    value = self.frozen_summary(first_strict_growth=True, selected_label="removed-10")
                else:
                    value = self.frozen_summary(first_strict_growth=True)
                    value["baseline"].update(leak_nodes=2, leak_bytes=252)
                    value["baseline_roots"]["roots"][0].update(nodes=2, bytes=252)
                    for point in value["checked_points"]:
                        point.update(leak_nodes=2, leak_bytes=252)
                with mock.patch.object(sys, "path", [str(INVESTIGATIONS), *sys.path]):
                    from ax_frozen_nodes import validate_summary
                validate_summary(value)
                _, summary = self.run_measurement(enabled=False, first_strict_growth=True, first_failure="strict",
                    first_scan_change=lambda scan: scan.update(leak_nodes=2, leak_bytes=252),
                    frozen_summary=value, frozen_failure=kind)
                self.assertFalse(summary["strict_checks_passed"])
                self.assertFalse(summary["frozen_node_checks_passed"])
                self.assertFalse(summary["trials"][0]["frozen_nodes_available"])

    def test_first_strict_growth_rejects_selected_totals_different_from_original_scans(self):
        value = self.frozen_summary(first_strict_growth=True, selected_label="added-10")
        def scans_change(scans):
            scans[0].update(leak_nodes=2, leak_bytes=252)
            for scan in scans[1:]:
                scan.update(leak_bytes=301)
        _, summary = self.run_measurement(enabled=False, first_strict_growth=True, first_failure="strict",
            first_scans_change=scans_change, frozen_summary=value, frozen_failure="selected-mismatch")
        self.assertFalse(summary["frozen_node_checks_passed"])
        self.assertFalse(summary["trials"][0]["frozen_nodes_available"])
        self.assertEqual(summary["trials"][0]["scan_totals"][1]["leak_bytes"], 301)

    def test_external_receipt_requires_live_scribble_before_starting_fixtures(self):
        script = self.workflow_script("Verify investigation identity")
        for scan_mode, enabled, receipt, diagnostic in (("diagnostic", "true", "external-startup", "false"),
                ("live", "false", "external-startup", "false"), ("live", "true", "unknown", "false"),
                ("live", "true", "external-startup", "true")):
            with mock.patch.dict(os.environ, {"CAUSAL_PROBE": "false", "AX_SCAN_MODE": scan_mode,
                    "MALLOC_SCRIBBLE_EXPERIMENT": enabled, "AX_RECEIPT_MODE": receipt, "AX_HEAP_DIAGNOSTICS": diagnostic}), \
                    mock.patch.object(subprocess, "check_output") as query, self.assertRaises(AssertionError):
                exec(compile(script, "ax-system-baseline.yml", "exec"), {})
            query.assert_not_called()

    def test_pure_control_workflow_has_an_explicit_exclusive_opt_in(self):
        script = self.workflow_script("Verify investigation identity")
        environment = {"AX_PURE_APPKIT_CONTROL": "true", "AX_SCAN_MODE": "diagnostic", "AX_RECEIPT_MODE": "internal",
                       "AX_TERMINAL_ORIGIN": "false", "MALLOC_SCRIBBLE_EXPERIMENT": "false", "AX_HEAP_DIAGNOSTICS": "false", "CAUSAL_PROBE": "false"}
        outputs = {('sw_vers', '-productVersion'): '26.6.2', ('sw_vers', '-buildVersion'): '25G83',
                   ('uname', '-m'): 'arm64', ('xcodebuild', '-version'): 'Xcode 26.3\nBuild version 17C529',
                   ('git', 'rev-parse', 'HEAD'): '1' * 40}
        variants = [None, ("AX_SCAN_MODE", "live"), ("AX_RECEIPT_MODE", "external-startup")]
        variants += [(key, "true") for key in ("AX_TERMINAL_ORIGIN", "MALLOC_SCRIBBLE_EXPERIMENT", "AX_HEAP_DIAGNOSTICS", "CAUSAL_PROBE")]
        for variant in variants:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory) / "records"
                code = script.replace("pathlib.Path('.build/Temporary/ax-heap-diagnostics')", f"pathlib.Path({str(root)!r})")
                changed = environment | (dict([variant]) if variant else {})
                with mock.patch.dict(os.environ, changed), contextlib.redirect_stdout(io.StringIO()), \
                        mock.patch.object(subprocess, "check_output", side_effect=lambda command, **_: outputs[tuple(command)]) as query:
                    if variant:
                        with self.assertRaises(AssertionError):
                            exec(compile(code, "ax-system-baseline.yml", "exec"), {})
                        query.assert_not_called()
                    else:
                        exec(compile(code, "ax-system-baseline.yml", "exec"), {})
                        summary = json.loads((root / "summary.json").read_text())
                        self.assertEqual(summary["expected_trials"], 10)
                        self.assertTrue(summary["identity"]["pure_appkit_control"])
                        self.assertEqual(summary["identity"]["scan_mode"], "live")
                        self.assertEqual(summary["identity"]["receipt_mode"], "external-startup")

    def test_install_gate_workflow_has_an_explicit_exclusive_opt_in(self):
        script = self.workflow_script("Verify investigation identity")
        environment = {"AX_INSTALL_GATE_CONTROL": "true", "AX_SCAN_MODE": "diagnostic", "AX_RECEIPT_MODE": "internal",
                       "AX_TERMINAL_ORIGIN": "false", "MALLOC_SCRIBBLE_EXPERIMENT": "false", "CAUSAL_PROBE": "false",
                       "AX_PURE_APPKIT_CONTROL": "false", "AX_FROZEN_CONTROL": "false"}
        outputs = {('sw_vers', '-productVersion'): '26.6.2', ('sw_vers', '-buildVersion'): '25G83',
                   ('uname', '-m'): 'arm64', ('xcodebuild', '-version'): 'Xcode 26.3\nBuild version 17C529',
                   ('git', 'rev-parse', 'HEAD'): '1' * 40}
        variants = [None, ("AX_SCAN_MODE", "live"), ("AX_RECEIPT_MODE", "external-startup")]
        variants += [(key, "true") for key in ("AX_TERMINAL_ORIGIN", "MALLOC_SCRIBBLE_EXPERIMENT", "CAUSAL_PROBE", "AX_PURE_APPKIT_CONTROL", "AX_FROZEN_CONTROL")]
        for diagnostic, variant in itertools.product((False, True), variants):
            with self.subTest(diagnostic=diagnostic, variant=variant), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory) / "records"
                code = script.replace("pathlib.Path('.build/Temporary/ax-heap-diagnostics')", f"pathlib.Path({str(root)!r})")
                changed = environment | {"AX_HEAP_DIAGNOSTICS": str(diagnostic).lower()} | (dict([variant]) if variant else {})
                with mock.patch.dict(os.environ, changed), contextlib.redirect_stdout(io.StringIO()), \
                        mock.patch.object(subprocess, "check_output", side_effect=lambda command, **_: outputs[tuple(command)]) as query:
                    if variant:
                        with self.assertRaises(AssertionError):
                            exec(compile(code, "ax-system-baseline.yml", "exec"), {})
                        query.assert_not_called()
                    else:
                        exec(compile(code, "ax-system-baseline.yml", "exec"), {})
                        summary = json.loads((root / "summary.json").read_text())
                        self.assertEqual(summary["expected_trials"], 10)
                        self.assertTrue(summary["identity"]["install_gate_control"])
                        self.assertEqual(summary["identity"]["scan_mode"], "diagnostic" if diagnostic else "live")
                        self.assertEqual(summary["identity"]["receipt_mode"], "external-startup")
                        self.assertEqual(summary["identity"].get("frozen_node_selection"), "first-strict-growth" if diagnostic else None)

    def test_install_gate_workflow_reuses_one_build_and_retains_failures(self):
        for failure in (None, "strict", "timeout", "install-capability", "install-initial", "install-scan", "install-env", "external-missing"):
            with self.subTest(failure=failure):
                invocations, summary = self.run_measurement(enabled=False, scan_mode="live", receipt_mode="external-startup",
                    install_control=True, first_failure=failure)
                pair = [("off", "installed"), ("off", "preflight-only")]
                self.assertEqual(invocations, pair + list(reversed(pair)) + pair + list(reversed(pair)) + pair)
                self.assertEqual(summary["install_gate_build"]["build_mode"], "install-gate")
                for trial in summary["trials"][1:]:
                    self.assertTrue(trial["initial_install_gate_verified"])
                    self.assertTrue(trial["capability_install_gate_verified"])
                    self.assertTrue(trial["control_zero_targets"])
                    self.assertEqual(trial["startup_environment"]["executables"], summary["fixture_executables"])
                    self.assertEqual(trial["startup_environment"]["install_gate"], trial["mode"])
                    self.assertEqual(len(trial["scan_totals"]), 6)
        for failure in ("build", "build-timeout", "cleanup"):
            self.run_measurement(enabled=False, scan_mode="live", receipt_mode="external-startup", install_control=True, first_failure=failure)

    def test_install_gate_frozen_pairs_reuse_one_build_and_bind_all_seven_snapshots(self):
        invocations, summary = self.run_measurement(enabled=False, receipt_mode="external-startup",
            install_control=True, first_strict_growth=True)
        pair = [("off", "installed"), ("off", "preflight-only")]
        self.assertEqual(invocations, pair + list(reversed(pair)) + pair + list(reversed(pair)) + pair)
        self.assertEqual(summary["install_gate_build"]["build_mode"], "install-gate")
        self.assertTrue(summary["strict_checks_passed"])
        self.assertTrue(summary["frozen_node_checks_passed"])
        for trial in summary["trials"]:
            self.assertTrue(trial["initial_install_gate_verified"])
            self.assertTrue(trial["capability_install_gate_verified"])
            self.assertTrue(trial["control_zero_targets"])
            self.assertEqual(trial["startup_environment"]["executables"], summary["fixture_executables"])
            self.assertEqual(trial["startup_environment"]["install_gate"], trial["mode"])
            self.assertEqual([scan["label"] for scan in trial["scan_totals"]], list(REPORT.HEAP_LABELS))
            self.assertEqual(trial["frozen_nodes"]["selection"], "no-strict-growth")
            self.assertEqual(trial["parser_evidence"]["file"], f'parser-evidence-trial-{trial["trial"]}-{trial["mode"]}.json')

    def test_install_gate_frozen_first_growth_survives_later_shrinkage_and_marks_truncation(self):
        for new_nodes in (1, 18):
            with self.subTest(new_nodes=new_nodes):
                value = self.frozen_summary(first_strict_growth=True, selected_label="registered-10", new_nodes=new_nodes)
                def scans_change(scans):
                    for scan in scans:
                        point = value["selected"] if scan["label"] == "registered-10" else value["baseline"]
                        scan.update({key: point[key] for key in ("leak_nodes", "leak_bytes")})
                _, summary = self.run_measurement(enabled=False, receipt_mode="external-startup", install_control=True,
                    first_strict_growth=True, first_failure="strict", frozen_summary=value, first_scans_change=scans_change)
                first = summary["trials"][0]
                self.assertFalse(summary["strict_checks_passed"])
                self.assertEqual(first["return_code"], 1)
                self.assertEqual(first["validation_failure_counts"]["heap_baseline"], 1)
                self.assertTrue(first["frozen_nodes_available"])
                self.assertEqual(first["frozen_nodes"]["selected_label"], "registered-10")
                self.assertEqual(first["frozen_node_checks_passed"], new_nodes == 1)
                self.assertEqual(first["frozen_nodes"]["candidate_count"], new_nodes)
                if new_nodes == 18:
                    self.assertEqual(first["frozen_nodes"]["status"], "partial")
                    self.assertIn("candidate_limit", first["frozen_nodes"]["reasons"])
                    self.assertEqual(len(first["frozen_nodes"]["nodes"]) + first["frozen_nodes"]["omitted_candidates"], 18)
                    self.assertGreater(first["frozen_nodes"]["omitted_candidates"], 0)

    def test_install_gate_frozen_cleanup_failure_stops_following_cases(self):
        self.run_measurement(enabled=False, receipt_mode="external-startup", install_control=True,
            first_strict_growth=True, first_failure="cleanup")
        self.run_measurement(enabled=False, receipt_mode="external-startup", install_control=True,
            first_strict_growth=True, frozen_failure="cleanup")

    def test_startup_failure_summary_is_bounded_and_never_weakens_the_verdict(self):
        valid = [{"stage": "external-startup-reader", "reason": "sysctl_procargs", "errno": 13},
                 {"stage": "external-startup-complete", "reason": "receipt_incomplete", "errno": None},
                 {"stage": "external-startup-final", "reason": "receipt_incomplete", "errno": None}]
        for evidence in (valid, None, [{"stage": "external-startup-host", "reason": "secret", "errno": None}],
                         [dict(valid[0], errno=True)], [valid[0]] * 5, [dict(valid[0], private="secret")]):
            _, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                first_failure="startup-failures", first_startup_failures=evidence)
            first = summary["trials"][0]
            self.assertEqual(first["startup_failures_available"], evidence == valid)
            if evidence == valid:
                self.assertEqual(first["startup_failures"], valid)
            else:
                self.assertNotIn("startup_failures", first)
            self.assertTrue(all(row["startup_failures_available"] and row["startup_failures"] == [] for row in summary["trials"][1:]))

    def test_pure_control_workflow_reuses_each_build_and_keeps_all_ten_cases_after_failure(self):
        for failure in (None, "strict", "timeout", "control-mode", "cross-mode-receipt", "external-receipt", "external-private", "external-missing", "scan-fields"):
            with self.subTest(failure=failure):
                change = (lambda scan: scan["host"].update(buttons=1)) if failure == "scan-fields" else None
                invocations, summary = self.run_measurement(enabled=False, scan_mode="live", receipt_mode="external-startup",
                    pure_control=True, first_failure=failure, first_scan_change=change)
                pair = [("off", "patched"), ("off", "pure-appkit")]
                self.assertEqual(invocations, pair + list(reversed(pair)) + pair + list(reversed(pair)) + pair)
                self.assertEqual(set(summary["empty_control_builds"]), {"patched", "pure-appkit"})
                for trial in summary["trials"][1:]:
                    self.assertTrue(trial["control_zero_targets"])
                    self.assertTrue(trial["fixture_mode_verified"])
                    self.assertEqual(len(trial["scan_totals"]), 6)
                    self.assertEqual(trial["startup_environment"]["executables"], summary["empty_control_builds"][trial["mode"]]["manifest"]["executables"])
                self.assertNotEqual(summary["empty_control_builds"]["patched"]["manifest"]["executables"]["host"],
                                    summary["empty_control_builds"]["pure-appkit"]["manifest"]["executables"]["host"])
        for failure in ("build", "build-timeout"):
            self.run_measurement(enabled=False, scan_mode="live", receipt_mode="external-startup", pure_control=True, first_failure=failure)

    def test_failed_or_timed_out_preparation_cannot_claim_completed_trials(self):
        for failure in ("build", "build-timeout"):
            self.run_measurement(scan_mode="live", receipt_mode="external-startup", first_failure=failure)

    def test_external_workflow_builds_once_and_keeps_every_case_after_failure(self):
        for failure in (None, "strict", "classification", "timeout", "external-receipt", "external-private", "external-missing"):
            with self.subTest(failure=failure):
                invocations, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup", first_failure=failure)
                self.assertEqual(len(invocations), 20)
                self.assertEqual(summary["fixture_build_return_code"], 0)
                for receipt in summary["trials"][1:]:
                    self.assertTrue(receipt["external_startup_verified"])
                    self.assertEqual(receipt["startup_environment"]["executables"], summary["fixture_executables"])

    def test_terminal_workflow_runs_only_off_pair_and_retains_independent_verdicts(self):
        for failure in (None, "strict", "terminal", "terminal-private", "terminal-missing", "timeout"):
            with self.subTest(failure=failure):
                invocations, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                                                          terminal_origin=True, first_failure=failure)
                self.assertEqual(invocations, [("off", "control"), ("off", "product")])
                self.assertTrue(summary["trials"][1]["terminal_snapshot_checks_passed"])
                self.assertEqual(summary["terminal_snapshot_checks_passed"], failure not in ("terminal", "terminal-private", "terminal-missing", "timeout"))

    def test_terminal_upload_prunes_unverified_images_without_losing_strict_failure_or_old_evidence(self):
        reports, catalog = AXTerminalSnapshotTests.image_reports()
        with mock.patch.object(REPORT.ax_system_images, "loaded_system_images", return_value=catalog):
            terminal = AXTerminalSnapshotTests.summary(reports)
        partial = {key: catalog[key] for key in list(catalog)[:1]}
        for fresh in (None, partial):
            with self.subTest(fresh=fresh), \
                    mock.patch.object(REPORT.ax_system_images, "loaded_system_images", return_value=fresh) as load:
                invocations, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                    terminal_origin=True, first_failure="strict", first_terminal_change=lambda value:
                        value.update(json.loads(json.dumps(terminal))))
            self.assertEqual(load.call_count, 1)
            self.assertEqual(invocations, [("off", "control"), ("off", "product")])
            self.assertFalse(summary["strict_checks_passed"])
            self.assertTrue(summary["terminal_snapshot_checks_passed"])
            first = summary["trials"][0]
            self.assertEqual(first["return_code"], 1)
            self.assertTrue(first["terminal_snapshot_available"])
            self.assertTrue(first["failure_classification_available"])
            self.assertEqual(first["validation_failure_counts"]["heap_baseline"], 1)
            self.assertEqual(first["validation_failure_counts"]["notifications"], 1)
            self.assertEqual(sum(len(row["scan_totals"]) for row in summary["trials"]), 12)
            published = first["terminal_snapshot"]
            self.assertEqual(AXTerminalSnapshotTests.without_image_identity(published),
                             AXTerminalSnapshotTests.without_image_identity(terminal))
            identity = published["root_groups"][0]["other_image_identity"]
            self.assertEqual(identity["frames"], [] if fresh is None else [{"index": 2, **next(iter(partial.values()))}])
            reason = "local_catalog_unavailable" if fresh is None else "uuid_not_verified"
            self.assertEqual(identity["reason_counts"][reason], 2 if fresh is None else 1)
            self.assertEqual(identity["status"], "partial")

    def test_terminal_worker_unknown_exit_saves_strict_failure_and_blocks_next_case(self):
        reports, catalog = AXTerminalSnapshotTests.image_reports()
        images = REPORT.ax_system_images
        with mock.patch.object(images, "loaded_system_images", return_value=catalog):
            terminal = AXTerminalSnapshotTests.summary(reports)
        for failure in ("collection", "fresh", "missing"):
            def fail(path):
                images.write_worker_cleanup(path, False)
                raise images.ImageWorkerCleanupError()
            with self.subTest(failure=failure), mock.patch.object(images, "loaded_system_images", side_effect=fail) as load:
                invocations, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                    terminal_origin=True, first_failure="strict", image_cleanup_failure=failure,
                    first_terminal_change=lambda value: value.update(json.loads(json.dumps(terminal))))
            self.assertEqual(load.call_count, int(failure == "fresh"))
            self.assertEqual(invocations, [("off", "control")])
            self.assertFalse(summary["strict_checks_passed"])
            first = summary["trials"][0]
            self.assertEqual(first["return_code"], 1)
            self.assertEqual(first["validation_failure_counts"]["heap_baseline"], 1)
            self.assertEqual(first["validation_failure_counts"]["notifications"], 1)
            self.assertEqual(len(first["scan_totals"]), 6)
            self.assertTrue(first["terminal_snapshot_checks_passed"])  # Old extraction verdict is unchanged.
            self.assertFalse(summary["terminal_snapshot_checks_passed"])  # Cleanup is an independent hard failure.
            self.assertEqual(AXTerminalSnapshotTests.without_image_identity(first["terminal_snapshot"]),
                             AXTerminalSnapshotTests.without_image_identity(terminal))
            identity = first["terminal_snapshot"]["root_groups"][0]["other_image_identity"]
            self.assertEqual(identity["frames"], [])
            self.assertEqual(identity["reason_counts"]["local_catalog_unavailable"], 2)

    def test_terminal_artifact_failures_keep_confirmed_exit_strict_failure_and_safe_evidence(self):
        reports, catalog = AXTerminalSnapshotTests.image_reports()
        images = REPORT.ax_system_images
        with mock.patch.object(images, "loaded_system_images", return_value=catalog):
            terminal = AXTerminalSnapshotTests.summary(reports)
        for failure in ("collection-artifact", "fresh-artifact", "gate-write"):
            def fail(path):
                images.write_worker_cleanup(path, True, False)
                raise images.ImageWorkerArtifactError() from PermissionError(13, "/private/secret")
            write = pathlib.Path.write_text
            writes = []
            def save(path, data, *args, **kwargs):
                if failure == "gate-write" and path.name == "terminal-image-upload-worker.json":
                    writes.append(path)
                    raise PermissionError(13, "/private/secret")
                return write(path, data, *args, **kwargs)
            with self.subTest(failure=failure), mock.patch.object(images, "loaded_system_images", side_effect=fail) as load, \
                    mock.patch.object(pathlib.Path, "write_text", new=save):
                invocations, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                    terminal_origin=True, first_failure="strict", image_cleanup_failure=failure,
                    first_terminal_change=lambda value: value.update(json.loads(json.dumps(terminal))))
            self.assertEqual(load.call_count, int(failure == "fresh-artifact"))
            self.assertEqual(len(writes), int(failure == "gate-write"))
            self.assertEqual(invocations, [("off", "control")])
            self.assertFalse(summary["strict_checks_passed"])
            first = summary["trials"][0]
            self.assertEqual(first["terminal_image_worker_cleanup"], "confirmed")
            self.assertEqual(first["terminal_image_worker_artifact_cleanup"], "failed")
            self.assertEqual(first["validation_failure_counts"]["heap_baseline"], 1)
            self.assertEqual(first["validation_failure_counts"]["notifications"], 1)
            self.assertEqual(len(first["scan_totals"]), 6)
            self.assertTrue(first["terminal_snapshot_checks_passed"])
            self.assertFalse(summary["terminal_snapshot_checks_passed"])
            self.assertEqual(AXTerminalSnapshotTests.without_image_identity(first["terminal_snapshot"]),
                             AXTerminalSnapshotTests.without_image_identity(terminal))
            self.assertEqual(first["terminal_snapshot"]["root_groups"][0]["other_image_identity"]["frames"], [])

    def test_collection_stage_overrides_stale_success_before_first_or_fresh_helper(self):
        reports, catalog = AXTerminalSnapshotTests.image_reports()
        images = REPORT.ax_system_images
        for failed_write in (1, 2):
            with self.subTest(failed_write=failed_write), tempfile.TemporaryDirectory() as directory:
                records = pathlib.Path(directory)
                capture = REPORT.empty_terminal_snapshot()
                capture.update(capture_status="complete", capture_exit_code=0)
                write = pathlib.Path.write_text
                attempts = []
                def save(path, data, *args, **kwargs):
                    if path.name == "terminal-image-worker.json" and json.loads(data)["cleanup_confirmed"] is False:
                        attempts.append(path)
                        if len(attempts) == failed_write:
                            raise PermissionError(13, "/private/secret")
                    return write(path, data, *args, **kwargs)
                def run(command, log, environment, timeout):
                    log.write_text("")
                    pathlib.Path(command[-1]).write_text(json.dumps({"schema": 1, "images": list(catalog.values())}))
                    return {"status": "completed", "return_code": 0, "cleanup": {"complete": True}}
                with mock.patch.object(images, "WORKER_ROOT", records), \
                        mock.patch.object(images.ax_process, "run_owned", side_effect=run) as owned, \
                        mock.patch.object(pathlib.Path, "write_text", new=save), \
                        mock.patch.object(REPORT.subprocess, "run", side_effect=[subprocess.CompletedProcess([], 1, text, "") for text in reports]), \
                        mock.patch.object(REPORT, "SystemSymbols", return_value=AXTerminalSnapshotTests.resolver()), \
                        self.assertRaises(images.ImageWorkerArtifactError) as raised:
                    REPORT.collect_terminal_snapshot(records / "terminal.memgraph", records, capture)
                self.assertEqual(owned.call_count, failed_write - 1)
                self.assertEqual(len(attempts), failed_write)
                self.assertNotIn("private", str(raised.exception))
                self.assertEqual(images.worker_cleanup_state(records / "terminal-image-worker.json"), (True, True))
                self.assertEqual(list(records.glob("ax-system-images-*")), [])
                terminal = json.loads((records / "terminal-snapshot.json").read_text())
                self.assertEqual((terminal["leak_nodes"], terminal["leak_bytes"]), (2, 144))
                # The runner's existing cleanup_step records this fixed stage.
                # Pass the actual collector files across the persisted boundary.
                def transfer(destination):
                    for name in ("terminal-image-worker.json", "terminal-snapshot.json"):
                        (destination / name).write_bytes((records / name).read_bytes())
                    PROBE.write_json(destination / "process-cleanup.json",
                                     {"processes_exited": True, "errors": ["terminal_snapshot"]})
                    result = json.loads((destination / "result.json").read_text())
                    result["validation_errors"].append({"stage": "cleanup", "message": "terminal_snapshot"})
                    PROBE.write_json(destination / "result.json", result)
                with mock.patch.object(images, "loaded_system_images", return_value=catalog) as upload:
                    invocations, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                        terminal_origin=True, first_failure="strict", image_cleanup_failure="collection-stage",
                        first_records_change=transfer)
                upload.assert_not_called()
                self.assertEqual(invocations, [("off", "control")])
                first = summary["trials"][0]
                self.assertEqual(first["terminal_image_worker_cleanup"], "confirmed")
                self.assertEqual(first["terminal_image_worker_artifact_cleanup"], "failed")
                self.assertEqual(first["terminal_snapshot"], terminal)
                self.assertTrue(first["terminal_snapshot_checks_passed"])
                self.assertFalse(summary["terminal_snapshot_checks_passed"])
                self.assertFalse(summary["strict_checks_passed"])
                self.assertEqual(first["validation_failure_counts"]["heap_baseline"], 1)
                self.assertEqual(first["validation_failure_counts"]["notifications"], 1)
                self.assertEqual(first["validation_failure_counts"]["other"], 1)
                self.assertEqual([scan["label"] for scan in first["scan_totals"]],
                                 [label for label in REPORT.HEAP_LABELS if label != "added-10"])

    def test_terminal_cleanup_stage_receipt_is_bounded_and_fail_closed(self):
        reports, catalog = AXTerminalSnapshotTests.image_reports()
        images = REPORT.ax_system_images
        with mock.patch.object(images, "loaded_system_images", return_value=catalog):
            terminal = AXTerminalSnapshotTests.summary(reports)
        failures = [{"errors": ["terminal_snapshot"]}, None, [], {}, {"errors": None}, {"errors": "terminal_snapshot"},
                     {"errors": [True]}, {"errors": ["/private/secret"]}, {"errors": [{}]},
                     {"errors": ["terminal_snapshot"] * 17}, "missing", "oversize", "directory", "symlink"]
        for cleanup in failures:
            def change(records):
                path = records / "process-cleanup.json"
                if cleanup in ("missing", "directory", "symlink"):
                    path.unlink()
                    if cleanup == "directory":
                        path.mkdir()
                    elif cleanup == "symlink":
                        target = records / "private-cleanup.json"
                        PROBE.write_json(target, {"errors": []})
                        path.symlink_to(target)
                elif cleanup == "oversize":
                    path.write_text(json.dumps({"errors": [], "private": "secret" * 700}))
                else:
                    PROBE.write_json(path, cleanup)
            with self.subTest(cleanup=cleanup), mock.patch.object(images, "loaded_system_images", return_value=catalog) as upload:
                _, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                    terminal_origin=True, first_failure="strict", image_cleanup_failure="collection-stage",
                    first_terminal_change=lambda value: value.update(json.loads(json.dumps(terminal))), first_records_change=change)
            upload.assert_not_called()
            first = summary["trials"][0]
            self.assertEqual(first["terminal_image_worker_artifact_cleanup"], "failed")
            self.assertEqual(AXTerminalSnapshotTests.without_image_identity(first["terminal_snapshot"]),
                             AXTerminalSnapshotTests.without_image_identity(terminal))
            self.assertEqual(first["terminal_snapshot"]["root_groups"][0]["other_image_identity"]["frames"], [])
            self.assertEqual(first["validation_failure_counts"]["heap_baseline"], 1)
            self.assertEqual(len(first["scan_totals"]), 6)

    def test_terminal_stage_does_not_bypass_structure_gate_or_infer_from_other_errors(self):
        images = REPORT.ax_system_images
        with mock.patch.object(images, "loaded_system_images") as load:
            _, invalid = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                terminal_origin=True, first_failure="strict", image_cleanup_failure="collection-stage",
                first_terminal_change=lambda value: value.update(private="secret"),
                first_records_change=lambda records: PROBE.write_json(records / "process-cleanup.json",
                    {"errors": ["terminal_snapshot"], "processes_exited": True}))
        load.assert_not_called()
        self.assertNotIn("terminal_snapshot", invalid["trials"][0])
        reports, catalog = AXTerminalSnapshotTests.image_reports()
        with mock.patch.object(images, "loaded_system_images", return_value=catalog):
            terminal = AXTerminalSnapshotTests.summary(reports)
        with mock.patch.object(images, "loaded_system_images", return_value=catalog) as load:
            invocations, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                terminal_origin=True, first_failure="strict",
                first_terminal_change=lambda value: value.update(terminal),
                first_records_change=lambda records: PROBE.write_json(records / "process-cleanup.json",
                    {"errors": ["launch_services"], "processes_exited": True}))
        load.assert_called_once()
        self.assertEqual(invocations, [("off", "control"), ("off", "product")])
        self.assertEqual(summary["trials"][0]["terminal_image_worker_artifact_cleanup"], "complete")
        self.assertFalse(summary["strict_checks_passed"])

    def test_deep_cache_json_preserves_collection_upload_evidence_and_allows_next_case(self):
        fixture = AXTerminalCacheIdentityTests(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        images = REPORT.ax_system_images
        real_lookup = images.shared_cache_images
        capture = REPORT.empty_terminal_snapshot(); capture.update(capture_status="complete", capture_exit_code=0)
        for failure_phase in ("collection", "upload"):
            with self.subTest(failure_phase=failure_phase):
                calls, cleanup_states, phase = [], [], "collection"
                def lookup(identifiers, cleanup):
                    try:
                        return real_lookup(identifiers, cleanup)
                    finally:
                        cleanup_states.append(images.worker_cleanup_state(cleanup))
                def owned(command, log, environment, timeout):
                    calls.append((phase, log.stem))
                    log.write_bytes(b"")
                    if log.stem == "lookup":
                        payload = (b"[" * 10000 + b"0" + b"]" * 10000 if phase == failure_phase
                                   else json.dumps(fixture.packet(command[3:])).encode())
                        pathlib.Path(command[2]).write_bytes(payload)
                    return {"status": "completed", "return_code": 0, "cleanup": {"complete": True}}
                def collect(records):
                    nonlocal phase
                    with mock.patch.object(REPORT.subprocess, "run", side_effect=[
                            subprocess.CompletedProcess([], 1, text, "") for text in fixture.reports]):
                        REPORT.collect_terminal_snapshot(records / "terminal.memgraph", records, capture)
                    self.assertEqual(images.worker_cleanup_state(records / "terminal-image-worker.json"), (True, True))
                    self.assertEqual(json.loads((records / "terminal-snapshot.json").read_text()), fixture.terminal)
                    phase = "upload"
                with mock.patch.object(images, "WORKER_ROOT", fixture.records / "workers"), \
                        mock.patch.object(images, "ax_process", mock.Mock(run_owned=mock.Mock(side_effect=owned))), \
                        mock.patch.object(images, "shared_cache_images", side_effect=lookup), \
                        mock.patch.object(images, "loaded_system_images", return_value=fixture.catalog):
                    invocations, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                        terminal_origin=True, first_failure="strict", first_records_change=collect)
                self.assertEqual(calls, [("collection", "compile"), ("collection", "lookup")]
                                 + ([("upload", "compile"), ("upload", "lookup")] if failure_phase == "upload" else []))
                self.assertEqual(cleanup_states, [(True, True)] * (2 if failure_phase == "upload" else 1))
                self.assertEqual(invocations, [("off", "control"), ("off", "product")])
                first = summary["trials"][0]
                self.assertEqual(first["terminal_snapshot"], fixture.terminal)
                self.assertEqual(first["terminal_image_worker_cleanup"], "confirmed")
                self.assertEqual(first["terminal_image_worker_artifact_cleanup"], "complete")
                self.assertEqual(first["terminal_cache_image_identity"]["status"], "unavailable")
                self.assertEqual(first["terminal_cache_image_identity"]["frames"], [])
                self.assertEqual(first["validation_failure_counts"]["heap_baseline"], 1)
                self.assertEqual(len(first["scan_totals"]), 6)
                self.assertFalse(summary["strict_checks_passed"])
                self.assertEqual(list((fixture.records / "workers").iterdir()), [])

    def test_optional_cache_upload_persists_old_evidence_before_query_and_stops_on_cleanup_failure(self):
        fixture = AXTerminalCacheIdentityTests(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        packet = fixture.collect()
        images = REPORT.ax_system_images
        for failure in (None, "unavailable", "malformed", "fresh", "fresh-artifact"):
            def transfer(records):
                for name in ("terminal-snapshot.json", "terminal-cache-images.json", "terminal-cache-grouped.txt"):
                    (records / name).write_bytes((fixture.records / name).read_bytes())
                if failure == "malformed":
                    bad = json.loads((records / "terminal-cache-images.json").read_text()); bad["private"] = "secret"
                    PROBE.write_json(records / "terminal-cache-images.json", bad)
            def query(ids, cleanup):
                saved = json.loads((cleanup.parent.parent / "summary.json").read_text())
                self.assertEqual(len(saved["trials"]), 1)
                first = saved["trials"][0]
                self.assertEqual(len(first["scan_totals"]), 6)
                self.assertEqual(first["validation_failure_counts"]["heap_baseline"], 1)
                self.assertEqual(first["terminal_snapshot"], fixture.terminal)
                if failure in ("fresh", "fresh-artifact"):
                    raise (images.ImageWorkerCleanupError() if failure == "fresh" else images.ImageWorkerArtifactError()) from OSError("/private/secret")
                return None if failure == "unavailable" else packet["lookup"]
            with self.subTest(failure=failure), mock.patch.object(images, "loaded_system_images", return_value=fixture.catalog), \
                    mock.patch.object(images, "shared_cache_images", side_effect=query) as fresh:
                invocations, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                    terminal_origin=True, first_failure="strict", first_records_change=transfer,
                    image_cleanup_failure=failure if failure in ("fresh", "fresh-artifact") else None)
            self.assertEqual(fresh.call_count, int(failure != "malformed"))
            self.assertEqual(len(invocations), 1 if failure in ("fresh", "fresh-artifact") else 2)
            first = summary["trials"][0]
            self.assertEqual(first["terminal_snapshot"], fixture.terminal)
            self.assertTrue(first["terminal_snapshot_checks_passed"])
            self.assertEqual(len(first["scan_totals"]), 6)
            self.assertFalse(summary["strict_checks_passed"])
            self.assertEqual(first["terminal_cache_image_identity"]["status"], "complete" if failure is None else "unavailable")
            self.assertEqual(len(first["terminal_cache_image_identity"]["frames"]), 2 if failure is None else 0)

    def test_terminal_worker_unknown_exit_does_not_publish_malformed_old_evidence(self):
        with mock.patch.object(REPORT.ax_system_images, "loaded_system_images") as load:
            _, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                terminal_origin=True, first_failure="strict", image_cleanup_failure="collection",
                first_terminal_change=lambda value: value.update(private="secret"))
        load.assert_not_called()
        self.assertNotIn("terminal_snapshot", summary["trials"][0])
        self.assertEqual(summary["trials"][0]["validation_failure_counts"]["heap_baseline"], 1)

    def test_no_offline_analysis_is_not_reported_as_a_started_worker(self):
        with mock.patch.object(REPORT.ax_system_images, "loaded_system_images") as load:
            _, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                terminal_origin=True, first_failure="strict", image_cleanup_failure="not-run")
        load.assert_not_called()
        self.assertEqual(summary["trials"][0]["terminal_image_worker_cleanup"], "not-run")
        self.assertTrue(summary["completed"])

    def test_terminal_ledger_does_not_turn_omitted_groups_or_strict_failures_into_success(self):
        for groups, failure in ((96, None), (96, "strict"), (128, "terminal-omitted"), (128, "strict")):
            terminal = AXTerminalSnapshotTests.summary(AXTerminalSnapshotTests.many_group_reports(groups))
            with self.subTest(groups=groups, failure=failure):
                invocations, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                    terminal_origin=True, first_failure=failure, first_terminal_change=lambda value: value.update(terminal))
                self.assertEqual(invocations, [("off", "control"), ("off", "product")])
                self.assertEqual(summary["terminal_snapshot_checks_passed"], groups == 96)
                self.assertEqual(summary["strict_checks_passed"], failure != "strict")
                first, second = summary["trials"]
                self.assertTrue(first["terminal_snapshot_available"])
                self.assertEqual(first["terminal_snapshot"]["allocation_type_totals"], terminal["allocation_type_totals"])
                self.assertEqual(first["terminal_snapshot"]["omitted_allocation_groups"], max(0, groups - 96))
                self.assertTrue(second["terminal_snapshot_checks_passed"])
                self.assertEqual(sum(len(trial["scan_totals"]) for trial in summary["trials"]), 12)

    def test_terminal_upload_keeps_actual_indented_file_64k_limit(self):
        terminal = AXTerminalSnapshotTests.large_public_summary()
        self.assertLessEqual(len(json.dumps(terminal).encode()), 65536)
        with mock.patch.object(REPORT, "SystemSymbols", return_value=AXTerminalSnapshotTests.resolver()):
            REPORT.validate_terminal_snapshot(terminal)
        sizes, original_write = [], PROBE.write_json
        def write(path, value):
            original_write(path, value)
            if path.name == "terminal-snapshot.json":
                sizes.append(path.stat().st_size)
        with mock.patch.object(PROBE, "write_json", side_effect=write):
            _, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                terminal_origin=True, first_failure="terminal-size", first_terminal_change=lambda value: value.update(terminal))
        self.assertEqual(sizes[0], len((json.dumps(terminal, indent=2) + "\n").encode()))
        self.assertGreater(sizes[0], 65536)
        self.assertTrue(summary["strict_checks_passed"])
        self.assertFalse(summary["terminal_snapshot_checks_passed"])
        self.assertFalse(summary["trials"][0]["terminal_snapshot_available"])
        self.assertTrue(summary["trials"][1]["terminal_snapshot_checks_passed"])

    def test_terminal_workflow_rejects_private_or_inconsistent_new_fields(self):
        changes = [lambda value: value["allocation_type_totals"]["unknown"].update(retained_nodes=0),
                   lambda value: value["root_groups"][0]["reported_image_counts"].update({"/private/secret": 1})]
        for change in changes:
            _, summary = self.run_measurement(scan_mode="live", receipt_mode="external-startup",
                terminal_origin=True, first_failure="terminal-fields", first_terminal_change=change)
            self.assertFalse(summary["terminal_snapshot_checks_passed"])
            self.assertFalse(summary["trials"][0]["terminal_snapshot_available"])
            self.assertNotIn("terminal_snapshot", summary["trials"][0])
            self.assertTrue(summary["trials"][1]["terminal_snapshot_checks_passed"])

    def test_terminal_workflow_rejects_internal_or_diagnostic_before_querying_host(self):
        script = self.workflow_script("Verify investigation identity")
        for mode, receipt in (("live", "internal"), ("diagnostic", "external-startup"), ("diagnostic", "internal")):
            with mock.patch.dict(os.environ, {"CAUSAL_PROBE": "false", "AX_SCAN_MODE": mode,
                    "MALLOC_SCRIBBLE_EXPERIMENT": "true", "AX_RECEIPT_MODE": receipt,
                    "AX_HEAP_DIAGNOSTICS": "false", "AX_TERMINAL_ORIGIN": "true"}), \
                    mock.patch.object(subprocess, "check_output") as query, self.assertRaises(AssertionError):
                exec(compile(script, "ax-system-baseline.yml", "exec"), {})
            query.assert_not_called()

    def test_scan_tool_status_and_independent_assertion_categories_are_preserved(self):
        _, summary = self.run_measurement(scan_mode="live", first_failure="strict")
        first = summary["trials"][0]
        self.assertEqual(first["validation_failure_counts"]["heap_baseline"], 1)
        self.assertEqual(first["validation_failure_counts"]["notifications"], 1)
        self.assertTrue(first["failure_classification_available"])
        self.run_measurement(scan_mode="live", first_failure="tool", first_scan_change=lambda scan: scan.update(exit_code=2))
        for value in (True, None, "secret", 256, -129):
            self.run_measurement(scan_mode="live", first_failure="scan-fields", first_scan_change=lambda scan: scan.update(exit_code=value))

    def test_unconfirmed_group_cleanup_stops_before_next_case(self):
        self.run_measurement(scan_mode="live", first_failure="cleanup")
        self.run_measurement(enabled=False, scan_mode="live", receipt_mode="external-startup",
                             pure_control=True, first_failure="cleanup")

    def test_scan_mode_identity_and_invalid_combinations_before_starting_fixtures(self):
        script = self.workflow_script("Verify investigation identity")
        outputs = {('sw_vers', '-productVersion'): '26.6.2', ('sw_vers', '-buildVersion'): '25G83',
                   ('uname', '-m'): 'arm64', ('xcodebuild', '-version'): 'Xcode 26.3\nBuild version 17C529',
                   ('git', 'rev-parse', 'HEAD'): '1' * 40}
        for mode, enabled, causal, allowed, receipt_mode in (("live", True, False, True, "internal"), ("diagnostic", True, False, True, "internal"),
                ("diagnostic", False, False, True, "internal"), ("live", False, False, False, "internal"),
                ("unknown", True, False, False, "internal"), ("live", True, True, False, "internal"),
                ("live", True, False, True, "external-startup")):
            with self.subTest(mode=mode, enabled=enabled, causal=causal), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory) / "records"
                code = script.replace("pathlib.Path('.build/Temporary/ax-heap-diagnostics')", f"pathlib.Path({str(root)!r})")
                with mock.patch.dict(os.environ, {"AX_SCAN_MODE": mode, "CAUSAL_PROBE": str(causal).lower(),
                                                  "MALLOC_SCRIBBLE_EXPERIMENT": str(enabled).lower(), "AX_RECEIPT_MODE": receipt_mode, "AX_HEAP_DIAGNOSTICS": "false"}), \
                        mock.patch.object(subprocess, "check_output", side_effect=lambda command, **_: outputs[tuple(command)]), \
                        contextlib.redirect_stdout(io.StringIO()):
                    if allowed:
                        exec(compile(code, "ax-system-baseline.yml", "exec"), {})
                        summary = json.loads((root / "summary.json").read_text())
                        self.assertEqual(summary["identity"]["scan_mode"], mode)
                        self.assertEqual(summary["expected_trials"], 20 if enabled else 10)
                    else:
                        with self.assertRaises(AssertionError):
                            exec(compile(code, "ax-system-baseline.yml", "exec"), {})
                        self.assertFalse(root.exists())

    def run_measurement(self, *, enabled=True, first_failure=None, scan_mode="diagnostic", unexpected_diagnostics=False,
                        first_scan_change=None, receipt_mode="internal", terminal_origin=False, first_terminal_change=None, pure_control=False, install_control=False,
                        first_startup_failures=None, image_cleanup_failure=None, first_records_change=None,
                        frozen_control=False, frozen_summary=None, frozen_failure=None, first_strict_growth=False,
                        first_scans_change=None, parser_evidence=None, parser_failure=None, bridge_failure=None,
                        live_attribution=False, expected_smoke_safe=None):
        script = self.workflow_script("Measure matched cases with strict heap checks")
        frozen_analysis = frozen_control or first_strict_growth or live_attribution
        with tempfile.TemporaryDirectory(prefix="ax-workflow-") as directory:
            root = pathlib.Path(directory)
            summary_file = root / "summary.json"
            github_output = root / "github-output.txt"
            PROBE.write_json(summary_file, {"identity": {"scan_mode": scan_mode, "receipt_mode": receipt_mode, "terminal_origin": terminal_origin}, "trials": [], "completed": False,
                                           "expected_trials": 1 if frozen_control else 2 if terminal_origin or live_attribution else 20 if enabled else 10})
            if live_attribution:
                value = json.loads(summary_file.read_text())
                value["identity"]["live_attribution"] = True
                PROBE.write_json(summary_file, value)
            if frozen_control:
                value = json.loads(summary_file.read_text())
                value["identity"]["frozen_control"] = True
                PROBE.write_json(summary_file, value)
            if first_strict_growth:
                value = json.loads(summary_file.read_text())
                value["identity"]["frozen_node_selection"] = "first-strict-growth"
                PROBE.write_json(summary_file, value)
            if pure_control:
                value = json.loads(summary_file.read_text())
                value["identity"]["pure_appkit_control"] = True
                PROBE.write_json(summary_file, value)
            if install_control:
                value = json.loads(summary_file.read_text())
                value["identity"]["install_gate_control"] = True
                PROBE.write_json(summary_file, value)
            script = script.replace("pathlib.Path('.build/Temporary/ax-heap-diagnostics')", f"pathlib.Path({str(root)!r})")
            invocations = []
            frozen_invocations = []
            builds = []
            test = self

            class Process:
                pid = 12345

                def __init__(self, command, **kwargs):
                    self.build = "--prepare-external-fixture" in command
                    if self.build:
                        self.first = False
                        builds.append(command)
                        build_mode = "install-gate" if install_control else command[command.index("--empty-control-mode") + 1] if pure_control else "ordinary"
                        prepared = pathlib.Path(command[command.index("--work-directory") + 1])
                        for role, name in EXTERNAL.EXECUTABLES.items():
                            path = prepared / name
                            path.parent.mkdir(parents=True, exist_ok=True)
                            path.write_bytes((build_mode + role).encode() if pure_control else role.encode())
                            path.chmod(0o700)
                        sources = ["QuickFileApp/AXCompatibility.m", "QuickFileApp/AXCompatibility.h",
                                   "Scripts/tests/fixtures/AXCompatibilityNotifications.m", "Scripts/tests/fixtures/AXCompatibilityReader.swift"]
                        PROBE.write_json(prepared / "fixture-build.json", {"schema": 1, "build_mode": "ordinary",
                            "sources": {name: PROBE.hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources},
                            "executables": EXTERNAL.fixture_hashes(prepared)})
                        if pure_control:
                            PROBE.write_json(prepared / "fixture-build.json", AXPureAppKitControlTests.manifest(build_mode, EXTERNAL.fixture_hashes(prepared)))
                        if install_control:
                            test.assertIn("--prepare-install-gate-fixture", command)
                            PROBE.write_json(prepared / "fixture-build.json", AXInstallGateTests.manifest(EXTERNAL.fixture_hashes(prepared)))
                        if first_failure == "prepared-manifest":
                            (prepared / "fixture-build.json").unlink()
                        return
                    test.assertEqual("--external-startup-receipt" in command, receipt_mode == "external-startup")
                    test.assertEqual("--terminal-origin" in command, terminal_origin)
                    test.assertEqual("--live-attribution" in command, live_attribution)
                    setting = command[command.index("--malloc-scribble") + 1] if "--malloc-scribble" in command else None
                    mode = "control" if "--heap-control" in command else "product"
                    if pure_control:
                        test.assertEqual(mode, "control")
                        mode = command[command.index("--empty-control-mode") + 1]
                    if install_control:
                        test.assertEqual(mode, "control")
                        mode = command[command.index("--install-gate") + 1]
                    invocations.append((setting, mode))
                    self.first = len(invocations) == 1
                    test.assertTrue(kwargs["start_new_session"])
                    test.assertEqual("--heap-diagnostics" in command, scan_mode == "diagnostic")
                    if setting:
                        test.assertEqual(kwargs["env"].get("MallocScribble"), "1" if setting == "on" else None)
                    else:
                        test.assertEqual(kwargs["env"].get("MallocScribble"), None if frozen_analysis else "inherited-secret")
                    records = pathlib.Path(command[command.index("--records-directory") + 1])
                    records.mkdir()
                    if frozen_analysis:
                        PROBE.write_json(records / "process-cleanup.json", {
                            "processes_exited": not (self.first and frozen_failure == "host-exit"), "errors": []})
                    if terminal_origin:
                        PROBE.write_json(records / "process-cleanup.json", {"processes_exited": True, "errors": []})
                        # This fake runner explicitly enters offline collection,
                        # except the case proving a still-live host never did.
                        if not self.first or image_cleanup_failure not in ("missing", "not-run"):
                            REPORT.ax_system_images.write_worker_cleanup(records / "terminal-image-worker.json",
                                not (self.first and image_cleanup_failure == "collection"),
                                not (self.first and image_cleanup_failure in ("collection", "collection-artifact")))
                        if self.first and image_cleanup_failure == "not-run":
                            PROBE.write_json(records / "process-cleanup.json", {"processes_exited": False, "errors": []})
                    if self.first and first_failure == "timeout":
                        return
                    expected = "1" if setting == "on" else "unset"
                    receipt = {"requested": setting, "host": expected, "reader": expected}
                    if self.first and first_failure == "receipt":
                        receipt["reader"] = "/private/secret"
                    if receipt_mode == "external-startup":
                        failures = first_startup_failures if self.first and first_failure == "startup-failures" else []
                        if failures is not None:
                            PROBE.write_json(records / "startup-failures.json", failures)
                        hashes = EXTERNAL.fixture_hashes(root / (("install-gate" if install_control else mode if pure_control else "ordinary") + "-fixture"))
                        if self.first and first_failure == "cross-mode-receipt":
                            hashes = EXTERNAL.fixture_hashes(root / "pure-appkit-fixture")
                        startup = {"receipt_mode": receipt_mode, "requested": setting, "executables": hashes,
                                   "binary_reuse_verified": True}
                        for role in hashes:
                            startup[role] = {"malloc_scribble": expected, "path_matches": True,
                                "startup_executable_matches": True, "alive_during_check": True,
                                "executable_sha256": hashes[role]}
                        if install_control:
                            startup["install_gate"] = mode
                            for role in hashes:
                                startup[role]["install_gate"] = mode
                            if self.first and first_failure == "install-env":
                                startup["reader"]["install_gate"] = "secret"
                        if self.first and first_failure == "external-receipt":
                            startup["reader"]["executable_sha256"] = "0" * 64
                        if self.first and first_failure == "external-private":
                            startup["reader"]["private"] = "/private/secret"
                        if not (self.first and first_failure == "external-missing"):
                            PROBE.write_json(records / "external-startup.json", startup)
                    PROBE.write_json(records / "malloc-scribble.json", receipt)
                    capabilities = {"images": {
                        "AppKit": "B6B4BDAD-6428-3E64-8747-275700109B46",
                        "CoreFoundation": "9B672762-7B1F-30BC-96DE-F176B372D66D"}}
                    if pure_control:
                        capabilities.update(empty_control_mode=mode, enabled=mode == "patched", status="enabled" if mode == "patched" else "pure-appkit")
                        if self.first and first_failure == "control-mode":
                            capabilities["empty_control_mode"] = "/private/secret"
                    if install_control:
                        capabilities.update(enabled=mode == "installed", status="enabled" if mode == "installed" else "probe-preflight-only", install_probe=AXInstallGateTests.state(mode))
                        if self.first and first_failure == "install-capability":
                            capabilities["install_probe"]["gate_calls"] = 0
                        initial = AXInstallGateTests.state(mode)
                        if self.first and first_failure == "install-initial":
                            initial["mode"] = "secret"
                        PROBE.write_json(records / "install-gate-initial.json", initial)
                    PROBE.write_json(records / "inputs.json", {"capabilities": capabilities})
                    point = REPORT.heap_diff_summary("Process 123: 0 leaks for 0 total leaked bytes.\n")
                    diagnostic = {"schema": 4, "status": "complete", "symbols": [], "omitted_symbols": 0,
                                  "symbols_status": "complete", "cohorts_status": "complete",
                                  "checkpoints": [point | {"label": label} for label in REPORT.HEAP_LABELS[1:]]}
                    if scan_mode == "diagnostic" and not (self.first and first_failure == "diagnostics"):
                        PROBE.write_json(records / "heap-diagnostics.json", diagnostic)
                    if scan_mode == "live" and unexpected_diagnostics:
                        PROBE.write_json(records / "heap-diagnostics.json", diagnostic | {"private": "secret"})
                    if terminal_origin and not (self.first and first_failure == "terminal-missing"):
                        terminal = AXTerminalSnapshotTests.summary()
                        if self.first and first_failure == "terminal":
                            terminal = REPORT.empty_terminal_snapshot()
                        elif self.first and first_failure == "terminal-private":
                            terminal["private"] = "secret"
                        if self.first and first_terminal_change:
                            first_terminal_change(terminal)
                        PROBE.write_json(records / "terminal-snapshot.json", terminal)
                    labels = [label for label in REPORT.HEAP_LABELS if scan_mode == "diagnostic" or label != "added-10"]
                    if self.first and first_failure == "scans":
                        labels.remove("registered-10")
                    scans = [{"label": label, "exit_code": 0, "leak_nodes": 3, "leak_bytes": 300,
                        "groups": [{"root_type": "NSXPCConnection", "root_instances": 1},
                                   {"root_type": "NSXPCConnection", "root_instances": 2}],
                        "destroyed_notification_stack_present": False,
                        "unclassified_nodes": 0, "host": dict.fromkeys(("buttons", "allocatedButtons", "destroyedButtons",
                        "compensations", "mutableCompensations"), 0)} for label in labels]
                    if install_control:
                        for scan in scans:
                            scan["host"]["install_probe"] = AXInstallGateTests.state(mode)
                        if self.first and first_failure == "install-scan":
                            scans[2]["host"]["install_probe"]["copy_imp"] = "secret"
                    if self.first and first_scan_change:
                        first_scan_change(scans[0])
                    if self.first and first_scans_change:
                        first_scans_change(scans)
                    PROBE.write_json(records / "scans.json", scans)
                    if live_attribution:
                        for label in labels:
                            (records / (label + "-live.stdout.txt")).write_text("Process 123: 3 leaks for 300 total leaked bytes.\n")
                        captures = frozen_summary if self.first and frozen_summary is not None else test.live_summary()
                        PROBE.write_json(records / "live-captures.json", captures["live_captures"])
                    result = {"coverage": "passed"}
                    if terminal_origin and self.first and image_cleanup_failure == "not-run":
                        PROBE.write_json(records / "terminal-snapshot.json", REPORT.empty_terminal_snapshot())
                    if self.first and first_failure == "strict":
                        result.update(coverage="failed", validation_errors=[{"stage": "registered-10", "message": "/private/secret"},
                            {"stage": "notifications", "message": "/private/secret"}])
                    if self.first and first_failure == "classification":
                        result.update(coverage="failed", validation_errors=[{"stage": 123, "message": "/private/secret"}])
                    PROBE.write_json(records / "result.json", result)
                    # Raw records and arbitrary fields must never enter the public artifact.
                    (records / "host.log").write_text("private-raw-host-data")
                    if self.first and first_records_change:
                        first_records_change(records)

                def wait(self, timeout):
                    if self.build and first_failure == "build-timeout" and timeout == 180:
                        raise subprocess.TimeoutExpired("prepare", timeout)
                    if self.build and first_failure == "build":
                        return 1
                    if self.first and first_failure == "timeout" and timeout == 180:
                        raise subprocess.TimeoutExpired("probe", timeout)
                    return 1 if self.first and first_failure == "strict" else 0

            def run_owned(command, log_path, environment, timeout=180):
                if command[1] == "Scripts/Investigations/ax_frozen_nodes.py":
                    test.assertTrue(frozen_analysis)
                    test.assertEqual(timeout, 120)
                    test.assertEqual("--first-strict-growth" in command, first_strict_growth)
                    test.assertEqual("--live-pair" in command, live_attribution)
                    test.assertIn("--bridge-evidence", command)
                    test.assertNotIn("MallocScribble", environment)
                    frozen_invocations.append(invocations[-1])
                    if frozen_control:
                        test.assertEqual(invocations, [(None, "control")])
                    else:
                        test.assertLessEqual(len(invocations), 10)
                        test.assertIn(invocations[-1], (("off", "installed"), ("off", "preflight-only")) if install_control
                                      else (("off", "control"), ("off", "product")) if live_attribution
                                      else ((None, "control"), (None, "product")))
                    saved = json.loads(summary_file.read_text())
                    test.assertEqual(len(saved["trials"]), len(invocations))
                    test.assertEqual(saved["strict_checks_passed"], first_failure is None)
                    test.assertEqual(saved["trials"][-1]["mode"], invocations[-1][1])
                    test.assertNotIn("frozen_node_process_run", saved["trials"][-1])
                    test.assertEqual([scan["label"] for scan in saved["trials"][-1]["scan_totals"]],
                        [label for label in REPORT.HEAP_LABELS if not live_attribution or label != "added-10"])
                    records = pathlib.Path(command[command.index("--records-directory") + 1])
                    test.assertIs(json.loads((records / "process-cleanup.json").read_text())["processes_exited"], True)
                    test.assertTrue(saved["trials"][-1]["process_run"]["cleanup"]["complete"])
                    test.assertEqual(pathlib.Path(command[command.index("--graph-directory") + 1]), records.parent / "fixture/heap")
                    failure = frozen_failure if len(invocations) == 1 else None
                    value = (frozen_summary if len(invocations) == 1 and frozen_summary is not None else
                             test.live_summary() if live_attribution else test.frozen_summary(first_strict_growth=first_strict_growth))
                    if live_attribution and failure == "stdout":
                        (records / "removed-30-live.stdout.txt").write_text("changed original stdout")
                    if live_attribution and failure == "capture":
                        (records / "live-captures.json").write_text("[]")
                    if failure != "missing":
                        PROBE.write_json(records / "frozen-nodes.json", value)
                    from ax_bridge_evidence import initial_summary as bridge_summary, fail_closed as bridge_failed
                    bridges = bridge_summary(value)
                    # These synthetic frozen traces contain no 64B +40 -> 48B path.
                    if value['status'] == 'complete':
                        bridges['status'] = 'not_needed'
                    else:
                        bridge_failed(bridges, 'not_ready')
                    bridge_error = bridge_failure if len(invocations) == 1 else None
                    bridge_path = records / 'bridge-evidence.json'
                    if bridge_error == 'private':
                        bridges['raw'] = '/private/secret'
                    if bridge_error == 'hash':
                        bridges['frozen_sha256'] = '9' * 64
                    if bridge_error in ('partial', 'cleanup'):
                        bridge_failed(bridges, 'tool_budget' if bridge_error == 'partial' else 'process_exit_unconfirmed')
                    if bridge_error == 'cleanup':
                        bridges.update(process_cleanup_confirmed=False, heap_tool_index=0,
                            tools=[{'tool':'heap', 'label':'selected', 'status':'timeout', 'return_code':None, 'cleanup_confirmed':False}])
                    if bridge_error == 'oversized':
                        bridge_path.write_bytes(b' ' * (32768 + 1))
                    elif bridge_error == 'symlink':
                        private_bridge = records / 'private-bridge.json'
                        PROBE.write_json(private_bridge, bridges)
                        bridge_path.symlink_to(private_bridge)
                    elif bridge_error != 'missing':
                        bridge_path.write_text(json.dumps(bridges, separators=(',', ':')) + ('\n ' if bridge_error == 'encoding' else '\n'))
                    evidence = copy.deepcopy(parser_evidence) if len(invocations) == 1 and parser_evidence is not None else {
                        "schema": 1, "status": "complete", "documents": [], "omitted_documents": 0}
                    evidence_path = records / "parser-evidence.json"
                    parser_error = parser_failure if len(invocations) == 1 else None
                    if parser_error == "private":
                        evidence["raw"] = "/private/secret"
                    if parser_error == "hash":
                        evidence["documents"][0]["graph_sha256"] = "9" * 64
                    if parser_error == "index":
                        evidence["documents"][0]["tool_index"] = 127
                    if parser_error == "tool":
                        evidence["documents"][0]["tool_index"] = 0
                    if parser_error == "label":
                        evidence["documents"][0]["label"] = "removed-30"
                    if parser_error == "exists":
                        (root / f"parser-evidence-trial-1-{invocations[-1][1]}.json").write_text("existing")
                    if parser_error == "oversized":
                        evidence_path.write_bytes(b" " * (2 * 1024 * 1024 + 1))
                    elif parser_error == "symlink":
                        target = records / "private-evidence.json"
                        PROBE.write_json(target, evidence)
                        evidence_path.symlink_to(target)
                    elif parser_error != "missing":
                        PROBE.write_json(evidence_path, evidence)
                    complete = failure != "cleanup"
                    return {"return_code": 125 if not complete else 124 if failure == "timeout" else 0,
                            "command_return_code": None if failure else 0,
                            "status": "timeout" if failure == "timeout" else "completed",
                            "cleanup": {"complete": complete, "group_members_exited": complete,
                                "leader_reaped": True, "group_signal": "sent",
                                "group_inspection": "exited" if complete else "running"}}
                process = Process(command, env=environment, start_new_session=True)
                try:
                    code = process.wait(180)
                    status, command_code = "completed", code
                except subprocess.TimeoutExpired:
                    code, command_code, status = 124, None, "timeout"
                complete = not (process.first and first_failure == "cleanup")
                return {"return_code": code if complete or code else 125, "command_return_code": command_code,
                        "status": status, "cleanup": {"complete": complete, "group_members_exited": complete,
                        "leader_reaped": True, "group_signal": "sent", "group_inspection": "exited" if complete else "running"}}

            with mock.patch.dict(os.environ, {"MALLOC_SCRIBBLE_EXPERIMENT": "true" if enabled else "false",
                                              "MallocScribble": "inherited-secret", "GITHUB_OUTPUT": str(github_output)}), \
                    mock.patch.dict(sys.modules, {"verify-ax-compatibility": PROBE}), \
                    mock.patch.object(sys, "path", list(sys.path)), \
                    mock.patch.object(PROCESSES, "run_owned", side_effect=run_owned), \
                    mock.patch.object(REPORT, "SystemSymbols", return_value=AXTerminalSnapshotTests.resolver()), \
                    contextlib.redirect_stdout(io.StringIO()) as output, \
                    self.assertRaises((OSError, RuntimeError) if first_failure == "prepared-manifest" else SystemExit) as result:
                exec(compile(script, "ax-system-baseline.yml", "exec"), {})
            smoke_output = github_output.read_text() if github_output.exists() else ""
            if expected_smoke_safe is not None:
                self.assertEqual(smoke_output, "smoke_safe=true\n" if expected_smoke_safe else "")
            if not live_attribution:
                self.assertEqual(smoke_output, "")
            summary = json.loads(summary_file.read_text())
            if first_failure == "prepared-manifest":
                self.assertEqual(invocations, [])
                self.assertFalse(summary["completed"])
                return invocations, summary
            self.assertEqual(len(builds), 2 if pure_control and first_failure not in ("build", "build-timeout") else int(receipt_mode == "external-startup"))
            if first_failure in ("build", "build-timeout"):
                self.assertEqual(result.exception.code, 1)
                build_code = summary["empty_control_builds"]["patched"]["return_code"] if pure_control else summary["fixture_build_return_code"]
                self.assertEqual(build_code, 124 if first_failure == "build-timeout" else 1)
                self.assertFalse(summary["completed"])
                self.assertEqual(summary["trials"], [])
                self.assertEqual(invocations, [])
                return invocations, summary
            self.assertEqual(result.exception.code, int(first_failure is not None or image_cleanup_failure is not None
                or frozen_failure is not None or parser_failure is not None or bridge_failure is not None))
            if bridge_failure == 'cleanup':
                self.assertFalse(summary['completed'])
                self.assertFalse(summary['bridge_checks_passed'])
                self.assertEqual(len(invocations), 1)
                return invocations, summary
            if frozen_failure == "cleanup":
                self.assertFalse(summary["completed"])
                self.assertFalse(summary["frozen_node_checks_passed"])
                self.assertEqual(frozen_invocations, [invocations[0]])
                return invocations, summary
            if image_cleanup_failure in ("collection", "fresh", "missing", "collection-artifact", "fresh-artifact", "gate-write", "collection-stage"):
                self.assertFalse(summary["completed"])
                self.assertEqual(len(invocations), 1)
                self.assertEqual(len(summary["trials"]), 1)
                self.assertEqual(summary["trials"][0]["terminal_image_worker_cleanup"],
                    "confirmed" if image_cleanup_failure in ("collection-artifact", "fresh-artifact", "gate-write", "collection-stage") else "unconfirmed")
                self.assertNotIn("secret", output.getvalue() + summary_file.read_text())
                return invocations, summary
            if first_failure == "cleanup":
                self.assertFalse(summary["completed"])
                self.assertEqual(len(invocations), 1)
                self.assertEqual(len(summary["trials"]), 1)
                self.assertFalse(summary["trials"][0]["process_run"]["cleanup"]["complete"])
                self.assertEqual(frozen_invocations, [])
                return invocations, summary
            self.assertEqual(summary["strict_checks_passed"], first_failure is None or first_failure.startswith("terminal"))
            self.assertTrue(summary["completed"])
            self.assertEqual(len(summary["trials"]), 1 if frozen_control else 2 if terminal_origin or live_attribution else 20 if enabled else 10)
            if first_strict_growth or live_attribution:
                self.assertEqual(frozen_invocations, invocations[1:] if frozen_failure == "host-exit" else invocations)
            for receipt in summary["trials"]:
                if receipt.get("parser_evidence_available"):
                    from ax_parser_evidence import validate_evidence, encode_evidence
                    record = receipt["parser_evidence"]
                    contents = (root / record["file"]).read_bytes()
                    self.assertEqual(record["sha256"], hashlib.sha256(contents).hexdigest())
                    self.assertEqual(record["bytes"], len(contents))
                    evidence = json.loads(contents)
                    validate_evidence(evidence)
                    self.assertEqual(contents, encode_evidence(evidence))
                    self.assertNotIn("secret", contents.decode())
            for trial_index, receipt in enumerate(summary["trials"]):
                self.assertEqual(receipt["scan_mode"], scan_mode)
                self.assertEqual(receipt["diagnostics_expected"], scan_mode == "diagnostic")
                for scan_index, scan in enumerate(receipt['scan_totals']):
                    if trial_index == 0 and (first_scans_change or first_scan_change and scan_index == 0):
                        continue
                    self.assertEqual(scan, {"label": scan["label"], "leak_nodes": 3, "leak_bytes": 300,
                        "unclassified_nodes": 0, "root_instances": 3, "unexpected_root_groups": 0,
                        "destroyed_notification_stack_present": False, "tool_exit_code": 0,
                        **({"install_probe": AXInstallGateTests.state(receipt["mode"])} if install_control else {})})
                if scan_mode == "live":
                    self.assertFalse(receipt["diagnostics_available"])
                    self.assertNotIn("diagnostics", receipt)
            self.assertNotIn("secret", output.getvalue() + summary_file.read_text())
            self.assertNotIn("private-raw-host-data", output.getvalue() + summary_file.read_text())
            if first_failure == "timeout":
                self.assertEqual(summary["trials"][0]["return_code"], 124)
            if first_failure == "scan-fields":
                self.assertEqual(summary["trials"][0]["scan_totals"], [])
            return invocations, summary

    def test_scan_summary_counts_roots_without_exporting_arbitrary_class_names(self):
        def change(scan):
            scan["groups"].append({"root_type": "/private/secret", "root_instances": 4})
            scan["destroyed_notification_stack_present"] = True
        for mode in ("live", "diagnostic"):
            with self.subTest(mode=mode):
                _, summary = self.run_measurement(scan_mode=mode, first_failure="strict", first_scan_change=change)
                first = summary["trials"][0]["scan_totals"][0]
                self.assertEqual(first["root_instances"], 7)
                self.assertEqual(first["unexpected_root_groups"], 1)
                self.assertIs(first["destroyed_notification_stack_present"], True)
                _, empty = self.run_measurement(scan_mode=mode, first_scan_change=lambda scan:
                    scan.update(groups=[], leak_nodes=0, leak_bytes=0))
                self.assertEqual(empty["trials"][0]["scan_totals"][0]["root_instances"], 0)
                self.assertEqual(empty["trials"][0]["scan_totals"][0]["unexpected_root_groups"], 0)

    def test_malformed_scan_root_fields_fail_closed_and_preserve_later_trials(self):
        mutations = (
            lambda scan: scan.pop("groups"),
            lambda scan: scan.update(groups=None),
            lambda scan: scan.update(groups={}),
            lambda scan: scan.update(groups=[1]),
            lambda scan: scan["groups"][0].pop("root_type"),
            lambda scan: scan["groups"][0].update(root_type=None),
            lambda scan: scan["groups"][0].update(root_type=""),
            lambda scan: scan["groups"][0].pop("root_instances"),
            lambda scan: scan["groups"][0].update(root_instances=True),
            lambda scan: scan["groups"][0].update(root_instances=-1),
            lambda scan: scan["groups"][0].update(root_instances=1_000_000_001),
            lambda scan: scan["groups"][0].update(root_instances=1_000_000_000),
            lambda scan: scan.pop("destroyed_notification_stack_present"),
            lambda scan: scan.update(destroyed_notification_stack_present=1),
            lambda scan: scan.update(destroyed_notification_stack_present="private-secret"),
        )
        for mode, mutation_index in itertools.product(("live", "diagnostic"), range(len(mutations))):
            with self.subTest(mode=mode, mutation=mutation_index):
                self.run_measurement(scan_mode=mode, first_failure="scan-fields", first_scan_change=mutations[mutation_index])

    def test_paired_experiment_alternates_all_four_conditions_and_keeps_failures(self):
        for mode, failure in itertools.product(("live", "diagnostic"), (None, "strict", "receipt", "timeout", "scans")):
            with self.subTest(mode=mode, failure=failure):
                invocations, _ = self.run_measurement(first_failure=failure, scan_mode=mode)
                odd = [("off", "control"), ("off", "product"), ("on", "control"), ("on", "product")]
                self.assertEqual(invocations, odd + list(reversed(odd)) + odd + list(reversed(odd)) + odd)

    def test_diagnostic_requires_allocation_evidence_and_live_never_claims_it(self):
        self.run_measurement(first_failure="diagnostics")
        self.run_measurement(scan_mode="live", unexpected_diagnostics=True)

    def test_original_diagnostics_still_have_ten_trials_without_allocator_override(self):
        self.assertEqual(self.run_measurement(enabled=False)[0],
                         [(None, mode) for pair in range(5) for mode in
                          (("control", "product") if pair % 2 == 0 else ("product", "control"))])


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "requires macOS SDK")
class AXMallocScribbleFixtureTests(unittest.TestCase):
    def test_native_environment_receipts_are_bounded_and_opt_in_without_launching_apps(self):
        temporary_root = ROOT / ".build/Temporary"
        temporary_root.mkdir(parents=True, exist_ok=True)
        parent = pathlib.Path(tempfile.gettempdir()).resolve()
        if not parent.is_relative_to(temporary_root):
            parent = temporary_root
        with tempfile.TemporaryDirectory(prefix="ax-allocator-", dir=parent) as directory:
            work = pathlib.Path(directory)
            common = ["xcrun", "clang", "-O2", "-I", str(ROOT / "QuickFileApp")]
            subprocess.run(common + ["-fno-objc-arc", "-c", str(ROOT / "QuickFileApp/AXCompatibility.m"),
                "-o", str(work / "compatibility.o")], check=True, capture_output=True, timeout=60)
            for instrumented in (False, True):
                flags = ["-DQUICKFILE_AX_MALLOC_RECEIPT"] if instrumented else []
                host, reader = work / "host", work / "reader"
                subprocess.run(common + flags + ["-fobjc-arc", "-framework", "AppKit", "-framework", "ApplicationServices",
                    str(ROOT / "Scripts/tests/fixtures/AXCompatibilityNotifications.m"), str(work / "compatibility.o"),
                    "-o", str(host)], check=True, capture_output=True, timeout=60)
                subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library",
                    "-module-cache-path", str(work / "swift-module-cache"), *flags,
                    str(ROOT / "Scripts/tests/fixtures/AXCompatibilityReader.swift"), "-o", str(reader)],
                    check=True, capture_output=True, timeout=60)
                for value, expected in ((None, "unset"), ("1", "1"), ("0", "other"), ("private-secret", "other")):
                    environment = dict(os.environ)
                    environment.pop("MallocScribble", None)
                    if value is not None:
                        environment["MallocScribble"] = value
                    for arguments in ([str(host), "--capabilities", "--system-baseline"], [str(reader), "--capabilities"]):
                        result = subprocess.run(arguments, env=environment, check=True, capture_output=True, text=True, timeout=15)
                        receipt = json.loads(result.stdout)
                        self.assertNotIn("private-secret", result.stdout)
                        if instrumented:
                            self.assertEqual(receipt["malloc_scribble"], expected)
                        else:
                            self.assertNotIn("malloc_scribble", receipt)


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

    def run_notifications_fixture(self, copy_lifetime=False, require_strict_heap=False):
        temporary_root = ROOT / ".build/Temporary"
        temporary_root.mkdir(parents=True, exist_ok=True)
        parent = pathlib.Path(tempfile.gettempdir()).resolve()
        if not parent.is_relative_to(temporary_root):
            parent = temporary_root
        with tempfile.TemporaryDirectory(prefix="ax-notifications-", dir=parent) as directory:
            work = pathlib.Path(directory)
            records = notification_records(work, copy_lifetime=copy_lifetime)
            arguments = [
                sys.executable, str(ROOT / "Scripts/Investigations/verify-ax-compatibility.py"),
                "--work-directory", str(work / "fixture"), "--records-directory", str(records)
            ]
            if copy_lifetime:
                arguments.append("--copy-lifetime")
            else:
                arguments.append("--settle-startup-baseline")
            if not copy_lifetime and os.environ.get("QUICKFILE_AX_CI_FAILURE_EVIDENCE") == "1":
                arguments.append("--ci-failure-evidence")
            result = subprocess.run(arguments, capture_output=True, text=True, timeout=300)
            kind = "copy-lifetime" if copy_lifetime else "ordinary"
            if result.returncode == 77:
                LIFECYCLE.record(records, kind, result.returncode)
                self.skipTest("AX notification coverage unavailable: " + result.stdout.strip())
            diagnostics = (f"AX {kind} runner exit code: {result.returncode}\n"
                           f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
            self.assertIn(result.returncode, (0,) if require_strict_heap else (0, 1), diagnostics)
            try:
                receipt = json.loads((records / "result.json").read_text())
                LIFECYCLE.evaluate(kind, receipt, result.returncode)
            except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
                problem = ("AX receipt incomplete: result.json missing"
                           if isinstance(error, FileNotFoundError) and error.filename == str(records / "result.json")
                           else f"AX receipt validation failed: {error}")
                raise self.failureException(f"{problem}\n{diagnostics}") from error
            if require_strict_heap:
                self.assertEqual(receipt["coverage"], "passed", diagnostics)
            self.assertEqual(receipt["notifications"], 60)
            self.assertGreaterEqual(receipt["ordinary_compensations"], 30)
            self.assertGreaterEqual(receipt["mutable_compensations"], 30)
            if copy_lifetime:
                self.assertEqual(receipt["mode"], "copy-lifetime")
                self.assertIs(receipt["instrumented"], True)
                self.assertEqual(receipt["copy_lifetime"], AXCompatibilityCopyLifetimeTests.receipt(30)["copyLifetime"])
                hosts = json.loads((records / "copy-lifetime-hosts.json").read_text())
                self.assertEqual([host["sequence"] for host in hosts], list(range(10)))
                for host in hosts:
                    PROBE.validate_copy_lifetime_host(host)
                PROBE.validate_copy_lifetime_host(hosts[-1], 30)
                self.assertFalse((records / "scans.json").exists())
            else:
                PROBE.ax_startup_baseline.validate(receipt["startup_baseline"])
                self.assertEqual(receipt["startup_baseline"]["status"], "observed-stable")
                print(json.dumps({"startup_baseline": receipt["startup_baseline"],
                    "strict_scans": [{key: row[key] for key in ("label", "leak_nodes", "leak_bytes")}
                                     for row in receipt["scans"]]}))
                # Preserve the runner's strict failure rather than rewriting it.
                if receipt["coverage"] == "passed":
                    self.assertEqual(receipt["ax_leak_nodes"], 0)
                else:
                    self.assertIsNone(receipt["ax_leak_nodes"])
            LIFECYCLE.record(records, kind, result.returncode)

    def test_real_destroyed_notifications_cover_both_compensation_branches(self):
        self.run_notifications_fixture()

    def test_real_destroyed_notifications_verify_copy_lifetime(self):
        self.run_notifications_fixture(copy_lifetime=True)

    def test_unrelated_copy_ownership_and_concurrency(self):
        self.run_fixture()

    def test_unknown_system_image_does_not_enable_patch(self):
        self.run_fixture(reject_image=True)
