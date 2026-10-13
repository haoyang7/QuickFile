"""Synthetic campaign/projection evidence; no native AX sampling or wall sleeps."""
import copy
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
INVESTIGATIONS = ROOT / "Scripts/Investigations"
SPEC = importlib.util.spec_from_file_location("ax_reader_exit_campaign_target", INVESTIGATIONS / "ax_reader_exit_campaign.py")
C = importlib.util.module_from_spec(SPEC)
with mock.patch.object(sys, "path", [str(INVESTIGATIONS), *sys.path]): SPEC.loader.exec_module(C)
TEMPORARY = ROOT / ".build/Temporary/ax-reader-exit-campaign-unit"


def process(code=0, complete=True):
    return {"return_code": code, "command_return_code": code, "status": "completed", "cleanup": {
        "group_signal": "sent", "group_members_exited": complete, "group_inspection": "exited" if complete else "running",
        "leader_reaped": True, "complete": complete}}


def identity():
    return {"checkout_sha": "a" * 40, "macos": "26.0.1", "os_build": "25A354", "architecture": "arm64",
        "xcode": "26.3", "scan_mode": "reader-exit", "history_mode": "current-stacks"}


def manifest():
    return {"schema": 1, "build_mode": "ordinary", "sources": {
        name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in C.fixture_sources()},
        "executables": {"host": "b" * 64, "reader": "c" * 64}}


def cleanup(complete=True):
    row = {"started": True, "exited": complete, "terminate_sent": False, "kill_sent": False,
        "return_code": 0 if complete else None, "errors": []}
    return {"reader": dict(row), "host": dict(row), "errors": [] if complete else ["reader"], "processes_exited": complete}


def report(nodes=2, kind="NSXPCConnection", full=True):
    total = f"Process 123: {nodes} leaks for {nodes * 48} total leaked bytes.\n" if full else f"{nodes} leaks for {nodes * 48} total leaked bytes\n"
    frame = "0 synthetic-image 0x1234 synthetic_function + 0\n====\n" if full else ""
    return total + f"STACK OF {nodes} INSTANCES OF 'ROOT LEAK: {kind}':\n" + frame + f" {nodes} ({nodes * 48} bytes) ROOT LEAK: <{kind}>\n"


def reader(warm=False):
    return dict.fromkeys((*C.READER_KEYS, *( ("buttons", "registrations") if warm else ())), 0) | {"target_notification_counts": []}


def external(expected):
    return {"receipt_mode": "external-startup", "requested": "off", "executables": expected, "binary_reuse_verified": True,
        **{role: {"malloc_scribble": "unset", "path_matches": True, "startup_executable_matches": True,
            "alive_during_check": True, "executable_sha256": expected[role]} for role in ("host", "reader")}}


def save(path, value): path.write_bytes(C.canonical(value))


