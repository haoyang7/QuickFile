"""Campaign orchestration and publication tests without native AX processes."""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import re
import sys
import tempfile
import types
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
INVESTIGATIONS = ROOT / "Scripts/Investigations"
TEMPORARY = ROOT / ".build/Temporary/ax-reference-verification-20261012/campaign-tests"
SPEC = importlib.util.spec_from_file_location("ax_reference_campaign_tests_target", INVESTIGATIONS / "ax_reference_campaign.py")
CAMPAIGN = importlib.util.module_from_spec(SPEC)
with mock.patch.object(sys, "path", [str(INVESTIGATIONS), *sys.path]):
    SPEC.loader.exec_module(CAMPAIGN)
REFERENCE = types.ModuleType("ax_reference_validation")
REFERENCE.validate_summary = mock.Mock()


def process_run(code=0, cleanup=True, status="completed", command_code=None):
    return {"return_code": code, "command_return_code": code if command_code is None else command_code,
            "status": status, "cleanup": {"group_signal": "sent", "group_members_exited": cleanup,
            "group_inspection": "exited" if cleanup else "running", "leader_reaped": True,
            "complete": cleanup}}


def measurement(failed=False):
    return {"scan_totals": [{"label": label, "leak_nodes": 1, "leak_bytes": 48,
            "unclassified_nodes": 0, "destroyed_notification_stack_present": False,
            "exit_code": 1, "xpc_roots": 1, "unexpected_roots": False} for label in CAMPAIGN.HEAP_LABELS],
            "failure_counts": {key: int(failed and key == "heap_baseline") for key in CAMPAIGN.FAILURES},
            "activity_counts": {key: 0 for key in ("destroyed_buttons", "notifications",
                                                   "ordinary_compensations", "mutable_compensations")}}


def manifest(mode, sources=None):
    value = {"schema": 1 if mode == "ordinary" else 2, "build_mode": mode,
             "sources": sources or {name: "a" * 64 for name in CAMPAIGN.fixture_sources(mode)},
             "executables": {"host": "b" * 64, "reader": "c" * 64}}
    if mode == "pure-appkit":
        value["build_evidence"] = {"link_inputs": {
            "host": ["Scripts/tests/fixtures/AXCompatibilityNotifications.m"],
            "reader": ["Scripts/tests/fixtures/AXCompatibilityReader.swift"]},
            "production_ax_symbol_counts": {"host": 0, "reader": 0}}
    return value


def summary():
    return {"schema": 1, "identity": {"checkout_sha": "a" * 40, "macos": "26.0.1",
            "os_build": "25A354", "architecture": "arm64", "xcode": "26.3",
            "scan_mode": "frozen-reference-investigation", "history_mode": "full-no-compact"},
            "builds": {}, "cases": [], "completed": False, "strict_checks_passed": False,
            "evidence_checks_passed": False, "temporary_cleanup": "not-run"}


def case(name="patched-product", strict=False):
    return {"name": name, "process_run": process_run(0 if strict else 1),
            "measurement": measurement(failed=not strict), "measurement_valid": True,
            "strict_checks_passed": strict, "offline_process_run": None, "frozen": None,
            "bridge": None, "reference": None, "evidence_checks_passed": False,
            "cleanup_confirmed": False}


class CampaignBoundaryTests(unittest.TestCase):
    def setUp(self):
        sidecar = mock.patch.dict(sys.modules, {"ax_reference_validation": REFERENCE})
        sidecar.start()
        self.addCleanup(sidecar.stop)


class CampaignTemporaryTests(CampaignBoundaryTests):
    @classmethod
    def setUpClass(cls):
        TEMPORARY.mkdir(parents=True, exist_ok=True)

    @classmethod
    def tearDownClass(cls):
        TEMPORARY.rmdir()

    def setUp(self):
        super().setUp()
        self.temporary = tempfile.TemporaryDirectory(prefix="unit-", dir=TEMPORARY)
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name) / "campaign"


