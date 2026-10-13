"""Bounded ordinary AX scan evidence and one independent later heap snapshot.

Grouped live reports cannot identify original allocations. Snapshot-local IDs,
reference edges and stack addresses never establish allocation generations or
ownership. Collection errors supplement, rather than replace, the strict result.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import time

import ax_frozen_nodes as frozen
import ax_composition as composition
import ax_startup_baseline as startup
from ax_evidence_errors import EvidenceError, ExitUnconfirmed
from ax_probe_report import HEAP_LABELS, leak_groups
from ax_process import run_owned

PUBLIC_LIMIT = 262144
RAW_LIMIT = 16 * 1024 * 1024
GRAPH_LIMIT = 256 * 1024 * 1024
SECONDS = 45
NODE_LIMIT = 512
EDGE_LIMIT = 1024
GROUP_LIMIT = 64
LABELS = tuple(label for label in HEAP_LABELS if label != "added-10")
UNSUPPORTED = ("unsupported-images", "unsupported-architecture", "reader-not-trusted")
REASONS = ("result_unavailable", "result_mismatch", "scans_unavailable", "scan_missing", "scan_invalid", "scan_mismatch",
           "group_budget", "fixture_cleanup_unconfirmed", "capture_missing", "capture_invalid", "capture_failed",
           "graph_unavailable", "graph_changed", "graph_budget", "node_budget", "edge_budget",
           "list_invalid", "tree_invalid", "tool_failed", "deadline", "worker_failed",
           "process_exit_unconfirmed", "private_cleanup_failed", "startup_baseline_invalid")


def encoded(value):
    return (json.dumps(value, separators=(",", ":")) + "\n").encode()


def empty_scan(label):
    return {"label": label, "status": "unavailable", "binding": "unavailable", "stdout_sha256": None,
            "recorded_stdout_sha256": None, "exit_code": None, "leak_nodes": None, "leak_bytes": None,
            "unclassified_nodes": None, "root_instances": None, "destroyed_notification_stack_present": None,
            "unexpected_roots": None, "groups": [], "omitted_groups": 0, "omitted_root_instances": 0,
            "omitted_tree_nodes": 0, "composition": composition.empty_grouped(), "reasons": []}


def empty_terminal():
    return {"status": "not_attempted", "timing": "after-six-original-scans", "identity": "snapshot-local",
            "generation": "unknown", "ownership": "not-established", "capture_status": "not_attempted",
            "capture_exit_code": None, "graph_sha256": None, "leak_nodes": None, "leak_bytes": None,
            "nodes": [], "back_edges": [], "omitted_nodes": 0, "omitted_edges": 0, "tools": [],
            "process_cleanup_confirmed": True, "histogram": composition.empty_histogram(), "reasons": []}


def empty(status="not_attempted"):
    if status not in ("not_attempted", "unavailable"):
        raise ValueError("Invalid empty evidence status")
    scans = [empty_scan(label) for label in LABELS]
    return {"schema": 3, "status": status, "original_verdict": "unknown", "unsupported_reason": None,
            "baseline_protocol": "unknown", "startup_baseline": None,
            "original_address_coverage": "unavailable", "generation": "unknown", "inputs_sha256": None,
            "fixture_cleanup_confirmed": None, "process_cleanup_confirmed": True,
            "original_scans": scans, "strict_growth_labels": [], "composition_deltas": composition_deltas(scans),
            "strict_failure_labels": [], "terminal": empty_terminal(), "reasons": []}


def fail(value, reason):
    if reason not in value["reasons"]:
        value["reasons"].append(reason)
    value["status"] = "partial"


def sha(value):
    return type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def integer(value):
    return type(value) is int and 0 <= value <= 1_000_000_000


def json_file(path):
    return frozen.read_json(path, 1024 * 1024)


def unsupported_reason(inputs):
    if type(inputs) is not dict:
        return None
    host, reader = inputs.get("capabilities"), inputs.get("reader_capabilities")
    if type(host) is not dict or type(reader) is not dict or type(reader.get("trusted")) is not bool:
        return None
    if host.get("status") in UNSUPPORTED[:2] and host.get("enabled") is False:
        return host["status"]
    if host.get("status") == "enabled" and host.get("enabled") is True and reader["trusted"] is False:
        return "reader-not-trusted"
    return None


def scan_summary(label, entry, raw):
    value = empty_scan(label)
    value["stdout_sha256"] = hashlib.sha256(raw).hexdigest()
    if sha(entry.get("stdout_sha256")):
        value["recorded_stdout_sha256"] = entry["stdout_sha256"]
    try:
        report = raw.decode("utf-8")
        value["composition"] = composition.grouped_composition(report)
        nodes, size = frozen.totals(report)
        groups = leak_groups(report)
        if len(re.findall(r"^STACK OF ", report, re.M)) != len(groups):
            raise ValueError("Incomplete root groups")
        for group in groups:
            if (not integer(group["root_instances"]) or group["root_instances"] == 0
                    or group["tree_nodes"] is not None and not integer(group["tree_nodes"])):
                raise ValueError("Invalid group counts")
        unclassified = nodes - sum(group["tree_nodes"] or 0 for group in groups)
        roots = sum(group["root_instances"] for group in groups)
        if not integer(unclassified) or not integer(roots):
            raise ValueError("Invalid classification counts")
        destroyed = "_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification" in report
        value.update(status="complete", leak_nodes=nodes, leak_bytes=size, unclassified_nodes=unclassified,
            root_instances=roots, destroyed_notification_stack_present=destroyed,
            unexpected_roots=any(group["root_type"] != "NSXPCConnection" for group in groups))
        value["groups"] = [{"root_type": group["root_type"] if group["root_type"] in frozen.REFERENCE_TYPES else "unknown",
                            "root_kind": group["root_kind"] if group["root_kind"] in ("LEAK", "CYCLE") else "unknown",
                            "root_instances": group["root_instances"], "tree_nodes": group["tree_nodes"]}
                           for group in groups[:GROUP_LIMIT]]
        omitted = groups[GROUP_LIMIT:]
        value.update(omitted_groups=len(omitted), omitted_root_instances=sum(group["root_instances"] for group in omitted),
                     omitted_tree_nodes=sum(group["tree_nodes"] or 0 for group in omitted))
        if omitted:
            fail(value, "group_budget")
        code = entry.get("exit_code")
        if type(code) is int and -255 <= code <= 255:
            value["exit_code"] = code
        matched = (value["recorded_stdout_sha256"] == value["stdout_sha256"] and entry.get("label") == label
                   and entry.get("groups") == groups and code in (0, 1) and type(code) is int
                   and all(type(entry.get(key)) is int and entry[key] == value[key]
                           for key in ("leak_nodes", "leak_bytes", "unclassified_nodes"))
                   and type(entry.get("destroyed_notification_stack_present")) is bool
                   and entry["destroyed_notification_stack_present"] == destroyed)
        value["binding"] = "matched" if matched else "mismatch"
        if not matched:
            fail(value, "scan_mismatch")
    except (UnicodeError, ValueError, TypeError, KeyError, OverflowError):
        fail(value, "scan_invalid")
    return value


def composition_deltas(scans):
    def matched(row):
        return row["composition"] if row["binding"] == "matched" else composition.empty_grouped()
    return [{"label": row["label"], "delta": composition.composition_delta(matched(scans[0]), matched(row))} for row in scans[1:]]


def bound_compositions(value):
    """Supplemental size limits cannot weaken or fail the original evidence."""
    value["composition_deltas"] = composition_deltas(value["original_scans"])
    if len(encoded(value)) > PUBLIC_LIMIT:
        for row in value["original_scans"]:
            row["composition"] = composition.empty_grouped("summary_budget")
        if value["terminal"]["histogram"]["status"] != "unavailable":
            value["terminal"]["histogram"] = composition.empty_histogram("summary_budget")
        value["composition_deltas"] = composition_deltas(value["original_scans"])


def verdict_labels(scans):
    known = [row for row in scans if row["binding"] == "matched"]
    failures = [row["label"] for row in known if row["unclassified_nodes"] or
                row["destroyed_notification_stack_present"] or row["unexpected_roots"]]
    baseline = scans[0]
    growth = [row["label"] for row in known[1:] if any(row[key] > baseline[key]
              for key in ("leak_nodes", "leak_bytes", "root_instances"))] if baseline["binding"] == "matched" else []
    return growth, [row["label"] for row in scans if row["label"] in (*failures, *growth)]


def capture_receipt(value):
    if (type(value) is not dict or set(value) != {"status", "exit_code", "after_label", "graph_sha256"}
            or value["status"] not in ("not_attempted", "complete", "failed", "timeout")
            or value["exit_code"] is not None and (type(value["exit_code"]) is not int or not -255 <= value["exit_code"] <= 255)):
        raise ValueError("Invalid capture receipt")
    if value["status"] == "not_attempted":
        if any(value[key] is not None for key in ("exit_code", "after_label", "graph_sha256")):
            raise ValueError("Invalid unused capture")
    elif value["after_label"] != LABELS[-1]:
        raise ValueError("Invalid capture checkpoint")
    if value["status"] == "complete":
        if value["exit_code"] not in (0, 1) or not sha(value["graph_sha256"]):
            raise ValueError("Invalid complete capture")
    elif value["graph_sha256"] is not None:
        raise ValueError("Invalid failed capture hash")


def graph_hash(path, deadline):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise EvidenceError("graph_unavailable")
    if info.st_size > GRAPH_LIMIT:
        raise EvidenceError("graph_budget")
    result = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            if time.monotonic() >= deadline:
                raise EvidenceError("deadline")
            result.update(chunk)
    return result.hexdigest()


def terminal_snapshot(records, private, deadline):
    """Runs only in the collector's separately supervised process group."""
    value = empty_terminal()
    tools = frozen.Tools(private / "tools", value, deadline)
    try:
        capture = json_file(records / "failure-capture.json")
        capture_receipt(capture)
        value.update(status="complete", capture_status=capture["status"], capture_exit_code=capture["exit_code"], graph_sha256=capture["graph_sha256"])
        graph = records / "terminal.memgraph"
        if capture["status"] != "complete" or graph_hash(graph, deadline) != capture["graph_sha256"]:
            raise EvidenceError("graph_changed")
        report = tools.run("list", "terminal", ["/usr/bin/leaks", "--noContent", "--nosources", "--list", str(graph)], (0, 1))
        try:
            allocations, _ = frozen.parse_list(report)
        except ValueError:
            raise EvidenceError("list_invalid") from None
        value.update(leak_nodes=len(allocations), leak_bytes=sum(allocations.values()))
        if len(allocations) > NODE_LIMIT:
            value["omitted_nodes"] = len(allocations)
            raise EvidenceError("node_budget")
        report = tools.run("tree", "terminal", ["/usr/bin/leaks", "--noContent", "--nosources", str(graph)], (0, 1))
        try:
            parsed = frozen.parse_tree_graph(report, allocations)
        except ValueError:
            raise EvidenceError("tree_invalid") from None
        edges = sum(obj["parent"] is not None for obj in parsed["members"].values()) + len(parsed["back_edges"])
        if edges > EDGE_LIMIT:
            value.update(omitted_nodes=len(allocations), omitted_edges=edges)
            raise EvidenceError("edge_budget")
        ids = {address: number for number, address in enumerate(sorted(allocations))}
        value["nodes"] = [{"id": ids[address], "size": obj["size"],
            "type": obj["kind"] if obj["kind"] in frozen.REFERENCE_TYPES else "unknown", "protocol": obj["protocol"],
            "root": ids[parsed["roots"][obj["root"]]["address"]], "parent": ids.get(obj["parent"]), "label": obj["edge"],
            "root_kind": parsed["roots"][obj["root"]]["summary"]["root_kind"] if obj["parent"] is None else None}
            for address, obj in sorted(parsed["members"].items())]
        value["back_edges"] = [{"source": ids[edge["source"]], "target": ids[edge["target"]], "label": edge["label"]}
                               for edge in parsed["back_edges"]]
        value["histogram"] = composition.histogram_nodes(value["nodes"])
        if graph_hash(graph, deadline) != value["graph_sha256"]:
            raise EvidenceError("graph_changed")
    except ExitUnconfirmed:
        value["process_cleanup_confirmed"] = False
        fail(value, "process_exit_unconfirmed")
    except EvidenceError as error:
        fail(value, error.reason if error.reason in REASONS else "tool_failed")
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        fail(value, "graph_unavailable")
    if value["status"] != "complete":
        value["nodes"], value["back_edges"] = [], []
        value["histogram"] = composition.empty_histogram()
        value["omitted_nodes"] = value["leak_nodes"] or 0
    return value


