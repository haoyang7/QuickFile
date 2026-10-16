"""Synthetic scan-timing matrix, binding, verdict and publication tests."""
import contextlib
import copy
import hashlib
import importlib.util
import io
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
INVESTIGATIONS = ROOT / "Scripts/Investigations"
SPEC = importlib.util.spec_from_file_location("ax_scan_timing_campaign_target", INVESTIGATIONS / "ax_scan_timing_campaign.py")
C = importlib.util.module_from_spec(SPEC)
with mock.patch.object(sys, "path", [str(INVESTIGATIONS), *sys.path]): SPEC.loader.exec_module(C)
TEMPORARY = ROOT / ".build/Temporary/ax-scan-timing-campaign-unit"


def process(code=0, clean=True):
    return {"return_code": code, "command_return_code": code, "status": "completed", "cleanup": {
        "group_signal": "sent", "group_members_exited": clean, "group_inspection": "exited" if clean else "running",
        "leader_reaped": True, "complete": clean}}


def identity():
    return {"checkout_sha": "a" * 40, "macos": "26.0.1", "os_build": "25A354", "architecture": "arm64",
        "xcode": "26.3", "scan_mode": C.PROTOCOL, "history_mode": "current-stacks"}


def manifest():
    return {"schema": 3, "build_mode": "install-gate", "sources": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
        for name in C.fixture_sources("install-gate")}, "executables": {"host": "b" * 64, "reader": "c" * 64}, "build_evidence": {
        "link_inputs": {"host": ["Scripts/tests/fixtures/AXCompatibilityNotifications.m", "AXCompatibility.o"],
            "reader": ["Scripts/tests/fixtures/AXCompatibilityReader.swift"]},
        "compile_definitions": {"production": ["QUICKFILE_AX_INSTALL_PROBE"], "host": ["QUICKFILE_AX_INSTALL_PROBE"], "reader": []},
        "gate_symbol_present": {"host": True, "reader": False}}}


def gate(mode):
    imp = "replacement" if mode == "installed" else "saved"
    return {"mode": mode, "preflight_completed": True, "gate_calls": 1, "copy_imp": imp, "mutable_copy_imp": imp}


def host(mode): return dict.fromkeys(C.reader.HOST_KEYS, 0) | {"install_probe": gate(mode)}
def activity(warm=False):
    return dict.fromkeys((*C.reader.READER_KEYS, *(("buttons", "registrations") if warm else ())), 0) | {"target_notification_counts": []}


def cleanup(clean=True):
    row = {"started": True, "exited": clean, "terminate_sent": False, "kill_sent": False,
        "return_code": 0 if clean else None, "errors": []}
    return {"reader": dict(row), "host": dict(row), "errors": [] if clean else ["host"], "processes_exited": clean}


def external(mode):
    expected = manifest()["executables"]
    return {"receipt_mode": "external-startup", "requested": "off", "executables": expected, "binary_reuse_verified": True,
        "install_gate": mode, **{role: {"malloc_scribble": "unset", "path_matches": True, "startup_executable_matches": True,
            "alive_during_check": True, "executable_sha256": expected[role], "install_gate": mode} for role in ("host", "reader")}}


def window(offset, scan=False):
    return {"start": offset + (.06 if scan else .01), "end": offset + (.2 if scan else .05),
        "reader_alive_before": True, "reader_alive_after": True}


def report(nodes, kind="NSXPCConnection", full=True):
    total = f"Process 123: {nodes} leaks for {nodes * 48} total leaked bytes.\n"
    frames = "0 synthetic-image 0x1234 synthetic_function + 0\n====\n" if full else ""
    return total + f"STACK OF {nodes} INSTANCES OF 'ROOT LEAK: {kind}':\n" + frames + f" {nodes} ({nodes * 48} bytes) ROOT LEAK: <{kind}>\n"


def save(path, value): path.write_bytes(C.canonical(value))


