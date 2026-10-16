#!/usr/bin/env python3
"""Exercise both real AX destruction branches and scan an owned synthetic fixture.

Exit 77 explicitly means the OS image or existing AX permission does not cover
this test. No permission prompt, system change, installed app or user data access.
--system-baseline disables the product compensation even on unverified images.
Optional ownership/balance probes instrument only the disposable synthetic host.
Successful measurement may report leaks, not verified product compensation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import time
import ax_composition
import ax_startup_baseline
from ax_process import reap_owned
from ax_probe_report import (capture_terminal_snapshot, collect_heap_diagnostics, collect_terminal_snapshot,
                             disassemble_symbols, empty_terminal_snapshot, leak_groups)
from ax_external_receipt import (EXECUTABLES, FIXTURE_SOURCES, INSTALL_ENV, INSTALL_MODES, STARTUP_STAGES, StartupReceiptError,
                                 fixture_hashes, fixture_sources, load_prepared_fixture, startup_failure,
                                 owned_child_receipt, read_procargs, require_fixture_hashes, validate_empty_control_build,
                                 validate_external_receipt, validate_install_gate_build, validate_install_gate_state)

ROOT = Path(__file__).resolve().parents[2]


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def wait_json(path, predicate, processes, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for process in processes:
            if process.poll() is not None:
                raise RuntimeError(f"Fixture process {process.pid} exited: {process.returncode}")
        if path.exists():
            value = json.loads(path.read_text())
            if predicate(value):
                return value
        time.sleep(0.025)
    raise TimeoutError(f"Fixture handshake timed out: {path.name}")


def validate_empty_control_capabilities(host, mode):
    if mode not in ("patched", "pure-appkit") or type(host) is not dict or host.get("empty_control_mode") != mode:
        raise RuntimeError("Empty-control capability mode differs from prepared build")
    if mode == "pure-appkit" and (host.get("enabled") is not False or host.get("status") != "pure-appkit"):
        raise RuntimeError("Pure AppKit capability unexpectedly contains the product patch")
    if mode == "patched" and (host.get("enabled") is not True or host.get("status") != "enabled"):
        raise RuntimeError("Patched empty-control capability did not install the product patch")


def validate_install_gate_capabilities(host, mode):
    if type(host) is not dict:
        raise RuntimeError("Invalid install-gate capability")
    validate_install_gate_state(host.get("install_probe"), mode)
    if (host.get("enabled") is not (mode == "installed")
            or host.get("status") != ("enabled" if mode == "installed" else "probe-preflight-only")):
        raise RuntimeError("Install-gate capability does not match the method state")


def preflight_reason(host, reader, system_baseline=False, empty_control_mode=None, install_gate=None):
    if install_gate:
        validate_install_gate_capabilities(host, install_gate)
    if empty_control_mode:
        validate_empty_control_capabilities(host, empty_control_mode)
    if not system_baseline and host["status"] in ("unsupported-images", "unsupported-architecture"):
        return host["status"]
    if system_baseline:
        if host["enabled"] or host["status"] != "system-baseline":
            raise RuntimeError("System baseline must preserve the unpatched implementation")
    elif empty_control_mode != "pure-appkit" and install_gate != "preflight-only" and not host["enabled"]:
        raise RuntimeError(f"Unexpected installation refusal: {host['status']}")
    if not isinstance(reader.get("trusted"), bool):
        raise RuntimeError("AX reader returned an invalid capability receipt")
    return None if reader["trusted"] else "reader-not-trusted"


def validate_product_scan(entry, baseline=None):
    # The reviewed macOS 26 fixture has a small NSXPCConnection startup baseline.
    # Classify the entire heap and reject target AX groups, unknown roots, missed
    # nodes, and any growth beyond that measured baseline. Never call this zero
    # whole-heap leakage when the baseline itself contains reported nodes.
    if (entry["unclassified_nodes"] != 0 or entry["destroyed_notification_stack_present"]
            or any(group.get("tree_nodes") is None for group in entry["groups"])):
        raise RuntimeError(f"AX leakage or incomplete heap classification: {entry}")
    if any(group["root_type"] != "NSXPCConnection" for group in entry["groups"]):
        raise RuntimeError(f"Unexpected non-AX leak roots: {entry}")
    if baseline is not None:
        roots = lambda value: sum(group["root_instances"] for group in value["groups"])
        if (entry["leak_nodes"] > baseline["leak_nodes"]
                or entry["leak_bytes"] > baseline["leak_bytes"] or roots(entry) > roots(baseline)):
            raise RuntimeError(
                f"Heap leakage grew beyond the startup baseline: baseline={baseline}; current={entry}")


def validate_notifications(receipt, expected_buttons, read_only=False):
    expected = [] if read_only else [1, 1]
    counts = receipt.get("target_notification_counts")
    if (not isinstance(counts, list) or len(counts) != expected_buttons
            or any(value != expected for value in counts)
            or receipt.get("tracked_buttons") != expected_buttons):
        raise RuntimeError(f"Destroyed notifications did not cover each owned button exactly once per observer: {receipt}")
    total = receipt.get("all_notifications")
    unmatched = receipt.get("unmatched_notifications")
    target = receipt.get("notifications")
    if (any(type(value) is not int or value < 0 for value in (total, unmatched, target))
            or target != expected_buttons * len(expected) or total != target + unmatched):
        raise RuntimeError(f"Invalid destroyed notification accounting: {receipt}")


def validate_control_host(receipt):
    keys = ("buttons", "allocatedButtons", "destroyedButtons", "compensations", "mutableCompensations")
    if any(type(receipt.get(key)) is not int or receipt[key] != 0 for key in keys):
        raise RuntimeError(f"Heap control created targets or applied compensation: {receipt}")


def validate_control_reader(receipt, completed=False):
    keys = ("notifications", "all_notifications", "unmatched_notifications", "tracked_buttons")
    if not completed:
        keys += ("buttons", "registrations")
    if (any(type(receipt.get(key)) is not int or receipt[key] != 0 for key in keys)
            or receipt.get("target_notification_counts") != []):
        raise RuntimeError(f"Heap control read targets, registered targets or received notifications: {receipt}")


def validate_malloc_scribble_receipt(receipt, requested):
    expected = "1" if requested == "on" else "unset"
    if (requested not in ("off", "on") or type(receipt) is not dict
            or set(receipt) != {"requested", "host", "reader"}
            or receipt["requested"] != requested
            or receipt["host"] != expected or receipt["reader"] != expected):
        raise RuntimeError("Actual host/reader MallocScribble environment was not confirmed")


def validate_copy_lifetime_host(receipt, expected_copies=None):
    lifetime = receipt.get("copyLifetime")
    keys = ("ordinary", "mutable", "liveOrdinary", "liveMutable", "invalid")
    host_keys = ("destroyedButtons", "compensations", "mutableCompensations")
    if (not isinstance(lifetime, dict)
            or any(type(lifetime.get(key)) is not int or lifetime[key] < 0 for key in keys)
            or any(type(receipt.get(key)) is not int or receipt[key] < 0 for key in host_keys)):
        raise RuntimeError(f"Invalid copy lifetime accounting: {receipt}")
    destroyed = receipt["destroyedButtons"]
    if (lifetime["ordinary"] != destroyed or lifetime["mutable"] != destroyed
            or receipt["compensations"] != lifetime["ordinary"] + lifetime["mutable"]
            or receipt["mutableCompensations"] != lifetime["mutable"]
            or any(lifetime[key] != 0 for key in ("liveOrdinary", "liveMutable", "invalid"))
            or (expected_copies is not None and destroyed != expected_copies)):
        raise RuntimeError(f"Copy lifetime coverage or weak unavailability failed: {receipt}")



class SettledBaselineShadow:
    """Auxiliary current-stack observations; never an ordinary gate input."""

    def __init__(self, records, graphs, idle=False):
        self.records, self.graphs = records, graphs
        self.data = {"schema": 2, "settling_policy": {"max_probes": 6, "min_interval_seconds": 2,
            "deadline_seconds": 15, "tool_timeout_seconds": 5, "graph_capture_timeout_seconds": 15, "consecutive_equal": 2,
            "comparison": "counts-bytes-root-kind-type-instances-tree-nodes", "size_histogram_compared": False},
            "status": "not_settled", "chosen_index": None, "probes": [], "captures": [],
            "errors": [], "environments": {}, "observer_query_policy": "initial-query-only" if idle else "ordinary",
            "timing_perturbed": True, "original_parity": False, "logging_mode": "compact", "history_mode": "current-stacks",
            "original_strict_verdict": "unavailable", "candidate_hypothetical_verdict": "unavailable",
            "baseline_finished_monotonic": None, "settling_started_monotonic": None,
            "first_measurement_cycle_monotonic": None, "last_original_scan_finished_monotonic": None}
        try:
            graphs.mkdir(parents=True)
        except OSError:
            self.error("graph_directory_failed")

    def error(self, reason):
        self.data["errors"].append(reason)

    def save(self):
        try:
            write_json(self.records / "settled-baseline-shadow.json", self.data)
        except Exception:
            self.error("receipt_write_failed")

    @staticmethod
    def signature(entry):
        return (entry["leak_nodes"], entry["leak_bytes"],
                sorted((g["root_kind"], g["root_type"], g["root_instances"], g["tree_nodes"]) for g in entry["groups"]))

    def environment(self, role, process):
        try:
            _, _, actual = read_procargs(process.pid)
            self.data["environments"][role] = {
                key: "unset" if actual.get(key.encode()) is None else
                     "1" if actual[key.encode()] == b"1" else "other"
                for key in ("MallocStackLogging", "MallocStackLoggingNoCompact", "MallocScribble")}
        except Exception:
            self.error("environment_unavailable")

    def capture(self, label, entry):
        row = {"label": label, "status": "failed", "graph_sha256": None,
               "capture_status": "failed", "host_activity_zero": False if label == "auxiliary-late" else None,
               "exit_code": None, "source_label": entry.get("label"), "source_stdout_sha256": entry.get("stdout_sha256"),
               "leak_nodes": entry.get("leak_nodes"), "leak_bytes": entry.get("leak_bytes"),
               "groups": entry.get("groups"), "counts_binding": "requires-offline-verification",
               "start_monotonic": time.monotonic()}
        self.data["captures"].append(row)
        try:
            source_suffix = ".stdout.txt" if entry["label"].startswith("shadow-probe-") else "-original.stdout.txt"
            source = self.records / (entry["label"] + source_suffix)
            source_info = source.lstat()
            if not stat.S_ISREG(source_info.st_mode) or source_info.st_size > 256 * 1024 * 1024:
                raise ValueError("invalid source stdout")
            with source.open("rb") as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() != entry["stdout_sha256"]:
                    raise ValueError("source stdout binding mismatch")
            if label != "auxiliary-late":
                validate_control_host(entry["host"])
                row["host_activity_zero"] = True
            graph = self.graphs / (label + ".memgraph")
            value = capture_terminal_snapshot(self.pid, graph, timeout=15)
            row["exit_code"] = value["capture_exit_code"]
            row["capture_status"] = value["capture_status"]
            if value["capture_status"] != "complete":
                raise RuntimeError("capture unavailable")
            info = graph.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_size > 256 * 1024 * 1024:
                raise ValueError("invalid graph")
            with graph.open("rb") as stream:
                row["graph_sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
            row.update(status="complete", graph_file=graph.name, graph_bytes=info.st_size)
        except Exception:
            self.error("capture_failed")
        row["end_monotonic"] = time.monotonic()
        self.save()

    def settle(self, pid, baseline, checkpoint, warmed):
        self.pid = pid
        previous = None
        try:
            validate_control_reader(warmed)
            validate_control_host(baseline["host"])
            self.capture("auxiliary-original-baseline", baseline)
            self.data["settling_started_monotonic"] = time.monotonic()
            deadline = self.data["settling_started_monotonic"] + 15
            for index in range(6):
                if previous is not None:
                    remaining_interval = previous["end_monotonic"] + 2 - time.monotonic()
                    if remaining_interval > 0:
                        if time.monotonic() + remaining_interval >= deadline:
                            break
                        time.sleep(remaining_interval)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                host = checkpoint(min(5, remaining))
                validate_control_host(host)
                validate_control_reader(warmed)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                started = time.monotonic()
                output = subprocess.run(["leaks", "--noContent", "--groupByType", "--nosources", "--fullStacks", str(pid)],
                                        capture_output=True, text=True, timeout=min(5, remaining))
                ended = time.monotonic()
                label = "shadow-probe-" + str(index)
                payload = output.stdout.encode()
                (self.records / (label + ".stdout.txt")).write_bytes(payload)
                match = re.search(r"(\d+) leaks for (\d+) total leaked bytes", output.stdout)
                if output.returncode not in (0, 1) or not match:
                    raise ValueError("invalid probe")
                groups = leak_groups(output.stdout)
                row = {"label": label, "index": index, "exit_code": output.returncode, "leak_nodes": int(match[1]), "leak_bytes": int(match[2]),
                    "groups": groups, "unclassified_nodes": int(match[1]) - sum(g["tree_nodes"] or 0 for g in groups),
                    "destroyed_notification_stack_present": "_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification" in output.stdout,
                    "stdout_sha256": hashlib.sha256(payload).hexdigest(), "host": host, "reader_warm": warmed,
                    "host_activity_zero": True, "start_monotonic": started, "end_monotonic": ended}
                self.data["probes"].append(row)
                validate_product_scan(row)
                if ended >= deadline:
                    break
                if previous is not None and self.signature(previous) == self.signature(row):
                    self.data.update(status="observed-stable", chosen_index=index)
                    break
                previous = row
        except Exception:
            self.error("settling_failed")
        if self.data["chosen_index"] is None:
            self.error("not_settled")
        else:
            self.capture("auxiliary-candidate", self.data["probes"][self.data["chosen_index"]])
        self.save()

    def finish(self, scans, errors, failed):
        self.data["original_strict_verdict"] = "failed" if failed or errors else "passed"
        index = self.data["chosen_index"]
        if index is not None and not self.data["errors"] and len(scans) == 6 and not failed:
            candidate = self.data["probes"][index]
            scan_labels = {row["label"] for row in scans}
            hypothetical = not any(error["stage"] not in scan_labels for error in errors)
            try:
                validate_product_scan(scans[0])
                for row in scans[1:]:
                    validate_product_scan(row, candidate)
            except Exception:
                hypothetical = False
            self.data["candidate_hypothetical_verdict"] = "passed" if hypothetical else "failed"
        self.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-directory", required=True, type=Path)
    parser.add_argument("--records-directory", required=True, type=Path)
    parser.add_argument("--system-baseline", action="store_true")
    parser.add_argument("--settle-startup-baseline", action="store_true",
                        help="Require bounded zero-target startup stability before the six strict product scans")
    parser.add_argument("--heap-diagnostics", action="store_true", help="Retain local heap graphs and write a bounded offline diff summary; product or install-gate controls only")
    parser.add_argument("--reference-validation", action="store_true", help="Explicit full-history frozen reference investigation using prepared external off fixtures; separate from ordinary CI")
    parser.add_argument("--reference-idle", action="store_true", help="Pure AppKit empty reference control: after the initial empty AX query, skip subsequent AX queries while retaining all seven heap checkpoints")
    parser.add_argument("--heap-control", action="store_true", help="Match the selected product scan checkpoints with an empty window and no target buttons; requires --heap-diagnostics or --malloc-scribble")
    parser.add_argument("--malloc-scribble", choices=("off", "on"), help="Explicitly unset MallocScribble or set it to 1 in both actual fixture processes, with environment receipts; uses ordinary live scans unless --heap-diagnostics is selected")
    parser.add_argument("--prepare-external-fixture", action="store_true", help="Build host/reader once without running them; ordinary binaries unless --empty-control-mode is explicit")
    parser.add_argument("--prepare-install-gate-fixture", action="store_true", help="Prepare one diagnostic host/reader build for both install-gate modes")
    parser.add_argument("--install-gate", choices=INSTALL_MODES, help="Use the prepared external off empty control; live by default, frozen with --heap-diagnostics")
    parser.add_argument("--external-startup-receipt", action="store_true", help="Read owned child startup metadata from a prepared fixture; frozen scans require --install-gate")
    parser.add_argument("--prepared-fixture-directory", type=Path)
    parser.add_argument("--empty-control-mode", choices=("patched", "pure-appkit"), help="Explicit empty-control build/measurement; pure-appkit excludes the production AX implementation; measurement requires external startup receipts, MallocScribble off and --heap-control")
    parser.add_argument("--terminal-origin", action="store_true", help="Capture one later heap graph after all six live scans; requires external startup receipts and MallocScribble off")
    parser.add_argument("--live-attribution", action="store_true", help="Keep six ordinary live scans and compact logging; capture auxiliary graphs after baseline and first node/byte growth; captures change later timing")
    parser.add_argument("--settled-baseline-shadow", action="store_true", help="Independent bounded idle baseline observations; preserves the six original strict scans and perturbs later timing")
    parser.add_argument("--ci-failure-evidence", action="store_true", help="Retain original ordinary stdout and capture one later graph only after all six strict scans complete with a failure; no baseline graph or address diff")
    parser.add_argument("--copy-lifetime", action="store_true", help="Instrument the product fixture with weak copy lifetime tracking; independent product mode only")
    parser.add_argument("--read-only", action="store_true", help="Read AX without subscriptions; requires --system-baseline")
    parser.add_argument("--ownership-trace", action="store_true", help="Trace copy/dealloc in the synthetic host; requires --system-baseline")
    parser.add_argument("--balance-copies", action="store_true", help="Causal experiment: add one autorelease at the traced call sites; requires --ownership-trace")
    parser.add_argument("--expected-appkit-uuid")
    parser.add_argument("--expected-corefoundation-uuid")
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--idle-seconds", type=int, default=2)
    args = parser.parse_args()
    if args.settle_startup_baseline and any((args.system_baseline, args.heap_diagnostics, args.heap_control,
            args.reference_validation, args.reference_idle, args.malloc_scribble, args.empty_control_mode,
            args.install_gate, args.prepare_external_fixture, args.prepare_install_gate_fixture,
            args.external_startup_receipt, args.prepared_fixture_directory, args.terminal_origin,
            args.live_attribution, args.copy_lifetime, args.read_only, args.ownership_trace, args.balance_copies,
            args.settled_baseline_shadow)):
        parser.error("--settle-startup-baseline requires independent ordinary product measurement")
    if args.settled_baseline_shadow and (not args.external_startup_receipt or args.malloc_scribble != "off"
            or any((args.heap_diagnostics, args.reference_validation, args.live_attribution, args.terminal_origin,
                    args.install_gate, args.copy_lifetime, args.system_baseline, args.ci_failure_evidence,
                    args.prepare_external_fixture, args.prepare_install_gate_fixture, args.read_only,
                    args.ownership_trace, args.balance_copies))):
        parser.error("--settled-baseline-shadow requires independent prepared external off ordinary measurement")
    if args.ci_failure_evidence and any((args.system_baseline, args.heap_diagnostics, args.heap_control,
            args.reference_validation, args.reference_idle, args.malloc_scribble, args.empty_control_mode,
            args.install_gate, args.prepare_external_fixture, args.prepare_install_gate_fixture,
            args.external_startup_receipt, args.prepared_fixture_directory, args.terminal_origin,
            args.live_attribution, args.copy_lifetime, args.read_only, args.ownership_trace, args.balance_copies)):
        parser.error("--ci-failure-evidence requires independent ordinary product measurement")
    if args.reference_validation and (not args.heap_diagnostics or not args.external_startup_receipt
            or args.malloc_scribble != "off" or args.install_gate or args.terminal_origin or args.live_attribution
            or args.empty_control_mode not in (None, "pure-appkit")
            or args.prepare_external_fixture or args.prepare_install_gate_fixture):
        parser.error("--reference-validation requires independent prepared external off frozen measurement")
    if args.reference_idle and (not (args.reference_validation or args.settled_baseline_shadow) or not args.heap_control
            or args.empty_control_mode != "pure-appkit"):
        parser.error("--reference-idle requires a pure AppKit empty reference control")
    if args.live_attribution and (not args.external_startup_receipt or args.malloc_scribble != "off"
            or args.heap_diagnostics or args.terminal_origin or args.install_gate or args.empty_control_mode
            or args.prepare_external_fixture or args.prepare_install_gate_fixture):
        parser.error("--live-attribution requires ordinary prepared external off/live measurement")
    if args.prepare_install_gate_fixture:
        if args.install_gate or args.empty_control_mode:
            parser.error("Install-gate preparation cannot select a measurement or empty-control build mode")
        args.prepare_external_fixture = True
    if args.install_gate and (args.prepare_external_fixture or args.empty_control_mode or args.terminal_origin
            or not args.heap_control or not args.external_startup_receipt or args.malloc_scribble != "off"):
        parser.error("--install-gate requires the prepared external off empty control")
    if args.empty_control_mode and not args.prepare_external_fixture and (
            not args.heap_control or not args.external_startup_receipt or args.malloc_scribble != "off" or args.terminal_origin):
        parser.error("--empty-control-mode requires an independent preparation or external off/live heap control without a terminal graph")
    if args.prepare_external_fixture and any((args.malloc_scribble, args.external_startup_receipt,
            args.prepared_fixture_directory, args.system_baseline, args.heap_diagnostics, args.heap_control,
            args.copy_lifetime, args.read_only, args.ownership_trace, args.balance_copies,
            args.expected_appkit_uuid, args.expected_corefoundation_uuid, args.terminal_origin)):
        parser.error("--prepare-external-fixture requires an independent fixture build")
    if args.external_startup_receipt and (not args.malloc_scribble or not args.prepared_fixture_directory
            or (args.heap_diagnostics and not (args.install_gate or args.reference_validation))
            or any((args.system_baseline, args.copy_lifetime, args.read_only,
                    args.ownership_trace, args.balance_copies, args.expected_appkit_uuid, args.expected_corefoundation_uuid))):
        parser.error("external startup receipts require a prepared fixture; frozen scans require --install-gate")
    if args.prepared_fixture_directory and not args.external_startup_receipt:
        parser.error("--prepared-fixture-directory requires --external-startup-receipt")
    if args.terminal_origin and (not args.external_startup_receipt or args.malloc_scribble != "off"):
        parser.error("--terminal-origin requires external startup receipts with --malloc-scribble off")
    if args.malloc_scribble and args.system_baseline:
        parser.error("--malloc-scribble requires product mode")
    if args.copy_lifetime and any((args.system_baseline, args.heap_diagnostics, args.heap_control,
                                   args.ownership_trace, args.read_only, args.malloc_scribble)):
        parser.error("--copy-lifetime requires independent product mode without other probes")
    if args.heap_control and (not (args.heap_diagnostics or args.malloc_scribble) or args.system_baseline):
        parser.error("--heap-control requires --heap-diagnostics or --malloc-scribble and cannot use --system-baseline")
    if args.heap_diagnostics and args.system_baseline:
        parser.error("--heap-diagnostics requires product mode")
    if args.read_only and not args.system_baseline:
        parser.error("--read-only requires --system-baseline")
    if args.ownership_trace and (not args.system_baseline or args.read_only):
        parser.error("--ownership-trace requires subscribed --system-baseline")
    if args.balance_copies and not args.ownership_trace:
        parser.error("--balance-copies requires --ownership-trace")
    if args.balance_copies and not (args.expected_appkit_uuid and args.expected_corefoundation_uuid):
        parser.error("--balance-copies requires the AppKit/CoreFoundation UUIDs from the reviewed trace")
    if args.ownership_trace and os.uname().machine != "arm64":
        parser.error("system instruction decoding currently requires arm64")
    if not 1 <= args.cycles <= 30 or not 2 <= args.idle_seconds <= 120:
        parser.error("cycles must be 1...30 and idle-seconds 2...120")
    if not args.system_baseline and (args.cycles != 3 or args.idle_seconds != 2):
        parser.error("custom measurement windows require --system-baseline")
    work, records = args.work_directory.resolve(), args.records_directory.resolve()
    work.relative_to(ROOT / ".build/Temporary")
    work.mkdir(parents=True, exist_ok=False)
    records.mkdir(parents=True, exist_ok=False)
    if args.ci_failure_evidence:
        write_json(records / "failure-capture.json", {"status": "not_attempted", "exit_code": None,
                   "after_label": None, "graph_sha256": None})
    state = work / "state"
    state.mkdir()
    graphs = work / "heap"
    if args.heap_diagnostics or args.terminal_origin or args.live_attribution:
        graphs.mkdir()
    app = work / "AXCompatibilityFixture.app"
    executable = app / "Contents/MacOS/AXCompatibilityFixture"
    reader_executable = work / "ax-reader"
    build_mode = "install-gate" if args.prepare_install_gate_fixture or args.install_gate else args.empty_control_mode or "ordinary"
    sources = fixture_sources(build_mode)
    commands = []

    def run(command, timeout=60):
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        commands.append({"command": list(map(str, command)), "exit_code": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        write_json(records / "commands.json", commands)
        result.check_returncode()
        return result

    source_hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources}
    if args.external_startup_receipt:
        prepared = args.prepared_fixture_directory.resolve()
        prepared.relative_to(ROOT / ".build/Temporary")
        expected_hashes = load_prepared_fixture(prepared, source_hashes, build_mode)
        prepared_app = prepared / app.name
        if prepared_app.is_symlink() or any(path.is_symlink() for path in prepared_app.rglob("*")):
            raise RuntimeError("Prepared fixture contains symbolic links")
        shutil.copytree(prepared_app, app)
        shutil.copy2(prepared / "ax-reader", reader_executable)
        require_fixture_hashes(work, expected_hashes)
    else:
        executable.parent.mkdir(parents=True)
        common = ["xcrun", "clang", "-O2"]
        if build_mode != "pure-appkit":
            common += ["-I", str(ROOT / "QuickFileApp")]
        if args.empty_control_mode:
            common.append("-DQUICKFILE_AX_EMPTY_CONTROL")
        if build_mode == "install-gate":
            common.append("-DQUICKFILE_AX_INSTALL_PROBE")
        if build_mode == "pure-appkit":
            common.append("-DQUICKFILE_AX_PURE_APPKIT_CONTROL")
        if args.malloc_scribble:
            common.append("-DQUICKFILE_AX_MALLOC_RECEIPT")
        if args.copy_lifetime:
            common.append("-DQUICKFILE_AX_COPY_LIFETIME")
        production_objects = []
        if build_mode != "pure-appkit":
            run(common + ["-fno-objc-arc", "-c", str(ROOT / sources[0]), "-o", str(work / "AXCompatibility.o")])
            production_objects.append(str(work / "AXCompatibility.o"))
        probe_arguments = []
        if args.ownership_trace:
            sources.append("Scripts/Investigations/AXOwnershipProbe.m")
            run(common + ["-fno-objc-arc", "-c", str(ROOT / sources[-1]), "-o", str(work / "AXOwnershipProbe.o")])
            probe_arguments = [f"-DQUICKFILE_AX_OWNERSHIP_PROBE={2 if args.balance_copies else 1}", str(work / "AXOwnershipProbe.o")]
        run(common + ["-fobjc-arc", "-framework", "AppKit", "-framework", "ApplicationServices",
                      str(ROOT / FIXTURE_SOURCES[0]), *production_objects, *probe_arguments, "-o", str(executable)])
        run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library",
             *(["-DQUICKFILE_AX_MALLOC_RECEIPT", "-module-cache-path", str(work / "swift-module-cache")]
               if args.malloc_scribble else ["-module-cache-path", str(work / "swift-module-cache")]
               if args.prepare_external_fixture else []), str(ROOT / FIXTURE_SOURCES[1]),
             "-o", str(reader_executable)])
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "local.quickfile.tests.ax-compatibility", "CFBundleName": "AXCompatibilityFixture",
            "CFBundleExecutable": "AXCompatibilityFixture", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"}))
        entitlements = work / "entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
        run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app)])
    if args.prepare_external_fixture:
        manifest = {"schema": 3 if build_mode == "install-gate" else 2 if args.empty_control_mode else 1, "build_mode": build_mode, "sources": source_hashes,
                    "executables": fixture_hashes(work)}
        if build_mode == "install-gate":
            presence = {}
            for role, name in EXECUTABLES.items():
                symbols = run(["xcrun", "nm", "-j", str(work / name)]).stdout.splitlines()
                if "_main" not in symbols:
                    raise RuntimeError("Install-gate executable symbol table unavailable")
                presence[role] = "_QuickFileAXInstallProbeGate" in symbols
            definitions = [flag[2:] for flag in common if flag.startswith("-D")]
            manifest["build_evidence"] = {
                "link_inputs": {"host": [FIXTURE_SOURCES[0]] + [Path(path).name for path in production_objects], "reader": [FIXTURE_SOURCES[1]]},
                "compile_definitions": {"production": definitions, "host": definitions, "reader": []},
                "gate_symbol_present": presence}
            validate_install_gate_build(manifest["build_evidence"])
        if args.empty_control_mode:
            counts = {}
            for role, name in EXECUTABLES.items():
                symbols = run(["xcrun", "nm", "-j", str(work / name)]).stdout.splitlines()
                if "_main" not in symbols:
                    raise RuntimeError("Empty-control executable symbol table unavailable")
                production = {symbol for symbol in symbols if symbol.startswith(("_QuickFileInstallAXCompatibility", "QuickFileInstallAXCompatibility", "_QuickFileAX", "QuickFileAX"))}
                counts[role] = len(production)
                if role == "host" and build_mode == "patched" and not {
                        "_QuickFileInstallAXCompatibility", "_QuickFileAXCompatibilityStatus",
                        "_QuickFileAXCompensatedCopies", "_QuickFileAXCompensatedMutableCopies"} <= production:
                    raise RuntimeError("Patched empty-control build is missing production exports")
            manifest["build_evidence"] = {
                "link_inputs": {"host": [FIXTURE_SOURCES[0]] + [Path(path).name for path in production_objects],
                                "reader": [FIXTURE_SOURCES[1]]},
                "production_ax_symbol_counts": counts}
            validate_empty_control_build(manifest["build_evidence"], build_mode)
        write_json(work / "fixture-build.json", manifest)
        write_json(records / "fixture-build.json", manifest)
        print(json.dumps(manifest))
        return 0
    external_receipt = None
    startup_failures = []
    if args.external_startup_receipt:
        external_receipt = {"receipt_mode": "external-startup", "requested": args.malloc_scribble,
                            "host": None, "reader": None, "executables": expected_hashes,
                            "binary_reuse_verified": False}
        if args.install_gate:
            external_receipt["install_gate"] = args.install_gate
        write_json(records / "external-startup.json", external_receipt)
        write_json(records / "startup-failures.json", startup_failures)
    environment = dict(os.environ)
    environment.pop("QUICKFILE_DISABLE_AX_COMPATIBILITY", None)
    # Preserve the reader's existing inherited environment by default. The paired
    # experiment changes only MallocScribble, not its stack-logging behavior.
    reader_environment = dict(os.environ) if args.malloc_scribble else None
    allocator_receipt = {"requested": args.malloc_scribble, "host": "missing", "reader": "missing"}
    if args.malloc_scribble:
        for target_environment in (environment, reader_environment):
            target_environment.pop("MallocScribble", None)
            if args.malloc_scribble == "on":
                target_environment["MallocScribble"] = "1"
        write_json(records / "malloc-scribble.json", allocator_receipt)
    if args.install_gate:
        for target_environment in (environment, reader_environment):
            target_environment[INSTALL_ENV] = args.install_gate
    host_arguments = ["--system-baseline"] if args.system_baseline else []
    capability = subprocess.run([str(executable), "--capabilities", *host_arguments], env=environment,
                                capture_output=True, text=True, check=True, timeout=15)
    capabilities = json.loads(capability.stdout)
    reader_capability = subprocess.run([str(reader_executable), "--capabilities"],
                                       env=reader_environment if args.malloc_scribble else environment,
                                       capture_output=True, text=True, check=True, timeout=15)
    reader_capabilities = json.loads(reader_capability.stdout)
    if args.balance_copies and capabilities["images"] != {
            "AppKit": args.expected_appkit_uuid, "CoreFoundation": args.expected_corefoundation_uuid}:
        raise RuntimeError("Diagnostic balance refused: system images differ from the reviewed trace")
    write_json(records / "inputs.json", {"capabilities": capabilities, "reader_capabilities": reader_capabilities,
        "baseline_protocol": ax_startup_baseline.PROTOCOL if args.settle_startup_baseline else "immediate",
        "system": run(["sw_vers"]).stdout,
        "sources": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources}})
    reason = preflight_reason(capabilities, reader_capabilities, args.system_baseline, args.empty_control_mode, args.install_gate)
    if reason:
        receipt = {"coverage": "not-covered", "reason": reason,
                   "host": capabilities, "reader": reader_capabilities}
        if args.heap_diagnostics or args.malloc_scribble:
            receipt["mode"] = "heap-control" if args.heap_control else "product"
            receipt["scan_mode"] = "diagnostic" if args.heap_diagnostics else "live"
        if args.copy_lifetime:
            receipt.update(mode="copy-lifetime", instrumented=True)
        if args.empty_control_mode:
            receipt["empty_control_mode"] = args.empty_control_mode
        if args.ci_failure_evidence:
            write_json(records / "result.json", receipt)
        print(json.dumps(receipt))
        return 77
    environment.update(MallocStackLogging="1", MallocStackLoggingNoCompact="1")
    if args.heap_diagnostics:
        # Full frozen histories must preserve free/reallocation generations.
        # MallocStackLogging would take precedence over NoCompact if both were set.
        environment.pop("MallocStackLogging")
    if args.reference_validation:
        # This independent frozen protocol also pins the reader environment.
        # Ordinary measurements retain their existing logging configuration.
        reader_environment.pop("MallocStackLogging", None)
        reader_environment["MallocStackLoggingNoCompact"] = "1"
    reference_environment = {}
    checkpoint_windows = []
    results = []
    startup_scans = []
    validation_errors = []
    checkpoints = []
    copy_lifetime_hosts = []
    expected_registrations = 0 if args.read_only else 20
    host = reader = None
    observer_exited = None
    sequence = reader_sequence = 0
    terminal_snapshot = empty_terminal_snapshot() if args.terminal_origin else None
    live_captures = []
    startup_baseline = ax_startup_baseline.empty() if args.settle_startup_baseline else None
    shadow = SettledBaselineShadow(records, records / "shadow", args.reference_idle) if args.settled_baseline_shadow else None
    with (records / "host.log").open("w") as host_log, (records / "reader.log").open("w") as reader_log:
        def validate(stage, validator, *values):
            # Assertion failures must not discard later lifecycle evidence. They
            # remain fatal even if a subsequent scan returns to the baseline.
            try:
                validator(*values)
            except Exception as error:
                if isinstance(error, RuntimeError):
                    validation_errors.append({"stage": stage, "message": str(error)})
                if stage in STARTUP_STAGES:
                    startup_failures.append(startup_failure(stage, error))
                    write_json(records / "startup-failures.json", startup_failures)
                if not isinstance(error, RuntimeError):
                    raise
                write_json(records / "validation-errors.json", validation_errors)

        def record_copy_lifetime_host(receipt, expected_copies=None):
            copy_lifetime_hosts.append(receipt)
            write_json(records / "copy-lifetime-hosts.json", copy_lifetime_hosts)
            validate(f"copy-lifetime-host-{receipt['sequence']}", validate_copy_lifetime_host, receipt, expected_copies)

        def command(action, expected_copies=None, timeout=15):
            nonlocal sequence
            sequence += 1
            write_json(state / "command.json", {"sequence": sequence, "action": action, "count": 10})
            receipt = wait_json(state / "ready.json", lambda value: value["sequence"] == sequence, [host],
                                **({"timeout": timeout} if timeout != 15 else {}))
            if args.heap_control and timeout == 15:
                validate(f"control-host-{sequence}", validate_control_host, receipt)
            if args.install_gate:
                validate(f"install-gate-host-{sequence}", validate_install_gate_state, receipt.get("install_probe"), args.install_gate)
            if args.copy_lifetime:
                record_copy_lifetime_host(receipt, expected_copies)
            return receipt

        def observe():
            nonlocal reader_sequence
            reader_sequence += 1
            write_json(state / "reader-command.json", {"sequence": reader_sequence})
            receipt = wait_json(state / "reader-ready.json", lambda value: value["sequence"] == reader_sequence, [host, reader])
            if args.malloc_scribble and reader_sequence == 1 and not args.external_startup_receipt:
                record_allocator_environment("reader", receipt)
                validate("malloc-scribble", validate_malloc_scribble_receipt, allocator_receipt, args.malloc_scribble)
            if args.heap_control:
                validate(f"control-reader-{reader_sequence}", validate_control_reader, receipt)
            return receipt

        def record_allocator_environment(role, receipt):
            value = receipt.get("malloc_scribble", "missing")
            allocator_receipt[role] = value if value in ("unset", "1", "other", "missing") else "other"
            write_json(records / "malloc-scribble.json", allocator_receipt)

        def record_external_environment(role, process, path, child_environment):
            value = owned_child_receipt(process, path, child_environment, args.malloc_scribble, expected_hashes[role], args.install_gate)
            external_receipt[role] = value
            allocator_receipt[role] = value["malloc_scribble"]
            write_json(records / "external-startup.json", external_receipt)
            write_json(records / "malloc-scribble.json", allocator_receipt)
            if shadow:
                shadow.environment(role, process)
            if args.reference_validation:
                _, _, actual = read_procargs(process.pid)
                if (process.poll() is not None or actual.get(b"PATH") != os.fsencode(child_environment["PATH"])
                        or actual.get(b"MallocStackLogging") is not None
                        or actual.get(b"MallocStackLoggingNoCompact") != b"1"):
                    raise RuntimeError("Reference fixture full-history startup environment was not confirmed")
                reference_environment[role] = {"malloc_stack_logging": "unset", "malloc_stack_logging_no_compact": "1"}

        def finish_external_receipt():
            for directory, reason in ((prepared, "prepared_hash"), (work, "working_hash")):
                try:
                    require_fixture_hashes(directory, expected_hashes)
                except OSError as error:
                    # Preserve the original I/O exception and execution/cleanup
                    # path; only attach an allowlisted diagnostic reason.
                    error._startup_hash_reason = reason
                    raise
                except RuntimeError as error:
                    raise StartupReceiptError(reason, str(error)) from None
            external_receipt["binary_reuse_verified"] = True
            write_json(records / "external-startup.json", external_receipt)
            try:
                validate_external_receipt(external_receipt, args.malloc_scribble, expected_hashes, args.install_gate)
            except RuntimeError as error:
                raise StartupReceiptError("receipt_incomplete", str(error)) from None

        def scan(label, host_state, *, startup=False, timeout=60):
            if args.copy_lifetime:
                # Preserve commands evaluated at scan call sites. This separate
                # probe measures weak availability without sampling the heap.
                return
            started = time.monotonic()
            target = str(host.pid)
            if args.heap_diagnostics:
                graph = graphs / f"{label}.memgraph"
                capture = subprocess.run(["leaks", "--noContent", "--fullStacks", "--fullStackHistory", f"--outputGraph={graph}", target],
                                         capture_output=True, text=True, timeout=60)
                (graphs / f"{label}-capture.txt").write_text(capture.stdout + capture.stderr)
                if capture.returncode not in (0, 1) or not graph.is_file():
                    raise RuntimeError("Diagnostic heap graph capture was unavailable")
                if args.reference_validation:
                    checkpoint_windows.append({"label": label, "phase": label,
                        "start_monotonic": started, "end_monotonic": time.monotonic()})
                # --outputGraph suppresses the text report. Decode that same
                # snapshot offline; do not sample the live heap a second time.
                target = str(graph)
            result = subprocess.run(["leaks", "--noContent", "--groupByType", "--nosources", "--fullStacks", target],
                                    capture_output=True, text=True, timeout=timeout)
            completed = time.monotonic() if args.live_attribution else None
            (records / f"{label}-leaks.txt").write_text(result.stdout + result.stderr)
            if args.ci_failure_evidence or startup:
                (records / f"{label}-original.stdout.txt").write_bytes(result.stdout.encode())
            elif shadow:
                try:
                    (records / f"{label}-original.stdout.txt").write_bytes(result.stdout.encode())
                except OSError:
                    shadow.error("stdout_write_failed")
            match = re.search(r"(\d+) leaks for (\d+) total leaked bytes", result.stdout)
            entry = {"label": label, "host": host_state, "exit_code": result.returncode,
                     "leak_nodes": int(match[1]) if match else None, "leak_bytes": int(match[2]) if match else None,
                     "destroyed_notification_stack_present": "_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification" in result.stdout}
            entry["groups"] = leak_groups(result.stdout)
            if args.ci_failure_evidence or shadow or startup:
                entry["stdout_sha256"] = hashlib.sha256(result.stdout.encode()).hexdigest()
            entry["unclassified_nodes"] = int(match[1]) - sum(group["tree_nodes"] or 0 for group in entry["groups"]) if match else None
            entry["scan_duration_seconds"] = round(time.monotonic() - started, 3)
            entry["since_observer_exit_seconds"] = round(started - observer_exited, 3) if observer_exited is not None else None
            if not startup:
                results.append(entry)
                write_json(records / "scans.json", results)
            else:
                startup_scans.append(entry)
                write_json(records / "startup-scans.json", startup_scans)
            if not match or result.returncode not in (0, 1):
                raise RuntimeError(f"Full-heap scan was unavailable: {entry}")
            if startup:
                validate_control_host(host_state)
                validate_product_scan(entry)
                entry["startup_signature"] = ax_startup_baseline.fingerprint(
                    entry, ax_composition.grouped_composition(result.stdout))
                return entry
            if not args.system_baseline:
                validate(label, validate_product_scan, entry, results[0] if label != "baseline" else None)
            if args.live_attribution:
                # Preserve original stdout separately from stderr for binding.
                # No auxiliary capture precedes the ordinary baseline scan.
                (records / (label + "-live.stdout.txt")).write_text(result.stdout)
                growth = label != "baseline" and any(entry[key] > results[0][key] for key in ("leak_nodes", "leak_bytes"))
                if label == "baseline" or growth and len(live_captures) == 1:
                    from ax_frozen_nodes import capture_live_point
                    live_captures.append(capture_live_point(host.pid, label, graphs, records, completed))
                    write_json(records / "live-captures.json", live_captures)

        try:
            host = subprocess.Popen([str(executable), str(state), *host_arguments], env=environment, stdout=host_log, stderr=host_log)
            initial = wait_json(state / "ready.json", lambda value: value["sequence"] == 0, [host])
            if args.install_gate:
                write_json(records / "install-gate-initial.json", initial.get("install_probe"))
                validate("install-gate-host-0", validate_install_gate_state, initial.get("install_probe"), args.install_gate)
            if args.external_startup_receipt:
                validate("external-startup-host", record_external_environment, "host", host, executable, environment)
            elif args.malloc_scribble:
                record_allocator_environment("host", initial)
            if args.heap_control:
                validate("control-host-0", validate_control_host, initial)
            if args.copy_lifetime:
                record_copy_lifetime_host(initial)
            if args.system_baseline:
                scan("baseline", initial)
            reader_arguments = ["--read-only"] if args.read_only else []
            reader = subprocess.Popen([str(reader_executable), str(host.pid), str(executable), str(state), *reader_arguments],
                                      env=reader_environment, stdout=reader_log, stderr=reader_log)
            if args.external_startup_receipt:
                validate("external-startup-reader", record_external_environment, "reader", reader, reader_executable, reader_environment)
            if not args.system_baseline:
                # Establish AX/XPC setup before the baseline, with no owned test
                # buttons yet. All target destruction remains after this scan.
                warmed = observe()
                if not args.heap_control and (warmed["buttons"] or warmed["registrations"] or warmed["notifications"]):
                    raise RuntimeError(f"AX baseline warm-up was not empty: {warmed}")
                if startup_baseline is not None:
                    validate_control_reader(warmed)
                    def startup_measure(index, deadline):
                        if reader.poll() is not None:
                            raise RuntimeError("AX reader exited during startup observation")
                        empty_host = command("checkpoint", timeout=min(5, deadline - time.monotonic()))
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise RuntimeError("Startup checkpoint exceeded the fixed deadline")
                        # Every sample shares the fixed startup deadline. A
                        # separate short tool timeout can discard a valid first
                        # scan while most of that total budget is still unused.
                        return scan(f"startup-{index}", empty_host, startup=True, timeout=remaining)
                    baseline = ax_startup_baseline.settle(startup_measure,
                        lambda value: write_json(records / "startup-baseline.json", value), startup_baseline)
                    # Reuse the selected scan byte-for-byte; a later capture must
                    # not silently replace the established measurement baseline.
                    source = records / (baseline["label"] + "-original.stdout.txt")
                    (records / "baseline-original.stdout.txt").write_bytes(source.read_bytes())
                    (records / "baseline-leaks.txt").write_bytes(
                        (records / (baseline["label"] + "-leaks.txt")).read_bytes())
                    baseline = {key: value for key, value in baseline.items() if key != "startup_signature"}
                    baseline["label"] = "baseline"
                    results.append(baseline)
                    write_json(records / "scans.json", results)
                else:
                    scan("baseline", command("checkpoint"))
                if shadow:
                    shadow.data["baseline_finished_monotonic"] = time.monotonic()
                    shadow.settle(host.pid, results[0], lambda timeout: command("checkpoint", timeout=timeout), warmed)
            for cycle in range(1, args.cycles + 1):
                if shadow and cycle == 1:
                    shadow.data["first_measurement_cycle_monotonic"] = time.monotonic()
                added = command("checkpoint" if args.heap_control else "add")
                if args.heap_diagnostics and cycle == 1:
                    # Split button construction from the first AX subscription;
                    # this remains subject to the original empty-window baseline.
                    scan("added-10", added)
                observed = warmed if args.reference_idle else observe()
                if not args.heap_control and (observed["buttons"] != 10 or observed["registrations"] != expected_registrations):
                    raise RuntimeError(f"AX registrations incomplete: {observed}")
                if not args.system_baseline and cycle == 1:
                    # Locate setup growth without replacing the empty baseline
                    # or destroying any target button before the first scan.
                    scan("registered-10", command("checkpoint"))
                removed = command("checkpoint" if args.heap_control else "remove")
                if not args.reference_idle:
                    observe()
                if not args.heap_control and removed["destroyedButtons"] != cycle * 10:
                    raise RuntimeError(f"Buttons did not deallocate: {removed}")
                checkpoint_keys = (("buttons", "allocatedButtons", "destroyedButtons", "compensations", "mutableCompensations")
                                   if args.heap_control else ("allocatedButtons", "destroyedButtons", "ownership"))
                if args.copy_lifetime:
                    checkpoint_keys += ("copyLifetime",)
                checkpoints.append({key: removed[key] for key in checkpoint_keys if key in removed})
                if not args.system_baseline or cycle in {1, 3, args.cycles}:
                    scan(f"removed-{cycle * 10}", removed)
            (state / "stop-reader").touch()
            reader.wait(timeout=5)
            if reader.returncode != 0:
                raise RuntimeError("AX observer did not exit successfully")
            notification_receipt = json.loads((state / "reader-completed.json").read_text())
            write_json(records / "notifications.json", notification_receipt)
            if args.heap_control:
                validate("notifications", validate_control_reader, notification_receipt, True)
            else:
                validate("notifications", validate_notifications, notification_receipt, args.cycles * 10, args.read_only)
            notification_count = notification_receipt.get("notifications")
            observer_exited = time.monotonic()
            if args.idle_seconds > 10:
                time.sleep(10)
                scan("observer-exited-idle10", command("checkpoint"))
            while True:
                remaining = args.idle_seconds - (time.monotonic() - observer_exited)
                if remaining <= 0:
                    break
                time.sleep(min(1, remaining))
            final = command("checkpoint", 30 if args.copy_lifetime else None)
            scan("observer-exited", final)
            if shadow:
                shadow.data["last_original_scan_finished_monotonic"] = time.monotonic()
            if args.terminal_origin:
                # The ordinary six scans are finished. This later capture never
                # changes their totals or strict validation results.
                terminal_snapshot = capture_terminal_snapshot(host.pid, graphs / "terminal.memgraph")
            if shadow:
                shadow.capture("auxiliary-late", results[-1])
            ordinary = final["compensations"] - final["mutableCompensations"]
            if args.system_baseline:
                if final["compensations"] != 0 or final["mutableCompensations"] != 0:
                    raise RuntimeError("System baseline unexpectedly applied compensation")
                summary = {"coverage": "measured", "mode": "diagnostic-balance" if args.balance_copies else "system-baseline",
                           "reader_mode": "read-only" if args.read_only else "subscribed",
                           "patch_enabled": args.balance_copies, "product_compensation_enabled": False,
                           "destroyed_buttons": final["destroyedButtons"],
                           "notifications": notification_count, "notification_receipt": notification_receipt,
                           "images": capabilities["images"],
                           "idle_seconds": args.idle_seconds, "instrumented": args.ownership_trace,
                           "checkpoints": checkpoints,
                           "scans": [{key: value for key, value in scan.items() if key != "host"} for scan in results],
                           "scope": "synthetic AppKit lifecycle with product compensation disabled; "
                                    + ("ownership tracking and heap scans use the same instrumented host; an uninstrumented heap control requires a separate run"
                                       if args.ownership_trace else
                                       "heap scans use an uninstrumented host; ownership tracking requires a separate run")
                                    + "; not installed-app validation"}
                if args.ownership_trace:
                    ownership = final["ownership"]
                    if ownership["duplicateLiveAddresses"] or ownership["offMainHits"] or not ownership["created"]:
                        raise RuntimeError(f"Ownership trace was incomplete: {ownership}")
                    summary["ownership"] = ownership
                    summary["system_code"] = disassemble_symbols(state, work, records)
                    if args.balance_copies and (ownership["live"] or any(
                            group["destroyed_return_offsets"] for entry in results for group in entry.get("groups", []))):
                        raise RuntimeError(f"Diagnostic balance left live target arrays or AX leak groups: {ownership}")
            elif args.heap_control:
                summary = {"coverage": "measured", "mode": "heap-control", "reader_mode": "subscribed",
                           "destroyed_buttons": final["destroyedButtons"],
                           "allocated_buttons": final["allocatedButtons"], "buttons": final["buttons"],
                           "notifications": notification_count, "notification_receipt": notification_receipt,
                           "ordinary_compensations": ordinary, "mutable_compensations": final["mutableCompensations"],
                           "ax_leak_nodes": None if validation_errors else 0,
                           "baseline_leak_nodes": results[0]["leak_nodes"],
                           "baseline_leak_bytes": results[0]["leak_bytes"],
                           "leak_nodes": results[-1]["leak_nodes"], "leak_bytes": results[-1]["leak_bytes"],
                           "images": capabilities["images"], "checkpoints": checkpoints,
                           "scans": [{key: value for key, value in scan.items() if key != "host"} for scan in results],
                           "scope": "empty-window control with the "
                                    + ("diagnostic" if args.heap_diagnostics else "ordinary live")
                                    + " product checkpoint sequence and strict heap guard; "
                                    "application AX reads and observers active; zero target buttons; no product destruction coverage"}
            elif args.copy_lifetime:
                summary = {"coverage": "passed", "mode": "copy-lifetime", "instrumented": True,
                           "copy_lifetime": final.get("copyLifetime"), "checkpoints": checkpoints,
                           "destroyed_buttons": final["destroyedButtons"],
                           "notifications": notification_count, "notification_receipt": notification_receipt,
                           "ordinary_compensations": ordinary, "mutable_compensations": final["mutableCompensations"],
                           "images": capabilities["images"], "idle_seconds": args.idle_seconds,
                           "scope": "synthetic AppKit fixture with diagnostic weak copy tracking; "
                                    "verifies two compensated copy branches and destroyed notifications; "
                                    "requires that weak targets cannot be acquired after the existing autorelease pool drains; "
                                    "this does not establish completed object destruction; "
                                    "not an installed-app or VoiceOver test"}
            else:
                if ordinary < 30 or final["mutableCompensations"] < 30:
                    validation_errors.append({"stage": "compensation-branches",
                        "message": f"Both destruction branches were not covered: {final}, notifications={notification_count}"})
                summary = {"coverage": "passed", "destroyed_buttons": final["destroyedButtons"],
                           "notifications": notification_count, "notification_receipt": notification_receipt,
                           "ordinary_compensations": ordinary,
                           "mutable_compensations": final["mutableCompensations"],
                           "ax_leak_nodes": None if validation_errors else 0,
                           "baseline_leak_nodes": results[0]["leak_nodes"],
                           "baseline_leak_bytes": results[0]["leak_bytes"],
                           "leak_nodes": results[-1]["leak_nodes"], "leak_bytes": results[-1]["leak_bytes"],
                           "scans": [{key: value for key, value in scan.items() if key != "host"} for scan in results],
                           "scope": "optimized production implementation, synthetic AppKit fixture; requires absent target AX groups and no increase over the zero-target AX startup baseline; not an installed-app or VoiceOver test"}
            if args.ci_failure_evidence and validation_errors:
                # Every original strict scan and notification check is finished.
                # This later graph cannot identify baseline allocations or turn
                # the original grouped reports into an address-level difference.
                graph = records / "terminal.memgraph"
                captured = capture_terminal_snapshot(host.pid, graph, timeout=15)
                failure_capture = {"status": captured["capture_status"],
                    "exit_code": captured["capture_exit_code"], "after_label": "observer-exited",
                    "graph_sha256": None}
                if failure_capture["status"] == "complete":
                    try:
                        graph_info = graph.lstat()
                        if not stat.S_ISREG(graph_info.st_mode) or graph_info.st_size > 256 * 1024 * 1024:
                            raise ValueError("Failure graph exceeds the bounded input limit")
                        with graph.open("rb") as stream:
                            failure_capture["graph_sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
                    except (OSError, ValueError):
                        failure_capture["status"] = "failed"
                write_json(records / "failure-capture.json", failure_capture)
            if args.external_startup_receipt:
                validate("external-startup-complete", finish_external_receipt)
                summary["receipt_mode"] = "external-startup"
            if args.empty_control_mode:
                summary["empty_control_mode"] = args.empty_control_mode
                summary["product_compensation_enabled"] = args.empty_control_mode == "patched"
                summary["scope"] += "; " + args.empty_control_mode + " empty control; no product destruction coverage"
            if args.install_gate:
                summary["install_gate"] = args.install_gate
                summary["product_compensation_enabled"] = args.install_gate == "installed"
                summary["scope"] += "; install-gate empty control; no product destruction coverage"
            if args.live_attribution:
                summary["live_attribution"] = True
            if args.reference_validation:
                if set(reference_environment) != {"host", "reader"}:
                    raise RuntimeError("Reference environment receipt is incomplete")
                summary["reference_validation"] = True
                summary["reader_mode"] = "initial-query-only" if args.reference_idle else "subscribed"
                summary["scope"] += "; independent frozen full-history reference investigation; not ordinary CI parity"
                write_json(records / "reference-validation-input.json", {"schema": 1,
                    "history_mode": "full-no-compact", "malloc_stack_logging": "unset",
                    "malloc_stack_logging_no_compact": "1", "environments": reference_environment,
                    "checkpoint_windows": checkpoint_windows})
            if validation_errors:
                summary["coverage"] = "failed"
                summary["validation_errors"] = validation_errors
                write_json(records / "validation-errors.json", validation_errors)
            if args.heap_diagnostics or args.malloc_scribble:
                summary["mode"] = "heap-control" if args.heap_control else "product"
                summary["scan_mode"] = "diagnostic" if args.heap_diagnostics else "live"
            if args.malloc_scribble:
                summary["malloc_scribble"] = allocator_receipt
                summary["scope"] += "; MallocScribble environment experiment only; not an ownership fix or proof of completed free"
            write_json(records / "result.json", summary)
        finally:
            primary_exception = sys.exc_info()[0] is not None
            if shadow and host is not None and results and not any(row["label"] == "auxiliary-late" for row in shadow.data["captures"]):
                shadow.pid = host.pid
                shadow.capture("auxiliary-late", results[-1])
            cleanup = {"primary_exception": primary_exception, "errors": []}
            if primary_exception:
                validation_errors.append({"stage": "execution", "message": "Fixture execution failed"})

            def cleanup_step(stage, operation):
                try:
                    return operation()
                except Exception:
                    # Cleanup must retain the original exception/strict failure,
                    # and one failed operation must not skip independent cleanup.
                    cleanup["errors"].append(stage)
                    validation_errors.append({"stage": "cleanup", "message": stage})

            for role, process, stop in (("reader", reader, "stop-reader"), ("host", host, "quit")):
                value = cleanup_step(role, lambda: reap_owned(process, state / stop))
                cleanup[role] = value
                if value is not None and (not value["exited"] or value["errors"]):
                    cleanup["errors"].append(role)
                    validation_errors.append({"stage": "cleanup", "message": role})
            exited = all(cleanup[role] is not None and cleanup[role]["exited"] for role in ("reader", "host"))
            cleanup["processes_exited"] = exited

            def unregister():
                result = subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                    "-u", str(app)], capture_output=True, timeout=15)
                if result.returncode != 0:
                    raise RuntimeError("Launch Services cleanup failed")

            cleanup_step("launch_services", unregister)
            if args.external_startup_receipt:
                def final_external_receipt():
                    external_receipt["binary_reuse_verified"] = False
                    write_json(records / "external-startup.json", external_receipt)
                    if not exited:
                        raise RuntimeError("Owned process exit not confirmed")
                    validate("external-startup-final", finish_external_receipt)
                cleanup_step("external_receipt", final_external_receipt)
            # No offline analysis may treat a still-live owned process as exited.
            if exited:
                if args.heap_diagnostics:
                    cleanup_step("heap_diagnostics", lambda: collect_heap_diagnostics(graphs, records))
                if args.terminal_origin:
                    cleanup_step("terminal_snapshot", lambda: collect_terminal_snapshot(graphs / "terminal.memgraph", records, terminal_snapshot))
            elif args.terminal_origin:
                cleanup_step("terminal_snapshot_receipt", lambda: write_json(records / "terminal-snapshot.json", terminal_snapshot))
            cleanup_step("cleanup_receipt", lambda: write_json(records / "process-cleanup.json", cleanup))
            if "summary" not in locals():
                summary = {"coverage": "failed"}
            if primary_exception or validation_errors:
                summary["coverage"] = "failed"
            summary["cleanup"] = cleanup
            if startup_baseline is not None:
                summary["startup_baseline"] = startup_baseline
            if validation_errors:
                summary["validation_errors"] = validation_errors
                cleanup_step("validation_receipt", lambda: write_json(records / "validation-errors.json", validation_errors))
            if shadow:
                shadow.finish(results, validation_errors, primary_exception)
                summary["settled_baseline_shadow"] = True
                summary["reader_mode"] = "initial-query-only" if args.reference_idle else "subscribed"
                summary["scope"] = summary.get("scope", "") + "; shadow probes and captures perturb subsequent timing; observed stability is not permanent stability or ordinary run parity"
            cleanup_step("result_receipt", lambda: write_json(records / "result.json", summary))
            print(json.dumps(summary))
    return 1 if validation_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
