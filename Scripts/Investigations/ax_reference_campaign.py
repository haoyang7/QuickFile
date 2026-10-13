#!/usr/bin/env python3
"""One bounded four-case frozen AX reference campaign, separate from ordinary CI.

Only the allowlisted summary is publishable. Raw graphs, addresses, logs and
startup metadata remain private. Strict failures survive successful diagnosis.
"""
import argparse
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from ax_external_receipt import fixture_sources, load_prepared_build, validate_external_receipt
from ax_probe_report import HEAP_LABELS, validation_failure_counts
from ax_process import run_owned
from ax_frozen_nodes import graph_hash, validate_summary as validate_frozen
from ax_bridge_evidence import validate_summary as validate_bridge

ROOT = Path(__file__).resolve().parents[2]
PUBLIC_LIMIT = 2 * 1024 * 1024
CASES = ("patched-product", "patched-empty", "pure-appkit-empty", "pure-appkit-idle")
FAILURES = ("heap_baseline", "control_activity", "notifications", "compensation_branches", "allocator_environment", "other")


def require(condition):
    if not condition:
        raise ValueError("Invalid bounded reference campaign evidence")


def integer(value, maximum=2 ** 32):
    return type(value) is int and 0 <= value <= maximum


def digest(value):
    return type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def read_json(path, limit):
    require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= limit)
    return json.loads(path.read_bytes())


def validate_process(value):
    require(type(value) is dict and set(value) == {"return_code", "command_return_code", "status", "cleanup"})
    require(type(value["return_code"]) is int and -127 <= value["return_code"] <= 255)
    require(value["command_return_code"] is None or type(value["command_return_code"]) is int and -127 <= value["command_return_code"] <= 255)
    require(value["status"] in ("start_failed", "timeout", "protocol_failed", "completed"))
    if value["status"] == "completed":
        require(value["command_return_code"] is not None)
        require(value["return_code"] == value["command_return_code"] or value["return_code"] == 125 and not value["cleanup"]["complete"])
    cleanup = value["cleanup"]
    require(type(cleanup) is dict and set(cleanup) == {"group_signal", "group_members_exited", "group_inspection", "leader_reaped", "complete"})
    require(cleanup["group_signal"] in ("not_started", "sent", "absent", "failed"))
    require(cleanup["group_inspection"] in ("not_started", "exited", "running", "query_failed", "query_timeout", "parse_failed", "leader_unverified"))
    require(all(type(cleanup[key]) is bool for key in ("group_members_exited", "leader_reaped", "complete")))
    if cleanup["complete"]:
        require(cleanup["group_signal"] != "failed" and cleanup["group_members_exited"] and cleanup["leader_reaped"])


def fixture_clean(cleanup):
    return (type(cleanup) is dict and cleanup.get("processes_exited") is True and cleanup.get("errors") == []
            and all(type(cleanup.get(role)) is dict and cleanup[role].get("exited") is True
                    and cleanup[role].get("errors") == [] for role in ("host", "reader")))


def project_measurement(result, external, input_receipt, expected, case):
    require(result.get("reference_validation") is True and result.get("scan_mode") == "diagnostic")
    require(result.get("mode") == ("product" if case == "patched-product" else "heap-control"))
    require(result.get("reader_mode") == ("initial-query-only" if case == "pure-appkit-idle" else "subscribed"))
    validate_external_receipt(external, "off", expected)
    require(type(input_receipt.get("schema")) is int and input_receipt["schema"] == 1 and input_receipt.get("history_mode") == "full-no-compact")
    require(input_receipt.get("malloc_stack_logging") == "unset" and input_receipt.get("malloc_stack_logging_no_compact") == "1")
    require(input_receipt.get("environments") == dict.fromkeys(("host", "reader"), {
        "malloc_stack_logging": "unset", "malloc_stack_logging_no_compact": "1"}))
    failures = validation_failure_counts(result)
    scans = result.get("scans")
    require(type(scans) is list and len(scans) == len(HEAP_LABELS))
    totals = []
    for label, scan in zip(HEAP_LABELS, scans):
        require(type(scan) is dict and scan.get("label") == label)
        require(all(integer(scan.get(key)) for key in ("leak_nodes", "leak_bytes", "unclassified_nodes")))
        require(type(scan.get("destroyed_notification_stack_present")) is bool and type(scan.get("exit_code")) is int and scan["exit_code"] in (0, 1))
        groups = scan.get("groups")
        require(type(groups) is list and len(groups) <= 1024)
        require(all(type(group) is dict and integer(group.get("root_instances")) for group in groups))
        totals.append({key: scan[key] for key in ("label", "leak_nodes", "leak_bytes", "unclassified_nodes", "destroyed_notification_stack_present", "exit_code")} | {
            "xpc_roots": sum(group["root_instances"] for group in groups if group.get("root_type") == "NSXPCConnection"),
            "unexpected_roots": any(group.get("root_type") != "NSXPCConnection" for group in groups)})
    counts = {key: result.get(key) for key in ("destroyed_buttons", "notifications", "ordinary_compensations", "mutable_compensations")}
    require(all(integer(value, 100000) for value in counts.values()))
    return {"scan_totals": totals, "failure_counts": failures, "activity_counts": counts}