class CampaignOrchestrationTests(CampaignTemporaryTests):
    def run_campaign(self, *, strict_failures=False, failed_phase=None, fixture_exited=True,
                     tool_cleanup=True, final_cleanup_failure=False, build_failure=None,
                     reference_failure=None):
        calls = []
        prepared = []
        collect_evidence = CAMPAIGN.collect_evidence
        frozen = {"status": "complete", "selection": "no-strict-growth", "selected_label": None,
                  "baseline": {"leak_nodes": 1, "leak_bytes": 48}, "selected": None,
                  "tools": [], "process_cleanup_confirmed": True}
        bridge = {"status": "not_needed", "tools": [], "process_cleanup_confirmed": True}
        native_outputs = {("xcodebuild", "-version"): "Xcode 26.3\nBuild version 17C1",
                          ("git", "rev-parse", "HEAD"): "a" * 40,
                          ("sw_vers", "-productVersion"): "26.0.1",
                          ("sw_vers", "-buildVersion"): "25A354", ("uname", "-m"): "arm64"}

        def run(command, log, environment, **options):
            calls.append((command, log, environment, options))
            if "--prepare-external-fixture" in command:
                mode = "pure-appkit" if "pure-appkit" in command else "ordinary"
                return process_run(2 if build_failure == mode else 0,
                                   cleanup=failed_phase != "build-" + mode)
            if "--reference-validation" in command and "--heap-diagnostics" in command:
                return process_run(7 if strict_failures else 0, cleanup=failed_phase != "measurement")
            return process_run(cleanup=failed_phase != "offline")

        def build(directory, sources, mode):
            prepared.append((directory, copy.deepcopy(sources), mode))
            return manifest(mode, sources)

        def read(path, limit):
            if path.name == "result.json":
                return {"cleanup": {"processes_exited": fixture_exited}}
            if path.name == "frozen-nodes.json":
                return frozen
            if path.name == "bridge-evidence.json":
                return bridge
            if path.name == "reference-validation.json":
                if reference_failure == "missing":
                    raise FileNotFoundError("synthetic missing reference")
                if reference_failure == "invalid-json":
                    raise json.JSONDecodeError("synthetic invalid JSON", "{", 1)
            return {}

        def evidence(records, totals, destination=None):
            if reference_failure:
                return collect_evidence(records, totals, destination)
            return tuple({"status": "complete", "tools": [{"cleanup_confirmed": tool_cleanup}],
                          "process_cleanup_confirmed": True} for _ in range(3))

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(CAMPAIGN, "run_owned", side_effect=run))
            stack.enter_context(mock.patch.object(CAMPAIGN.subprocess, "check_output",
                                                   side_effect=lambda command, **kwargs: native_outputs[tuple(command)]))
            stack.enter_context(mock.patch.object(CAMPAIGN, "load_prepared_build", side_effect=build))
            stack.enter_context(mock.patch.object(CAMPAIGN, "read_json", side_effect=read))
            stack.enter_context(mock.patch.object(CAMPAIGN, "project_measurement",
                                                   return_value=measurement(strict_failures)))
            stack.enter_context(mock.patch.object(CAMPAIGN, "collect_evidence", side_effect=evidence))
            stack.enter_context(mock.patch.object(CAMPAIGN, "graph_hash", return_value="d" * 64))
            # These sidecars have their own contract tests; keep the campaign's validator real.
            stack.enter_context(mock.patch.object(CAMPAIGN, "validate_frozen"))
            stack.enter_context(mock.patch.object(CAMPAIGN, "validate_bridge"))
            stack.enter_context(mock.patch.object(REFERENCE, "validate_summary",
                side_effect=ValueError("synthetic invalid reference") if reference_failure == "invalid-summary" else None))
            if final_cleanup_failure:
                stack.enter_context(mock.patch.object(CAMPAIGN.shutil, "rmtree", side_effect=OSError("synthetic failure")))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            code = CAMPAIGN.main(["--work-directory", str(self.work)])
        return code, json.loads((self.work / "summary.json").read_bytes()), calls, prepared

    def test_four_known_strict_failures_continue_and_preserve_original_results(self):
        code, value, calls, _ = self.run_campaign(strict_failures=True)
        self.assertEqual(code, 1)
        self.assertTrue(value["completed"])
        self.assertEqual([row["name"] for row in value["cases"]], list(CAMPAIGN.CASES))
        self.assertFalse(value["strict_checks_passed"])
        self.assertTrue(value["evidence_checks_passed"])
        self.assertEqual(len(calls), 10)
        for row in value["cases"]:
            self.assertEqual(row["process_run"]["return_code"], 7)
            self.assertEqual(row["process_run"]["command_return_code"], 7)
            self.assertFalse(row["strict_checks_passed"])
            self.assertEqual(row["measurement"]["failure_counts"]["heap_baseline"], 1)
        self.assertEqual(value["temporary_cleanup"], "complete")
        self.assertFalse((self.work / "private").exists())

    def test_ordinary_and_pure_builds_are_reused_by_their_two_cases(self):
        code, value, calls, prepared = self.run_campaign()
        self.assertEqual(code, 0)
        self.assertEqual([row[2] for row in prepared], ["ordinary", "pure-appkit"])
        builds = [command for command, *_ in calls if "--prepare-external-fixture" in command]
        self.assertEqual(len(builds), 2)
        commands = [command for command, *_ in calls if "--heap-diagnostics" in command]
        directories = [command[command.index("--prepared-fixture-directory") + 1] for command in commands]
        self.assertEqual(directories, [str(prepared[0][0])] * 2 + [str(prepared[1][0])] * 2)
        self.assertNotIn("--heap-control", commands[0])
        self.assertTrue(all("--heap-control" in command for command in commands[1:]))
        self.assertTrue(all(("--reference-idle" in command) == (i == 3) for i, command in enumerate(commands)))
        pure = value["builds"]["pure-appkit"]["manifest"]
        self.assertEqual(pure["build_evidence"]["production_ax_symbol_counts"], {"host": 0, "reader": 0})
        self.assertEqual(set(pure["sources"]), set(CAMPAIGN.fixture_sources("pure-appkit")))
        self.assertTrue(all(name not in pure["sources"] for name in ("QuickFileApp/AXCompatibility.m", "QuickFileApp/AXCompatibility.h")))

    def test_cleanup_unconfirmed_stops_immediately_and_retains_private(self):
        scenarios = (("build-ordinary", True, True, 1, 0),
                     ("build-pure-appkit", True, True, 2, 0),
                     ("measurement", True, True, 3, 1),
                     (None, False, True, 3, 1),
                     ("offline", True, True, 4, 1),
                     (None, True, False, 4, 1))
        for index, (phase, exited, tools, count, case_count) in enumerate(scenarios):
            with self.subTest(phase=phase, fixture_exited=exited, tool_cleanup=tools):
                self.work = Path(self.temporary.name) / ("campaign-" + str(index))
                code, value, calls, _ = self.run_campaign(failed_phase=phase,
                                                        fixture_exited=exited, tool_cleanup=tools)
                self.assertEqual(code, 1)
                self.assertEqual(len(calls), count)
                self.assertEqual(len(value["cases"]), case_count)
                self.assertFalse(value["completed"])
                self.assertEqual(value["temporary_cleanup"], "retained-unconfirmed")
                self.assertTrue((self.work / "private").is_dir())

    def test_build_command_failure_never_starts_measurement(self):
        code, value, calls, _ = self.run_campaign(build_failure="ordinary")
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 1)
        self.assertEqual(value["cases"], [])
        self.assertEqual(value["builds"]["ordinary"]["process_run"]["return_code"], 2)
        self.assertEqual(value["temporary_cleanup"], "complete")

    def test_final_cleanup_failure_cannot_return_success(self):
        code, value, _, _ = self.run_campaign(final_cleanup_failure=True)
        self.assertNotEqual(code, 0)
        self.assertTrue(value["completed"])
        self.assertEqual(value["temporary_cleanup"], "failed")
        self.assertTrue((self.work / "private").is_dir())

    def test_missing_or_invalid_reference_keeps_verified_frozen_and_bridge_in_public_summary(self):
        for failure in ("missing", "invalid-json", "invalid-summary"):
            with self.subTest(failure=failure):
                self.work = Path(self.temporary.name) / ("campaign-" + failure)
                code, value, calls, _ = self.run_campaign(strict_failures=True, reference_failure=failure)
                self.assertEqual(code, 1)
                self.assertEqual(len(calls), 4)
                self.assertEqual(len(value["cases"]), 1)
                row = value["cases"][0]
                self.assertEqual(row["frozen"]["status"], "complete")
                self.assertEqual(row["frozen"]["baseline"], {"leak_nodes": 1, "leak_bytes": 48})
                self.assertEqual(row["bridge"]["status"], "not_needed")
                self.assertIsNone(row["reference"])
                self.assertFalse(row["evidence_checks_passed"])
                self.assertEqual(row["process_run"]["return_code"], 7)
                self.assertFalse(row["strict_checks_passed"])
                self.assertEqual(value["temporary_cleanup"], "retained-unconfirmed")
                self.assertTrue((self.work / "private").is_dir())

    def test_campaign_removes_parent_allocator_environment_from_all_children(self):
        with mock.patch.dict(CAMPAIGN.os.environ, {"MallocScribble": "1", "MallocStackLogging": "1",
                                                  "MallocStackLoggingNoCompact": "1"}):
            _, _, calls, _ = self.run_campaign()
        for _, _, environment, _ in calls:
            self.assertTrue(all(key not in environment for key in ("MallocScribble", "MallocStackLogging", "MallocStackLoggingNoCompact")))