def ordinary_composition(scale):
    # Synthetic shape matching ordinary NSXPC reports: 288/384 total nodes,
    # thirteen types and twenty-six bounded aggregate-size entries.
    weights = {"CFDictionary": 1, "CFDictionary (Key Storage)": 1, "CFDictionary (Value Storage)": 1,
        "NSArray": 30, "NSSet": 30, "NSXPCConnection": 1, "NSXPCInterface": 1, "__NSMallocBlock__": 2,
        "dispatch_group_t": 1, "dispatch_mach_t": 1, "dispatch_queue_t (serial)": 1, "unknown": 25, "xpc_connection_t": 1}
    counts = {kind: weight * scale for kind, weight in weights.items()}
    unresolved = []
    for kind, count in sorted(counts.items()):
        for number in (count // 2, count - count // 2):
            unresolved.append({"type": kind, "count": number, "bytes_min": number * 48, "bytes_max": number * 48,
                "reason": "multiple_instances" if number > 1 else "rounded_subtree"})
    nodes = sum(counts.values())
    value = {"schema": 3, "status": "partial", "counts_status": "complete", "size_bounds": "combined-self-bytes",
        "failure_stage": None, "failure_fragment": None, "total_nodes": nodes, "total_bytes": nodes * 48,
        "type_counts": [{"type": kind, "count": count} for kind, count in sorted(counts.items())],
        "exact_size_histogram": [], "size_unknown_nodes": nodes, "unresolved_sizes": unresolved,
        "unknown_type_nodes": counts["unknown"], "omitted_nodes": 0, "reasons": ["unknown_type", "size_unresolved"]}
    C.composition.validate_grouped_composition(value)
    return value


def dense_composition():
    exact = [{"type": "NSXPCConnection", "size": size, "count": 5} for size in range(1, 31)]
    unresolved = [{"type": "NSXPCConnection", "count": 3, "bytes_min": 144, "bytes_max": 144,
        "reason": "multiple_instances"} for _ in range(49)]
    unresolved[-1].update(count=90, bytes_min=4320, bytes_max=4320)
    nodes = sum(row["count"] for row in exact + unresolved)
    size = sum(row["count"] * row["size"] for row in exact) + sum(row["bytes_min"] for row in unresolved)
    value = {"schema": 3, "status": "partial", "counts_status": "complete", "size_bounds": "combined-self-bytes",
        "failure_stage": None, "failure_fragment": None, "total_nodes": nodes, "total_bytes": size,
        "type_counts": [{"type": "NSXPCConnection", "count": nodes}], "exact_size_histogram": exact,
        "size_unknown_nodes": sum(row["count"] for row in unresolved), "unresolved_sizes": unresolved,
        "unknown_type_nodes": 0, "omitted_nodes": 0, "reasons": ["size_unresolved"]}
    C.composition.validate_grouped_composition(value)
    return value


def scaled_measurement(measurement, profile):
    for index, row in enumerate(measurement["scans"]):
        comp = ordinary_composition(4 if index % 2 == 0 else 3) if profile == "ordinary" else dense_composition()
        row["composition"] = comp
        result = row["result"]
        result.update(leak_nodes=comp["total_nodes"], leak_bytes=comp["total_bytes"])
        # Many distinct reported groups exercise optional-composition fallback.
        tree_sizes = [*range(1, 20), comp["total_nodes"] - sum(range(1, 20))] if profile == "dense" else [comp["total_nodes"]]
        result["groups"] = sorted([{"root_kind": "leak", "root_type": "NSXPCConnection", "root_instances": 1,
            "tree_nodes": nodes, "groups": 1} for nodes in tree_sizes],
            key=lambda group: C.canonical([group[key] for key in ("root_kind", "root_type", "root_instances", "tree_nodes")]))
    for row in measurement["scans"]:
        row["baseline_delta"] = C.composition.composition_delta(measurement["scans"][0]["composition"], row["composition"])
    return measurement


def raw_fixture(records, arm="keep", failed=False, clean=True, full=True, kind="NSXPCConnection", partial=False):
    records.mkdir(parents=True, exist_ok=True)
    expected = manifest()["executables"]
    target = C.ARMS[arm]
    raw = {"schema": 1, "arm": arm, "policy": C.policy(arm), "status": "failed" if partial else "complete",
        "reason": "timing_mismatch" if partial else None, "executables": expected, "external_startup": external(expected),
        "environments": copy.deepcopy(C.ENVIRONMENT), "clock_markers": {"origin_monotonic": 100.0,
            "host_start": -2.0, "host_ready": -1.0, "reader_start": -0.5, "warm": 0},
        "exit_timing": {"target_offset_seconds": target, "stop_requested": 111 if target is None else target + .01,
            "wait_returned": 111.1 if target is None else target + .1,
            "notification_received": 111.2 if target is None else target + .2, "return_code": 0,
            "phase": "cleanup" if target is None else "scheduled"}, "scans": [], "warm_receipt": reader(True),
        "completed_receipt": reader(), "strict_verdict": {"status": "failed" if failed else "passed",
            "failed_labels": list(C.LABELS[1:]) if failed else []}, "cleanup": cleanup(clean)}
    for index, (label, offset) in enumerate(C.SCHEDULE):
        text = report(3 if index and failed else 2, kind, full)
        groups = C.leak_groups(text)
        alive = target is None or offset < target
        stage = {"start": offset + .01, "end": offset + .05, "reader_alive_before": alive, "reader_alive_after": alive}
        scan = {"start": offset + .06, "end": offset + .2, "reader_alive_before": alive, "reader_alive_after": alive}
        row = {"label": label, "target_offset_seconds": offset, "host": dict.fromkeys(C.HOST_KEYS, 0),
            "checkpoint": stage, "scan": scan, "exit_code": 1, "leak_nodes": 3 if index and failed else 2,
            "leak_bytes": (3 if index and failed else 2) * 48, "groups": groups,
            "unclassified_nodes": (3 if index and failed else 2) - sum(group["tree_nodes"] or 0 for group in groups),
            "destroyed_notification_stack_present": False, "stdout_sha256": hashlib.sha256(text.encode()).hexdigest()}
        (records / (label + "-original.stdout.txt")).write_text(text)
        raw["scans"].append(row)
    if kind != "NSXPCConnection": raw["strict_verdict"] = {"status": "failed", "failed_labels": list(C.LABELS)}
    if partial:
        raw["scans"] = raw["scans"][:2]
        raw["strict_verdict"]["failed_labels"] = [label for label in raw["strict_verdict"]["failed_labels"] if label in C.LABELS[:2]]
        raw["strict_verdict"]["status"] = "failed" if raw["strict_verdict"]["failed_labels"] else "passed"
    save(records / "trial.json", raw)
    save(records / "external-startup.json", raw["external_startup"])
    save(records / "inputs.json", {"sources": manifest()["sources"], "capabilities": {}})
    save(records / "process-cleanup.json", raw["cleanup"])
    return raw


class TemporaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): TEMPORARY.mkdir(parents=True, exist_ok=True)
    @classmethod
    def tearDownClass(cls): TEMPORARY.rmdir()
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=TEMPORARY)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.records = self.root / "records"
    def project(self, arm="keep", **kwargs):
        raw_fixture(self.records, arm, **kwargs)
        return C.project_trial(self.records, process(1 if kwargs.get("failed") else 0), manifest()["executables"], arm, manifest()["sources"])