def raw_fixture(records, control="twice", mode="installed", *, growth=False, classified=True, clean=True, partial=False, full=True):
    records.mkdir(parents=True, exist_ok=True)
    raw = {"schema": 2, "arm": "keep", "timing_control": control, "install_gate": mode, "policy": C.policy(control),
        "status": "failed" if partial else "complete", "reason": "scan_unavailable" if partial else None,
        "executables": manifest()["executables"], "external_startup": external(mode), "environments": C.environment(mode),
        "clock_markers": {"origin_monotonic": 100.0, "host_start": -1.0, "host_ready": -.5, "reader_start": -.2, "warm": 0},
        "exit_timing": {"target_offset_seconds": None, "stop_requested": 40.01, "wait_returned": 40.1,
            "notification_received": 40.2, "return_code": 0, "phase": "cleanup"},
        "initial_host_receipt": host(mode), "checkpoints": [], "scans": [], "warm_receipt": activity(True), "completed_receipt": activity(),
        "strict_verdict": {"status": "passed", "failed_labels": []}, "cleanup": cleanup(clean)}
    for label, offset in C.CHECKPOINTS:
        raw["checkpoints"].append({"label": label, "target_offset_seconds": offset, "checkpoint": window(offset), "host": host(mode)})
    for index, (label, offset) in enumerate(C.CONTROLS[control]):
        nodes = 3 if index and growth else 2
        text = report(nodes, "NSXPCConnection" if classified else "PrivateTargetType", full)
        groups = C.leak_groups(text)
        checkpoint = next(row for row in raw["checkpoints"] if row["target_offset_seconds"] == offset)
        row = {"label": label, "target_offset_seconds": offset, "host": copy.deepcopy(checkpoint["host"]),
            "checkpoint": copy.deepcopy(checkpoint["checkpoint"]), "scan": window(offset, True), "exit_code": 1,
            "leak_nodes": nodes, "leak_bytes": nodes * 48, "groups": groups, "unclassified_nodes": nodes - sum(group["tree_nodes"] or 0 for group in groups),
            "destroyed_notification_stack_present": False, "stdout_sha256": hashlib.sha256(text.encode()).hexdigest()}
        (records / (label + "-original.stdout.txt")).write_text(text)
        raw["scans"].append(row)
        if not classified or index and growth: raw["strict_verdict"]["failed_labels"].append(label)
    raw["strict_verdict"]["status"] = "failed" if raw["strict_verdict"]["failed_labels"] else "passed"
    if partial:
        last = raw["scans"][-1]
        last.update(leak_nodes=None, leak_bytes=None, groups=None, unclassified_nodes=None, exit_code=2, stdout_sha256=hashlib.sha256(b"").hexdigest())
        (records / (last["label"] + "-original.stdout.txt")).write_bytes(b"")
        raw["strict_verdict"]["failed_labels"] = [label for label in raw["strict_verdict"]["failed_labels"] if label != last["label"]]
        raw["strict_verdict"]["status"] = "failed" if raw["strict_verdict"]["failed_labels"] else "passed" if len(raw["scans"]) > 1 else "not-evaluated"
    save(records / "trial.json", raw); save(records / "external-startup.json", raw["external_startup"])
    save(records / "inputs.json", {"sources": manifest()["sources"]}); save(records / "process-cleanup.json", raw["cleanup"])
    return raw


def gate_failed_fixture(records, control, mode, key, state):
    raw = raw_fixture(records, control, mode, classified=False)
    raw.update(status="failed", reason="activity_violation")
    raw["checkpoints"][1]["host"]["install_probe"][key] = state
    # The t20 gate check throws before another scan is requested. Earlier
    # classification failures are still observations and must remain available.
    raw["scans"] = [row for row in raw["scans"] if row["target_offset_seconds"] < 20]
    raw["strict_verdict"] = {"status": "failed" if raw["scans"] else "not-evaluated",
        "failed_labels": [row["label"] for row in raw["scans"]]}
    raw["exit_timing"].update(stop_requested=20.1, wait_returned=20.2, notification_received=20.3)
    later = records / "t20-original.stdout.txt"
    if later.exists(): later.unlink()
    save(records / "trial.json", raw)
    return raw