class CampaignPublicBoundaryTests(CampaignBoundaryTests):
    def test_empty_initial_summary_round_trips_with_real_validator(self):
        value = summary()
        self.assertEqual(json.loads(CAMPAIGN.encode_summary(value)), value)

    def test_unknown_and_private_fields_are_rejected_at_nested_boundaries(self):
        value = summary()
        value["builds"] = {mode: {"process_run": process_run(), "manifest": manifest(mode)}
                           for mode in ("ordinary", "pure-appkit")}
        value["cases"] = [case()]
        CAMPAIGN.validate_summary(value)
        targets = ((), ("identity",), ("builds", "ordinary"),
                   ("builds", "ordinary", "process_run"),
                   ("builds", "ordinary", "process_run", "cleanup"),
                   ("builds", "ordinary", "manifest"),
                   ("builds", "pure-appkit", "manifest", "build_evidence"),
                   ("cases", 0), ("cases", 0, "process_run"),
                   ("cases", 0, "measurement"),
                   ("cases", 0, "measurement", "scan_totals", 0),
                   ("cases", 0, "measurement", "failure_counts"),
                   ("cases", 0, "measurement", "activity_counts"))
        for target in targets:
            for field, private in (("raw", "Process 424242: address 0xfeed"),
                                   ("path", "/private/synthetic/raw.memgraph"), ("pid", 424242)):
                with self.subTest(target=target, field=field):
                    candidate = copy.deepcopy(value)
                    nested = candidate
                    for component in target:
                        nested = nested[component]
                    nested[field] = private
                    with self.assertRaises((ValueError, RuntimeError)):
                        CAMPAIGN.encode_summary(candidate)

    def test_pure_build_cannot_claim_production_symbols_or_production_inputs(self):
        value = summary()
        value["builds"]["pure-appkit"] = {"process_run": process_run(), "manifest": manifest("pure-appkit")}
        for change in ("host-symbol", "reader-symbol", "production-input"):
            with self.subTest(change=change):
                candidate = copy.deepcopy(value)
                evidence = candidate["builds"]["pure-appkit"]["manifest"]["build_evidence"]
                if change == "production-input":
                    evidence["link_inputs"]["host"].append("AXCompatibility.o")
                else:
                    evidence["production_ax_symbol_counts"][change.split("-")[0]] = 1
                with self.assertRaises((ValueError, RuntimeError)):
                    CAMPAIGN.encode_summary(candidate)

    def test_global_evidence_pass_cannot_hide_false_case_evidence_when_strict_passes(self):
        value = summary()
        value.update(completed=True, strict_checks_passed=True, evidence_checks_passed=True)
        value["cases"] = [case(name, strict=True) for name in CAMPAIGN.CASES]
        with self.assertRaises(ValueError):
            CAMPAIGN.validate_summary(value)

    def test_strict_pass_requires_both_reported_process_return_codes_to_pass(self):
        value = summary()
        value["cases"] = [case(strict=True)]
        for key in ("return_code", "command_return_code"):
            with self.subTest(key=key):
                candidate = copy.deepcopy(value)
                candidate["cases"][0]["process_run"][key] = 1
                with self.assertRaises(ValueError):
                    CAMPAIGN.validate_summary(candidate)

    def test_measurement_projection_discards_private_unknown_fields(self):
        result = {"reference_validation": True, "scan_mode": "diagnostic", "mode": "product",
                  "reader_mode": "subscribed", "raw": "0xfeed", "pid": 424242,
                  "path": "/private/synthetic/raw.memgraph", "scans": []}
        result.update(measurement()["activity_counts"])
        for row in measurement()["scan_totals"]:
            result["scans"].append({key: value for key, value in row.items()
                                   if key not in ("xpc_roots", "unexpected_roots")} | {
                "raw": "0xfeed", "groups": [{"root_instances": 2, "root_type": "NSXPCConnection", "address": "0xfeed"}]})
        receipt = {"schema": 1, "history_mode": "full-no-compact", "malloc_stack_logging": "unset",
                   "malloc_stack_logging_no_compact": "1", "environments": dict.fromkeys(("host", "reader"),
                   {"malloc_stack_logging": "unset", "malloc_stack_logging_no_compact": "1"}),
                   "path": "/private/synthetic/raw.memgraph"}
        with mock.patch.object(CAMPAIGN, "validate_external_receipt"), mock.patch.object(
                CAMPAIGN, "validation_failure_counts", return_value=measurement()["failure_counts"]):
            projected = CAMPAIGN.project_measurement(result, {"pid": 424242}, receipt, {}, "patched-product")
        encoded = json.dumps(projected)
        for secret in ("0xfeed", "424242", "/private/synthetic", '"raw"', '"path"', '"pid"'):
            self.assertNotIn(secret, encoded)
        self.assertEqual([row["xpc_roots"] for row in projected["scan_totals"]], [2] * 7)


