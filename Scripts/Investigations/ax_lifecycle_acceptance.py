"""AX lifecycle acceptance, separate from the unchanged strict heap verdict.

Known-root growth has no magnitude exemption here: it remains an unresolved
strict failure, but is outside this policy's lifecycle acceptance boundary.
"""
from functools import lru_cache
import hashlib
import importlib.util
import json
from pathlib import Path

import ax_ci_failure as evidence
from ax_external_receipt import fixture_sources
from ax_frozen_nodes import read_bytes, read_json

POLICY = "ax-lifecycle-v1"
KINDS = ("ordinary", "copy-lifetime", "negative-control")
LABELS = list(evidence.LABELS)
LIMIT = 16384
ROOT = Path(__file__).resolve().parents[2]


def require(ok):
    if not ok:
        raise ValueError("Invalid AX lifecycle evidence")


def receipt_fields(value, fields):
    require(type(value) is dict)
    missing = sorted(set(fields) - value.keys())
    if missing:
        # Only fixed contract keys enter diagnostics, never receipt values.
        raise ValueError("AX receipt incomplete: missing fields " + ", ".join(missing))


@lru_cache(maxsize=1)
def runner():
    spec = importlib.util.spec_from_file_location("ax_acceptance_runner", Path(__file__).with_name("verify-ax-compatibility.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def activity(receipt):
    require(type(receipt) is dict)
    cleanup = receipt.get("cleanup")
    if type(cleanup) is dict and cleanup.get("primary_exception") is True:
        require(receipt.get("coverage") == "failed")
        raise ValueError("AX receipt incomplete: runner aborted")
    receipt_fields(receipt, ("destroyed_buttons", "notifications", "ordinary_compensations",
                             "mutable_compensations", "notification_receipt", "cleanup"))
    probe = runner()
    for key, expected in (("destroyed_buttons", 30), ("notifications", 60)):
        require(type(receipt[key]) is int and receipt[key] == expected)
    for key in ("ordinary_compensations", "mutable_compensations"):
        require(type(receipt[key]) is int and receipt[key] >= 30)
    receipt_fields(receipt["notification_receipt"], ("notifications", "all_notifications",
                   "unmatched_notifications", "tracked_buttons", "target_notification_counts"))
    probe.validate_notifications(receipt["notification_receipt"], 30)
    require(receipt["notification_receipt"]["notifications"] == receipt["notifications"])
    receipt_fields(cleanup, ("primary_exception", "processes_exited", "errors", "host", "reader"))
    require(cleanup["primary_exception"] is False and cleanup["processes_exited"] is True and cleanup["errors"] == [])
    for role in ("host", "reader"):
        row = cleanup[role]
        receipt_fields(row, ("started", "exited", "errors", "return_code"))
        require(row["started"] is True and row["exited"] is True and row["errors"] == []
                and type(row["return_code"]) is int and row["return_code"] == 0)


def scan_valid(row):
    require(type(row["exit_code"]) is int and row["exit_code"] in (0, 1))
    for key in ("leak_nodes", "leak_bytes", "unclassified_nodes"):
        require(evidence.integer(row[key]))
    require(type(row["destroyed_notification_stack_present"]) is bool)
    require(type(row["groups"]) is list and len(row["groups"]) <= evidence.GROUP_LIMIT)
    for group in row["groups"]:
        require(evidence.integer(group["tree_nodes"]) and evidence.integer(group["root_instances"])
                and group["root_instances"] > 0)
    require(sum(group["tree_nodes"] for group in row["groups"]) + row["unclassified_nodes"] == row["leak_nodes"])


def counts(row):
    return {"label": row["label"], "leak_nodes": row["leak_nodes"], "leak_bytes": row["leak_bytes"],
            "root_instances": sum(group["root_instances"] for group in row["groups"])}


def growth_labels(scans):
    baseline = scans[0]
    return [row["label"] for row in scans[1:]
            if any(row[key] > baseline[key] for key in ("leak_nodes", "leak_bytes", "root_instances"))]


def evaluate(kind, receipt, code):
    """Reject all failures except recomputed ordinary, fully classified growth."""
    require(kind in KINDS and type(code) is int)
    activity(receipt)
    receipt_fields(receipt, ("coverage", "mode", "instrumented", "copy_lifetime") if kind == "copy-lifetime"
                   else ("coverage", "startup_baseline", "scans"))
    probe = runner()
    if kind == "copy-lifetime":
        require(code == 0 and receipt["coverage"] == "passed" and not receipt.get("validation_errors")
                and receipt["mode"] == kind and receipt["instrumented"] is True)
        require(receipt["copy_lifetime"] == {"ordinary": 30, "mutable": 30,
                                           "liveOrdinary": 0, "liveMutable": 0, "invalid": 0})
        return []
    probe.ax_startup_baseline.validate(receipt["startup_baseline"])
    require(receipt["startup_baseline"]["status"] == "observed-stable")
    scans = receipt["scans"]
    require([row["label"] for row in scans] == LABELS)
    for row in scans:
        scan_valid(row)
    values = [counts(row) for row in scans]
    labels = [row["stage"] for row in receipt.get("validation_errors", [])]
    if kind == "ordinary":
        for row in scans:
            require(row["destroyed_notification_stack_present"] is False)
            probe.validate_product_scan(row)
        growth = growth_labels(values)
        require(labels == growth and code == (1 if growth else 0)
                and receipt["coverage"] == ("failed" if growth else "passed"))
    else:
        require(code == 1 and receipt["coverage"] == "failed")
        require(receipt["ordinary_compensations"] == receipt["mutable_compensations"] == 30)
        for row in scans[:2]:
            require(row["destroyed_notification_stack_present"] is False)
            probe.validate_product_scan(row)
        for row in scans[2:]:
            require(row["destroyed_notification_stack_present"] is True
                    and row["leak_nodes"] > scans[0]["leak_nodes"] and row["leak_bytes"] > scans[0]["leak_bytes"])
        require(labels == growth_labels(values[:2]) + LABELS[2:])
    return values


def source_manifest(root, kind):
    sources = {}
    for name in fixture_sources():
        raw = (root / name).read_bytes()
        if kind == "negative-control" and name == "QuickFileApp/AXCompatibility.m":
            require(raw.count(b"[result autorelease];") == 2)
            raw = raw.replace(b"[result autorelease];", b"(void)result;")
        sources[name] = hashlib.sha256(raw).hexdigest()
    return sources


def manifest_hash(sources):
    return hashlib.sha256(json.dumps(sources, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def component(records, kind, code, root=ROOT):
    require(not any(path.is_symlink() for path in (records, *records.parents)))
    inputs_raw = read_bytes(records / "inputs.json", 1024 * 1024)
    inputs = json.loads(inputs_raw)
    require(inputs["sources"] == source_manifest(root, kind))
    unsupported = evidence.unsupported_reason(inputs)
    scans, result_hash = [], None
    if code == 77:
        require(unsupported is not None and not (records / "scans.json").exists())
        status, strict = "unsupported", "unsupported"
    else:
        require(unsupported is None)
        require(runner().preflight_reason(inputs["capabilities"], inputs["reader_capabilities"]) is None)
        if kind != "copy-lifetime":
            require(inputs["baseline_protocol"] == runner().ax_startup_baseline.PROTOCOL)
        raw = read_bytes(records / "result.json", 1024 * 1024)
        receipt = json.loads(raw)
        scans = evaluate(kind, receipt, code)
        if kind == "copy-lifetime":
            hosts = read_json(records / "copy-lifetime-hosts.json", 1024 * 1024)
            require([row["sequence"] for row in hosts] == list(range(10)))
            for row in hosts:
                runner().validate_copy_lifetime_host(row)
            runner().validate_copy_lifetime_host(hosts[-1], 30)
            require(not (records / "scans.json").exists())
        result_hash = hashlib.sha256(raw).hexdigest()
        status, strict = "passed", receipt["coverage"]
    return {"policy": POLICY, "kind": kind, "status": status, "unsupported_reason": unsupported,
            "runner_return_code": code, "original_verdict": strict, "scans": scans,
            "inputs_sha256": hashlib.sha256(inputs_raw).hexdigest(), "result_sha256": result_hash,
            "sources_sha256": manifest_hash(inputs["sources"])}


def record(records, kind, code):
    value = component(records, kind, code)
    validate_component(value, kind)
    # Written only after this component's required assertions, never reused.
    with (records / "lifecycle-acceptance.json").open("x") as stream:
        json.dump(value, stream, separators=(",", ":"))
        stream.write("\n")
    print(json.dumps({"ax_lifecycle_component": value}), flush=True)
    return value


def empty(checkout_sha, status="unavailable"):
    require(status in ("unavailable", "not_attempted"))
    return {"schema": 1, "policy": POLICY, "scope": "synthetic-ax-lifecycle-only",
            "checkout_sha": checkout_sha, "status": status, "growth_attribution": "not-evaluated",
            "components": dict.fromkeys(KINDS)}


def validate_component(value, kind):
    require(type(value) is dict and set(value) == {"policy", "kind", "status", "unsupported_reason",
        "runner_return_code", "original_verdict", "scans", "inputs_sha256", "result_sha256", "sources_sha256"})
    require(value["policy"] == POLICY and value["kind"] == kind)
    for key in ("inputs_sha256", "sources_sha256"):
        require(evidence.sha(value[key]))
    require(type(value["runner_return_code"]) is int)
    scans = value["scans"]
    require(type(scans) is list)
    if value["status"] == "unsupported":
        require(value["unsupported_reason"] in evidence.UNSUPPORTED and value["runner_return_code"] == 77
                and value["original_verdict"] == "unsupported" and value["result_sha256"] is None and scans == [])
        return
    require(value["status"] == "passed" and value["unsupported_reason"] is None and evidence.sha(value["result_sha256"]))
    require([row["label"] for row in scans] == ([] if kind == "copy-lifetime" else LABELS))
    for row in scans:
        require(set(row) == {"label", "leak_nodes", "leak_bytes", "root_instances"})
        require(all(evidence.integer(row[key]) for key in ("leak_nodes", "leak_bytes", "root_instances")))
    failed = kind == "negative-control" or kind == "ordinary" and bool(growth_labels(scans))
    if kind == "negative-control":
        require(all(row["leak_nodes"] > scans[0]["leak_nodes"] and row["leak_bytes"] > scans[0]["leak_bytes"]
                    for row in scans[2:]))
    require(value["runner_return_code"] == (1 if failed else 0)
            and value["original_verdict"] == ("failed" if failed else "passed"))


def validate_public(value):
    import re
    require(type(value) is dict and set(value) == set(empty("")))
    require(type(value["schema"]) is int and value["schema"] == 1 and value["policy"] == POLICY
            and value["scope"] == "synthetic-ax-lifecycle-only")
    require(type(value["checkout_sha"]) is str and re.fullmatch(r"[0-9a-f]{40}", value["checkout_sha"]) is not None)
    require(type(value["components"]) is dict and set(value["components"]) == set(KINDS))
    if value["status"] in ("unavailable", "not_attempted"):
        require(value == empty(value["checkout_sha"], value["status"]))
    else:
        for kind, row in value["components"].items():
            validate_component(row, kind)
        statuses = {row["status"] for row in value["components"].values()}
        require(statuses == {value["status"]} and value["status"] in ("passed", "unsupported"))
        if value["status"] == "unsupported":
            require(len({row["unsupported_reason"] for row in value["components"].values()}) == 1)
        ordinary = value["components"]["ordinary"]
        require(ordinary["sources_sha256"] == value["components"]["copy-lifetime"]["sources_sha256"])
        require(value["growth_attribution"] == ("not-evaluated" if value["status"] == "unsupported" else
                "unresolved" if growth_labels(ordinary["scans"]) else "not-applicable"))
    require(len(json.dumps(value).encode()) <= LIMIT)


def bind_original(value, original):
    if value["status"] in ("unavailable", "not_attempted"):
        return
    ordinary = value["components"]["ordinary"]
    require(ordinary["inputs_sha256"] == original["inputs_sha256"]
            and ordinary["original_verdict"] == original["original_verdict"])
    if ordinary["status"] == "passed":
        require(original["status"] == "complete")
        require(ordinary["scans"] == [{key: row[key] for key in ("label", "leak_nodes", "leak_bytes", "root_instances")}
                                      for row in original["original_scans"]])
        require(original["strict_failure_labels"] == growth_labels(ordinary["scans"]))
        require(all(row["unclassified_nodes"] == 0 and row["destroyed_notification_stack_present"] is False
                    and row["unexpected_roots"] is False for row in original["original_scans"]))
    else:
        require(original["status"] == "unsupported" and ordinary["unsupported_reason"] == original["unsupported_reason"])


def collect(records, checkout_sha, original, root=ROOT):
    value = empty(checkout_sha)
    for kind in KINDS:
        directory = records if kind == "ordinary" else records.with_name(records.name + "-" + kind)
        row = read_json(directory / "lifecycle-acceptance.json", LIMIT)
        validate_component(row, kind)
        require(row == component(directory, kind, row["runner_return_code"], root))
        value["components"][kind] = row
    ordinary = value["components"]["ordinary"]
    value["status"] = ordinary["status"]
    value["growth_attribution"] = ("not-evaluated" if ordinary["status"] == "unsupported" else
                                   "unresolved" if growth_labels(ordinary["scans"]) else "not-applicable")
    validate_public(value)
    bind_original(value, original)
    return value