def collect(records):
    deadline = time.monotonic() + SECONDS
    value = empty()
    value["status"] = "complete"
    try:
        raw = frozen.read_bytes(records / "inputs.json", 1024 * 1024)
        value["inputs_sha256"] = hashlib.sha256(raw).hexdigest()
        inputs = json.loads(raw)
        protocol = inputs.get("baseline_protocol", "immediate") if type(inputs) is dict else "unknown"
        if protocol in ("immediate", startup.PROTOCOL):
            value["baseline_protocol"] = protocol
        unsupported = unsupported_reason(inputs)
        if unsupported and not (records / "scans.json").exists():
            value.update(status="unsupported", original_verdict="unsupported", unsupported_reason=unsupported)
            return value
    except (OSError, ValueError, TypeError, KeyError):
        pass  # Ordinary raw scans and the strict result remain independently useful.
    try:
        result = json_file(records / "result.json")
        if result.get("coverage") not in ("passed", "failed"):
            raise ValueError("Unavailable ordinary verdict")
        value["original_verdict"] = result["coverage"]
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        fail(value, "result_unavailable")
    try:
        cleanup = json_file(records / "process-cleanup.json")
        confirmed = (cleanup.get("processes_exited") is True and cleanup.get("errors") == []
            and all(type(cleanup.get(role)) is dict and cleanup[role].get("exited") is True
                    and cleanup[role].get("errors") == [] for role in ("host", "reader")))
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        confirmed = False
    value["fixture_cleanup_confirmed"] = confirmed
    value["process_cleanup_confirmed"] = confirmed
    if not confirmed:
        fail(value, "fixture_cleanup_unconfirmed")
    try:
        scans = json_file(records / "scans.json")
        if (type(scans) is not list or len(scans) > len(LABELS) or any(type(row) is not dict for row in scans)
                or [row.get("label") for row in scans] != list(LABELS[:len(scans)])):
            raise ValueError("Invalid ordinary checkpoint sequence")
    except (OSError, ValueError, TypeError, KeyError):
        scans = []
        fail(value, "scans_unavailable")
    for index, label in enumerate(LABELS):
        if time.monotonic() >= deadline:
            fail(value, "deadline")
            break
        if index >= len(scans):
            fail(value["original_scans"][index], "scan_missing")
        else:
            try:
                raw = frozen.read_bytes(records / (label + "-original.stdout.txt"), RAW_LIMIT)
                value["original_scans"][index] = scan_summary(label, scans[index], raw)
            except (OSError, ValueError):
                fail(value["original_scans"][index], "scan_missing")
        for reason in value["original_scans"][index]["reasons"]:
            fail(value, reason)
    value["strict_growth_labels"], value["strict_failure_labels"] = verdict_labels(value["original_scans"])
    if value["baseline_protocol"] == startup.PROTOCOL:
        try:
            receipt = json_file(records / "startup-baseline.json")
            startup.validate(receipt)
            raw_scans = json_file(records / "startup-scans.json") if receipt["probes"] else []
            if (type(raw_scans) is not list or len(raw_scans) < len(receipt["probes"])
                    or len(raw_scans) > startup.POLICY["max_probes"]):
                raise ValueError("Incomplete startup scans")
            for index, probe in enumerate(receipt["probes"]):
                label = f"startup-{index}"
                raw = frozen.read_bytes(records / (label + "-original.stdout.txt"), RAW_LIMIT)
                entry = raw_scans[index]
                point = scan_summary(label, entry, raw)
                host = entry.get("host", {})
                if (point["status"] != "complete" or point["binding"] != "matched"
                        or point["unclassified_nodes"] or point["destroyed_notification_stack_present"]
                        or point["unexpected_roots"]
                        or any(type(host.get(key)) is not int or host[key] != 0 for key in (
                            "buttons", "allocatedButtons", "destroyedButtons", "compensations", "mutableCompensations"))
                        or any(probe[key] != point[key] for key in (
                            "stdout_sha256", "leak_nodes", "leak_bytes", "root_instances"))
                        or probe["signature_sha256"] != startup.fingerprint(entry, point["composition"])):
                    raise ValueError("Startup probe binding failed")
            value["startup_baseline"] = receipt
            if receipt["status"] == "observed-stable":
                selected = receipt["probes"][-1]
                baseline = value["original_scans"][0]
                if baseline["binding"] != "matched" or any(selected[key] != baseline[key] for key in (
                        "stdout_sha256", "leak_nodes", "leak_bytes", "root_instances")):
                    raise ValueError("Unbound startup baseline")
            elif value["original_verdict"] == "passed":
                raise ValueError("Unsettled startup cannot pass")
        except (OSError, ValueError, TypeError, KeyError, RuntimeError, AttributeError):
            fail(value, "startup_baseline_invalid")
    if value["original_verdict"] == "passed" and value["strict_failure_labels"]:
        fail(value, "result_mismatch")
    capture_path = records / "failure-capture.json"
    if capture_path.exists():
        terminal = value["terminal"]
        try:
            capture = json_file(capture_path)
            capture_receipt(capture)
            terminal.update(capture_status=capture["status"], capture_exit_code=capture["exit_code"], graph_sha256=capture["graph_sha256"])
            if capture["status"] != "not_attempted":
                if not confirmed:
                    raise EvidenceError("fixture_cleanup_unconfirmed")
                if (not all(row["binding"] == "matched" for row in value["original_scans"])
                        or value["original_verdict"] != "failed"):
                    raise EvidenceError("capture_invalid")
                if capture["status"] != "complete":
                    raise EvidenceError("capture_failed")
                remaining = deadline - time.monotonic() - 11  # Reserve the owned group exit and reap budget.
                if remaining <= 2:
                    raise EvidenceError("deadline")
                private = Path(tempfile.mkdtemp(prefix=".ax-ci-failure-", dir=records))
                outcome = None
                try:
                    outcome = run_owned([sys.executable, str(Path(__file__).resolve()), "--terminal-worker",
                        "--records", str(records), "--private", str(private), "--seconds", str(min(32, remaining))],
                        private / "worker.log", dict(os.environ), timeout=min(32, remaining))
                    if outcome["status"] != "completed" or outcome["command_return_code"] != 0:
                        fail(terminal, "worker_failed")
                    candidate = frozen.read_json(private / "terminal.json", PUBLIC_LIMIT)
                    validate_terminal(candidate)
                    if any(candidate[key] != capture[source] for key, source in (
                            ("capture_status", "status"), ("capture_exit_code", "exit_code"), ("graph_sha256", "graph_sha256"))):
                        raise EvidenceError("graph_changed")
                    terminal = candidate
                    value["terminal"] = terminal
                    if outcome["status"] != "completed" or outcome["command_return_code"] != 0:
                        fail(terminal, "worker_failed")
                finally:
                    if outcome is None or not outcome["cleanup"]["complete"]:
                        terminal["process_cleanup_confirmed"] = False
                        fail(terminal, "process_exit_unconfirmed")
                    if terminal["process_cleanup_confirmed"]:
                        try:
                            shutil.rmtree(private)
                        except OSError:
                            fail(terminal, "private_cleanup_failed")
        except EvidenceError as error:
            fail(terminal, error.reason if error.reason in REASONS else "tool_failed")
        except (OSError, ValueError, TypeError, KeyError, RecursionError):
            fail(terminal, "capture_invalid")
        for reason in terminal["reasons"]:
            fail(value, reason)
        value["process_cleanup_confirmed"] = confirmed and terminal["process_cleanup_confirmed"]
    else:
        fail(value, "capture_missing")
    bound_compositions(value)
    validate_public(value)
    return value


