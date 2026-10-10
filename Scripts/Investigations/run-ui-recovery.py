#!/usr/bin/env python3
"""Run isolated UI recovery checkpoints; keep raw heap/stack evidence only in --output.

AX cases require one read-only tree inspection per checkpoint, never clicks, key
presses, menu opening, or AX actions. The production-tabs fixture retains real
production controls; it is not safe for arbitrary manual interaction. This runner
only starts the owned fixture, scans its memory, and advances file handshakes.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

CASES = {
    "both-unobserved": ("both", "superset", "reload", False),
    "picker-unobserved": ("picker", "superset", "reload", False),
    "list-unobserved": ("list", "superset", "reload", False),
    "both-disjoint-unobserved": ("both", "disjoint", "reload", False),
    "both-preflight-unobserved": ("both", "superset", "create-preflight", False),
    "both-observed": ("both", "superset", "reload", True),
    "picker-observed": ("picker", "superset", "reload", True),
    "list-observed": ("list", "superset", "reload", True),
    "production-tabs-unobserved": ("production-tabs", "superset", "reload", False),
    "production-tabs-observed": ("production-tabs", "superset", "reload", True),
    "production-tabs-disjoint-unobserved": ("production-tabs", "disjoint", "reload", False),
    "production-tabs-preflight-unobserved": ("production-tabs", "superset", "create-preflight", False),
}
CHECKPOINTS = ("baseline8", "large300-1", "restored8-1", "large300-2", "restored8-2")


def wait_for(predicate, process, timeout=170):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        if process.poll() is not None:
            raise RuntimeError(f"UI fixture exited early ({process.returncode})")
        time.sleep(0.1)
    raise TimeoutError("UI checkpoint did not become ready")


def scan(pid, output, checkpoint):
    start = time.monotonic_ns()
    cmd = ["leaks", "--quiet", "--noContent", "--groupByType", "--nosources", "--fullStacks", str(pid)]
    leaks = subprocess.run(cmd, capture_output=True, text=True, timeout=45)
    raw = leaks.stdout + leaks.stderr
    (output / f"private-{checkpoint}-leaks.txt").write_text(raw)
    count = re.search(r"Process\s+\d+:\s+(\d+)\s+leaks?\s+for\s+(\d+)\s+total leaked bytes", raw)
    if leaks.returncode not in (0, 1) or count is None:
        raise RuntimeError(f"Leak scan could not inspect owned process; exit {leaks.returncode}")
    roots = []
    for line in raw.splitlines():
        match = re.match(r"\s+(\d+)\s+\([^)]*\) ROOT LEAK: (.+)", line)
        if match:
            roots.append({"nodesInGroup": int(match[1]),
                          "root": re.sub(r"0x[0-9a-fA-F]+", "<address>", match[2])})
    heap = subprocess.run(["heap", "--quiet", "--noContent", "--sortBySize", str(pid)],
                          capture_output=True, text=True, timeout=45)
    (output / f"private-{checkpoint}-heap.txt").write_text(heap.stdout + heap.stderr)
    if heap.returncode:
        raise RuntimeError(f"Heap scan failed ({heap.returncode})")
    classes = {}
    for line in heap.stdout.splitlines():
        if any(name in line for name in ("PlatformItemList", "AnyViewStorage", "NSArray", "Swift.StringStorage", "Swift._StringStorage", "Swift._ContiguousArrayStorage<QuickFileCore.FileTemplate>")):
            fields = re.match(r"\s*(\d+)\s+(\d+)\s+[\d.]+\s+(.+)", line)
            if fields:
                classes[fields[3]] = {"instances": int(fields[1]), "bytes": int(fields[2])}
    result = {"checkpoint": checkpoint, "pid": pid, "scanStartUptimeNS": start,
              "scanEndUptimeNS": time.monotonic_ns(), "leaks": int(count[1]),
              "scanClock": "Python time.monotonic_ns; not Swift DispatchTime",
              "leakedBytes": int(count[2]), "rootGroups": roots, "selectedHeapClasses": classes,
              "contentsIncluded": False, "stackLoggingEnabled": True}
    (output / f"memory-{checkpoint}.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cases", nargs="+", choices=CASES, required=True)
    args = parser.parse_args()
    executable = args.executable.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    summary = []
    for label in args.cases:
        variant, identities, restore, observed = CASES[label]
        case_output = output / label
        case_output.mkdir()  # Refuse to overwrite an earlier run.
        env = dict(os.environ, MallocStackLogging="1")
        with (case_output / "private-process.log").open("w") as log:
            process = subprocess.Popen([str(executable), "--output", str(case_output), "--variant", variant,
                                        "--identities", identities, "--restore", restore],
                                       env=env, stdout=log, stderr=log)
            scans = []
            try:
                (output / "active-case.json").write_text(json.dumps({"label": label, "pid": process.pid,
                    "output": str(case_output), "observed": observed}) + "\n")
                for checkpoint in CHECKPOINTS:
                    ready = case_output / "ready.json"
                    wait_for(lambda: ready.exists() and json.loads(ready.read_text())["checkpoint"] == checkpoint, process)
                    if observed:
                        print(json.dumps({"waitingForFixedAXRead": label, "checkpoint": checkpoint, "pid": process.pid,
                                          "inputPolicy": "read-only AX; do not activate production controls"}), flush=True)
                        acknowledgement = case_output / f"ax-{checkpoint}.json"
                        wait_for(lambda: acknowledgement.exists(), process, timeout=1790)
                        ax = json.loads(acknowledgement.read_text())
                        if ax.get("pid") != process.pid or ax.get("readCount") != 1:
                            raise RuntimeError("AX acknowledgement must match the owned process and one read")
                    else:
                        # Keep a fixed settling interval. Observer overhead/time is recorded
                        # separately; it cannot be treated as an exact subtraction control.
                        time.sleep(1)
                    result = scan(process.pid, case_output, checkpoint)
                    scans.append(result)
                    print(json.dumps({"label": label, "checkpoint": checkpoint, "leaks": result["leaks"],
                                      "bytes": result["leakedBytes"]}), flush=True)
                    (case_output / f"continue-{checkpoint}").touch()
                exit_code = process.wait(timeout=10)
                if exit_code != 0:
                    raise RuntimeError(f"UI fixture failed after checkpoints ({exit_code})")
                timeline = json.loads((case_output / "timeline.json").read_text())
                if timeline["events"][-1]["stage"] != "completed":
                    raise RuntimeError("UI protocol failed; inspect private process/timeline evidence")
                creation = case_output / "creation-must-remain-empty"
                if creation.exists() and any(creation.iterdir()):
                    raise RuntimeError("Preflight control unexpectedly created a file")
                summary.append({"label": label, "variant": variant, "identities": identities,
                                "restoreEntry": restore, "AXObserved": observed, "scans": scans,
                                "processEnded": True, "noFileCreation": timeline["noFileCreation"]})
                (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            finally:
                if process.poll() is None:
                    (case_output / "abort").touch()
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        process.wait(timeout=10)


if __name__ == "__main__":
    main()