class CampaignSelectionTests(CampaignBoundaryTests):
    def evidence(self, totals, selected):
        by_label = {row["label"]: row for row in totals}
        point = lambda label: {key: by_label[label][key] for key in ("leak_nodes", "leak_bytes")}
        return {"selection": "first-strict-growth" if selected else "no-strict-growth",
                "selected_label": selected, "baseline": point("baseline"),
                "selected": point(selected) if selected else None}

    def collect(self, totals, frozen):
        bridge = {"test": "bridge-boundary"}
        reference = {"test": "reference-boundary"}
        hashes = {label: f"{index + 1:064x}" for index, label in enumerate(CAMPAIGN.HEAP_LABELS)}
        records = Path("synthetic-case/records")
        values = {"frozen-nodes.json": frozen, "bridge-evidence.json": bridge,
                  "reference-validation.json": reference}
        with mock.patch.object(CAMPAIGN, "read_json", side_effect=lambda path, limit: values[path.name]), \
                mock.patch.object(CAMPAIGN, "graph_hash", side_effect=lambda path: hashes[path.stem]) as graph_hash, \
                mock.patch.object(CAMPAIGN, "validate_frozen") as validate_frozen, \
                mock.patch.object(CAMPAIGN, "validate_bridge") as validate_bridge, \
                mock.patch.object(REFERENCE, "validate_summary") as validate_reference:
            result = CAMPAIGN.collect_evidence(records, totals)
            validate_frozen.assert_called_once_with(frozen)
            validate_bridge.assert_called_once_with(bridge, frozen)
            validate_reference.assert_called_once_with(reference, frozen, bridge, graph_hashes=hashes)
            self.assertEqual(graph_hash.call_args_list, [mock.call(records.parent / "fixture/heap" / (label + ".memgraph"))
                                                        for label in CAMPAIGN.HEAP_LABELS])
        self.assertEqual(result, (frozen, bridge, reference))

    def test_seventh_graph_binding_rejection_retains_verified_frozen_and_bridge(self):
        totals = measurement()["scan_totals"]
        frozen = self.evidence(totals, None)
        bridge = {"test": "verified-bridge-boundary"}
        hashes = {label: f"{index + 1:064x}" for index, label in enumerate(CAMPAIGN.HEAP_LABELS)}
        reference = {"checkpoints": [{"label": label, "graph_sha256": hashes[label]}
                                      for label in CAMPAIGN.HEAP_LABELS]}
        reference["checkpoints"][-1]["graph_sha256"] = "f" * 64
        values = {"frozen-nodes.json": frozen, "bridge-evidence.json": bridge,
                  "reference-validation.json": reference}
        destination = {"frozen": None, "bridge": None, "reference": None}
        records = Path("synthetic-case/records")
        # The sidecar's real graph binding is tested separately; simulate its rejection here.
        with mock.patch.object(CAMPAIGN, "read_json", side_effect=lambda path, limit: values[path.name]), \
                mock.patch.object(CAMPAIGN, "graph_hash", side_effect=lambda path: hashes[path.stem]) as graph_hash, \
                mock.patch.object(CAMPAIGN, "validate_frozen"), \
                mock.patch.object(CAMPAIGN, "validate_bridge"), \
                mock.patch.object(REFERENCE, "validate_summary", side_effect=ValueError("synthetic seventh graph mismatch")) as validate_reference:
            with self.assertRaises(ValueError):
                CAMPAIGN.collect_evidence(records, totals, destination)
            validate_reference.assert_called_once_with(reference, frozen, bridge, graph_hashes=hashes)
            self.assertEqual(graph_hash.call_args_list, [mock.call(records.parent / "fixture/heap" / (label + ".memgraph"))
                                                        for label in CAMPAIGN.HEAP_LABELS])
        self.assertEqual(destination, {"frozen": frozen, "bridge": bridge, "reference": None})
        self.assertNotEqual(reference["checkpoints"][-1]["graph_sha256"], hashes[CAMPAIGN.HEAP_LABELS[-1]])

    def test_first_node_or_byte_growth_binds_all_three_sidecars(self):
        for field in ("leak_nodes", "leak_bytes"):
            with self.subTest(field=field):
                totals = measurement()["scan_totals"]
                totals[2][field] += 1
                totals[4][field] += 4
                frozen = self.evidence(totals, totals[2]["label"])
                self.collect(totals, frozen)

    def test_no_strict_growth_accepts_only_no_growth_selection(self):
        totals = measurement()["scan_totals"]
        self.collect(totals, self.evidence(totals, None))
        invalid = self.evidence(totals, totals[1]["label"])
        with self.assertRaises(ValueError):
            self.collect(totals, invalid)

    def test_later_selection_or_changed_checkpoint_totals_are_rejected(self):
        totals = measurement()["scan_totals"]
        totals[1]["leak_nodes"] += 1
        totals[2]["leak_nodes"] += 2
        valid = self.evidence(totals, totals[1]["label"])
        invalid_values = [self.evidence(totals, totals[2]["label"])]
        for checkpoint in ("baseline", "selected"):
            for field in ("leak_nodes", "leak_bytes"):
                invalid = copy.deepcopy(valid)
                invalid[checkpoint][field] += 1
                invalid_values.append(invalid)
        for index, frozen in enumerate(invalid_values):
            with self.subTest(index=index), self.assertRaises(ValueError):
                self.collect(totals, frozen)