def validate_terminal(value):
    def require(ok):
        if not ok: raise ValueError("Invalid bounded terminal evidence")
    require(type(value) is dict and set(value) == set(empty_terminal()))
    for key in ("timing", "identity", "generation", "ownership"):
        require(value[key] == empty_terminal()[key])
    require(value["status"] in ("not_attempted", "partial", "complete"))
    require(value["capture_status"] in ("not_attempted", "complete", "failed", "timeout"))
    require(value["capture_exit_code"] is None or type(value["capture_exit_code"]) is int and -255 <= value["capture_exit_code"] <= 255)
    require(value["graph_sha256"] is None or sha(value["graph_sha256"]))
    capture_receipt({"status": value["capture_status"], "exit_code": value["capture_exit_code"],
        "after_label": None if value["capture_status"] == "not_attempted" else LABELS[-1], "graph_sha256": value["graph_sha256"]})
    require(type(value["reasons"]) is list and len(value["reasons"]) == len(set(value["reasons"])) and all(reason in REASONS for reason in value["reasons"]))
    require(type(value["process_cleanup_confirmed"]) is bool and type(value["tools"]) is list and len(value["tools"]) <= 2)
    for index, tool in enumerate(value["tools"]):
        require(type(tool) is dict and set(tool) == {"tool", "label", "status", "return_code", "cleanup_confirmed"})
        require(tool["tool"] == ("list", "tree")[index] and tool["label"] == "terminal" and tool["status"] in frozen.TOOL_STATES)
        require(type(tool["cleanup_confirmed"]) is bool and (tool["return_code"] is None or type(tool["return_code"]) is int and -255 <= tool["return_code"] <= 255))
        if tool["status"] == "complete": require(tool["return_code"] in (0, 1) and tool["cleanup_confirmed"])
    if value["process_cleanup_confirmed"]: require(all(tool["cleanup_confirmed"] for tool in value["tools"]))
    else: require("process_exit_unconfirmed" in value["reasons"])
    for key in ("leak_nodes", "leak_bytes"): require(value[key] is None or integer(value[key]))
    require((value["leak_nodes"] is None) == (value["leak_bytes"] is None))
    for key in ("omitted_nodes", "omitted_edges"): require(integer(value[key]))
    require(type(value["nodes"]) is list and len(value["nodes"]) <= NODE_LIMIT)
    require(type(value["back_edges"]) is list and len(value["back_edges"]) <= EDGE_LIMIT)
    for index, node in enumerate(value["nodes"]):
        require(type(node) is dict and set(node) == {"id", "size", "type", "protocol", "root", "parent", "label", "root_kind"})
        require(type(node["id"]) is int and node["id"] == index and integer(node["size"]) and node["size"] > 0)
        require(node["type"] in frozen.REFERENCE_TYPES and node["protocol"] in frozen.REFERENCE_PROTOCOLS and node["label"] in frozen.REFERENCE_LABELS)
        require(integer(node["root"]) and node["root"] < len(value["nodes"]))
        if node["parent"] is None:
            require(node["root"] == index and node["root_kind"] in ("cycle", "leak"))
        else:
            require(integer(node["parent"]) and node["parent"] < len(value["nodes"]) and node["root_kind"] is None)
    for node in value["nodes"]:
        reached, cursor = set(), node
        while cursor["parent"] is not None:
            require(cursor["id"] not in reached)
            reached.add(cursor["id"])
            cursor = value["nodes"][cursor["parent"]]
        require(cursor["id"] == node["root"])
    for edge in value["back_edges"]:
        require(type(edge) is dict and set(edge) == {"source", "target", "label"})
        require(all(integer(edge[key]) and edge[key] < len(value["nodes"]) for key in ("source", "target")))
        require(edge["label"] in frozen.REFERENCE_LABELS)
        node = value["nodes"][edge["source"]]
        ancestors = {node["id"]}
        while node["parent"] is not None:
            node = value["nodes"][node["parent"]]
            ancestors.add(node["id"])
        require(edge["target"] in ancestors)
    require(sum(node["parent"] is not None for node in value["nodes"]) + len(value["back_edges"]) <= EDGE_LIMIT)
    composition.validate_histogram(value["histogram"])
    if value["histogram"]["status"] != "unavailable":
        require(value["histogram"] == composition.histogram_nodes(value["nodes"]))
    elif value["status"] == "complete":
        require(value["histogram"]["reasons"] == ["summary_budget"])
    if value["nodes"]:
        require(value["leak_nodes"] == len(value["nodes"]) and value["leak_bytes"] == sum(node["size"] for node in value["nodes"]) and value["omitted_nodes"] == 0)
    if value["status"] == "complete":
        require(not value["reasons"] and value["process_cleanup_confirmed"] and value["capture_status"] == "complete")
        require(sha(value["graph_sha256"]) and value["capture_exit_code"] in (0, 1) and len(value["tools"]) == 2 and all(tool["status"] == "complete" for tool in value["tools"]))
        require(value["leak_nodes"] == len(value["nodes"]) and value["leak_bytes"] == sum(node["size"] for node in value["nodes"]))
        require(value["omitted_nodes"] == value["omitted_edges"] == 0)
    elif value["status"] == "not_attempted": require(value == empty_terminal())
    else: require(bool(value["reasons"]))