class ProjectionTests(TemporaryTests):
    def test_three_arms_timing_liveness_and_signed_startup_clock(self):
        for arm in C.ARMS:
            with self.subTest(arm=arm):
                projected = self.project(arm)
                self.assertTrue(projected["timing_valid"])
                self.assertEqual(projected["clock_markers"]["host_start_ms"], -2000)
                self.assertNotIn("origin_monotonic", projected["clock_markers"])
                self.assertEqual(projected["exit_timing"]["phase"], "cleanup" if arm == "keep" else "scheduled")

    def test_growth_strict_roots_and_composition_unavailable_survive(self):
        projected = self.project(failed=True, full=False)
        self.assertEqual(projected["strict_verdict"], {"status": "failed", "failed_labels": list(C.LABELS[1:])})
        self.assertEqual(C.root_count(projected["scans"][0]["result"]), 2)
        self.assertEqual(C.root_count(projected["scans"][1]["result"]), 3)
        self.assertEqual(projected["scans"][0]["composition"]["status"], "unavailable")
        self.assertEqual(projected["scans"][1]["baseline_delta"]["status"], "unavailable")
        C.validate_measurement(projected, manifest()["executables"], "keep")

    def test_unknown_type_is_allowlisted_and_preserves_strict_failed(self):
        projected = self.project(kind="PrivateClassName")
        self.assertEqual(projected["strict_verdict"]["status"], "failed")
        self.assertEqual(projected["scans"][0]["result"]["groups"][0]["root_type"], "unknown")
        self.assertEqual(projected["scans"][0]["composition"]["unknown_type_nodes"], 2)
        self.assertEqual(projected["scans"][0]["composition"]["counts_status"], "complete")
        self.assertNotIn("PrivateClassName", C.canonical(projected).decode())

    def test_type_delta_reports_net_counts_with_unknown_generation(self):
        projected = self.project(failed=True)
        delta = projected["scans"][1]["baseline_delta"]
        self.assertEqual(delta["status"], "complete")
        self.assertEqual(delta["generation"], "unknown")
        self.assertEqual(delta["net_nodes"], 1)
        self.assertEqual(delta["changes"], [{"type": "NSXPCConnection", "count_delta": 1}])
        self.assertNotIn("0x1234", C.canonical(projected).decode())

    def test_partial_prefix_preserves_observed_growth(self):
        projected = self.project(failed=True, partial=True)
        self.assertEqual(projected["status"], "failed")
        self.assertEqual(projected["strict_verdict"], {"status": "failed", "failed_labels": ["t20"]})
        self.assertFalse(projected["timing_valid"])

    def test_bindings_independent_of_supplied_json(self):
        raw = raw_fixture(self.records)
        mutations = [lambda r: r["scans"][0].update(stdout_sha256="a" * 64),
            lambda r: r["scans"][0].update(leak_bytes=97),
            lambda r: r["scans"][0]["groups"][0].update(root_instances=55),
            lambda r: r.update(executables={"host": "a" * 64, "reader": "c" * 64})]
        for mutation in mutations:
            corrupted = copy.deepcopy(raw); mutation(corrupted); save(self.records / "trial.json", corrupted)
            with self.assertRaises((ValueError, RuntimeError)):
                C.project_trial(self.records, process(), manifest()["executables"], "keep", manifest()["sources"])
        save(self.records / "trial.json", raw)
        save(self.records / "inputs.json", {"sources": dict.fromkeys(C.fixture_sources(), "a" * 64)})
        with self.assertRaises(ValueError): C.project_trial(self.records, process(), manifest()["executables"], "keep", manifest()["sources"])

    def test_illegal_public_fields_floats_addresses_strict_math_rejected(self):
        projected = self.project(failed=True)
        mutations = [lambda r: r.update(extra="0x123"), lambda r: r["clock_markers"].update(warm_ms=0.0),
            lambda r: r["scans"][0]["result"]["groups"][0].update(root_type="0x123"),
            lambda r: r["strict_verdict"].update(status="passed", failed_labels=[]),
            lambda r: r["scans"][0]["result"].update(leak_nodes=999),
            lambda r: r["exit_timing"].update(notification_received_ms=1),
            lambda r: r["scans"][0]["scan"].update(end_ms=1),
            lambda r: r["scans"][0]["baseline_delta"].update(net_nodes=1)]
        for mutation in mutations:
            corrupted = copy.deepcopy(projected); mutation(corrupted)
            with self.assertRaises(ValueError): C.validate_measurement(corrupted, manifest()["executables"], "keep")

    def test_complete_rejects_late_or_dead_reader_or_wrong_exit_phase(self):
        projected = self.project("early")
        mutations = [lambda r: r["exit_timing"].update(phase="cleanup"),
            lambda r: r["exit_timing"].update(wait_returned_ms=34900, notification_received_ms=35000),
            lambda r: r["scans"][0]["scan"].update(reader_alive_after=False),
            lambda r: r["scans"][2]["scan"].update(reader_alive_before=True),
            lambda r: r["scans"][1]["checkpoint"].update(start_ms=24000, end_ms=24050),
            lambda r: r["warm_activity"].update(registrations=1)]
        for mutation in mutations:
            corrupted = copy.deepcopy(projected); mutation(corrupted)
            corrupted["timing_valid"] = C.timing_valid(corrupted, "early")
            corrupted["activity_zero"] = C.activity_zero(corrupted)
            with self.assertRaises(ValueError): C.validate_measurement(corrupted, manifest()["executables"], "early")

    def test_slow_wait_is_retained_as_timing_failure(self):
        raw = raw_fixture(self.records, "early")
        raw.update(status="failed", reason="timing_mismatch")
        raw["exit_timing"].update(wait_returned=34.9, notification_received=35.0)
        save(self.records / "trial.json", raw)
        projected = C.project_trial(self.records, process(2), manifest()["executables"], "early", manifest()["sources"])
        self.assertFalse(projected["timing_valid"])
        self.assertEqual(projected["exit_timing"]["wait_returned_ms"], 34900)
        self.assertEqual(projected["strict_verdict"]["status"], "passed")

    def test_not_covered_preserves_no_launch_cleanup_and_null_clocks(self):
        raw = raw_fixture(self.records)
        raw.update(status="not-covered", reason="reader-not-trusted", external_startup=None,
            environments={"host": None, "reader": None}, scans=[], warm_receipt=None, completed_receipt=None,
            strict_verdict={"status": "not-evaluated", "failed_labels": []})
        raw["clock_markers"] = dict.fromkeys(raw["clock_markers"])
        raw["exit_timing"].update(stop_requested=None, wait_returned=None, notification_received=None, return_code=None, phase=None)
        for role in ("reader", "host"):
            raw["cleanup"][role].update(started=False, return_code=None)
        save(self.records / "trial.json", raw)
        save(self.records / "process-cleanup.json", raw["cleanup"])
        projected = C.project_trial(self.records, process(77), manifest()["executables"], "keep", manifest()["sources"])
        self.assertEqual(projected["status"], "not-covered")
        self.assertFalse(projected["timing_valid"])
        self.assertTrue(C.fixture_clean(C.project_cleanup(raw["cleanup"])))

    def test_incomplete_attempt_keeps_available_stdout_hash(self):
        raw = raw_fixture(self.records, partial=True)
        raw["scans"] = raw["scans"][:1]
        raw["scans"][0].update(leak_nodes=None, leak_bytes=None, groups=None, unclassified_nodes=None, exit_code=None)
        raw["strict_verdict"] = {"status": "not-evaluated", "failed_labels": []}
        save(self.records / "trial.json", raw)
        projected = C.project_trial(self.records, process(2), manifest()["executables"], "keep", manifest()["sources"])
        self.assertIsNone(projected["scans"][0]["result"])
        self.assertEqual(projected["scans"][0]["stdout_sha256"], raw["scans"][0]["stdout_sha256"])

    def test_empty_failed_scan_preserves_earlier_growth_and_all_timestamps(self):
        raw = raw_fixture(self.records, failed=True)
        raw.update(status="failed", reason="scan_unavailable", scans=raw["scans"][:3],
            strict_verdict={"status": "failed", "failed_labels": ["t20"]})
        failed = raw["scans"][2]
        failed.update(leak_nodes=None, leak_bytes=None, groups=None, unclassified_nodes=None,
            exit_code=2, stdout_sha256=hashlib.sha256(b"").hexdigest())
        (self.records / "t40-original.stdout.txt").write_bytes(b"")
        save(self.records / "trial.json", raw)
        projected = C.project_trial(self.records, process(2), manifest()["executables"], "keep", manifest()["sources"])
        self.assertEqual([row["label"] for row in projected["scans"]], ["baseline", "t20", "t40"])
        self.assertEqual([row["result"]["leak_nodes"] for row in projected["scans"][:2]], [2, 3])
        self.assertEqual(projected["strict_verdict"], {"status": "failed", "failed_labels": ["t20"]})
        self.assertIsNone(projected["scans"][2]["result"])
        self.assertEqual(projected["scans"][2]["stdout_sha256"], hashlib.sha256(b"").hexdigest())
        self.assertEqual(projected["scans"][2]["checkpoint"], {"start_ms": 40010, "end_ms": 40050,
            "reader_alive_before": True, "reader_alive_after": True})
        self.assertEqual(projected["scans"][2]["scan"], {"start_ms": 40060, "end_ms": 40200,
            "reader_alive_before": True, "reader_alive_after": True})
        self.assertEqual(projected["exit_timing"]["wait_returned_ms"], 111100)
        self.assertEqual(projected["status"], "failed")
        C.validate_measurement(projected, manifest()["executables"], "keep")
        failed["stdout_sha256"] = "a" * 64
        save(self.records / "trial.json", raw)
        with self.assertRaises(ValueError): C.project_trial(self.records, process(2), manifest()["executables"], "keep", manifest()["sources"])

    def test_empty_stdout_cannot_supply_completed_scan_counts(self):
        raw = raw_fixture(self.records)
        raw["scans"][0].update(leak_nodes=0, leak_bytes=0, groups=[], unclassified_nodes=0,
            stdout_sha256=hashlib.sha256(b"").hexdigest())
        (self.records / "baseline-original.stdout.txt").write_bytes(b"")
        save(self.records / "trial.json", raw)
        with self.assertRaises(ValueError): C.project_trial(self.records, process(), manifest()["executables"], "keep", manifest()["sources"])

    def test_incomplete_stdout_preserves_regular_file_and_size_constraints(self):
        blank = self.root / "blank.stdout"; blank.write_bytes(b"")
        self.assertEqual(C.read_stdout(blank, allow_empty=True), b"")
        alias = self.root / "linked.stdout"; alias.symlink_to(blank)
        with self.assertRaises(ValueError): C.read_stdout(alias, allow_empty=True)
        alias.unlink(); os.link(blank, alias)
        with self.assertRaises(ValueError): C.read_stdout(blank, allow_empty=True)
        alias.unlink()
        directory = self.root / "stdout-directory"; directory.mkdir()
        with self.assertRaises(ValueError): C.read_stdout(directory, allow_empty=True)
        with blank.open("wb") as stream: stream.truncate(C.RAW_LIMIT + 1)
        with self.assertRaises(ValueError): C.read_stdout(blank, allow_empty=True)


