#!/usr/bin/env python3
"""Compare owned UI fixtures with identical memory/AX instrumentation.

No UI actions, App Group access, global cache purging or security changes.
The reader only inspects this repository's temporary UIRecovery fixture.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import time

SPEC = importlib.util.spec_from_file_location("ui_memory", Path(__file__).with_name("run-ui-recovery.py"))
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)


def command(args, timeout=45):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}): {result.stderr[:300]}")
    return result.stdout


def scan(pid, output, stage):
    start = time.monotonic_ns()
    rss = int(command(["ps", "-o", "rss=", "-p", str(pid)]).strip()) * 1024
    vm = command(["vmmap", "-summary", str(pid)])
    (output / f"private-{stage}-vmmap.txt").write_text(vm)
    footprint = re.search(r"Physical footprint:\s+([\d.]+)([KMGT]?)", vm)
    if not footprint:
        raise RuntimeError("vmmap did not report physical footprint")
    footprint_bytes = round(float(footprint[1]) * 1024 ** (" KMGT".index(footprint[2]) if footprint[2] else 0))
    memory = UI.scan(pid, output, stage)
    memory.update(rssBytes=rss, physicalFootprintBytes=footprint_bytes,
                  vmScanStartUptimeNS=start, atomicSnapshot=False,
                  measurementOrder=["ps RSS", "vmmap summary", "leaks", "heap"])
    (output / f"memory-{stage}.json").write_text(json.dumps(memory, indent=2) + "\n")
    return memory


def allocation_roots(pid, output, stage):
    result = subprocess.run(["leaks", "--quiet", "--noContent", "--nosources", str(pid)],
                            capture_output=True, text=True, timeout=45)
    raw = result.stdout + result.stderr
    if not re.search(r"Process\s+\d+:\s+\d+\s+leaks?", raw):
        raise RuntimeError("Cannot collect per-address leak evidence")
    (output / f"private-{stage}-addresses.txt").write_text(raw)
    return {address for line in raw.splitlines() if "ROOT LEAK:" in line
            for address in re.findall(r"0x[0-9a-fA-F]+", line)}


def run_case(executable, reader, output, observed):
    output.mkdir()  # Refuse to overwrite evidence.
    scans = []
    native = None
    with (output / "private-process.log").open("x") as log, (output / "private-reader.log").open("x") as reader_log:
        process = subprocess.Popen([str(executable), "--output", str(output), "--variant", "list",
                                    "--transition", "membership-only"],
                                   env=dict(os.environ, MallocStackLogging="1"), stdout=log, stderr=log)
        try:
            for stage in UI.CHECKPOINTS:
                ready = output / "ready.json"
                UI.wait_for(lambda: ready.exists() and json.loads(ready.read_text())["checkpoint"] == stage, process)
                if not json.loads(ready.read_text()).get("modelOperationsIdle"):
                    raise RuntimeError("Model is not idle at checkpoint")
                if observed:
                    if native is None:
                        native = subprocess.Popen([str(reader), str(process.pid), str(executable), str(output),
                                                   "--observe-destroyed"], stdout=reader_log, stderr=reader_log)
                    acknowledgement = output / f"ax-{stage}.json"
                    UI.wait_for(lambda: acknowledgement.exists() or native.poll() is not None, process)
                    if not acknowledgement.exists():
                        raise RuntimeError("AX reader exited before acknowledgement; inspect private-reader.log")
                    ax = json.loads(acknowledgement.read_text())
                    if ax["pid"] != process.pid or ax["readCount"] != 1:
                        raise RuntimeError("AX observation did not match owned process")
                time.sleep(1)  # Equal settling interval in both cases; not a clock subtraction control.
                memory = scan(process.pid, output, stage)
                scans.append(memory)
                print(json.dumps({"case": output.name, "stage": stage, "leaks": memory["leaks"],
                                  "rssBytes": memory["rssBytes"], "footprintBytes": memory["physicalFootprintBytes"]}), flush=True)
                if stage == UI.CHECKPOINTS[-1] and native is not None:
                    # Preserve one root's allocation history before/after observer exit.
                    before = allocation_roots(process.pid, output, "before-reader-exit")
                    root = sorted(before)[0] if before else None
                    if root is not None:
                        history = command(["malloc_history", str(process.pid), root])
                        (output / "private-root-before-exit.txt").write_text(history)
                    (output / "release-reader").touch()
                    if native.wait(timeout=10) != 0:
                        raise RuntimeError("AX reader did not exit cleanly")
                    time.sleep(10)
                    scans.append(scan(process.pid, output, "reader-exited-idle10"))
                    # Another 50 seconds gives a total idle interval of at least 60 seconds.
                    time.sleep(50)
                    scans.append(scan(process.pid, output, "reader-exited-idle60"))
                    after = allocation_roots(process.pid, output, "after-reader-exit")
                    (output / "address-persistence.json").write_text(json.dumps({
                        "beforeRootAddresses": sorted(before), "afterRootAddresses": sorted(after),
                        "matchingAddresses": sorted(before & after), "sampledHistoryAddress": root,
                        "addressMatchAloneProvesSameAllocation": False}, indent=2) + "\n")
                    if root is not None:
                        history = command(["malloc_history", str(process.pid), root])
                        (output / "private-root-after-exit.txt").write_text(history)
                (output / f"continue-{stage}").touch()
            if process.wait(timeout=15) != 0:
                raise RuntimeError("UI fixture failed")
            timeline = json.loads((output / "timeline.json").read_text())
            if timeline["events"][-1]["stage"] != "completed" or not timeline["noFileCreation"]:
                raise RuntimeError("Fixture protocol did not complete")
            result = {"case": output.name, "pid": process.pid, "observer": observed,
                      "transition": "membership-only", "scans": scans,
                      "processEnded": True, "noFileCreation": True, "appGroupUsed": False}
            (output / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
            return result
        finally:
            if native is not None and native.poll() is None:
                native.terminate()
                native.wait(timeout=10)
            if process.poll() is None:
                (output / "abort").touch()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--production", type=Path, required=True)
    parser.add_argument("--combined-labels", type=Path, required=True)
    parser.add_argument("--reader", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--observations", choices=("no-ax", "destroyed"), nargs="+", default=("no-ax", "destroyed"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    summary = []
    for observation in args.observations:
        observed = observation == "destroyed"
        for label, executable in (("production", args.production), ("combined-labels", args.combined_labels)):
            summary.append(run_case(executable.resolve(), args.reader.resolve(),
                                    args.output.resolve() / f"{label}-{'destroyed' if observed else 'no-ax'}", observed))
            (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