def validate_public(value):
    def require(ok):
        if not ok: raise ValueError("Invalid bounded ordinary AX evidence")
    require(type(value) is dict and set(value) == set(empty()))
    require(type(value["schema"]) is int and value["schema"] == 3 and value["original_address_coverage"] == "unavailable" and value["generation"] == "unknown")
    require(value["baseline_protocol"] in ("unknown", "immediate", startup.PROTOCOL))
    if value["startup_baseline"] is not None:
        require(value["baseline_protocol"] == startup.PROTOCOL)
        startup.validate(value["startup_baseline"])
        receipt = value["startup_baseline"]
        if receipt["status"] == "observed-stable":
            selected, baseline = receipt["probes"][-1], value["original_scans"][0]
            if baseline["binding"] != "matched" or any(selected[key] != baseline[key] for key in (
                    "stdout_sha256", "leak_nodes", "leak_bytes", "root_instances")):
                require("startup_baseline_invalid" in value["reasons"])
        elif value["original_verdict"] == "passed":
            require("startup_baseline_invalid" in value["reasons"])
    elif value["baseline_protocol"] == startup.PROTOCOL and value["status"] != "unsupported":
        require("startup_baseline_invalid" in value["reasons"])
    require(value["status"] in ("not_attempted", "unavailable", "unsupported", "partial", "complete"))
    require(value["original_verdict"] in ("unknown", "passed", "failed", "unsupported"))
    require(value["unsupported_reason"] is None or value["unsupported_reason"] in UNSUPPORTED)
    require(value["inputs_sha256"] is None or sha(value["inputs_sha256"]))
    require(value["fixture_cleanup_confirmed"] is None or type(value["fixture_cleanup_confirmed"]) is bool)
    require(type(value["process_cleanup_confirmed"]) is bool)
    require(type(value["reasons"]) is list and len(value["reasons"]) == len(set(value["reasons"])) and all(reason in REASONS for reason in value["reasons"]))
    require(type(value["original_scans"]) is list and len(value["original_scans"]) == len(LABELS))
    for label, row in zip(LABELS, value["original_scans"]):
        require(type(row) is dict and set(row) == set(empty_scan(label)) and row["label"] == label)
        require(row["status"] in ("unavailable", "partial", "complete") and row["binding"] in ("unavailable", "matched", "mismatch"))
        composition.validate_grouped_composition(row["composition"])
        if row["composition"]["counts_status"] == "complete":
            require(row["composition"]["total_nodes"] == row["leak_nodes"] and row["composition"]["total_bytes"] == row["leak_bytes"])
        for key in ("stdout_sha256", "recorded_stdout_sha256"): require(row[key] is None or sha(row[key]))
        require(row["exit_code"] is None or type(row["exit_code"]) is int and -255 <= row["exit_code"] <= 255)
        for key in ("leak_nodes", "leak_bytes", "unclassified_nodes", "root_instances"): require(row[key] is None or integer(row[key]))
        for key in ("destroyed_notification_stack_present", "unexpected_roots"): require(row[key] is None or type(row[key]) is bool)
        for key in ("omitted_groups", "omitted_root_instances", "omitted_tree_nodes"): require(integer(row[key]))
        require(type(row["groups"]) is list and len(row["groups"]) <= GROUP_LIMIT)
        for group in row["groups"]:
            require(type(group) is dict and set(group) == {"root_type", "root_kind", "root_instances", "tree_nodes"})
            require(group["root_type"] in frozen.REFERENCE_TYPES and group["root_kind"] in ("LEAK", "CYCLE", "unknown"))
            require(integer(group["root_instances"]) and group["root_instances"] > 0 and (group["tree_nodes"] is None or integer(group["tree_nodes"])))
        require(type(row["reasons"]) is list and len(row["reasons"]) == len(set(row["reasons"])) and all(reason in ("scan_missing", "scan_invalid", "scan_mismatch", "group_budget") for reason in row["reasons"]))
        if row["binding"] == "matched" or row["status"] == "complete":
            require(row["binding"] == "matched" and sha(row["stdout_sha256"]) and row["stdout_sha256"] == row["recorded_stdout_sha256"] and row["exit_code"] in (0, 1))
            require(all(row[key] is not None for key in ("leak_nodes", "leak_bytes", "unclassified_nodes", "root_instances", "destroyed_notification_stack_present", "unexpected_roots")))
        if row["leak_nodes"] is not None:
            require(row["root_instances"] == sum(group["root_instances"] for group in row["groups"]) + row["omitted_root_instances"])
            require(row["leak_nodes"] == row["unclassified_nodes"] + sum(group["tree_nodes"] or 0 for group in row["groups"]) + row["omitted_tree_nodes"])
            if not row["omitted_groups"]: require(row["unexpected_roots"] == any(group["root_type"] != "NSXPCConnection" for group in row["groups"]))
        if row["omitted_groups"]: require("group_budget" in row["reasons"] and row["status"] == "partial")
        else: require(row["omitted_root_instances"] == row["omitted_tree_nodes"] == 0)
        if row["status"] == "complete": require(not row["reasons"])
        if row["status"] == "partial": require(bool(row["reasons"]))
    require((value["strict_growth_labels"], value["strict_failure_labels"]) == verdict_labels(value["original_scans"]))
    require(value["composition_deltas"] == composition_deltas(value["original_scans"]))
    for entry, row in zip(value["composition_deltas"], value["original_scans"][1:]):
        before, after = (point["composition"] if point["binding"] == "matched" else composition.empty_grouped()
                         for point in (value["original_scans"][0], row))
        composition.validate_composition_delta(entry["delta"], before, after)
    if value["original_verdict"] == "passed" and value["strict_failure_labels"]:
        require(value["status"] == "partial" and "result_mismatch" in value["reasons"])
    validate_terminal(value["terminal"])
    require(value["process_cleanup_confirmed"] == (value["fixture_cleanup_confirmed"] is not False and value["terminal"]["process_cleanup_confirmed"]))
    if value["fixture_cleanup_confirmed"] is False: require("fixture_cleanup_unconfirmed" in value["reasons"])
    if value["status"] in ("not_attempted", "unavailable"): require(value == empty(value["status"]))
    elif value["status"] == "unsupported":
        require(value["original_verdict"] == "unsupported" and value["unsupported_reason"] in UNSUPPORTED and sha(value["inputs_sha256"]))
        require(value["original_scans"] == empty()["original_scans"] and not value["reasons"] and value["terminal"] == empty_terminal())
    elif value["status"] == "complete":
        require(value["original_verdict"] in ("passed", "failed") and value["fixture_cleanup_confirmed"] is True and value["process_cleanup_confirmed"] and not value["reasons"])
        require(all(row["status"] == "complete" for row in value["original_scans"]) and value["terminal"]["status"] in ("complete", "not_attempted"))
    else: require(bool(value["reasons"]))
    require(len(encoded(value)) <= PUBLIC_LIMIT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--terminal-worker", action="store_true")
    parser.add_argument("--records", type=Path, required=True)
    parser.add_argument("--private", type=Path)
    parser.add_argument("--seconds", type=float, default=32)
    args = parser.parse_args()
    if not args.terminal_worker:
        value = collect(args.records)
        print(encoded(value).decode(), end="")
        return 0 if value["status"] in ("complete", "unsupported") else 1
    try:
        if args.private is None or not 0 < args.seconds <= 32:
            return 1
        value = terminal_snapshot(args.records, args.private, time.monotonic() + args.seconds)
        validate_terminal(value)
        (args.private / "terminal.json").write_bytes(encoded(value))
        return 0
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