class CampaignTests(TemporaryTests):
    def run_campaign(self, failed=True, failure_index=None, group_failure=False, corrupt_index=None, partial_index=None, profile=None):
        self.calls = []
        def owned(command, log, environment, timeout):
            self.calls.append((command, timeout))
            self.assertEqual(timeout, 180)
            if "--prepare-external-fixture" in command:
                prepared = Path(command[command.index("--work-directory") + 1]); prepared.mkdir()
                save(prepared / "fixture-build.json", manifest())
                return process()
            index = len(self.calls) - 2
            arm = command[command.index("--arm") + 1]
            records = Path(command[command.index("--records-directory") + 1])
            raw_fixture(records, arm, failed=failed, clean=index != failure_index or group_failure, partial=index == partial_index)
            if index == corrupt_index:
                inputs = C.read_json(records / "inputs.json"); inputs["sources"] = dict.fromkeys(C.fixture_sources(), "a" * 64)
                save(records / "inputs.json", inputs)
            return process(2 if index == partial_index else 1 if failed else 0, complete=not (index == failure_index and group_failure))
        root = self.root / "campaign"
        project = C.project_trial
        def projected(*args):
            value = project(*args)
            return scaled_measurement(value, profile) if profile is not None else value
        with mock.patch.object(C, "identity", side_effect=identity), mock.patch.object(C, "run_owned", side_effect=owned), mock.patch.object(C, "load_prepared_build", return_value=manifest()), mock.patch.object(C, "project_trial", side_effect=projected), contextlib.redirect_stdout(io.StringIO()):
            code = C.campaign(root)
        summary = C.read_json(root / "summary.json")
        C.validate_summary(summary)
        return code, summary, root

    def test_fixed_nine_order_single_build_same_hash_strict_failure_continues(self):
        code, summary, root = self.run_campaign()
        self.assertEqual(code, 1)
        self.assertEqual(len(self.calls), 10)
        self.assertEqual([(row["block"], row["order"], row["arm"]) for row in summary["trials"]], list(C.TRIALS))
        directories = {command[command.index("--prepared-fixture-directory") + 1] for command, _ in self.calls[1:]}
        self.assertEqual(len(directories), 1)
        self.assertTrue(all(row["measurement"]["executables"] == manifest()["executables"] for row in summary["trials"]))
        self.assertTrue(summary["completed"] and summary["evidence_checks_passed"])
        self.assertFalse(summary["strict_checks_passed"])
        self.assertEqual(summary["temporary_cleanup"], "complete")
        self.assertFalse((root / "private").exists())
        self.assertEqual(C.main(["--work-directory", str(root), "--validate-public"]), 0)

    def test_passed_campaign_returns_zero(self):
        code, summary, _ = self.run_campaign(failed=False)
        self.assertEqual(code, 0)
        self.assertTrue(summary["strict_checks_passed"] and summary["evidence_checks_passed"])

    def test_full_scale_compact_campaign_preserves_nine_and_final_cleanup(self):
        code, summary, root = self.run_campaign(failed=False, profile="ordinary")
        self.assertEqual(code, 0)
        self.assertEqual(summary["schema"], 2)
        self.assertEqual(len(summary["trials"]), 9)
        self.assertTrue(summary["completed"] and summary["evidence_checks_passed"])
        self.assertEqual(summary["temporary_cleanup"], "complete")
        self.assertGreater(len(C.canonical(summary)), C.PUBLIC_LIMIT)
        self.assertLessEqual(len(C.public_bytes(summary)), C.PUBLIC_LIMIT)
        self.assertEqual((root / "summary.json").read_bytes(), C.public_bytes(summary))
        self.assertFalse((root / "private").exists())
        self.assertEqual(C.main(["--work-directory", str(root), "--validate-public"]), 0)
        self.assertTrue(all(scan["composition"]["counts_status"] == "complete" for trial in summary["trials"] for scan in trial["measurement"]["scans"]))
        self.assertEqual(summary["build"]["manifest_sha256"], hashlib.sha256(C.canonical(manifest())).hexdigest())

    def test_composition_budget_fallback_retains_counts_clocks_and_strict(self):
        code, summary, root = self.run_campaign(failed=False, profile="dense")
        self.assertEqual(code, 0)
        self.assertEqual(len(summary["trials"]), 9)
        self.assertEqual(summary["temporary_cleanup"], "complete")
        self.assertTrue(summary["strict_checks_passed"] and summary["evidence_checks_passed"])
        self.assertLessEqual(len(C.public_bytes(summary)), C.PUBLIC_LIMIT)
        omitted = [scan for trial in summary["trials"] for scan in trial["measurement"]["scans"] if scan["composition"]["reasons"] == ["summary_budget"]]
        self.assertTrue(omitted)
        for trial in summary["trials"]:
            self.assertEqual(trial["strict_verdict"]["status"], "passed")
            self.assertTrue(trial["measurement"]["timing_valid"])
            for scan in trial["measurement"]["scans"]:
                self.assertEqual(scan["result"]["leak_nodes"], 384)
                self.assertEqual(C.root_count(scan["result"]), 20)
                self.assertIsNotNone(scan["checkpoint"]["start_ms"])
                self.assertIsNotNone(scan["scan"]["end_ms"])
                if scan["composition"]["reasons"] == ["summary_budget"]:
                    self.assertEqual(scan["composition"]["total_nodes"], scan["result"]["leak_nodes"])
                    self.assertEqual(scan["baseline_delta"]["status"], "unavailable")
        self.assertFalse((root / "private").exists())
        self.assertEqual(C.main(["--work-directory", str(root), "--validate-public"]), 0)

    def test_schema_one_keeps_pretty_wire_and_schema_two_rejects_pretty(self):
        _, summary, root = self.run_campaign(failed=False)
        old = copy.deepcopy(summary); old["schema"] = 1
        save(root / "summary.json", old)
        self.assertEqual(C.encode_summary(old), C.canonical(old))
        self.assertEqual(C.main(["--work-directory", str(root), "--validate-public"]), 0)
        save(root / "summary.json", summary)
        with self.assertRaises(ValueError): C.main(["--work-directory", str(root), "--validate-public"])

    def test_core_budget_failure_retains_private_before_cleanup(self):
        errors = io.StringIO()
        with mock.patch.object(C, "PUBLIC_LIMIT", 18000), contextlib.redirect_stderr(errors):
            code, summary, root = self.run_campaign(failed=False)
            self.assertEqual(code, 1)
            self.assertTrue((root / "private").exists())
            self.assertIn("private evidence retained", errors.getvalue())
            self.assertNotEqual(summary["temporary_cleanup"], "complete")

    def test_passing_partial_prefix_cannot_make_whole_campaign_strict_pass(self):
        code, summary, root = self.run_campaign(failed=False, partial_index=0)
        self.assertEqual(code, 1)
        self.assertEqual(len(summary["trials"]), 9)
        self.assertTrue(summary["completed"])
        self.assertFalse(summary["strict_checks_passed"])
        self.assertFalse(summary["evidence_checks_passed"])
        self.assertTrue(all(row["strict_verdict"]["status"] == "passed" for row in summary["trials"]))
        self.assertEqual(len(summary["trials"][0]["measurement"]["scans"]), 2)
        self.assertEqual(summary["trials"][0]["measurement"]["status"], "failed")
        self.assertEqual(summary["temporary_cleanup"], "complete")
        self.assertFalse((root / "private").exists())

    def test_fixture_cleanup_failure_stops_preserves_private_partial(self):
        code, summary, root = self.run_campaign(failure_index=2)
        self.assertEqual(code, 1)
        self.assertEqual(len(summary["trials"]), 3)
        self.assertEqual(summary["temporary_cleanup"], "retained-unconfirmed")
        self.assertTrue((root / "private").exists())
        self.assertEqual(C.main(["--work-directory", str(root), "--validate-public"]), 0)

    def test_owned_group_cleanup_failure_stops(self):
        _, summary, root = self.run_campaign(failure_index=0, group_failure=True)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(summary["temporary_cleanup"], "retained-unconfirmed")
        self.assertTrue((root / "private").exists())

    def test_projection_binding_failure_retains_strict_and_runs_next(self):
        code, summary, _ = self.run_campaign(corrupt_index=0)
        self.assertEqual(code, 1)
        self.assertEqual(len(summary["trials"]), 9)
        self.assertIsNone(summary["trials"][0]["measurement"])
        self.assertEqual(summary["trials"][0]["strict_verdict"]["status"], "failed")
        self.assertFalse(summary["evidence_checks_passed"])

    def test_summary_rejects_identity_order_policy_manifest_and_unknown_fields(self):
        _, summary, _ = self.run_campaign()
        mutations = [lambda r: r["identity"].update(macos="15.6"), lambda r: r["identity"].update(xcode="26.2"),
            lambda r: r["trials"][0].update(order=2), lambda r: r["trials"][0]["policy"].update(scan_timeout_seconds=20),
            lambda r: r["build"].update(manifest_sha256="0" * 64),
            lambda r: r["build"]["manifest"]["sources"].update({"/private/home/source": "a" * 64}),
            lambda r: r.update(raw_environment="PATH=private"), lambda r: r.update(strict_checks_passed=True),
            lambda r: r["trials"][0]["fixture_cleanup"].update(pid=123)]
        for mutation in mutations:
            corrupted = copy.deepcopy(summary); mutation(corrupted)
            with self.assertRaises(ValueError): C.validate_summary(corrupted)

    def test_validate_public_requires_canonical_bytes_and_size_limit(self):
        _, summary, root = self.run_campaign()
        path = root / "summary.json"
        path.write_text(json.dumps(summary))
        with self.assertRaises(ValueError): C.main(["--work-directory", str(root), "--validate-public"])
        path.write_bytes(b" " * (C.PUBLIC_LIMIT + 1))
        with self.assertRaises(ValueError): C.main(["--work-directory", str(root), "--validate-public"])


if __name__ == "__main__": unittest.main()
