"""Bounded zero-target startup precondition, before any measured AX lifecycle."""
import hashlib
import json
import re
import time

from ax_composition import validate_grouped_composition

PROTOCOL = "zero-target-settled-v1"
POLICY = {"max_probes": 12, "deadline_ms": 40000, "interval_ms": 2000,
          "minimum_observation_ms": 20000, "consecutive_equal": 3}


def empty():
    return {"protocol": PROTOCOL, "policy": dict(POLICY), "status": "failed",
            "selected_index": None, "probes": []}


def fingerprint(entry, composition):
    # Aggregate stability is an observed precondition, not object identity or
    # proof of ownership. Incomplete parsing must not establish a baseline.
    if composition["counts_status"] != "complete" or composition["omitted_nodes"]:
        # CI retains stderr when a probe fails before entering the accepted
        # sequence. Publish only the bounded anonymous parser projection.
        validate_grouped_composition(composition)
        raise RuntimeError("Startup heap composition is incomplete: "
                           + json.dumps(composition, separators=(",", ":")))
    roots = sorted((g["root_kind"], g["root_type"], g["root_instances"], g["tree_nodes"])
                   for g in entry["groups"])
    value = [entry["leak_nodes"], entry["leak_bytes"], roots,
             composition["type_counts"], composition["exact_size_histogram"],
             sorted(composition["unresolved_sizes"], key=lambda row: json.dumps(row, sort_keys=True))]
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def settle(measure, save, receipt):
    """Measure returns a validated empty-host scan; never runs a target cycle."""
    started = time.monotonic()
    deadline = started + POLICY["deadline_ms"] / 1000
    equal = 0
    previous = None
    last_finished = None
    try:
        for index in range(POLICY["max_probes"]):
            if last_finished is not None:
                delay = max(0, last_finished + POLICY["interval_ms"] / 1000 - time.monotonic())
                if time.monotonic() + delay >= deadline:
                    break
                time.sleep(delay)
            if time.monotonic() >= deadline:
                break
            entry = measure(index, deadline)
            last_finished = time.monotonic()
            row = {"index": index, "elapsed_ms": round((last_finished - started) * 1000),
                   "leak_nodes": entry["leak_nodes"], "leak_bytes": entry["leak_bytes"],
                   "root_instances": sum(g["root_instances"] for g in entry["groups"]),
                   "signature_sha256": entry["startup_signature"], "stdout_sha256": entry["stdout_sha256"]}
            receipt["probes"].append(row)
            equal = equal + 1 if previous == row["signature_sha256"] else 1
            previous = row["signature_sha256"]
            if last_finished >= deadline:
                break
            if equal >= POLICY["consecutive_equal"] and row["elapsed_ms"] >= POLICY["minimum_observation_ms"]:
                receipt.update(status="observed-stable", selected_index=index)
                save(receipt)
                return entry
            save(receipt)
        raise RuntimeError("Zero-target startup heap did not settle within its fixed budget")
    except Exception:
        receipt.update(status="failed", selected_index=None)
        raise
    finally:
        save(receipt)


def validate(receipt):
    def require(condition):
        if not condition:
            raise ValueError("Invalid startup baseline receipt")
    require(type(receipt) is dict and set(receipt) == set(empty()))
    require(receipt["protocol"] == PROTOCOL and receipt["policy"] == POLICY)
    require(all(type(value) is int for value in receipt["policy"].values()))
    require(receipt["status"] in ("failed", "observed-stable"))
    probes = receipt["probes"]
    require(type(probes) is list and len(probes) <= POLICY["max_probes"])
    previous_elapsed = -POLICY["interval_ms"]
    for index, row in enumerate(probes):
        require(type(row) is dict and set(row) == {"index", "elapsed_ms", "leak_nodes", "leak_bytes",
            "root_instances", "signature_sha256", "stdout_sha256"})
        require(all(type(row[key]) is int and 0 <= row[key] <= 1_000_000_000
                    for key in ("index", "elapsed_ms", "leak_nodes", "leak_bytes", "root_instances")))
        require(row["index"] == index and row["elapsed_ms"] >= previous_elapsed + POLICY["interval_ms"])
        previous_elapsed = row["elapsed_ms"]
        require(all(type(row[key]) is str and re.fullmatch(r"[0-9a-f]{64}", row[key]) is not None
                    for key in ("signature_sha256", "stdout_sha256")))
    if receipt["status"] == "failed":
        require(receipt["selected_index"] is None)
    else:
        require(type(receipt["selected_index"]) is int and receipt["selected_index"] == len(probes) - 1)
        require(len(probes) >= POLICY["consecutive_equal"])
        require(POLICY["minimum_observation_ms"] <= probes[-1]["elapsed_ms"] < POLICY["deadline_ms"])
        require(len({row["signature_sha256"] for row in probes[-POLICY["consecutive_equal"]:]}) == 1)
        require(len({(row["leak_nodes"], row["leak_bytes"], row["root_instances"])
                     for row in probes[-POLICY["consecutive_equal"]:]}) == 1)