class CampaignWorkflowGuardTests(unittest.TestCase):
    FLAGS = ("ax_causal_probe", "heap_diagnostics", "malloc_scribble", "terminal_origin",
             "live_attribution", "install_gate_control", "pure_appkit_control", "frozen_control",
             "settled_baseline_shadow", "reader_exit_control", "scan_timing_control")

    @classmethod
    def setUpClass(cls):
        workflow = (ROOT / ".github/workflows/ax-reference-validation.yml").read_text()
        step = workflow.split("      - name: Reject mixed investigation requests\n", 1)[1]
        script = step.split("          python3 - <<'PY'\n", 1)[1].split("          PY\n", 1)[0]
        cls.guard = compile("\n".join(line[10:] for line in script.splitlines()),
                            ".github/workflows/ax-reference-validation.yml:request-guard", "exec")
        cls.wrapper = (ROOT / ".github/workflows/ax-system-baseline.yml").read_text()

    def run_guard(self, inputs):
        with mock.patch.dict(CAMPAIGN.os.environ, {"AX_REFERENCE_INPUTS": json.dumps(inputs)}):
            exec(self.guard, {})

    def test_direct_dispatch_and_wrapper_reference_defaults_are_accepted(self):
        defaults = {flag: False for flag in self.FLAGS}
        defaults.update(reference_validation=True, scan_mode="diagnostic", receipt_mode="internal")
        for inputs in ({}, {"reference_validation": True}, defaults):
            with self.subTest(inputs=inputs):
                self.run_guard(inputs)

    def test_each_other_investigation_flag_is_rejected(self):
        for flag in self.FLAGS:
            with self.subTest(flag=flag), self.assertRaises(AssertionError):
                self.run_guard({"reference_validation": True, flag: True})

    def test_non_default_modes_unknown_fields_and_false_reference_are_rejected(self):
        inputs = ({"scan_mode": "live"}, {"scan_mode": "unknown"},
                  {"receipt_mode": "external-startup"}, {"receipt_mode": "unknown"},
                  {"unknown": False}, {"reference_validation": False},
                  {"reference_validation": 1}, {"heap_diagnostics": 0}, [], None)
        for value in inputs:
            with self.subTest(value=value), self.assertRaises(AssertionError):
                self.run_guard(value)

    def wrapper_condition(self, job, inputs):
        block = self.wrapper.split("\n  " + job + ":\n", 1)[1]
        condition = block.split("    if: ${{ ", 1)[1].split(" }}", 1)[0]
        condition = re.sub(r"inputs\.([a-z_]+)", lambda match: repr(inputs[match[1]]), condition)
        condition = re.sub(r"!(?!=)", "not ", condition).replace("&&", "and").replace("||", "or")
        return eval(condition, {"__builtins__": {}}, {})

    def test_wrapper_excludes_reference_mode_from_both_existing_jobs(self):
        defaults = {flag: False for flag in self.FLAGS}
        defaults.update(reference_validation=False, scan_mode="diagnostic", receipt_mode="internal")
        self.assertTrue(self.wrapper_condition("ax-system-probe", defaults))
        self.assertTrue(self.wrapper_condition("ax-heap-diagnostics", defaults | {"heap_diagnostics": True}))
        requests = [defaults] + [defaults | {flag: True} for flag in self.FLAGS]
        requests += [defaults | {"scan_mode": "live"}, defaults | {"receipt_mode": "external-startup"}]
        for request in requests:
            for job in ("ax-system-probe", "ax-heap-diagnostics"):
                with self.subTest(job=job, request=request):
                    self.assertFalse(self.wrapper_condition(job, request | {"reference_validation": True}))
        reference = self.wrapper.split("\n  ax-reference-validation:\n", 1)[1]
        self.assertIn("uses: ./.github/workflows/ax-reference-validation.yml", reference)
        self.assertIn("dispatch_inputs: ${{ toJSON(inputs) }}", reference)


if __name__ == "__main__":
    unittest.main()
