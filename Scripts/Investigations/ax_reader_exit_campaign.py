#!/usr/bin/env python3
"""Fixed nine-trial Reader exit investigation. Only summary.json is public.

512 KiB public limit; schema 2 uses compact JSON, schema 1 retains indentation.
Roots and reported type net counts do not establish new
connections or allocation generations. No graph captures or parser extensions.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

import ax_composition as composition
from ax_external_receipt import fixture_sources, load_prepared_build, validate_external_receipt, validate_hashes
from ax_probe_report import leak_groups
from ax_process import run_owned
from ax_reference_campaign import validate_process
from ax_shadow_campaign import (canonical, fields, groups_projection, integer, read_bytes,
    read_json, require, validate_scan, root_count, classification_passed, fits)

ROOT = Path(__file__).resolve().parents[2]
PUBLIC_LIMIT = 512 * 1024
FINAL_RECEIPT_RESERVE = 64
RAW_LIMIT = 16 * 1024 * 1024
RUN_TIMEOUT = 180
SCHEDULE = (("baseline", 0), ("t20", 20), ("t40", 40), ("t60", 60), ("t80", 80), ("t110", 110))
LABELS = tuple(label for label, _ in SCHEDULE)
ARMS = {"keep": None, "early": 30, "late": 70}
ORDERS = (("keep", "early", "late"), ("early", "late", "keep"), ("late", "keep", "early"))
TRIALS = tuple((block, order, arm) for block, arms in enumerate(ORDERS, 1) for order, arm in enumerate(arms, 1))
HOST_KEYS = ("buttons", "allocatedButtons", "destroyedButtons", "compensations", "mutableCompensations")
READER_KEYS = ("notifications", "all_notifications", "unmatched_notifications", "tracked_buttons")
ENVIRONMENT = {"host": {"MallocStackLogging": "1", "MallocStackLoggingNoCompact": "1", "MallocScribble": "unset"},
    "reader": dict.fromkeys(("MallocStackLogging", "MallocStackLoggingNoCompact", "MallocScribble"), "unset")}
REASONS = ("execution_failed", "timing_mismatch", "activity_violation", "reader_liveness", "scan_unavailable",
    "environment_mismatch", "cleanup_failed", "unsupported-images", "unsupported-architecture", "reader-not-trusted")
PROJECTION_REASONS = ("none", "unavailable", "invalid", "binding")


def policy(arm):
    return {"schedule": [{"label": label, "offset_seconds": offset} for label, offset in SCHEDULE],
        "exit_offset_seconds": ARMS[arm], "scan_timeout_seconds": 12, "checkpoint_timeout_seconds": 5,
        "stop_timeout_seconds": 5, "max_lateness_ms": 3000}


def digest(value):
    return type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def read_stdout(path, allow_empty=False):
    if not allow_empty:
        return read_bytes(path, RAW_LIMIT)
    # A failed leaks invocation can write only stderr. Bind its empty stdout
    # without discarding earlier measurements, using the same file constraints.
    require(not any(parent.is_symlink() for parent in (path, *path.parents)))
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and 0 <= info.st_size <= RAW_LIMIT)
    data = path.read_bytes()
    require(len(data) == info.st_size)
    return data


def no_floats(value, depth=0):
    require(depth <= 32)
    require(type(value) in (dict, list, str, int, bool, type(None)))
    if type(value) is dict:
        require(all(type(key) is str for key in value))
        for item in value.values(): no_floats(item, depth + 1)
    elif type(value) is list:
        for item in value: no_floats(item, depth + 1)


def milliseconds(value):
    if value is None: return None
    require(type(value) in (int, float) and math.isfinite(value) and abs(value) <= 3600)
    return round(value * 1000)


def ms(value, signed=False):
    return type(value) is int and (-3600000 if signed else 0) <= value <= 3600000


def strict_verdict(value):
    fields(value, ("status", "failed_labels"))
    require(value["status"] in ("not-evaluated", "passed", "failed"))
    require(type(value["failed_labels"]) is list)
    require(value["failed_labels"] == [label for label in LABELS if label in value["failed_labels"]])
    require((value["status"] == "failed") == bool(value["failed_labels"]))


def derived_strict(scans):
    results = [row["result"] for row in scans if row["result"] is not None]
    failed = [row["label"] for row in results if not classification_passed(row) or not fits(row, results[0])]
    return {"status": "failed" if failed else "passed" if results else "not-evaluated", "failed_labels": failed}


def activity(raw, keys):
    if raw is None: return None
    value = {key: raw.get(key) for key in keys}
    require(all(integer(number, 100000) for number in value.values()))
    if keys != HOST_KEYS:
        require(type(raw.get("target_notification_counts")) is list and len(raw["target_notification_counts"]) <= 100000)
        # The fixture has zero targets; publish only the count, never target IDs.
        value["target_notification_count_entries"] = len(raw["target_notification_counts"])
    return value


def validate_activity(value, keys):
    if value is None: return
    fields(value, keys if keys == HOST_KEYS else (*keys, "target_notification_count_entries"))
    require(all(integer(number, 100000) for number in value.values()))


def window(raw):
    if raw is None: return None
    fields(raw, ("start", "end", "reader_alive_before", "reader_alive_after"))
    return {"start_ms": milliseconds(raw["start"]), "end_ms": milliseconds(raw["end"]),
        "reader_alive_before": raw["reader_alive_before"], "reader_alive_after": raw["reader_alive_after"]}


def validate_window(value):
    if value is None: return
    fields(value, ("start_ms", "end_ms", "reader_alive_before", "reader_alive_after"))
    require(all(value[key] is None or ms(value[key]) for key in ("start_ms", "end_ms")))
    require(all(value[key] is None or type(value[key]) is bool for key in ("reader_alive_before", "reader_alive_after")))
    require(value["end_ms"] is None or value["start_ms"] is not None and value["end_ms"] >= value["start_ms"])


def project_cleanup(raw):
    if raw is None: return None
    result = {key: raw[key] for key in ("reader", "host", "errors", "processes_exited")}
    validate_cleanup(result)
    return result


def validate_cleanup(value):
    if value is None: return
    fields(value, ("reader", "host", "errors", "processes_exited"))
    require(type(value["processes_exited"]) is bool and type(value["errors"]) is list)
    require(len(value["errors"]) <= 8 and all(error in ("reader_stop", "reader", "host", "launch_services", "external_receipt") for error in value["errors"]))
    for role in ("reader", "host"):
        row = value[role]
        if row is None: continue
        fields(row, ("started", "exited", "terminate_sent", "kill_sent", "return_code", "errors"))
        require(all(type(row[key]) is bool for key in ("started", "exited", "terminate_sent", "kill_sent")))
        require(row["return_code"] is None or type(row["return_code"]) is int and -127 <= row["return_code"] <= 255)
        require(type(row["errors"]) is list and len(row["errors"]) <= 8 and all(error in ("stop_request_failed", "terminate_failed", "kill_failed", "wait_timeout", "wait_failed") for error in row["errors"]))
        if not row["started"]: require(row["exited"] and row["return_code"] is None and not row["terminate_sent"] and not row["kill_sent"])
        elif row["exited"]: require(row["return_code"] is not None)
    require(value["processes_exited"] == all(value[role] is not None and value[role]["exited"] for role in ("reader", "host")))


def fixture_clean(cleanup):
    return cleanup is not None and cleanup["processes_exited"] and not cleanup["errors"] and all(not cleanup[role]["errors"] for role in ("host", "reader"))


def project_trial(records, process, expected, arm, sources=None):
    """Project one private receipt; standalone use does not assert campaign identity."""
    validate_process(process)
    raw = read_json(records / "trial.json", RAW_LIMIT)
    require(type(raw.get("schema")) is int and raw["schema"] == 1 and raw.get("arm") == arm)
    require(canonical(raw.get("policy")) == canonical(policy(arm)))
    require(raw.get("status") in ("complete", "failed", "not-covered") and raw.get("reason") in (None, *REASONS))
    require((raw["status"] == "complete") == (raw["reason"] is None))
    require(raw.get("executables") in (None, expected))
    if sources is not None and raw["executables"] is not None:
        require(read_json(records / "inputs.json", RAW_LIMIT).get("sources") == sources)
    if raw.get("external_startup") is not None:
        require(read_json(records / "external-startup.json", 16384) == raw["external_startup"])
    startup = raw.get("external_startup")
    try:
        validate_external_receipt(startup, "off", expected)
    except (ValueError, RuntimeError, TypeError, KeyError):
        startup = None
    environments = raw.get("environments")
    require(type(environments) is dict and set(environments) == {"host", "reader"})
    for role, entry in environments.items():
        if entry is not None:
            fields(entry, ENVIRONMENT[role])
            require(all(item in ("1", "unset") for item in entry.values()))
    markers = raw["clock_markers"]
    fields(markers, ("origin_monotonic", "host_start", "host_ready", "reader_start", "warm"))
    clock = {key + "_ms": milliseconds(markers[key]) if markers["origin_monotonic"] is not None else None
             for key in ("host_start", "host_ready", "reader_start", "warm")}
    timing = raw["exit_timing"]
    fields(timing, ("target_offset_seconds", "stop_requested", "wait_returned", "notification_received", "return_code", "phase"))
    require(timing["target_offset_seconds"] == ARMS[arm])
    exit_timing = {"target_offset_ms": ARMS[arm] * 1000 if ARMS[arm] is not None else None,
        **{key + "_ms": milliseconds(timing[key]) for key in ("stop_requested", "wait_returned", "notification_received")},
        "return_code": timing["return_code"], "phase": timing["phase"]}
    scans = []
    for raw_scan in raw["scans"]:
        label = raw_scan.get("label")
        require(label in LABELS)
        row = {"label": label, "target_offset_ms": dict(SCHEDULE)[label] * 1000,
            "checkpoint": window(raw_scan["checkpoint"]), "scan": window(raw_scan["scan"]),
            "activity": activity(raw_scan["host"], HOST_KEYS), "result": None,
            "stdout_sha256": None,
            "composition": composition.empty_grouped(), "baseline_delta": None}
        require(raw_scan.get("target_offset_seconds") == dict(SCHEDULE)[label])
        text = None
        if raw_scan.get("stdout_sha256") is not None:
            data = read_stdout(records / (label + "-original.stdout.txt"), allow_empty=raw_scan.get("leak_nodes") is None)
            require(hashlib.sha256(data).hexdigest() == raw_scan["stdout_sha256"])
            text = data.decode("utf-8")
            row["stdout_sha256"] = raw_scan["stdout_sha256"]
        if raw_scan.get("leak_nodes") is not None:
            require(text is not None)
            totals = re.findall(r"(\d+) leaks for (\d+) total leaked bytes", text)
            require(len(totals) == 1 and tuple(map(int, totals[0])) == (raw_scan["leak_nodes"], raw_scan["leak_bytes"]))
            actual = leak_groups(text)
            require(actual == raw_scan["groups"])
            require(raw_scan["destroyed_notification_stack_present"] == ("_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification" in text))
            row["result"] = {key: raw_scan[key] for key in ("label", "leak_nodes", "leak_bytes", "unclassified_nodes", "destroyed_notification_stack_present", "exit_code", "stdout_sha256")}
            row["result"]["groups"] = groups_projection(actual)
            validate_scan(row["result"], label)
            row["composition"] = composition.grouped_composition(text)
            # Parser fragments are useful privately, but no stack/text fragments escape.
            row["composition"]["failure_fragment"] = None
        scans.append(row)
        row["baseline_delta"] = composition.composition_delta(scans[0]["composition"], row["composition"])
    result = {"status": raw["status"], "reason": raw["reason"], "executables": raw["executables"],
        "external_startup": startup, "environments": environments, "clock_markers": clock, "exit_timing": exit_timing,
        "warm_activity": activity(raw["warm_receipt"], (*READER_KEYS, "buttons", "registrations")),
        "completed_activity": activity(raw["completed_receipt"], READER_KEYS), "scans": scans,
        "strict_verdict": raw["strict_verdict"], "timing_valid": False, "activity_zero": False}
    result["timing_valid"] = timing_valid(result, arm)
    result["activity_zero"] = activity_zero(result)
    validate_measurement(result, expected, arm)
    return result


def activity_zero(value):
    rows = [value["warm_activity"], value["completed_activity"], *[row["activity"] for row in value["scans"]]]
    return bool(rows) and all(row is not None and all(number == 0 for number in row.values()) for row in rows)


def timing_valid(value, arm):
    clock, timing, scans = value["clock_markers"], value["exit_timing"], value["scans"]
    if any(clock[key] is None for key in clock) or clock["warm_ms"] != 0: return False
    if not clock["host_start_ms"] <= clock["host_ready_ms"] <= clock["reader_start_ms"] <= 0: return False
    stop, waited, notified = (timing[key + "_ms"] for key in ("stop_requested", "wait_returned", "notification_received"))
    if stop is None or waited is None or notified is None or not stop <= waited <= notified or waited - stop > 5000 or timing["return_code"] != 0: return False
    target = ARMS[arm]
    if target is None:
        if timing["phase"] != "cleanup" or not scans or scans[-1]["scan"] is None or scans[-1]["scan"]["end_ms"] is None or stop < scans[-1]["scan"]["end_ms"]: return False
    elif (timing["phase"] != "scheduled" or not target * 1000 <= stop <= target * 1000 + 3000
          or waited > target * 1000 + 3000): return False
    previous_end = 0
    for row in scans:
        expected_alive = target is None or row["target_offset_ms"] < target * 1000
        checkpoint, scan = row["checkpoint"], row["scan"]
        if checkpoint is None or scan is None: return False
        for stage, maximum in ((checkpoint, 5000), (scan, 12000)):
            start, end = stage["start_ms"], stage["end_ms"]
            if start is None or end is None or not row["target_offset_ms"] <= start <= row["target_offset_ms"] + 3000 or end - start > maximum: return False
            if stage["reader_alive_before"] is not expected_alive or stage["reader_alive_after"] is not expected_alive: return False
            if target is not None and (expected_alive and end > stop or not expected_alive and start < notified): return False
        if checkpoint["start_ms"] < previous_end or scan["start_ms"] < checkpoint["end_ms"]: return False
        previous_end = scan["end_ms"]
    return len(scans) == 6


def validate_measurement(value, expected, arm):
    fields(value, ("status", "reason", "executables", "external_startup", "environments", "clock_markers", "exit_timing", "warm_activity", "completed_activity", "scans", "strict_verdict", "timing_valid", "activity_zero"))
    require(value["status"] in ("complete", "failed", "not-covered") and value["reason"] in (None, *REASONS))
    require((value["status"] == "complete") == (value["reason"] is None))
    if value["status"] == "not-covered": require(value["reason"] in REASONS[-3:])
    require(value["executables"] is None or value["executables"] == expected)
    if value["executables"] is not None: validate_hashes(value["executables"])
    if value["external_startup"] is not None: validate_external_receipt(value["external_startup"], "off", expected)
    fields(value["environments"], ("host", "reader"))
    for role, entry in value["environments"].items():
        if entry is not None:
            fields(entry, ENVIRONMENT[role]); require(all(item in ("1", "unset") for item in entry.values()))
    fields(value["clock_markers"], ("host_start_ms", "host_ready_ms", "reader_start_ms", "warm_ms"))
    require(all(item is None or ms(item, signed=True) for item in value["clock_markers"].values()))
    require(value["clock_markers"]["warm_ms"] in (None, 0))
    timing = value["exit_timing"]
    fields(timing, ("target_offset_ms", "stop_requested_ms", "wait_returned_ms", "notification_received_ms", "return_code", "phase"))
    require(timing["target_offset_ms"] == (ARMS[arm] * 1000 if ARMS[arm] is not None else None))
    require(timing["phase"] in (None, "scheduled", "cleanup"))
    require(timing["return_code"] is None or type(timing["return_code"]) is int and -127 <= timing["return_code"] <= 255)
    previous = None
    for key in ("stop_requested_ms", "wait_returned_ms", "notification_received_ms"):
        number = timing[key]
        require(number is None or ms(number))
        if number is not None:
            require(key == "stop_requested_ms" or previous is not None and number >= previous)
        previous = number
    if timing["stop_requested_ms"] is not None: require(timing["phase"] is not None)
    validate_activity(value["warm_activity"], (*READER_KEYS, "buttons", "registrations"))
    validate_activity(value["completed_activity"], READER_KEYS)
    require(type(value["scans"]) is list and len(value["scans"]) <= 6)
    require([row["label"] for row in value["scans"]] == list(LABELS[:len(value["scans"])]))
    for row in value["scans"]:
        fields(row, ("label", "target_offset_ms", "checkpoint", "scan", "activity", "result", "stdout_sha256", "composition", "baseline_delta"))
        require(type(row["target_offset_ms"]) is int and row["target_offset_ms"] == dict(SCHEDULE)[row["label"]] * 1000)
        validate_window(row["checkpoint"]); validate_window(row["scan"]); validate_activity(row["activity"], HOST_KEYS)
        require(row["stdout_sha256"] is None or digest(row["stdout_sha256"]))
        if row["result"] is not None:
            validate_scan(row["result"], row["label"])
            require(row["result"]["stdout_sha256"] == row["stdout_sha256"])
        composition.validate_grouped_composition(row["composition"])
        require(row["composition"]["failure_fragment"] is None)
        if row["composition"]["total_nodes"] is not None and row["result"] is not None:
            require((row["composition"]["total_nodes"], row["composition"]["total_bytes"]) == (row["result"]["leak_nodes"], row["result"]["leak_bytes"]))
        composition.validate_composition_delta(row["baseline_delta"], value["scans"][0]["composition"], row["composition"])
    strict_verdict(value["strict_verdict"])
    require(value["strict_verdict"] == derived_strict(value["scans"]))
    require(type(value["timing_valid"]) is bool and value["timing_valid"] == timing_valid(value, arm))
    require(type(value["activity_zero"]) is bool and value["activity_zero"] == activity_zero(value))
    if value["status"] == "complete":
        require(len(value["scans"]) == 6 and all(row["result"] is not None for row in value["scans"]))
        require(value["executables"] == expected and value["external_startup"] is not None)
        require(value["environments"] == ENVIRONMENT and value["timing_valid"] and value["activity_zero"])
    no_floats(value)


def evidence_passed(row):
    measurement = row["measurement"]
    return (measurement is not None and measurement["status"] == "complete" and measurement["timing_valid"]
        and measurement["activity_zero"] and row["cleanup_confirmed"] and row["process_run"]["status"] == "completed"
        and row["process_run"]["command_return_code"] == (1 if row["strict_verdict"]["status"] == "failed" else 0))


def conclusions(value):
    completed = len(value["trials"]) == 9
    strict = completed and all(evidence_passed(row) and row["strict_verdict"]["status"] == "passed" for row in value["trials"])
    evidence = completed and all(evidence_passed(row) for row in value["trials"])
    return completed, strict, evidence


def validate_identity(value):
    fields(value, ("checkout_sha", "macos", "os_build", "architecture", "xcode", "scan_mode", "history_mode"))
    require(type(value["checkout_sha"]) is str and re.fullmatch(r"[0-9a-f]{40}", value["checkout_sha"]))
    require(type(value["macos"]) is str and re.fullmatch(r"26\.\d+(?:\.\d+)?", value["macos"]))
    require(type(value["os_build"]) is str and re.fullmatch(r"25[A-Z][0-9]{1,6}[a-z]?", value["os_build"]))
    require(value["architecture"] == "arm64" and value["xcode"] == "26.3" and value["scan_mode"] == "reader-exit" and value["history_mode"] == "current-stacks")


def validate_summary(value):
    no_floats(value)
    fields(value, ("schema", "identity", "build", "trials", "completed", "strict_checks_passed", "evidence_checks_passed", "temporary_cleanup", "public_limit_bytes"))
    require(type(value["schema"]) is int and value["schema"] in (1, 2) and value["public_limit_bytes"] == PUBLIC_LIMIT)
    validate_identity(value["identity"])
    require(value["temporary_cleanup"] in ("not-run", "complete", "retained-unconfirmed", "failed"))
    build = value["build"]
    expected = None
    if build is not None:
        fields(build, ("process_run", "manifest", "manifest_sha256")); validate_process(build["process_run"])
        manifest = build["manifest"]
        if manifest is None: require(build["manifest_sha256"] is None)
        else:
            fields(manifest, ("schema", "build_mode", "sources", "executables"))
            require(type(manifest["schema"]) is int and manifest["schema"] == 1 and manifest["build_mode"] == "ordinary")
            fields(manifest["sources"], fixture_sources()); require(all(digest(item) for item in manifest["sources"].values()))
            validate_hashes(manifest["executables"]); expected = manifest["executables"]
            require(build["manifest_sha256"] == hashlib.sha256(canonical(manifest)).hexdigest())
            require(build["process_run"]["return_code"] == 0 and build["process_run"]["cleanup"]["complete"])
    require(type(value["trials"]) is list and len(value["trials"]) <= 9)
    for index, row in enumerate(value["trials"]):
        fields(row, ("block", "order", "arm", "policy", "process_run", "measurement", "projection_reason", "strict_verdict", "fixture_cleanup", "cleanup_confirmed"))
        require(expected is not None and type(row["block"]) is int and type(row["order"]) is int)
        require((row["block"], row["order"], row["arm"]) == TRIALS[index])
        require(canonical(row["policy"]) == canonical(policy(row["arm"])))
        validate_process(row["process_run"]); strict_verdict(row["strict_verdict"]); validate_cleanup(row["fixture_cleanup"])
        require(row["projection_reason"] in PROJECTION_REASONS)
        require((row["measurement"] is not None) == (row["projection_reason"] == "none"))
        if row["measurement"] is not None:
            validate_measurement(row["measurement"], expected, row["arm"])
            require(row["strict_verdict"] == row["measurement"]["strict_verdict"])
        require(type(row["cleanup_confirmed"]) is bool and row["cleanup_confirmed"] == (row["process_run"]["cleanup"]["complete"] and fixture_clean(row["fixture_cleanup"])))
        if index < len(value["trials"]) - 1: require(row["cleanup_confirmed"])
    derived = conclusions(value)
    for key, expected_result in zip(("completed", "strict_checks_passed", "evidence_checks_passed"), derived):
        require(type(value[key]) is bool and value[key] == expected_result)
    cleanup_known = (build is None or build["process_run"]["cleanup"]["complete"]) and all(row["cleanup_confirmed"] for row in value["trials"])
    if value["temporary_cleanup"] == "complete": require(cleanup_known)
    if value["temporary_cleanup"] == "retained-unconfirmed": require(not cleanup_known)
    require(len(public_bytes(value)) <= PUBLIC_LIMIT)


def public_bytes(value):
    if value["schema"] == 1:
        return canonical(value)
    require(type(value["schema"]) is int and value["schema"] == 2)
    return (json.dumps(value, separators=(",", ":"), allow_nan=False) + "\n").encode()


def bound_summary(value):
    """Only optional type composition yields to the public artifact budget."""
    if len(public_bytes(value)) <= PUBLIC_LIMIT - FINAL_RECEIPT_RESERVE:
        return
    require(value["schema"] == 2)
    for trial in value["trials"]:
        measurement = trial["measurement"]
        if measurement is None: continue
        scans = measurement["scans"]
        for row in scans:
            current = row["composition"]
            totals = (current["total_nodes"], current["total_bytes"]) if current["total_nodes"] is not None else None
            row["composition"] = composition.empty_grouped("summary_budget", totals)
        for row in scans:
            row["baseline_delta"] = composition.composition_delta(scans[0]["composition"], row["composition"])
    require(len(public_bytes(value)) <= PUBLIC_LIMIT - FINAL_RECEIPT_RESERVE)


def encode_summary(value):
    validate_summary(value)
    return public_bytes(value)


def save_summary(path, value):
    value["completed"], value["strict_checks_passed"], value["evidence_checks_passed"] = conclusions(value)
    bound_summary(value)
    payload = encode_summary(value)
    temporary = path.with_suffix(".tmp")
    require(not path.is_symlink() and not temporary.is_symlink())
    temporary.write_bytes(payload); temporary.replace(path)


def identity():
    def output(*command): return subprocess.check_output(command, text=True, timeout=15, cwd=ROOT).strip()
    require(output("xcodebuild", "-version").splitlines()[0] == "Xcode 26.3")
    value = {"checkout_sha": output("git", "rev-parse", "HEAD"), "macos": output("sw_vers", "-productVersion"),
        "os_build": output("sw_vers", "-buildVersion"), "architecture": output("uname", "-m"), "xcode": "26.3",
        "scan_mode": "reader-exit", "history_mode": "current-stacks"}
    validate_identity(value)
    return value


def campaign(root):
    observed = identity()
    root.mkdir(parents=True, exist_ok=False, mode=0o700)
    private = root / "private"; private.mkdir(mode=0o700)
    public = root / "summary.json"
    summary = {"schema": 2, "identity": observed, "build": None, "trials": [], "completed": False,
        "strict_checks_passed": False, "evidence_checks_passed": False, "temporary_cleanup": "not-run", "public_limit_bytes": PUBLIC_LIMIT}
    save_summary(public, summary)
    environment = dict(os.environ)
    for key in ("MallocScribble", "MallocStackLogging", "MallocStackLoggingNoCompact", "QUICKFILE_DISABLE_AX_COMPATIBILITY", "QUICKFILE_AX_INSTALL_PROBE_MODE"): environment.pop(key, None)
    cleanup_known = True
    try:
        prepared = private / "prepared"
        process = run_owned([sys.executable, str(ROOT / "Scripts/Investigations/verify-ax-compatibility.py"),
            "--prepare-external-fixture", "--work-directory", str(prepared), "--records-directory", str(private / "build-records")],
            private / "build.log", environment, timeout=RUN_TIMEOUT)
        summary["build"] = {"process_run": process, "manifest": None, "manifest_sha256": None}
        cleanup_known = process["cleanup"]["complete"]
        save_summary(public, summary)
        if process["return_code"] != 0 or not cleanup_known: return 1
        sources = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in fixture_sources()}
        manifest = load_prepared_build(prepared, sources)
        require(read_bytes(prepared / "fixture-build.json", 16384) == canonical(manifest))
        summary["build"].update(manifest=manifest, manifest_sha256=hashlib.sha256(canonical(manifest)).hexdigest())
        save_summary(public, summary)
        for block, order, arm in TRIALS:
            require(load_prepared_build(prepared, sources) == manifest)
            trial_root = private / f"block{block}-order{order}-{arm}"; trial_root.mkdir()
            records = trial_root / "records"
            process = run_owned([sys.executable, str(ROOT / "Scripts/Investigations/ax_reader_exit_trial.py"),
                "--prepared-fixture-directory", str(prepared), "--work-directory", str(trial_root / "fixture"),
                "--records-directory", str(records), "--arm", arm], trial_root / "runner.log", environment, timeout=RUN_TIMEOUT)
            row = {"block": block, "order": order, "arm": arm, "policy": policy(arm), "process_run": process,
                "measurement": None, "projection_reason": "unavailable", "strict_verdict": {"status": "not-evaluated", "failed_labels": []},
                "fixture_cleanup": None, "cleanup_confirmed": False}
            summary["trials"].append(row)
            try:
                raw = read_json(records / "trial.json", RAW_LIMIT)
                strict_verdict(raw["strict_verdict"])
                row["strict_verdict"] = raw["strict_verdict"]
                cleanup = read_json(records / "process-cleanup.json", 16384)
                require(cleanup == raw["cleanup"])
                row["fixture_cleanup"] = project_cleanup(cleanup)
            except (ValueError, RuntimeError, OSError, TypeError, KeyError, UnicodeError): pass
            cleanup_known = process["cleanup"]["complete"] and fixture_clean(row["fixture_cleanup"])
            row["cleanup_confirmed"] = cleanup_known
            try:
                require(load_prepared_build(prepared, sources) == manifest)
                row["measurement"] = project_trial(records, process, manifest["executables"], arm, sources)
                row["projection_reason"] = "none"
            except (ValueError, RuntimeError, OSError, TypeError, KeyError, UnicodeError):
                row["projection_reason"] = "invalid"
            save_summary(public, summary)
            print(json.dumps({"block": block, "order": order, "arm": arm, "strict": row["strict_verdict"]["status"],
                "projection": row["projection_reason"], "cleanup_confirmed": cleanup_known}), flush=True)
            if not cleanup_known: return 1
    except (ValueError, RuntimeError, OSError, TypeError, KeyError, UnicodeError):
        return 1
    finally:
        if cleanup_known:
            # Persist every collected trial and preflight the final receipt before
            # removing private evidence. A budget failure must retain that evidence.
            try:
                save_summary(public, summary)
                summary["temporary_cleanup"] = "complete"
                encode_summary(summary)
            except (ValueError, RuntimeError, OSError, TypeError, KeyError, UnicodeError):
                summary["temporary_cleanup"] = "failed"
                print("Public summary unavailable; private evidence retained", file=sys.stderr)
                return 1
            try:
                shutil.rmtree(private)
            except OSError: summary["temporary_cleanup"] = "failed"
        else: summary["temporary_cleanup"] = "retained-unconfirmed"
        save_summary(public, summary)
    return 0 if summary["strict_checks_passed"] and summary["evidence_checks_passed"] and summary["temporary_cleanup"] == "complete" else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-directory", required=True, type=Path)
    parser.add_argument("--validate-public", action="store_true")
    args = parser.parse_args(argv)
    root = args.work_directory.absolute()
    require(not any(path.is_symlink() for path in (root, *root.parents)))
    root = root.resolve()
    temporary = (ROOT / ".build/Temporary").resolve()
    require(root != temporary and root.is_relative_to(temporary))
    if args.validate_public:
        path = root / "summary.json"
        value = read_json(path, PUBLIC_LIMIT)
        require(read_bytes(path, PUBLIC_LIMIT) == encode_summary(value))
        return 0
    return campaign(root)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError, OSError, TypeError, KeyError, UnicodeError):
        print("Reader exit evidence validation failed", file=sys.stderr)
        raise SystemExit(1)