def ordinary_composition(scale):
    weights = {"CFDictionary": 1, "CFDictionary (Key Storage)": 1, "CFDictionary (Value Storage)": 1,
        "NSArray": 30, "NSSet": 30, "NSXPCConnection": 1, "NSXPCInterface": 1, "__NSMallocBlock__": 2,
        "dispatch_group_t": 1, "dispatch_mach_t": 1, "dispatch_queue_t (serial)": 1, "unknown": 25, "xpc_connection_t": 1}
    counts = {kind: number * scale for kind, number in weights.items()}
    unresolved = [{"type": kind, "count": number, "bytes_min": number * 48, "bytes_max": number * 48,
        "reason": "multiple_instances" if number > 1 else "rounded_subtree"} for kind, count in sorted(counts.items())
        for number in (count // 2, count - count // 2)]
    nodes = sum(counts.values())
    result = {"schema": 3, "status": "partial", "counts_status": "complete", "size_bounds": "combined-self-bytes", "failure_stage": None,
        "failure_fragment": None, "total_nodes": nodes, "total_bytes": nodes * 48, "type_counts": [{"type": kind, "count": count} for kind, count in sorted(counts.items())],
        "exact_size_histogram": [], "size_unknown_nodes": nodes, "unresolved_sizes": unresolved, "unknown_type_nodes": counts["unknown"], "omitted_nodes": 0,
        "reasons": ["unknown_type", "size_unresolved"]}
    C.composition.validate_grouped_composition(result)
    return result


class TemporaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): TEMPORARY.mkdir(parents=True, exist_ok=True)
    @classmethod
    def tearDownClass(cls): TEMPORARY.rmdir()
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=TEMPORARY); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name); self.records = self.root / "records"
    def project(self, control="twice", mode="installed", **kwargs):
        raw_fixture(self.records, control, mode, **kwargs)
        code = 2 if kwargs.get("partial") else 1 if kwargs.get("growth") or not kwargs.get("classified", True) else 0
        return C.project_trial(self.records, process(code), manifest()["executables"], control, mode, manifest()["sources"])