def validate_summary(value):
    from ax_reference_validation import validate_summary as validate_reference
    require(type(value) is dict and set(value) == {"schema", "identity", "builds", "cases", "completed", "strict_checks_passed", "evidence_checks_passed", "temporary_cleanup"})
    require(type(value["schema"]) is int and value["schema"] == 2)
    identity = value["identity"]
    require(type(identity) is dict and set(identity) == {"checkout_sha", "macos", "os_build", "architecture", "xcode", "scan_mode", "history_mode"})
    require(type(identity["checkout_sha"]) is str and re.fullmatch(r"[0-9a-f]{40}", identity["checkout_sha"]) is not None)
    require(type(identity["macos"]) is str and re.fullmatch(r"26\.\d+(?:\.\d+)?", identity["macos"]) is not None)
    require(type(identity["os_build"]) is str and re.fullmatch(r"25[A-Z][0-9]{1,6}[a-z]?", identity["os_build"]) is not None)
    require(identity["architecture"] == "arm64" and identity["xcode"] == "26.3")
    require(identity["scan_mode"] == "frozen-reference-investigation" and identity["history_mode"] == "full-no-compact")
    require(all(type(value[key]) is bool for key in ("completed", "strict_checks_passed", "evidence_checks_passed")))
    require(value["temporary_cleanup"] in ("not-run", "complete", "retained-unconfirmed", "retained-evidence", "failed"))
    builds = value["builds"]
    require(type(builds) is dict and set(builds) <= {"ordinary", "pure-appkit"})
    for mode, build in builds.items():
        require(type(build) is dict and set(build) == {"process_run", "manifest"})
        validate_process(build["process_run"])
        manifest = build["manifest"]
        if manifest is not None:
            require(build["process_run"]["status"] == "completed" and build["process_run"]["return_code"] == 0
                    and build["process_run"]["cleanup"]["complete"])
            fields = {"schema", "build_mode", "sources", "executables"} | ({"build_evidence"} if mode == "pure-appkit" else set())
            require(type(manifest) is dict and set(manifest) == fields and manifest["build_mode"] == mode)
            require(type(manifest["schema"]) is int and manifest["schema"] == (1 if mode == "ordinary" else 2))
            require(type(manifest["sources"]) is dict and set(manifest["sources"]) == set(fixture_sources(mode)))
            require(all(digest(item) for item in manifest["sources"].values()))
            require(type(manifest["executables"]) is dict and set(manifest["executables"]) == {"host", "reader"} and all(digest(item) for item in manifest["executables"].values()))
            if mode == "pure-appkit":
                from ax_external_receipt import validate_empty_control_build
                validate_empty_control_build(manifest["build_evidence"], mode)
    cases = value["cases"]
    require(type(cases) is list and len(cases) <= 4)
    for index, case in enumerate(cases):
        fields = {"name", "process_run", "measurement", "measurement_valid", "projection_reason", "strict_checks_passed", "offline_process_run", "frozen", "bridge", "reference", "evidence_checks_passed", "cleanup_confirmed"}
        require(type(case) is dict and set(case) == fields and case["name"] == CASES[index])
        require(all(type(case[key]) is bool for key in ("measurement_valid", "strict_checks_passed", "evidence_checks_passed", "cleanup_confirmed")))
        validate_process(case["process_run"])
        if case["offline_process_run"] is not None:
            validate_process(case["offline_process_run"])
        measurement = case["measurement"]
        require(case["measurement_valid"] == (measurement is not None))
        require(case["projection_reason"] in ("unavailable", "none", "measurement-invalid", "offline-invalid"))
        require((measurement is None) == (case["projection_reason"] in ("unavailable", "measurement-invalid")))
        if measurement is not None:
            require(type(measurement) is dict and set(measurement) == {"scan_totals", "failure_counts", "activity_counts"})
            require(type(measurement["failure_counts"]) is dict and set(measurement["failure_counts"]) == set(FAILURES) and all(integer(item, 64) for item in measurement["failure_counts"].values()))
            require(type(measurement["activity_counts"]) is dict and set(measurement["activity_counts"]) == {"destroyed_buttons", "notifications", "ordinary_compensations", "mutable_compensations"} and all(integer(item, 100000) for item in measurement["activity_counts"].values()))
            require(type(measurement["scan_totals"]) is list and len(measurement["scan_totals"]) == 7)
            for label, row in zip(HEAP_LABELS, measurement["scan_totals"]):
                require(type(row) is dict and set(row) == {"label", "leak_nodes", "leak_bytes", "unclassified_nodes", "destroyed_notification_stack_present", "exit_code", "xpc_roots", "unexpected_roots"} and row["label"] == label)
                require(all(integer(row[key]) for key in ("leak_nodes", "leak_bytes", "unclassified_nodes", "xpc_roots")))
                require(type(row["exit_code"]) is int and row["exit_code"] in (0, 1) and all(type(row[key]) is bool for key in ("destroyed_notification_stack_present", "unexpected_roots")))
        if case["frozen"] is not None:
            validate_frozen(case["frozen"])
        if case["bridge"] is not None:
            require(case["frozen"] is not None)
            validate_bridge(case["bridge"], case["frozen"])
        if case["reference"] is not None:
            require(case["frozen"] is not None and case["bridge"] is not None)
            validate_reference(case["reference"], case["frozen"], case["bridge"])
        if case["cleanup_confirmed"]:
            require(case["process_run"]["cleanup"]["complete"])
            require(measurement is None or case["offline_process_run"] is not None)
            if case["offline_process_run"] is not None:
                require(case["offline_process_run"]["cleanup"]["complete"])
                require(all(part is not None and part["process_cleanup_confirmed"] and all(tool["cleanup_confirmed"] for tool in part["tools"]) for part in (case["frozen"], case["bridge"], case["reference"])))
        if case["strict_checks_passed"]:
            require(case["measurement_valid"] and case["process_run"]["status"] == "completed" and case["process_run"]["return_code"] == 0 and not any(measurement["failure_counts"].values()))
        if case["evidence_checks_passed"]:
            require(case["offline_process_run"] is not None and case["offline_process_run"]["return_code"] == 0 and case["cleanup_confirmed"])
            require(case["frozen"] is not None and case["frozen"]["status"] == "complete" and case["bridge"] is not None and case["bridge"]["status"] in ("complete", "not_needed"))
            require(case["reference"] is not None and case["reference"]["status"] == "complete")
    if value["temporary_cleanup"] == "complete":
        require(all(build["process_run"]["cleanup"]["complete"] for build in builds.values()))
        require(all(case["cleanup_confirmed"] and case["projection_reason"] == "none" for case in cases))
    if value["temporary_cleanup"] == "retained-evidence":
        require(all(case["cleanup_confirmed"] for case in cases))
        require(any(case["projection_reason"] == "measurement-invalid" for case in cases))
    require(not value["completed"] or len(cases) == 4)
    for key in ("strict_checks_passed", "evidence_checks_passed"):
        if value[key]:
            require(value["completed"] and all(case[key] for case in cases))


