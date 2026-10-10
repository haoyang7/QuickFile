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
    def frame(image, symbol, offset):
        return {"image": image, "symbol": symbol, "offset": offset}

    @classmethod
    def stack(cls, make_offset=68, route_image="com.apple.LinkServices",
              route_symbol="+[NSXPCConnection(ApplicationService) ln_applicationServiceWithError:]",
              route_offset=84):
        return [cls.frame(route_image, route_symbol, route_offset),
                cls.frame("com.apple.AppIntents", "-[LNProcessInstanceRegistryClient makeXPCConnection]", make_offset),
                cls.frame("com.apple.AppIntents", "__52-[LNProcessInstanceRegistryClient makeXPCConnection]_block_invoke.16", 52)]

    @classmethod
    def scan(cls, *, root_instances=3):
        allocations = [
            {"type": "NSXPCConnection", "allocation_bytes": 128, "count": root_instances,
             "allocation_stack": cls.stack()},
            {"type": "NSMutableDictionary", "allocation_bytes": 64, "count": 2,
             "allocation_stack": cls.stack(route_offset=148)},
            {"type": "NSXPCInterface", "allocation_bytes": 48, "count": 1,
             "allocation_stack": cls.stack(240, "com.apple.LinkServices", "LNDaemonApplicationXPCInterface", 16)},
            {"type": "OS_dispatch_queue_serial", "allocation_bytes": 80, "count": 1,
             "allocation_stack": cls.stack(204, "libdispatch.dylib", "_dispatch_lane_create_with_target", 24)},
            {"type": "__NSMallocBlock__", "allocation_bytes": 32, "count": 1,
             "allocation_stack": cls.stack(364, "com.apple.Foundation", "-[NSXPCConnection setInterruptionHandler:]", 20)},
        ]
        nodes = sum(item["count"] for item in allocations)
        byte_count = sum(item["count"] * item["allocation_bytes"] for item in allocations)
        return {"leak_nodes": nodes, "leak_bytes": byte_count,
                "destroyed_notification_stack_present": False, "unclassified_nodes": 0,
                "groups": [{"root_kind": "CYCLE", "root_type": "NSXPCConnection",
                            "root_instances": root_instances, "tree_nodes": nodes,
                            "allocation_stack": cls.stack()}], "allocations": allocations}

    def assert_classified(self, entry):
        classification = PROBE.validate_product_scan(entry)
        self.assertEqual(classification, {"system_leak_nodes": entry["leak_nodes"],
                                          "system_leak_bytes": entry["leak_bytes"],
                                          "unattributed_leak_nodes": 0})

    def test_empty_heap_and_complete_known_system_routes_are_classified(self):
        self.assert_classified({"leak_nodes": 0, "leak_bytes": 0, "groups": [], "allocations": [],
                                "destroyed_notification_stack_present": False, "unclassified_nodes": 0})
        self.assert_classified(self.scan())

    def test_known_system_quantity_changes_need_no_startup_threshold(self):
        for roots in (1, 3, 8):
            with self.subTest(roots=roots):
                self.assert_classified(self.scan(root_instances=roots))

    def test_reversed_stack_order_preserves_the_known_route(self):
        entry = self.scan()
        entry["groups"][0]["allocation_stack"].reverse()
        for allocation in entry["allocations"]:
            allocation["allocation_stack"].reverse()
        self.assert_classified(entry)

    def test_target_ax_and_unclassified_or_unexpected_roots_fail(self):
        for field, value in (("destroyed_notification_stack_present", True), ("unclassified_nodes", 1)):
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                PROBE.validate_product_scan(self.scan() | {field: value})
        for field, value in (("root_type", "__NSArrayM"), ("root_kind", "LEAK")):
            entry = self.scan()
            entry["groups"][0][field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                PROBE.validate_product_scan(entry)

    def test_unknown_child_fails_even_when_heap_totals_and_xpc_root_are_unchanged(self):
        entry = self.scan()
        entry["allocations"][-1]["allocation_stack"] = [self.frame("QuickFile", "-[UnexpectedOwner allocate]", 8)]
        with self.assertRaises(RuntimeError):
            PROBE.validate_product_scan(entry)

    def test_other_xpc_connection_cannot_borrow_a_known_root_class(self):
        entry = self.scan()
        entry["groups"][0]["allocation_stack"] = [self.frame("com.apple.Foundation", "-[NSXPCConnection initWithServiceName:]", 8)]
        with self.assertRaises(RuntimeError):
            PROBE.validate_product_scan(entry)

    def test_root_cannot_borrow_a_route_allowed_only_for_descendants(self):
        for allocation in self.scan()["allocations"][1:]:
            entry = self.scan()
            entry["groups"][0]["allocation_stack"] = allocation["allocation_stack"]
            with self.subTest(route=allocation["type"]), self.assertRaises(RuntimeError):
                PROBE.validate_product_scan(entry)

    def test_missing_root_or_child_allocation_stacks_fail(self):
        for location in ("groups", "allocations"):
            for missing in (False, True):
                entry = self.scan()
                if missing:
                    del entry[location][0]["allocation_stack"]
                else:
                    entry[location][0]["allocation_stack"] = []
                with self.subTest(location=location, missing=missing), self.assertRaises(RuntimeError):
                    PROBE.validate_product_scan(entry)

    def test_all_nodes_and_bytes_must_close_against_complete_allocations(self):
        changes = [("leak_nodes", 1), ("leak_bytes", 1)]
        for field, change in changes:
            entry = self.scan()
            entry[field] += change
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                PROBE.validate_product_scan(entry)
        for location, field in (("groups", "tree_nodes"), ("allocations", "count"),
                                ("allocations", "allocation_bytes")):
            entry = self.scan()
            entry[location][0][field] += 1
            with self.subTest(location=location, field=field), self.assertRaises(RuntimeError):
                PROBE.validate_product_scan(entry)

    def test_ax_stack_cannot_hide_under_a_system_root_without_the_report_flag(self):
        entry = self.scan()
        entry["allocations"][-1]["allocation_stack"].append(self.frame(
            "com.apple.AppKit", "_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification", 128))
        with self.assertRaises(RuntimeError):
            PROBE.validate_product_scan(entry)

    def test_route_requires_adjacent_frames_and_exact_known_image_and_offsets(self):
        for mutation in ("separated-route", "wrong-image", "wrong-make-offset", "wrong-route-offset", "wrong-block-offset"):
            entry = self.scan()
            stack = entry["allocations"][0]["allocation_stack"]
            if mutation == "separated-route":
                stack.insert(1, self.frame("QuickFile", "-[UnexpectedOwner forward]", 8))
            elif mutation == "wrong-image":
                stack[1]["image"] = "QuickFile"
            elif mutation == "wrong-make-offset":
                stack[1]["offset"] = 72
            elif mutation == "wrong-route-offset":
                stack[0]["offset"] = 88
            else:
                stack[2]["offset"] = 56
            with self.subTest(mutation=mutation), self.assertRaises(RuntimeError):
                PROBE.validate_product_scan(entry)

    def test_real_leaks_cycle_label_is_parsed_as_its_class(self):
        text = "STACK OF 3 INSTANCES OF 'ROOT CYCLE: NSXPCConnection':\n  288 (18.4K) ROOT CYCLE: <NSXPCConnection>\n"
        groups = PROBE.leak_groups(text)
        self.assertEqual(groups[0]["root_type"], "NSXPCConnection")
        self.assertEqual(groups[0]["root_kind"], "CYCLE")
        self.assertEqual(groups[0]["root_instances"], 3)
        self.assertEqual(groups[0]["tree_nodes"], 288)

    def test_allocation_symbols_survive_without_addresses_or_binary_paths(self):
        report = ("STACK OF 1 INSTANCE OF 'ROOT CYCLE: NSXPCConnection':\n"
                  "2   AppKit  0x123456 -[Example start] + 24\n"
                  "1   Foundation  0xabcdef -[NSXPCConnection initWithServiceName:] + 8\n"
                  "====\n  96 (6.12K) ROOT CYCLE: NSXPCConnection\n"
                  "Binary Images:\n/Users/private/test.app\n")
        groups = PROBE.leak_groups(report)
        self.assertEqual(groups[0]["allocation_stack"], [
            {"image": "AppKit", "symbol": "-[Example start]", "offset": 24},
            {"image": "Foundation", "symbol": "-[NSXPCConnection initWithServiceName:]", "offset": 8}])
        self.assertNotIn("0x", json.dumps(groups))
        self.assertNotIn("/Users/", json.dumps(groups))

    def test_allocation_provenance_counts_children_by_size_and_stack(self):
        report = ""
        for address, size in (("abc", 32), ("def", 32), ("123", 48)):
            report += (f"Leak: 0x{address}  size={size}  zone: DefaultMallocZone_0x111   NSArray\n"
                       "\tCall stack:\n0   Foundation  0xabc -[Example initialize] + 16\n")
        groups = PROBE.allocation_groups(report + "Binary Images:\n/private/source\n")
        self.assertEqual([(group["count"], group["allocation_bytes"]) for group in groups], [(2, 32), (1, 48)])
        self.assertEqual(groups[0]["type"], "NSArray")
        self.assertNotIn("0x", json.dumps(groups))
        with self.assertRaisesRegex(RuntimeError, "no allocation stack"):
            PROBE.allocation_groups("Leak: 0xabc size=32 zone: DefaultMallocZone_0x111 NSArray\n")


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
                        system_baseline=False, insufficient_compensation=False,
                        system_growth=False, scan_fault=None):
        temporary_root = ROOT / ".build/Temporary"
        temporary_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="ax-protocol-", dir=temporary_root) as directory:
            temporary = pathlib.Path(directory).resolve()
            work = temporary / "fixture"
            records = temporary / "records"
            state = work / "state"
            host_state = {"pid": 1234, "sequence": 0, "buttons": 0, "allocatedButtons": 0,
                          "destroyedButtons": 0, "compensations": 0, "mutableCompensations": 0}
            notifications = {"notifications": 60, "all_notifications": 60, "unmatched_notifications": 0,
                             "tracked_buttons": 30, "target_notification_counts": [[1, 1] for _ in range(30)]}
            if invalid_notifications == "missing-count":
                del notifications["notifications"]
            elif invalid_notifications:
                notifications["target_notification_counts"][0] = [0, 2]
            scan_labels = (["baseline", "removed-10", "removed-30", "observer-exited"] if system_baseline else
                           ["baseline", "registered-10", "removed-10", "removed-20", "removed-30", "observer-exited"])
            scanned = []
            captures = []
            allocation_scans = []
            processes = []

            def scan_entry(label):
                roots = 3 + scan_labels.index(label) if system_growth else 3
                entry = AXCompatibilityHeapValidationTests.scan(root_instances=roots)
                if label == failed_scan:
                    # Replace provenance without changing root, node or byte
                    # totals: a startup threshold cannot detect this child.
                    entry["allocations"][-1]["allocation_stack"] = [
                        AXCompatibilityHeapValidationTests.frame("QuickFile", "-[UnexpectedOwner allocate]", 8)]
                return entry

            def stack_report(stack):
                return "".join(f"{index}   {frame['image']}  0xabc {frame['symbol']} + {frame['offset']}\n"
                               for index, frame in enumerate(stack))

            class FixtureProcess:
                returncode = None

                def __init__(self, command, **_kwargs):
                    self.is_reader = pathlib.Path(command[0]).name == "ax-reader"
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
                output = ""
                if "--capabilities" in command:
                    capability = {"trusted": True} if pathlib.Path(command[0]).name == "ax-reader" else {
                        "enabled": not system_baseline, "status": "system-baseline" if system_baseline else "enabled",
                        "images": {"AppKit": "synthetic", "CoreFoundation": "synthetic"}}
                    output = json.dumps(capability)
                elif command[0] == "leaks":
                    graph_output = next((str(part).split("=", 1)[1] for part in command
                                         if str(part).startswith("--outputGraph=")), None)
                    if graph_output:
                        graph = pathlib.Path(graph_output)
                        self.assertEqual(command[-1], "1234")
                        self.assertEqual(graph.stem, scan_labels[len(scanned)])
                        if scan_fault != "missing-graph":
                            graph.write_text("synthetic complete heap snapshot\n")
                        captures.append(graph)
                        return subprocess.CompletedProcess(command, 1 if scan_fault == "capture-exit" else 0,
                                                           "Snapshot captured\n", "")
                    if "--groupByType" in command:
                        label = scan_labels[len(scanned)]
                        scanned.append(label)
                        if not system_baseline:
                            self.assertEqual(pathlib.Path(command[-1]), work / f"{label}.memgraph")
                            self.assertTrue(pathlib.Path(command[-1]).is_file())
                        else:
                            self.assertEqual(command[-1], "1234")
                    else:
                        self.assertIn("--list", command)
                        label = pathlib.Path(command[-1]).stem
                        self.assertEqual(label, scanned[-1])
                        self.assertEqual(pathlib.Path(command[-1]), captures[-1])
                        self.assertFalse(any(str(part).startswith("--diffFrom=") for part in command))
                        allocation_scans.append(label)
                    entry = scan_entry(label)
                    nodes, size = entry["leak_nodes"], entry["leak_bytes"]
                    if "--list" in command:
                        nodes += 1 if scan_fault == "list-count" else 0
                        size += 1 if scan_fault == "list-bytes" else 0
                    output = f"Process 1234: {nodes} leaks for {size} total leaked bytes.\n"
                    if "--groupByType" in command:
                        root = entry["groups"][0]
                        output += (f"STACK OF {root['root_instances']} INSTANCES OF 'ROOT CYCLE: NSXPCConnection':\n"
                                   + stack_report(root["allocation_stack"])
                                   + f"====\n  {nodes} ({size} bytes) ROOT CYCLE: NSXPCConnection\n")
                    else:
                        address = 0x1000
                        for allocation in entry["allocations"]:
                            for _ in range(allocation["count"]):
                                output += (f"Leak: 0x{address:x} size={allocation['allocation_bytes']} "
                                           f"zone: DefaultMallocZone_0x111 {allocation['type']}\n"
                                           "\tCall stack:\n" + stack_report(allocation["allocation_stack"]))
                                address += 0x100
                exit_code = 1 if command[0] == "leaks" else 0
                if command[0] == "leaks" and "--list" in command and scan_fault == "list-exit":
                    exit_code = 2
                return subprocess.CompletedProcess(command, exit_code, output, "")

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
            with mock.patch.object(sys, "argv", arguments), mock.patch.object(PROBE, "ROOT", ProbeRoot()), \
                    mock.patch.object(PROBE.subprocess, "run", side_effect=run), \
                    mock.patch.object(PROBE.subprocess, "Popen", side_effect=FixtureProcess), \
                    mock.patch.object(PROBE, "wait_json", side_effect=wait_json), \
                    mock.patch.object(PROBE.time, "sleep"), \
                    mock.patch.object(PROBE.time, "monotonic", side_effect=itertools.count(step=0.25)), \
                    contextlib.redirect_stdout(io.StringIO()):
                exit_code = PROBE.main()
            summary = json.loads((records / "result.json").read_text())
            self.assertEqual(scanned, scan_labels)
            self.assertEqual([graph.stem for graph in captures], [] if system_baseline else scan_labels)
            self.assertEqual(allocation_scans, [] if system_baseline else scan_labels)
            self.assertEqual(json.loads((records / "notifications.json").read_text()), notifications)
            self.assertTrue((state / "stop-reader").exists())
            self.assertTrue((state / "quit").exists())
            self.assertTrue(all(process.returncode == 0 for process in processes))
            self.assertEqual(summary["scans"][0]["label"], "baseline")
            scans = json.loads((records / "scans.json").read_text())
            self.assertEqual(scans[0]["host"]["allocatedButtons"], 0)
            self.assertEqual(scans[-1]["host"]["destroyedButtons"], 30)
            if not system_baseline:
                self.assertEqual(scans[1]["host"]["allocatedButtons"], 10)
                self.assertEqual(scans[1]["host"]["destroyedButtons"], 0)
                for scan in scans:
                    self.assertEqual(scan["allocations"], scan_entry(scan["label"])["allocations"])
                    if scan["label"] != failed_scan:
                        self.assertEqual(scan["system_leak_nodes"], scan["leak_nodes"])
                        self.assertEqual(scan["system_leak_bytes"], scan["leak_bytes"])
                        self.assertEqual(scan["unattributed_leak_nodes"], 0)
                    else:
                        self.assertNotIn("system_leak_nodes", scan)
                        self.assertNotIn("system_leak_bytes", scan)
                        self.assertNotIn("unattributed_leak_nodes", scan)
            if exit_code:
                self.assertEqual(json.loads((records / "validation-errors.json").read_text()), summary["validation_errors"])
            return exit_code, summary

    def test_stable_heap_completes_every_lifecycle_checkpoint(self):
        exit_code, summary = self.exercise_runner()
        self.assertEqual(exit_code, 0)
        self.assertEqual(summary["coverage"], "passed")
        self.assertEqual(summary["ax_leak_nodes"], 0)
        self.assertNotIn("validation_errors", summary)

    def test_known_system_growth_completes_every_checkpoint(self):
        exit_code, summary = self.exercise_runner(system_growth=True)
        self.assertEqual(exit_code, 0)
        self.assertEqual(summary["coverage"], "passed")
        self.assertGreater(summary["leak_nodes"], summary["baseline_leak_nodes"])
        self.assertGreater(summary["leak_bytes"], summary["baseline_leak_bytes"])

    def test_snapshot_requires_successful_capture_and_a_graph_file(self):
        for fault in ("capture-exit", "missing-graph"):
            with self.subTest(fault=fault), self.assertRaisesRegex(RuntimeError, "snapshot capture"):
                self.exercise_runner(scan_fault=fault)

    def test_raw_allocation_list_requires_matching_node_and_byte_accounting(self):
        for fault in ("list-count", "list-bytes", "list-exit"):
            with self.subTest(fault=fault), self.assertRaisesRegex(RuntimeError, "Allocation provenance"):
                self.exercise_runner(scan_fault=fault)

    def test_unknown_same_root_child_fails_even_after_provenance_recovers(self):
        for label in ("baseline", "registered-10", "removed-10", "removed-20", "removed-30", "observer-exited"):
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
        exit_code, summary = self.exercise_runner(system_growth=True, system_baseline=True)
        self.assertEqual(exit_code, 0)
        self.assertEqual(summary["coverage"], "measured")
        self.assertFalse(summary["product_compensation_enabled"])
        self.assertGreater(summary["scans"][-1]["leak_nodes"], summary["scans"][0]["leak_nodes"])

    def test_insufficient_compensation_preserves_evidence_and_fails(self):
        exit_code, summary = self.exercise_runner(insufficient_compensation=True)
        self.assertEqual(exit_code, 1)
        self.assertEqual(summary["coverage"], "failed")
        self.assertEqual(summary["ordinary_compensations"], 29)
        self.assertEqual([error["stage"] for error in summary["validation_errors"]], ["compensation-branches"])


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "requires macOS SDK")
class AXCompatibilityCopyTests(unittest.TestCase):
    def run_fixture(self, reject_image=False, disable_environment=False, disable_argument=False):
        temporary_root = ROOT / ".build/Temporary"
        temporary_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="ax-copy-", dir=temporary_root) as directory:
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
            self.assertEqual(receipt["ordinary_compensations"], 30)
            self.assertEqual(receipt["mutable_compensations"], 30)
            self.assertEqual(receipt["notification_receipt"]["target_notification_counts"], [[1, 1] for _ in range(30)])
            self.assertEqual(receipt["ax_leak_nodes"], 0)
            for scan in receipt["scans"]:
                self.assertEqual(scan["system_leak_nodes"], scan["leak_nodes"])
                self.assertEqual(scan["system_leak_bytes"], scan["leak_bytes"])
                self.assertEqual(scan["unattributed_leak_nodes"], 0)

    def test_unrelated_copy_ownership_and_concurrency(self):
        self.run_fixture()

    def test_unknown_system_image_does_not_enable_patch(self):
        self.run_fixture(reject_image=True)