class ProjectionTests(TemporaryTests):
    def test_failed_measurement_cannot_change_planned_install_mode(self):
        value = self.project(partial=True)
        for role in ('host', 'reader'):
            with self.subTest(role=role):
                changed = copy.deepcopy(value)
                changed['environments'][role][C.INSTALL_ENV] = 'preflight-only'
                with self.assertRaises(ValueError):
                    C.validate_measurement(changed, manifest()['executables'], 'twice', 'installed')

    def test_trial_initializer_policy_contract_is_order_independent_and_typed(self):
        spec = importlib.util.spec_from_file_location("ax_scan_timing_trial_contract", INVESTIGATIONS / "ax_reader_exit_trial.py")
        trial = importlib.util.module_from_spec(spec)
        with mock.patch.object(sys, "path", [str(INVESTIGATIONS), *sys.path]): spec.loader.exec_module(trial)
        for control in C.CONTROLS:
            raw = raw_fixture(self.records, control)
            raw["policy"] = trial.initial_trial("keep", control, "installed")["policy"]
            self.assertNotEqual(C.canonical(raw["policy"]), C.canonical(C.policy(control)))
            save(self.records / "trial.json", raw)
            value = C.project_trial(self.records, process(), manifest()["executables"], control, "installed", manifest()["sources"])
            self.assertTrue(value["timing_valid"])
        for mutation in (lambda p: p.update(scan_timeout_seconds=12.0), lambda p: p["checkpoint_schedule"][0].update(offset_seconds=False)):
            raw = raw_fixture(self.records)
            raw["policy"] = trial.initial_trial("keep", "twice", "installed")["policy"]
            mutation(raw["policy"]); save(self.records / "trial.json", raw)
            with self.assertRaises(ValueError): C.project_trial(self.records, process(), manifest()["executables"], "twice", "installed", manifest()["sources"])

    def test_six_conditions_keep_two_checkpoints_and_late_offset(self):
        for control in C.CONTROLS:
            for mode in C.INSTALL_MODES:
                with self.subTest(control=control, mode=mode):
                    value = self.project(control, mode)
                    self.assertTrue(value["timing_valid"] and value["gate_valid"] and value["activity_zero"])
                    self.assertEqual(len(value["checkpoints"]), 2)
                    self.assertEqual([row["target_offset_ms"] for row in value["scans"]], [offset * 1000 for _, offset in C.CONTROLS[control]])
                    self.assertEqual(value["growth_verdict"], "passed" if control == "twice" else "not-evaluated")
                    self.assertEqual(value["scans"][0]["checkpoint_label"], "t20" if control == "late-only" else "t0")
                    self.assertEqual(value["exit_timing"]["wait_returned_ms"], 40100)
                    self.assertNotIn("origin_monotonic", value["clock_markers"])

    def test_classification_and_growth_are_distinct(self):
        value = self.project(growth=True)
        self.assertEqual(value["classification_verdict"], "passed")
        self.assertEqual(value["growth_verdict"], "failed")
        self.assertEqual(value["original_strict_verdict"], {"status": "failed", "failed_labels": ["t20"]})
        self.assertEqual(value["scans"][1]["earlier_scan_delta"]["net_nodes"], 1)
        value = self.project(classified=False)
        self.assertEqual(value["classification_verdict"], "failed")
        self.assertEqual(value["growth_verdict"], "passed")
        self.assertEqual(value["scans"][0]["composition"]["unknown_type_nodes"], 2)
        self.assertNotIn("PrivateTargetType", C.public_bytes(value).decode())
        self.assertNotIn("0x1234", C.public_bytes(value).decode())

    def test_zero_totals_project_classification_from_complete_group_trees(self):
        empty = "Process 123: 0 leaks for 0 total leaked bytes.\n"
        invalid = empty + ("STACK OF 1 INSTANCE OF 'ROOT LEAK: NSXPCConnection':\n"
            "0 synthetic-image 0x1234 synthetic_function + 0\n====\n"
            "    1 (48 bytes) << TOTAL >>\n      1 (48 bytes) ROOT LEAK: NSXPCConnection\n")
        for text, passed in ((invalid, False), (empty, True)):
            with self.subTest(complete_tree=passed):
                raw = raw_fixture(self.records)
                scan = raw["scans"][0]
                scan.update(leak_nodes=0, leak_bytes=0, unclassified_nodes=0, groups=C.leak_groups(text),
                    stdout_sha256=hashlib.sha256(text.encode()).hexdigest())
                (self.records / (scan["label"] + "-original.stdout.txt")).write_text(text)
                projected = C.project_scan(scan, self.records, 0, "t0")
                self.assertEqual(projected["classification"], "passed" if passed else "failed")
                self.assertEqual(projected["composition"]["counts_status"], "complete" if passed else "unavailable")
                self.assertEqual(C.strict_from_scans([projected]), {
                    "status": "passed" if passed else "failed", "failed_labels": [] if passed else [scan["label"]]})

    def test_empty_failed_scan_keeps_checkpoints_and_baseline(self):
        value = self.project(partial=True)
        self.assertEqual(value["status"], "failed")
        self.assertEqual(value["growth_verdict"], "not-evaluated")
        self.assertEqual(value["classification_verdict"], "not-evaluated")
        self.assertEqual(len(value["checkpoints"]), 2)
        self.assertEqual(value["scans"][0]["result"]["leak_nodes"], 2)
        self.assertIsNone(value["scans"][1]["result"])
        self.assertEqual(value["scans"][1]["stdout_sha256"], hashlib.sha256(b"").hexdigest())
        self.assertEqual(value["scans"][1]["scan"]["start_ms"], 20060)
        self.assertEqual(value["original_strict_verdict"]["status"], "passed")

    def test_composition_unavailable_does_not_revoke_raw_strict(self):
        value = self.project(growth=True, full=False)
        self.assertEqual(value["growth_verdict"], "failed")
        self.assertEqual(value["original_strict_verdict"]["status"], "failed")
        self.assertEqual(value["scans"][1]["earlier_scan_delta"]["status"], "unavailable")

    def test_bindings_reject_sources_sha_totals_groups_and_checkpoint_alias(self):
        raw = raw_fixture(self.records)
        mutations = [lambda r: r["scans"][0].update(stdout_sha256="a" * 64), lambda r: r["scans"][0].update(leak_bytes=97),
            lambda r: r["scans"][0]["groups"][0].update(root_instances=55), lambda r: r["scans"][0]["host"].update(buttons=1),
            lambda r: r["scans"][0]["checkpoint"].update(start=.02), lambda r: r.update(executables={"host": "d" * 64, "reader": "c" * 64})]
        for mutation in mutations:
            altered = copy.deepcopy(raw); mutation(altered); save(self.records / "trial.json", altered)
            with self.assertRaises((ValueError, RuntimeError)): C.project_trial(self.records, process(), manifest()["executables"], "twice", "installed", manifest()["sources"])
        save(self.records / "trial.json", raw); save(self.records / "inputs.json", {"sources": dict.fromkeys(C.fixture_sources("install-gate"), "a" * 64)})
        with self.assertRaises(ValueError): C.project_trial(self.records, process(), manifest()["executables"], "twice", "installed", manifest()["sources"])

    def test_late_single_cannot_be_zero_baseline_or_claim_growth(self):
        value = self.project("late-only")
        mutations = [lambda r: r["scans"][0].update(target_offset_ms=0), lambda r: r.update(growth_verdict="passed"),
            lambda r: r["scans"][0].update(checkpoint_label="t0"), lambda r: r["scans"][0].update(earlier_scan_delta={})]
        for mutation in mutations:
            altered = copy.deepcopy(value); mutation(altered)
            with self.assertRaises(ValueError): C.validate_measurement(altered, manifest()["executables"], "late-only", "installed")

    def test_invalid_gate_activity_timing_and_reader_liveness_rejected(self):
        value = self.project()
        mutations = [lambda r: r["initial_host"]["install_probe"].update(copy_imp="saved"),
            lambda r: r["checkpoints"][1]["host"]["install_probe"].update(gate_calls=2),
            lambda r: r["checkpoints"][1]["host"]["activity"].update(buttons=1),
            lambda r: r["exit_timing"].update(wait_returned_ms=43100, notification_received_ms=43200),
            lambda r: r["checkpoints"][1]["checkpoint"].update(reader_alive_before=False),
            lambda r: r["scans"][1]["scan"].update(reader_alive_after=False),
            lambda r: r["scans"][1]["scan"].update(start_ms=24000, end_ms=24100)]
        for mutation in mutations:
            altered = copy.deepcopy(value); mutation(altered)
            altered.update(gate_valid=C.gates_valid(altered, "installed"), activity_zero=C.activity_zero(altered), timing_valid=C.timing_valid(altered, "twice"))
            with self.assertRaises(ValueError): C.validate_measurement(altered, manifest()["executables"], "twice", "installed")

    def test_failed_gate_observation_and_late_exit_are_retained(self):
        value = self.project()
        value.update(status="failed", reason="activity_violation")
        value["initial_host"]["install_probe"]["copy_imp"] = "saved"; value["gate_valid"] = False
        C.validate_measurement(value, manifest()["executables"], "twice", "installed")
        self.assertEqual(len(value["scans"]), 2)
        value.update(reason="timing_mismatch")
        value["exit_timing"].update(wait_returned_ms=44000, notification_received_ms=44100); value["timing_valid"] = False
        C.validate_measurement(value, manifest()["executables"], "twice", "installed")

    def test_private_t20_failed_gate_enums_preserve_prior_scan_and_strict(self):
        observations = (("copy_imp", "other"), ("mutable_copy_imp", "other"), ("copy_imp", "unavailable"),
            ("mutable_copy_imp", "unavailable"), ("mode", "invalid"))
        for key, state in observations:
            with self.subTest(key=key, state=state):
                raw = gate_failed_fixture(self.records, "twice", "installed", key, state)
                value = C.project_trial(self.records, process(2), manifest()["executables"], "twice", "installed", manifest()["sources"])
                self.assertEqual(value["status"], "failed"); self.assertEqual(value["reason"], "activity_violation")
                self.assertFalse(value["gate_valid"]); self.assertFalse(value["timing_valid"])
                self.assertEqual(value["checkpoints"][1]["host"]["install_probe"][key], state)
                self.assertEqual(len(value["checkpoints"]), 2); self.assertEqual(len(value["scans"]), 1)
                self.assertEqual(value["scans"][0]["result"]["leak_nodes"], 2)
                self.assertEqual(value["scans"][0]["stdout_sha256"], raw["scans"][0]["stdout_sha256"])
                self.assertEqual(value["scans"][0]["scan"]["end_ms"], 200)
                self.assertEqual(value["original_strict_verdict"], {"status": "failed", "failed_labels": ["baseline"]})
                C.validate_measurement(value, manifest()["executables"], "twice", "installed")
        gate_failed_fixture(self.records, "twice", "installed", "copy_imp", "private-state-0x1234")
        with self.assertRaises(ValueError): C.project_trial(self.records, process(2), manifest()["executables"], "twice", "installed", manifest()["sources"])

    def test_failed_gate_enums_cannot_make_complete_evidence_valid(self):
        value = self.project()
        for key, state in (("copy_imp", "other"), ("mutable_copy_imp", "unavailable"), ("mode", "invalid")):
            altered = copy.deepcopy(value); altered["checkpoints"][1]["host"]["install_probe"][key] = state
            altered["gate_valid"] = False
            with self.assertRaises(ValueError): C.validate_measurement(altered, manifest()["executables"], "twice", "installed")
            altered["gate_valid"] = True
            with self.assertRaises(ValueError): C.validate_measurement(altered, manifest()["executables"], "twice", "installed")

    def test_public_math_fields_addresses_and_float_rejected(self):
        value = self.project(growth=True)
        mutations = [lambda r: r.update(pid=123), lambda r: r["clock_markers"].update(warm_ms=0.0),
            lambda r: r["scans"][0]["result"]["groups"][0].update(root_type="0x1234"),
            lambda r: r["original_strict_verdict"].update(status="passed", failed_labels=[]),
            lambda r: r.update(growth_verdict="passed"), lambda r: r["scans"][1].update(classification="failed"),
            lambda r: r["scans"][1]["earlier_scan_delta"].update(net_nodes=0),
            lambda r: r["environments"]["host"].update(PATH="private")]
        for mutation in mutations:
            altered = copy.deepcopy(value); mutation(altered)
            with self.assertRaises(ValueError): C.validate_measurement(altered, manifest()["executables"], "twice", "installed")

    def test_host_age_is_observed_without_an_added_cutoff(self):
        value = self.project()
        value["clock_markers"]["host_start_ms"] = -5000
        self.assertTrue(C.timing_valid(value, "twice"))
        C.validate_measurement(value, manifest()["executables"], "twice", "installed")