def encode_summary(value):
    validate_summary(value)
    payload = (json.dumps(value, indent=2, allow_nan=False) + "\n").encode()
    require(len(payload) <= PUBLIC_LIMIT)
    return payload


def save_summary(path, summary):
    payload = encode_summary(summary)
    temporary = path.with_suffix(".tmp")
    temporary.write_bytes(payload)
    temporary.replace(path)


def collect_evidence(records, totals, destination=None):
    from ax_reference_validation import validate_summary as validate_reference
    frozen = read_json(records / "frozen-nodes.json", 131072)
    validate_frozen(frozen)
    growing = [row["label"] for row in totals[1:] if any(row[key] > totals[0][key] for key in ("leak_nodes", "leak_bytes"))]
    require(frozen["selection"] == ("first-strict-growth" if growing else "no-strict-growth"))
    require(frozen["selected_label"] == (growing[0] if growing else None))
    by_label = {row["label"]: row for row in totals}
    for label, point in (("baseline", frozen["baseline"]), (frozen["selected_label"], frozen["selected"])):
        if point is not None:
            require(all(point[key] == by_label[label][key] for key in ("leak_nodes", "leak_bytes")))
    if destination is not None:
        destination["frozen"] = frozen
    bridge = read_json(records / "bridge-evidence.json", 32768)
    validate_bridge(bridge, frozen)
    if destination is not None:
        destination["bridge"] = bridge
    reference = read_json(records / "reference-validation.json", 131072)
    hashes = {label: graph_hash(records.parent / "fixture/heap" / (label + ".memgraph")) for label in HEAP_LABELS}
    validate_reference(reference, frozen, bridge, graph_hashes=hashes)
    return frozen, bridge, reference


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-directory", required=True, type=Path)
    parser.add_argument("--validate-public", action="store_true", help="Validate only the already written public summary before upload")
    args = parser.parse_args(argv)
    root = args.work_directory.resolve()
    root.relative_to(ROOT / ".build/Temporary")
    public = root / "summary.json"
    if args.validate_public:
        value = read_json(public, PUBLIC_LIMIT)
        require(public.read_bytes() == encode_summary(value))
        return 0
    root.mkdir(parents=True, exist_ok=False, mode=0o700)
    private = root / "private"
    private.mkdir(mode=0o700)
    def output(*command):
        return subprocess.check_output(command, text=True, timeout=15).strip()
    xcode = output("xcodebuild", "-version").splitlines()[0]
    require(xcode == "Xcode 26.3")
    summary = {"schema": 2, "identity": {"checkout_sha": output("git", "rev-parse", "HEAD"),
        "macos": output("sw_vers", "-productVersion"), "os_build": output("sw_vers", "-buildVersion"),
        "architecture": output("uname", "-m"), "xcode": "26.3", "scan_mode": "frozen-reference-investigation", "history_mode": "full-no-compact"},
        "builds": {}, "cases": [], "completed": False, "strict_checks_passed": False,
        "evidence_checks_passed": False, "temporary_cleanup": "not-run"}
    save_summary(public, summary)
    environment = dict(os.environ)
    for key in ("MallocScribble", "MallocStackLogging", "MallocStackLoggingNoCompact"):
        environment.pop(key, None)
    prepared = {}
    cleanup_confirmed = True
    evidence_preserved = True
    exception_pending = False
    try:
        for mode in ("ordinary", "pure-appkit"):
            directory = private / mode
            build_run = run_owned([sys.executable, str(ROOT / "Scripts/Investigations/verify-ax-compatibility.py"),
                "--prepare-external-fixture", "--work-directory", str(directory),
                "--records-directory", str(private / (mode + "-records")),
                *(["--empty-control-mode", mode] if mode != "ordinary" else [])], private / (mode + ".log"), environment)
            summary["builds"][mode] = {"process_run": build_run, "manifest": None}
            cleanup_confirmed &= build_run["cleanup"]["complete"]
            save_summary(public, summary)
            if build_run["return_code"] != 0 or not cleanup_confirmed:
                return 1
            sources = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in fixture_sources(mode)}
            manifest = load_prepared_build(directory, sources, mode)
            summary["builds"][mode]["manifest"] = manifest
            prepared[mode] = directory, manifest["executables"]
            save_summary(public, summary)
        for name in CASES:
            mode = "ordinary" if name.startswith("patched-") else "pure-appkit"
            directory, hashes = prepared[mode]
            case_root = private / name
            case_root.mkdir()
            records = case_root / "records"
            process = run_owned([sys.executable, str(ROOT / "Scripts/Investigations/verify-ax-compatibility.py"),
                "--reference-validation", "--heap-diagnostics", "--external-startup-receipt", "--malloc-scribble", "off",
                "--prepared-fixture-directory", str(directory), "--work-directory", str(case_root / "fixture"), "--records-directory", str(records),
                *(["--heap-control"] if name != "patched-product" else []),
                *(["--empty-control-mode", "pure-appkit"] if mode == "pure-appkit" else []),
                *(["--reference-idle"] if name == "pure-appkit-idle" else [])], case_root / "measurement.log", environment, timeout=330)
            case = {"name": name, "process_run": process, "measurement": None, "measurement_valid": False, "projection_reason": "unavailable",
                "strict_checks_passed": False, "offline_process_run": None, "frozen": None, "bridge": None,
                "reference": None, "evidence_checks_passed": False, "cleanup_confirmed": False}
            summary["cases"].append(case)
            cleanup_confirmed &= process["cleanup"]["complete"]
            save_summary(public, summary)
            try:
                result = read_json(records / "result.json", 262144)
                require(type(result) is dict)
                cleanup_confirmed &= fixture_clean(result.get("cleanup"))
            except (OSError, ValueError, TypeError, KeyError, RuntimeError):
                cleanup_confirmed = False
                result = None
            try:
                require(type(result) is dict)
                case["measurement"] = project_measurement(result, read_json(records / "external-startup.json", 16384),
                    read_json(records / "reference-validation-input.json", 16384), hashes, name)
                case["measurement_valid"] = True
                case["projection_reason"] = "none"
                case["strict_checks_passed"] = (process["status"] == "completed" and process["return_code"] == 0
                    and not any(case["measurement"]["failure_counts"].values()))
            except (OSError, ValueError, TypeError, KeyError, RuntimeError):
                case["projection_reason"] = "measurement-invalid"
                evidence_preserved = False
            if cleanup_confirmed and case["measurement_valid"]:
                offline = run_owned([sys.executable, str(ROOT / "Scripts/Investigations/ax_frozen_nodes.py"),
                    "--graph-directory", str(case_root / "fixture/heap"), "--records-directory", str(records),
                    "--first-strict-growth", "--bridge-evidence", "--reference-validation"], case_root / "offline.log", environment, timeout=310)
                case["offline_process_run"] = offline
                cleanup_confirmed &= offline["cleanup"]["complete"]
                try:
                    frozen, bridge, reference = collect_evidence(records, case["measurement"]["scan_totals"], case)
                    case.update(frozen=frozen, bridge=bridge, reference=reference)
                    cleanup_confirmed &= all(part["process_cleanup_confirmed"] and all(tool["cleanup_confirmed"] for tool in part["tools"]) for part in (frozen, bridge, reference))
                    case["cleanup_confirmed"] = cleanup_confirmed
                    case["evidence_checks_passed"] = (offline["return_code"] == 0 and cleanup_confirmed and frozen["status"] == "complete"
                        and bridge["status"] in ("complete", "not_needed") and reference["status"] == "complete")
                except (OSError, ValueError, TypeError, KeyError, RuntimeError):
                    case["projection_reason"] = "offline-invalid"
                    cleanup_confirmed = False
            case["cleanup_confirmed"] = bool(cleanup_confirmed)
            save_summary(public, summary)
            print(json.dumps({"case": name, "strict_checks_passed": case["strict_checks_passed"],
                "evidence_checks_passed": case["evidence_checks_passed"], "cleanup_confirmed": case["cleanup_confirmed"]}), flush=True)
            if not cleanup_confirmed:
                return 1
        summary["completed"] = True
        summary["strict_checks_passed"] = all(case["strict_checks_passed"] for case in summary["cases"])
        summary["evidence_checks_passed"] = all(case["evidence_checks_passed"] for case in summary["cases"])
        return 0 if summary["strict_checks_passed"] and summary["evidence_checks_passed"] else 1
    except BaseException:
        exception_pending = True
        raise
    finally:
        # An unhandled failure keeps private diagnostics and the last durable
        # summary. Finalization must neither delete evidence nor mask the error.
        if not exception_pending:
            if cleanup_confirmed and evidence_preserved:
                # Keep raw evidence until all collected cases are durably saved and
                # the final cleanup receipt also fits the public encoding budget.
                try:
                    save_summary(public, summary)
                    encode_summary(dict(summary, temporary_cleanup="complete"))
                except (ValueError, RuntimeError, OSError, TypeError, KeyError, UnicodeError):
                    print("Public summary unavailable; private evidence retained", file=sys.stderr)
                    return 1
                try:
                    shutil.rmtree(private)
                    summary["temporary_cleanup"] = "complete"
                except OSError:
                    summary["temporary_cleanup"] = "failed"
                    summary["evidence_checks_passed"] = False
            elif not cleanup_confirmed:
                summary["temporary_cleanup"] = "retained-unconfirmed"
            else:
                summary["temporary_cleanup"] = "retained-evidence"
            save_summary(public, summary)
            if summary["temporary_cleanup"] == "failed":
                return 1


if __name__ == "__main__":
    raise SystemExit(main())
