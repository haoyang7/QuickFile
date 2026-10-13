#!/usr/bin/env python3
"""Fixed install-gate scan-timing experiment; only compact summary.json is public.

Single scans classify reported roots and do not evaluate growth. Reported root
and type net counts do not establish connection generations or root closure.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys

import ax_reader_exit_campaign as reader
from ax_external_receipt import (INSTALL_ENV, INSTALL_MODES, fixture_sources, load_prepared_build,
    validate_external_receipt, validate_hashes, validate_install_gate_build, validate_install_gate_state)
from ax_probe_report import leak_groups
from ax_process import run_owned

ROOT = Path(__file__).resolve().parents[2]
PUBLIC_LIMIT = 512 * 1024
RAW_LIMIT = reader.RAW_LIMIT
RUN_TIMEOUT = 180
PROTOCOL = "scan-timing-install-gate"
CONTROLS = {"early-only": (("baseline", 0),), "late-only": (("baseline", 20),),
    "twice": (("baseline", 0), ("t20", 20))}
CHECKPOINTS = (("t0", 0), ("t20", 20))
ORDERS = (
    (("early-only", "installed"), ("early-only", "preflight-only"), ("late-only", "preflight-only"),
     ("late-only", "installed"), ("twice", "installed"), ("twice", "preflight-only")),
    (("late-only", "installed"), ("late-only", "preflight-only"), ("twice", "preflight-only"),
     ("twice", "installed"), ("early-only", "preflight-only"), ("early-only", "installed")),
    (("twice", "installed"), ("twice", "preflight-only"), ("early-only", "preflight-only"),
     ("early-only", "installed"), ("late-only", "installed"), ("late-only", "preflight-only")))
TRIALS = tuple((block, order, control, mode) for block, cases in enumerate(ORDERS, 1)
    for order, (control, mode) in enumerate(cases, 1))
VERDICTS = ("not-evaluated", "passed", "failed")
require, fields, integer = reader.require, reader.fields, reader.integer
canonical, read_json, read_bytes = reader.canonical, reader.read_json, reader.read_bytes
composition = reader.composition


def policy(control):
    return {"checkpoint_schedule": [{"label": label, "offset_seconds": offset} for label, offset in CHECKPOINTS],
        "scan_schedule": [{"label": label, "offset_seconds": offset} for label, offset in CONTROLS[control]],
        "hold_until_seconds": 40, "exit_offset_seconds": None, "scan_timeout_seconds": 12,
        "checkpoint_timeout_seconds": 5, "stop_timeout_seconds": 5, "max_lateness_ms": 3000}


def policy_matches(value, control):
    # Key insertion order is not part of the fixed policy; numeric JSON types
    # remain significant (False, 0 and 0.0 must not compare equal).
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) == json.dumps(policy(control), sort_keys=True, separators=(",", ":"), allow_nan=False)


def environment(mode):
    return {role: dict(values, **{INSTALL_ENV: mode}) for role, values in reader.ENVIRONMENT.items()}


def gate_valid(value, mode):
    try:
        validate_install_gate_state(value, mode)
        return True
    except (ValueError, RuntimeError, TypeError, KeyError):
        return False


def validate_gate(value):
    if value is None: return
    fields(value, ("mode", "preflight_completed", "gate_calls", "copy_imp", "mutable_copy_imp"))
    require(value["mode"] in (*INSTALL_MODES, "invalid") and type(value["preflight_completed"]) is bool)
    require(integer(value["gate_calls"], 64))
    states = ("saved", "replacement", "other", "unavailable")
    require(value["copy_imp"] in states and value["mutable_copy_imp"] in states)


def project_host(raw):
    if raw is None: return None
    probe = raw.get("install_probe")
    if probe is not None:
        probe = {key: probe.get(key) for key in ("mode", "preflight_completed", "gate_calls", "copy_imp", "mutable_copy_imp")}
    value = {"activity": reader.activity(raw, reader.HOST_KEYS), "install_probe": probe}
    validate_host(value)
    return value


def validate_host(value):
    if value is None: return
    fields(value, ("activity", "install_probe"))
    reader.validate_activity(value["activity"], reader.HOST_KEYS)
    validate_gate(value["install_probe"])


def gates_valid(value, mode):
    hosts = [value["initial_host"], *[row["host"] for row in value["checkpoints"]]]
    return len(hosts) == 3 and all(host is not None and gate_valid(host["install_probe"], mode) for host in hosts)


def activity_zero(value):
    hosts = [value["initial_host"], *[row["host"] for row in value["checkpoints"]]]
    rows = [value["warm_activity"], value["completed_activity"], *[host["activity"] if host else None for host in hosts]]
    return all(row is not None and all(number == 0 for number in row.values()) for row in rows)


def strict_from_scans(scans):
    results = [row["result"] for row in scans if row["result"] is not None]
    failed = [row["label"] for index, row in enumerate(results)
              if not reader.classification_passed(row) or index and not reader.fits(row, results[0])]
    return {"status": "failed" if failed else "passed" if results else "not-evaluated", "failed_labels": failed}


def classification_verdict(value, control):
    statuses = [row["classification"] for row in value["scans"]]
    if "failed" in statuses: return "failed"
    return "passed" if len(statuses) == len(CONTROLS[control]) and all(status == "passed" for status in statuses) else "not-evaluated"


def growth_verdict(value, control):
    if control != "twice" or len(value["scans"]) != 2 or any(row["result"] is None for row in value["scans"]):
        return "not-evaluated"
    old, new = (row["result"] for row in value["scans"])
    return "failed" if (any(new[key] > old[key] for key in ("leak_nodes", "leak_bytes"))
        or reader.root_count(new) > reader.root_count(old)) else "passed"


def timing_valid(value, control):
    clock, timing, checkpoints = value["clock_markers"], value["exit_timing"], value["checkpoints"]
    if any(number is None for number in clock.values()) or clock["warm_ms"] != 0: return False
    if not clock["host_start_ms"] <= clock["host_ready_ms"] <= clock["reader_start_ms"] <= 0: return False
    stop, waited, notified = (timing[key + "_ms"] for key in ("stop_requested", "wait_returned", "notification_received"))
    if (stop is None or waited is None or notified is None or not 40000 <= stop <= waited <= 43000
            or notified < waited or timing["phase"] != "cleanup" or timing["return_code"] != 0): return False
    if len(checkpoints) != 2 or len(value["scans"]) != len(CONTROLS[control]): return False
    previous_end = 0
    for checkpoint in checkpoints:
        stage, target = checkpoint["checkpoint"], checkpoint["target_offset_ms"]
        if not stage_valid(stage, target, 5000) or stage["start_ms"] < previous_end: return False
        previous_end = stage["end_ms"]
        scans = [row for row in value["scans"] if row["checkpoint_label"] == checkpoint["label"]]
        for scan in scans:
            stage = scan["scan"]
            if not stage_valid(stage, scan["target_offset_ms"], 12000) or stage["start_ms"] < previous_end: return False
            previous_end = stage["end_ms"]
    return previous_end <= stop


def stage_valid(value, target, timeout):
    return (value is not None and value["start_ms"] is not None and value["end_ms"] is not None
        and target <= value["start_ms"] <= target + 3000 and 0 <= value["end_ms"] - value["start_ms"] <= timeout
        and value["reader_alive_before"] is True and value["reader_alive_after"] is True)


def project_scan(raw, records, target, checkpoint_label):
    row = {"label": raw["label"], "target_offset_ms": target * 1000, "checkpoint_label": checkpoint_label,
        "scan": reader.window(raw["scan"]), "stdout_sha256": None, "result": None,
        "classification": "not-evaluated", "composition": composition.empty_grouped(), "earlier_scan_delta": None}
    text = None
    if raw.get("stdout_sha256") is not None:
        data = reader.read_stdout(records / (raw["label"] + "-original.stdout.txt"), allow_empty=raw.get("leak_nodes") is None)
        require(hashlib.sha256(data).hexdigest() == raw["stdout_sha256"])
        row["stdout_sha256"] = raw["stdout_sha256"]
        text = data.decode("utf-8")
    if raw.get("leak_nodes") is not None:
        require(text is not None)
        totals = re.findall(r"(\d+) leaks for (\d+) total leaked bytes", text)
        require(len(totals) == 1 and tuple(map(int, totals[0])) == (raw["leak_nodes"], raw["leak_bytes"]))
        actual = leak_groups(text)
        require(actual == raw["groups"] and raw["destroyed_notification_stack_present"] == ("_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification" in text))
        row["result"] = {key: raw[key] for key in ("label", "leak_nodes", "leak_bytes", "unclassified_nodes", "destroyed_notification_stack_present", "exit_code", "stdout_sha256")}
        row["result"]["groups"] = reader.groups_projection(actual)
        reader.validate_scan(row["result"], raw["label"])
        row["classification"] = "passed" if reader.classification_passed(row["result"]) else "failed"
        row["composition"] = composition.grouped_composition(text)
        row["composition"]["failure_fragment"] = None
    return row


def project_trial(records, process, expected, control, mode, sources=None):
    """Project one local trial without claiming the complete remote identity."""
    reader.validate_process(process)
    raw = read_json(records / "trial.json", RAW_LIMIT)
    require(type(raw.get("schema")) is int and raw["schema"] == 2 and raw.get("arm") == "keep")
    require(raw.get("timing_control") == control and raw.get("install_gate") == mode and policy_matches(raw.get("policy"), control))
    require(raw.get("executables") in (None, expected))
    if sources is not None and raw["executables"] is not None:
        require(read_json(records / "inputs.json", RAW_LIMIT).get("sources") == sources)
    startup = raw.get("external_startup")
    if startup is not None: require(read_json(records / "external-startup.json", 16384) == startup)
    try:
        validate_external_receipt(startup, "off", expected, install_gate=mode)
    except (ValueError, RuntimeError, TypeError, KeyError): startup = None
    markers = raw["clock_markers"]
    fields(markers, ("origin_monotonic", "host_start", "host_ready", "reader_start", "warm"))
    clock = {key + "_ms": reader.milliseconds(markers[key]) if markers["origin_monotonic"] is not None else None
        for key in ("host_start", "host_ready", "reader_start", "warm")}
    raw_timing = raw["exit_timing"]
    fields(raw_timing, ("target_offset_seconds", "stop_requested", "wait_returned", "notification_received", "return_code", "phase"))
    require(raw_timing["target_offset_seconds"] is None)
    timing = {"target_offset_ms": None, **{key + "_ms": reader.milliseconds(raw_timing[key])
        for key in ("stop_requested", "wait_returned", "notification_received")}, "return_code": raw_timing["return_code"], "phase": raw_timing["phase"]}
    require(type(raw["checkpoints"]) is list and len(raw["checkpoints"]) <= 2)
    for index, row in enumerate(raw["checkpoints"]):
        label, offset = CHECKPOINTS[index]
        require(row.get("label") == label and type(row.get("target_offset_seconds")) is int and row["target_offset_seconds"] == offset)
    require(type(raw["scans"]) is list and len(raw["scans"]) <= len(CONTROLS[control]))
    checkpoints = [{"label": row["label"], "target_offset_ms": row["target_offset_seconds"] * 1000,
        "checkpoint": reader.window(row["checkpoint"]), "host": project_host(row["host"])} for row in raw["checkpoints"]]
    scans = []
    for index, row in enumerate(raw["scans"]):
        require(index < len(CONTROLS[control]))
        label, offset = CONTROLS[control][index]
        require(row["label"] == label and type(row["target_offset_seconds"]) is int and row["target_offset_seconds"] == offset)
        matched = [checkpoint for checkpoint in raw["checkpoints"] if checkpoint["target_offset_seconds"] == offset]
        require(len(matched) == 1 and row["host"] == matched[0]["host"] and row["checkpoint"] == matched[0]["checkpoint"])
        projected = project_scan(row, records, offset, matched[0]["label"])
        if index: projected["earlier_scan_delta"] = composition.composition_delta(scans[0]["composition"], projected["composition"])
        scans.append(projected)
    value = {"status": raw["status"], "reason": raw["reason"], "executables": raw["executables"], "external_startup": startup,
        "environments": raw["environments"], "clock_markers": clock, "exit_timing": timing, "initial_host": project_host(raw["initial_host_receipt"]),
        "checkpoints": checkpoints, "scans": scans, "warm_activity": reader.activity(raw["warm_receipt"], (*reader.READER_KEYS, "buttons", "registrations")),
        "completed_activity": reader.activity(raw["completed_receipt"], reader.READER_KEYS), "original_strict_verdict": raw["strict_verdict"],
        "classification_verdict": "not-evaluated", "growth_verdict": "not-evaluated", "timing_valid": False, "activity_zero": False, "gate_valid": False}
    value.update(classification_verdict=classification_verdict(value, control), growth_verdict=growth_verdict(value, control),
        timing_valid=timing_valid(value, control), activity_zero=activity_zero(value), gate_valid=gates_valid(value, mode))
    validate_measurement(value, expected, control, mode)
    return value


def validate_measurement(value, expected, control, mode):
    reader.no_floats(value)
    fields(value, ("status", "reason", "executables", "external_startup", "environments", "clock_markers", "exit_timing", "initial_host", "checkpoints", "scans",
        "warm_activity", "completed_activity", "original_strict_verdict", "classification_verdict", "growth_verdict", "timing_valid", "activity_zero", "gate_valid"))
    require(value["status"] in ("complete", "failed", "not-covered") and value["reason"] in (None, *reader.REASONS))
    require((value["status"] == "complete") == (value["reason"] is None))
    if value["status"] == "not-covered": require(value["reason"] in reader.REASONS[-3:])
    require(value["executables"] in (None, expected))
    if value["executables"] is not None: validate_hashes(value["executables"])
    if value["external_startup"] is not None: validate_external_receipt(value["external_startup"], "off", expected, install_gate=mode)
    fields(value["environments"], ("host", "reader"))
    for entry in value["environments"].values():
        if entry is not None:
            fields(entry, environment(mode)["host"])
            require(all(entry[key] in ("1", "unset") for key in reader.ENVIRONMENT["host"]))
            require(entry[INSTALL_ENV] in INSTALL_MODES)
    fields(value["clock_markers"], ("host_start_ms", "host_ready_ms", "reader_start_ms", "warm_ms"))
    require(all(number is None or reader.ms(number, signed=True) for number in value["clock_markers"].values()))
    require(value["clock_markers"]["warm_ms"] in (None, 0))
    timing = value["exit_timing"]
    fields(timing, ("target_offset_ms", "stop_requested_ms", "wait_returned_ms", "notification_received_ms", "return_code", "phase"))
    require(timing["target_offset_ms"] is None and timing["phase"] in (None, "cleanup"))
    require(timing["return_code"] is None or type(timing["return_code"]) is int and -127 <= timing["return_code"] <= 255)
    previous = None
    for key in ("stop_requested_ms", "wait_returned_ms", "notification_received_ms"):
        number = timing[key]; require(number is None or reader.ms(number))
        if number is not None: require(key == "stop_requested_ms" or previous is not None and number >= previous)
        previous = number
    if timing["stop_requested_ms"] is not None: require(timing["phase"] == "cleanup")
    validate_host(value["initial_host"])
    reader.validate_activity(value["warm_activity"], (*reader.READER_KEYS, "buttons", "registrations"))
    reader.validate_activity(value["completed_activity"], reader.READER_KEYS)
    require(type(value["checkpoints"]) is list and len(value["checkpoints"]) <= 2)
    require([row["label"] for row in value["checkpoints"]] == [label for label, _ in CHECKPOINTS[:len(value["checkpoints"])]])
    for row in value["checkpoints"]:
        fields(row, ("label", "target_offset_ms", "checkpoint", "host"))
        require(type(row["target_offset_ms"]) is int and row["target_offset_ms"] == dict(CHECKPOINTS)[row["label"]] * 1000)
        reader.validate_window(row["checkpoint"]); validate_host(row["host"])
    require(type(value["scans"]) is list and len(value["scans"]) <= len(CONTROLS[control]))
    for index, row in enumerate(value["scans"]):
        fields(row, ("label", "target_offset_ms", "checkpoint_label", "scan", "stdout_sha256", "result", "classification", "composition", "earlier_scan_delta"))
        label, offset = CONTROLS[control][index]
        require(row["label"] == label and type(row["target_offset_ms"]) is int and row["target_offset_ms"] == offset * 1000)
        require(row["checkpoint_label"] == dict((offset, label) for label, offset in CHECKPOINTS)[offset])
        require(any(checkpoint["label"] == row["checkpoint_label"] for checkpoint in value["checkpoints"]))
        reader.validate_window(row["scan"])
        require(row["stdout_sha256"] is None or reader.digest(row["stdout_sha256"]))
        if row["result"] is not None:
            reader.validate_scan(row["result"], label)
            require(row["stdout_sha256"] == row["result"]["stdout_sha256"])
        require(row["classification"] == ("not-evaluated" if row["result"] is None else "passed" if reader.classification_passed(row["result"]) else "failed"))
        composition.validate_grouped_composition(row["composition"]); require(row["composition"]["failure_fragment"] is None)
        if row["composition"]["total_nodes"] is not None and row["result"] is not None:
            require((row["composition"]["total_nodes"], row["composition"]["total_bytes"]) == (row["result"]["leak_nodes"], row["result"]["leak_bytes"]))
        if index: composition.validate_composition_delta(row["earlier_scan_delta"], value["scans"][0]["composition"], row["composition"])
        else: require(row["earlier_scan_delta"] is None)
    reader.strict_verdict(value["original_strict_verdict"])
    require(value["original_strict_verdict"] == strict_from_scans(value["scans"]))
    require(value["classification_verdict"] == classification_verdict(value, control) and value["growth_verdict"] == growth_verdict(value, control))
    for key, derived in (("timing_valid", timing_valid(value, control)), ("activity_zero", activity_zero(value)), ("gate_valid", gates_valid(value, mode))):
        require(type(value[key]) is bool and value[key] == derived)
    if value["status"] == "complete":
        require(len(value["scans"]) == len(CONTROLS[control]) and all(row["result"] is not None for row in value["scans"]))
        require(value["executables"] == expected and value["external_startup"] is not None and value["environments"] == environment(mode))
        require(value["timing_valid"] and value["activity_zero"] and value["gate_valid"])


def evidence_passed(row):
    value, process = row["measurement"], row["process_run"]
    return (value is not None and value["status"] == "complete" and row["cleanup_confirmed"]
        and process["status"] == "completed" and process["command_return_code"] == (1 if row["original_strict_verdict"]["status"] == "failed" else 0))


def conclusions(value):
    trials = value["trials"]; completed = len(trials) == 18
    evidence = completed and all(evidence_passed(row) for row in trials)
    classified = completed and all(evidence_passed(row) and row["classification_verdict"] == "passed" for row in trials)
    twice = [row for row in trials if row["timing_control"] == "twice"]
    growth = completed and len(twice) == 6 and all(evidence_passed(row) and row["growth_verdict"] == "passed" for row in twice)
    return completed, evidence, classified, growth


def validate_identity(value):
    require(type(value) is dict and value.get("scan_mode") == PROTOCOL)
    reader.validate_identity(dict(value, scan_mode="reader-exit"))


def validate_summary(value):
    reader.no_floats(value)
    fields(value, ("schema", "protocol", "identity", "build", "trials", "completed", "evidence_checks_passed", "classification_checks_passed", "growth_checks_passed",
        "single_group_growth_verdict", "temporary_cleanup", "public_limit_bytes"))
    require(type(value["schema"]) is int and value["schema"] == 1 and value["protocol"] == PROTOCOL and value["public_limit_bytes"] == PUBLIC_LIMIT)
    require(value["single_group_growth_verdict"] == "not-evaluated")
    validate_identity(value["identity"])
    require(value["temporary_cleanup"] in ("not-run", "complete", "retained-unconfirmed", "failed"))
    expected = None
    if value["build"] is not None:
        build = value["build"]; fields(build, ("process_run", "manifest", "manifest_sha256")); reader.validate_process(build["process_run"])
        manifest = build["manifest"]
        if manifest is None: require(build["manifest_sha256"] is None)
        else:
            fields(manifest, ("schema", "build_mode", "sources", "executables", "build_evidence"))
            require(type(manifest["schema"]) is int and manifest["schema"] == 3 and manifest["build_mode"] == "install-gate")
            fields(manifest["sources"], fixture_sources("install-gate")); require(all(reader.digest(number) for number in manifest["sources"].values()))
            validate_hashes(manifest["executables"]); validate_install_gate_build(manifest["build_evidence"])
            require(build["manifest_sha256"] == hashlib.sha256(canonical(manifest)).hexdigest())
            require(build["process_run"]["return_code"] == 0 and build["process_run"]["cleanup"]["complete"])
            expected = manifest["executables"]
    require(type(value["trials"]) is list and len(value["trials"]) <= 18)
    for index, row in enumerate(value["trials"]):
        fields(row, ("block", "order", "timing_control", "install_gate", "policy", "process_run", "measurement", "projection_reason", "original_strict_verdict",
            "classification_verdict", "growth_verdict", "fixture_cleanup", "cleanup_confirmed"))
        require(expected is not None and type(row["block"]) is int and type(row["order"]) is int)
        require((row["block"], row["order"], row["timing_control"], row["install_gate"]) == TRIALS[index])
        require(policy_matches(row["policy"], row["timing_control"]))
        reader.validate_process(row["process_run"]); reader.strict_verdict(row["original_strict_verdict"]); reader.validate_cleanup(row["fixture_cleanup"])
        require(row["original_strict_verdict"]["failed_labels"] == [label for label, _ in CONTROLS[row["timing_control"]] if label in row["original_strict_verdict"]["failed_labels"]])
        require(row["projection_reason"] in reader.PROJECTION_REASONS and (row["measurement"] is not None) == (row["projection_reason"] == "none"))
        if row["measurement"] is not None:
            validate_measurement(row["measurement"], expected, row["timing_control"], row["install_gate"])
            require(all(row[key] == row["measurement"][key] for key in ("original_strict_verdict", "classification_verdict", "growth_verdict")))
        else: require(row["classification_verdict"] == row["growth_verdict"] == "not-evaluated")
        require(type(row["cleanup_confirmed"]) is bool and row["cleanup_confirmed"] == (row["process_run"]["cleanup"]["complete"] and reader.fixture_clean(row["fixture_cleanup"])))
        if index < len(value["trials"]) - 1: require(row["cleanup_confirmed"])
    for key, derived in zip(("completed", "evidence_checks_passed", "classification_checks_passed", "growth_checks_passed"), conclusions(value)):
        require(type(value[key]) is bool and value[key] == derived)
    cleanup_known = (value["build"] is None or value["build"]["process_run"]["cleanup"]["complete"]) and all(row["cleanup_confirmed"] for row in value["trials"])
    if value["temporary_cleanup"] == "complete": require(cleanup_known)
    if value["temporary_cleanup"] == "retained-unconfirmed": require(not cleanup_known)
    require(len(public_bytes(value)) <= PUBLIC_LIMIT)


def public_bytes(value):
    return (json.dumps(value, separators=(",", ":"), allow_nan=False) + "\n").encode()


def encode_summary(value):
    validate_summary(value)
    return public_bytes(value)


def bound_summary(value):
    if len(public_bytes(value)) <= PUBLIC_LIMIT - reader.FINAL_RECEIPT_RESERVE: return
    for trial in value["trials"]:
        if trial["measurement"] is None: continue
        scans = trial["measurement"]["scans"]
        for row in scans:
            old = row["composition"]
            totals = (old["total_nodes"], old["total_bytes"]) if old["total_nodes"] is not None else None
            row["composition"] = composition.empty_grouped("summary_budget", totals)
        for index, row in enumerate(scans):
            row["earlier_scan_delta"] = composition.composition_delta(scans[0]["composition"], row["composition"]) if index else None
    require(len(public_bytes(value)) <= PUBLIC_LIMIT - reader.FINAL_RECEIPT_RESERVE)


def save_summary(path, value):
    for key, derived in zip(("completed", "evidence_checks_passed", "classification_checks_passed", "growth_checks_passed"), conclusions(value)): value[key] = derived
    bound_summary(value); payload = encode_summary(value)
    temporary = path.with_suffix(".tmp")
    require(not path.is_symlink() and not temporary.is_symlink())
    temporary.write_bytes(payload); temporary.replace(path)


def identity():
    value = reader.identity(); value["scan_mode"] = PROTOCOL
    validate_identity(value)
    return value


def campaign(root):
    observed = identity(); root.mkdir(parents=True, exist_ok=False, mode=0o700)
    private = root / "private"; private.mkdir(mode=0o700)
    public = root / "summary.json"
    summary = {"schema": 1, "protocol": PROTOCOL, "identity": observed, "build": None, "trials": [], "completed": False,
        "evidence_checks_passed": False, "classification_checks_passed": False, "growth_checks_passed": False,
        "single_group_growth_verdict": "not-evaluated", "temporary_cleanup": "not-run", "public_limit_bytes": PUBLIC_LIMIT}
    save_summary(public, summary)
    env = dict(os.environ)
    for key in (*reader.ENVIRONMENT["host"], "QUICKFILE_DISABLE_AX_COMPATIBILITY", INSTALL_ENV): env.pop(key, None)
    cleanup_known = True
    try:
        prepared = private / "prepared"
        process = run_owned([sys.executable, str(ROOT / "Scripts/Investigations/verify-ax-compatibility.py"), "--prepare-install-gate-fixture",
            "--work-directory", str(prepared), "--records-directory", str(private / "build-records")], private / "build.log", env, timeout=RUN_TIMEOUT)
        summary["build"] = {"process_run": process, "manifest": None, "manifest_sha256": None}
        cleanup_known = process["cleanup"]["complete"]; save_summary(public, summary)
        if process["return_code"] != 0 or not cleanup_known: return 1
        sources = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in fixture_sources("install-gate")}
        manifest = load_prepared_build(prepared, sources, "install-gate")
        require(read_bytes(prepared / "fixture-build.json", 16384) == canonical(manifest))
        summary["build"].update(manifest=manifest, manifest_sha256=hashlib.sha256(canonical(manifest)).hexdigest()); save_summary(public, summary)
        for block, order, control, mode in TRIALS:
            require(load_prepared_build(prepared, sources, "install-gate") == manifest)
            case = private / f"block{block}-order{order}"; case.mkdir(); records = case / "records"
            process = run_owned([sys.executable, str(ROOT / "Scripts/Investigations/ax_reader_exit_trial.py"), "--prepared-fixture-directory", str(prepared),
                "--work-directory", str(case / "fixture"), "--records-directory", str(records), "--arm", "keep", "--timing-control", control,
                "--install-gate", mode], case / "runner.log", env, timeout=RUN_TIMEOUT)
            row = {"block": block, "order": order, "timing_control": control, "install_gate": mode, "policy": policy(control), "process_run": process,
                "measurement": None, "projection_reason": "unavailable", "original_strict_verdict": {"status": "not-evaluated", "failed_labels": []},
                "classification_verdict": "not-evaluated", "growth_verdict": "not-evaluated", "fixture_cleanup": None, "cleanup_confirmed": False}
            summary["trials"].append(row)
            raw = None
            try:
                raw = read_json(records / "trial.json", RAW_LIMIT)
                reader.strict_verdict(raw["strict_verdict"])
                require(raw["strict_verdict"]["failed_labels"] == [label for label, _ in CONTROLS[control] if label in raw["strict_verdict"]["failed_labels"]])
                row["original_strict_verdict"] = raw["strict_verdict"]
            except (ValueError, RuntimeError, OSError, TypeError, KeyError, UnicodeError): pass
            try:
                cleanup = read_json(records / "process-cleanup.json", 16384); require(cleanup == raw["cleanup"])
                row["fixture_cleanup"] = reader.project_cleanup(cleanup)
            except (ValueError, RuntimeError, OSError, TypeError, KeyError, UnicodeError): pass
            cleanup_known = process["cleanup"]["complete"] and reader.fixture_clean(row["fixture_cleanup"]); row["cleanup_confirmed"] = cleanup_known
            try:
                require(load_prepared_build(prepared, sources, "install-gate") == manifest)
                row["measurement"] = project_trial(records, process, manifest["executables"], control, mode, sources)
                row["projection_reason"] = "none"
                for key in ("classification_verdict", "growth_verdict"): row[key] = row["measurement"][key]
            except (ValueError, RuntimeError, OSError, TypeError, KeyError, UnicodeError): row["projection_reason"] = "invalid"
            save_summary(public, summary)
            print(json.dumps({"block": block, "order": order, "timing_control": control, "install_gate": mode,
                "classification": row["classification_verdict"], "growth": row["growth_verdict"], "cleanup_confirmed": cleanup_known}), flush=True)
            if not cleanup_known: return 1
    except (ValueError, RuntimeError, OSError, TypeError, KeyError, UnicodeError): return 1
    finally:
        if cleanup_known:
            try:
                save_summary(public, summary); summary["temporary_cleanup"] = "complete"; encode_summary(summary)
            except (ValueError, RuntimeError, OSError, TypeError, KeyError, UnicodeError):
                print("Public summary unavailable; private evidence retained", file=sys.stderr)
                return 1
            try: shutil.rmtree(private)
            except OSError: summary["temporary_cleanup"] = "failed"
        else: summary["temporary_cleanup"] = "retained-unconfirmed"
        save_summary(public, summary)
    return 0 if all(summary[key] for key in ("completed", "evidence_checks_passed", "classification_checks_passed", "growth_checks_passed")) and summary["temporary_cleanup"] == "complete" else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-directory", required=True, type=Path); parser.add_argument("--validate-public", action="store_true")
    args = parser.parse_args(argv); root = args.work_directory.absolute()
    require(not any(path.is_symlink() for path in (root, *root.parents)))
    root = root.resolve(); temporary = (ROOT / ".build/Temporary").resolve()
    require(root != temporary and root.is_relative_to(temporary))
    if args.validate_public:
        path = root / "summary.json"; value = read_json(path, PUBLIC_LIMIT)
        require(read_bytes(path, PUBLIC_LIMIT) == encode_summary(value)); return 0
    return campaign(root)


if __name__ == "__main__":
    try: raise SystemExit(main())
    except (ValueError, RuntimeError, OSError, TypeError, KeyError, UnicodeError):
        print("Scan timing evidence validation failed", file=sys.stderr); raise SystemExit(1)