class CampaignTests(TemporaryTests):
    def run_campaign(self, *, growth=False, classified=True, cleanup_index=None, group_failure=False, partial_index=None, corrupt_index=None, large=False,
                     gate_failure=None, missing_cleanup_index=None):
        self.calls = []
        def owned(command, log, env, timeout):
            self.calls.append(command); self.assertEqual(timeout, 180)
            if "--prepare-install-gate-fixture" in command:
                prepared = Path(command[command.index("--work-directory") + 1]); prepared.mkdir(); save(prepared / "fixture-build.json", manifest())
                return process()
            index = len(self.calls) - 2
            control, mode = (command[command.index(flag) + 1] for flag in ("--timing-control", "--install-gate"))
            records = Path(command[command.index("--records-directory") + 1])
            raw_fixture(records, control, mode, growth=growth, classified=classified, clean=index != cleanup_index or group_failure, partial=index == partial_index)
            if gate_failure is not None and index == 4: gate_failed_fixture(records, control, mode, *gate_failure)
            if index == missing_cleanup_index: (records / "process-cleanup.json").unlink()
            if index == corrupt_index: save(records / "inputs.json", {"sources": dict.fromkeys(C.fixture_sources("install-gate"), "a" * 64)})
            return process(2 if index == partial_index or gate_failure is not None and index == 4 else 1 if growth and control == "twice" or not classified else 0,
                clean=not (index == cleanup_index and group_failure))
        original = C.project_trial
        def projected(*args):
            value = original(*args)
            if large:
                for index, row in enumerate(value["scans"]):
                    comp = ordinary_composition(4 if index == 0 else 3); row["composition"] = comp
                    row["result"].update(leak_nodes=comp["total_nodes"], leak_bytes=comp["total_bytes"], groups=[{
                        "root_kind": "leak", "root_type": "NSXPCConnection", "root_instances": 4 if index == 0 else 3,
                        "tree_nodes": comp["total_nodes"], "groups": 1}])
                    if index: row["earlier_scan_delta"] = C.composition.composition_delta(value["scans"][0]["composition"], comp)
            return value
        root = self.root / "campaign"
        with mock.patch.object(C, "identity", side_effect=identity), mock.patch.object(C, "run_owned", side_effect=owned), mock.patch.object(C, "load_prepared_build", return_value=manifest()), mock.patch.object(C, "project_trial", side_effect=projected), contextlib.redirect_stdout(io.StringIO()):
            code = C.campaign(root)
        value = C.read_json(root / "summary.json"); C.validate_summary(value)
        return code, value, root

    def test_fixed_eighteen_fresh_processes_single_build_twentyfour_scans(self):
        code, value, root = self.run_campaign()
        self.assertEqual(code, 0); self.assertEqual(len(self.calls), 19)
        self.assertEqual([(row["block"], row["order"], row["timing_control"], row["install_gate"]) for row in value["trials"]], list(C.TRIALS))
        self.assertEqual(sum(len(row["measurement"]["scans"]) for row in value["trials"]), 24)
        self.assertEqual(len({command[command.index("--prepared-fixture-directory") + 1] for command in self.calls[1:]}), 1)
        self.assertEqual(len({command[command.index("--work-directory") + 1] for command in self.calls[1:]}), 18)
        self.assertTrue(all(row["measurement"]["executables"] == manifest()["executables"] for row in value["trials"]))
        self.assertTrue(value["completed"] and value["evidence_checks_passed"] and value["classification_checks_passed"] and value["growth_checks_passed"])
        self.assertEqual(value["single_group_growth_verdict"], "not-evaluated")
        self.assertFalse((root / "private").exists()); self.assertEqual(value["temporary_cleanup"], "complete")
        self.assertEqual(C.main(["--work-directory", str(root), "--validate-public"]), 0)

    def test_growth_failure_continues_all_conditions_and_remains_independent(self):
        code, value, _ = self.run_campaign(growth=True)
        self.assertEqual(code, 1); self.assertEqual(len(self.calls), 19)
        self.assertTrue(value["evidence_checks_passed"] and value["classification_checks_passed"])
        self.assertFalse(value["growth_checks_passed"])
        self.assertEqual(sum(row["growth_verdict"] == "failed" for row in value["trials"]), 6)

    def test_classification_failure_does_not_delete_scans_or_stop_conditions(self):
        code, value, _ = self.run_campaign(classified=False)
        self.assertEqual(code, 1); self.assertTrue(value["completed"] and value["evidence_checks_passed"])
        self.assertFalse(value["classification_checks_passed"]); self.assertTrue(value["growth_checks_passed"])
        self.assertEqual(sum(len(row["measurement"]["scans"]) for row in value["trials"]), 24)

    def test_partial_or_binding_failure_cannot_pass(self):
        for argument in ("partial_index", "corrupt_index"):
            with self.subTest(argument=argument):
                code, value, root = self.run_campaign(**{argument: 4})
                self.assertEqual(code, 1); self.assertEqual(len(self.calls), 19)
                self.assertTrue(value["completed"])
                for key in ("evidence_checks_passed", "classification_checks_passed", "growth_checks_passed"): self.assertFalse(value[key])
                if argument == "partial_index": self.assertEqual(len(value["trials"][4]["measurement"]["checkpoints"]), 2)
                else: self.assertIsNone(value["trials"][4]["measurement"])
                self.assertEqual((root / "private").exists(), argument == "corrupt_index")
                shutil.rmtree(root)

    def test_unknown_fixture_or_owned_group_cleanup_stops_and_retains(self):
        for group_failure in (False, True):
            code, value, root = self.run_campaign(cleanup_index=2, group_failure=group_failure)
            self.assertEqual(code, 1); self.assertEqual(len(value["trials"]), 3)
            self.assertTrue((root / "private").exists()); self.assertEqual(value["temporary_cleanup"], "retained-unconfirmed")
            self.assertEqual(C.main(["--work-directory", str(root), "--validate-public"]), 0)
            shutil.rmtree(root)

    def test_failed_gate_observations_persist_after_confirmed_cleanup(self):
        for observation in (("copy_imp", "other"), ("mutable_copy_imp", "other"), ("copy_imp", "unavailable"),
                            ("mutable_copy_imp", "unavailable"), ("mode", "invalid")):
            with self.subTest(observation=observation):
                code, value, root = self.run_campaign(gate_failure=observation)
                self.assertEqual(code, 1); self.assertTrue(value["completed"]); self.assertEqual(len(self.calls), 19)
                failed = value["trials"][4]; measurement = failed["measurement"]
                self.assertIsNotNone(measurement); self.assertEqual(failed["projection_reason"], "none")
                self.assertTrue(failed["cleanup_confirmed"]); self.assertFalse(C.evidence_passed(failed))
                self.assertFalse(measurement["gate_valid"]); self.assertEqual(len(measurement["checkpoints"]), 2)
                self.assertEqual(len(measurement["scans"]), 1); self.assertEqual(measurement["scans"][0]["result"]["leak_nodes"], 2)
                self.assertEqual(failed["original_strict_verdict"], {"status": "failed", "failed_labels": ["baseline"]})
                self.assertEqual(measurement["original_strict_verdict"], failed["original_strict_verdict"])
                key, state = observation; self.assertEqual(measurement["checkpoints"][1]["host"]["install_probe"][key], state)
                self.assertEqual(value["temporary_cleanup"], "complete"); self.assertFalse((root / "private").exists())
                self.assertEqual(C.main(["--work-directory", str(root), "--validate-public"]), 0)
                shutil.rmtree(root)

    def test_missing_cleanup_receipt_keeps_measured_growth_and_strict_failure(self):
        code, value, root = self.run_campaign(growth=True, missing_cleanup_index=4)
        self.assertEqual(code, 1); self.assertEqual(len(value["trials"]), 5); self.assertEqual(len(self.calls), 6)
        failed = value["trials"][-1]
        self.assertEqual(failed["original_strict_verdict"], {"status": "failed", "failed_labels": ["t20"]})
        self.assertEqual(failed["measurement"]["original_strict_verdict"], failed["original_strict_verdict"])
        self.assertEqual(failed["growth_verdict"], "failed"); self.assertEqual(len(failed["measurement"]["scans"]), 2)
        self.assertIsNone(failed["fixture_cleanup"]); self.assertFalse(failed["cleanup_confirmed"])
        self.assertEqual(value["temporary_cleanup"], "retained-unconfirmed"); self.assertTrue((root / "private").exists())
        self.assertEqual(C.main(["--work-directory", str(root), "--validate-public"]), 0)

    def test_standard_capacity_preflight_preserves_eighteen_and_final_receipt(self):
        code, value, root = self.run_campaign(large=True)
        self.assertEqual(code, 0); self.assertEqual(len(value["trials"]), 18)
        self.assertEqual(sum(len(row["measurement"]["scans"]) for row in value["trials"]), 24)
        self.assertLessEqual(len(C.public_bytes(value)), C.PUBLIC_LIMIT)
        self.assertTrue(all(scan["composition"]["counts_status"] == "complete" for row in value["trials"] for scan in row["measurement"]["scans"]))
        self.assertEqual(value["temporary_cleanup"], "complete"); self.assertFalse((root / "private").exists())
        self.assertEqual(value["build"]["manifest_sha256"], hashlib.sha256(C.canonical(manifest())).hexdigest())

    def test_budget_fallback_keeps_core_results_and_verdicts(self):
        with mock.patch.object(C, "PUBLIC_LIMIT", 120000):
            code, value, root = self.run_campaign(large=True)
            self.assertEqual(code, 0); self.assertEqual(len(value["trials"]), 18)
            self.assertTrue(value["growth_checks_passed"] and value["classification_checks_passed"])
            scans = [scan for row in value["trials"] for scan in row["measurement"]["scans"]]
            self.assertTrue(any(scan["composition"]["reasons"] == ["summary_budget"] for scan in scans))
            self.assertTrue(all(scan["result"]["leak_nodes"] in (288, 384) and scan["scan"]["reader_alive_after"] for scan in scans))
            self.assertFalse((root / "private").exists()); self.assertEqual(value["temporary_cleanup"], "complete")

    def test_core_budget_failure_preflights_before_removing_private(self):
        errors = io.StringIO()
        with mock.patch.object(C, "PUBLIC_LIMIT", 16000), contextlib.redirect_stderr(errors):
            code, value, root = self.run_campaign()
            self.assertEqual(code, 1); self.assertTrue((root / "private").exists())
            self.assertIn("private evidence retained", errors.getvalue())
            self.assertNotEqual(value["temporary_cleanup"], "complete")

    def test_public_gate_rejects_identity_policy_order_binding_and_forged_checks(self):
        _, value, root = self.run_campaign()
        mutations = [lambda r: r["identity"].update(macos="15.6"), lambda r: r["identity"].update(xcode="26.2"),
            lambda r: r.update(protocol="reader-exit"), lambda r: r["trials"][0].update(order=2),
            lambda r: r["trials"][0]["policy"].update(hold_until_seconds=30), lambda r: r["build"].update(manifest_sha256="a" * 64),
            lambda r: r["build"]["manifest"]["build_evidence"]["gate_symbol_present"].update(host=False),
            lambda r: r["trials"][0].update(growth_verdict="passed"), lambda r: r.update(single_group_growth_verdict="passed"),
            lambda r: r["trials"][0]["fixture_cleanup"].update(pid=123), lambda r: r.update(raw_stack="0x1234"),
            lambda r: r["build"]["manifest"]["sources"].update({"/private/source": "a" * 64})]
        for mutation in mutations:
            altered = copy.deepcopy(value); mutation(altered)
            with self.assertRaises((ValueError, RuntimeError)): C.validate_summary(altered)
        save(root / "summary.json", value)
        with self.assertRaises(ValueError): C.main(["--work-directory", str(root), "--validate-public"])


if __name__ == "__main__": unittest.main()
