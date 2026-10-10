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
import subprocess
import time
from ax_probe_report import collect_heap_diagnostics, disassemble_symbols, leak_groups

ROOT = Path(__file__).resolve().parents[2]


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def wait_json(path, predicate, processes):
    deadline = time.monotonic() + 15
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


def preflight_reason(host, reader, system_baseline=False):
    if not system_baseline and host["status"] in ("unsupported-images", "unsupported-architecture"):
        return host["status"]
    if system_baseline:
        if host["enabled"] or host["status"] != "system-baseline":
            raise RuntimeError("System baseline must preserve the unpatched implementation")
    elif not host["enabled"]:
        raise RuntimeError(f"Unexpected installation refusal: {host['status']}")
    if not isinstance(reader.get("trusted"), bool):
        raise RuntimeError("AX reader returned an invalid capability receipt")
    return None if reader["trusted"] else "reader-not-trusted"


def validate_product_scan(entry, baseline=None):
    # The reviewed macOS 26 fixture has a small NSXPCConnection startup baseline.
    # Classify the entire heap and reject target AX groups, unknown roots, missed
    # nodes, and any growth beyond that measured baseline. Never call this zero
    # whole-heap leakage when the baseline itself contains reported nodes.
    if entry["unclassified_nodes"] != 0 or entry["destroyed_notification_stack_present"]:
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-directory", required=True, type=Path)
    parser.add_argument("--records-directory", required=True, type=Path)
    parser.add_argument("--system-baseline", action="store_true")
    parser.add_argument("--heap-diagnostics", action="store_true", help="Retain local heap graphs and write a bounded offline diff summary; compensation-enabled modes only")
    parser.add_argument("--heap-control", action="store_true", help="Match all diagnostic checkpoints with an empty window and no target buttons; requires --heap-diagnostics")
    parser.add_argument("--copy-lifetime", action="store_true", help="Instrument the product fixture with weak copy lifetime tracking; independent product mode only")
    parser.add_argument("--read-only", action="store_true", help="Read AX without subscriptions; requires --system-baseline")
    parser.add_argument("--ownership-trace", action="store_true", help="Trace copy/dealloc in the synthetic host; requires --system-baseline")
    parser.add_argument("--balance-copies", action="store_true", help="Causal experiment: add one autorelease at the traced call sites; requires --ownership-trace")
    parser.add_argument("--expected-appkit-uuid")
    parser.add_argument("--expected-corefoundation-uuid")
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--idle-seconds", type=int, default=2)
    args = parser.parse_args()
    if args.copy_lifetime and any((args.system_baseline, args.heap_diagnostics, args.heap_control,
                                   args.ownership_trace, args.read_only)):
        parser.error("--copy-lifetime requires independent product mode without other probes")
    if args.heap_control and (not args.heap_diagnostics or args.system_baseline):
        parser.error("--heap-control requires --heap-diagnostics and cannot use --system-baseline")
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
    state = work / "state"
    state.mkdir()
    graphs = work / "heap"
    if args.heap_diagnostics:
        graphs.mkdir()
    app = work / "AXCompatibilityFixture.app"
    executable = app / "Contents/MacOS/AXCompatibilityFixture"
    executable.parent.mkdir(parents=True)
    reader_executable = work / "ax-reader"
    sources = ["QuickFileApp/AXCompatibility.m", "QuickFileApp/AXCompatibility.h",
               "Scripts/tests/fixtures/AXCompatibilityNotifications.m", "Scripts/tests/fixtures/AXCompatibilityReader.swift"]
    commands = []

    def run(command, timeout=60):
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        commands.append({"command": list(map(str, command)), "exit_code": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        write_json(records / "commands.json", commands)
        result.check_returncode()
        return result

    common = ["xcrun", "clang", "-O2", "-I", str(ROOT / "QuickFileApp")]
    if args.copy_lifetime:
        common.append("-DQUICKFILE_AX_COPY_LIFETIME")
    run(common + ["-fno-objc-arc", "-c", str(ROOT / sources[0]), "-o", str(work / "AXCompatibility.o")])
    probe_arguments = []
    if args.ownership_trace:
        sources.append("Scripts/Investigations/AXOwnershipProbe.m")
        run(common + ["-fno-objc-arc", "-c", str(ROOT / sources[-1]), "-o", str(work / "AXOwnershipProbe.o")])
        probe_arguments = [f"-DQUICKFILE_AX_OWNERSHIP_PROBE={2 if args.balance_copies else 1}", str(work / "AXOwnershipProbe.o")]
    run(common + ["-fobjc-arc", "-framework", "AppKit", "-framework", "ApplicationServices",
                  str(ROOT / sources[2]), str(work / "AXCompatibility.o"), *probe_arguments, "-o", str(executable)])
    run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library", str(ROOT / sources[3]),
         "-o", str(reader_executable)])
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "local.quickfile.tests.ax-compatibility", "CFBundleName": "AXCompatibilityFixture",
        "CFBundleExecutable": "AXCompatibilityFixture", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"}))
    entitlements = work / "entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
    run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app)])
    environment = dict(os.environ)
    environment.pop("QUICKFILE_DISABLE_AX_COMPATIBILITY", None)
    host_arguments = ["--system-baseline"] if args.system_baseline else []
    capability = subprocess.run([str(executable), "--capabilities", *host_arguments], env=environment,
                                capture_output=True, text=True, check=True, timeout=15)
    capabilities = json.loads(capability.stdout)
    reader_capability = subprocess.run([str(reader_executable), "--capabilities"], env=environment,
                                       capture_output=True, text=True, check=True, timeout=15)
    reader_capabilities = json.loads(reader_capability.stdout)
    if args.balance_copies and capabilities["images"] != {
            "AppKit": args.expected_appkit_uuid, "CoreFoundation": args.expected_corefoundation_uuid}:
        raise RuntimeError("Diagnostic balance refused: system images differ from the reviewed trace")
    write_json(records / "inputs.json", {"capabilities": capabilities, "reader_capabilities": reader_capabilities,
        "system": run(["sw_vers"]).stdout,
        "sources": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources}})
    reason = preflight_reason(capabilities, reader_capabilities, args.system_baseline)
    if reason:
        receipt = {"coverage": "not-covered", "reason": reason,
                   "host": capabilities, "reader": reader_capabilities}
        if args.heap_diagnostics:
            receipt["mode"] = "heap-control" if args.heap_control else "product"
        if args.copy_lifetime:
            receipt.update(mode="copy-lifetime", instrumented=True)
        print(json.dumps(receipt))
        return 77
    environment.update(MallocStackLogging="1", MallocStackLoggingNoCompact="1")
    if args.heap_diagnostics:
        # Full frozen histories must preserve free/reallocation generations.
        # MallocStackLogging would take precedence over NoCompact if both were set.
        environment.pop("MallocStackLogging")
    results = []
    validation_errors = []
    checkpoints = []
    copy_lifetime_hosts = []
    expected_registrations = 0 if args.read_only else 20
    host = reader = None
    observer_exited = None
    sequence = reader_sequence = 0
    with (records / "host.log").open("w") as host_log, (records / "reader.log").open("w") as reader_log:
        def validate(stage, validator, *values):
            # Assertion failures must not discard later lifecycle evidence. They
            # remain fatal even if a subsequent scan returns to the baseline.
            try:
                validator(*values)
            except RuntimeError as error:
                validation_errors.append({"stage": stage, "message": str(error)})
                write_json(records / "validation-errors.json", validation_errors)

        def record_copy_lifetime_host(receipt, expected_copies=None):
            copy_lifetime_hosts.append(receipt)
            write_json(records / "copy-lifetime-hosts.json", copy_lifetime_hosts)
            validate(f"copy-lifetime-host-{receipt['sequence']}", validate_copy_lifetime_host, receipt, expected_copies)

        def command(action, expected_copies=None):
            nonlocal sequence
            sequence += 1
            write_json(state / "command.json", {"sequence": sequence, "action": action, "count": 10})
            receipt = wait_json(state / "ready.json", lambda value: value["sequence"] == sequence, [host])
            if args.heap_control:
                validate(f"control-host-{sequence}", validate_control_host, receipt)
            if args.copy_lifetime:
                record_copy_lifetime_host(receipt, expected_copies)
            return receipt

        def observe():
            nonlocal reader_sequence
            reader_sequence += 1
            write_json(state / "reader-command.json", {"sequence": reader_sequence})
            receipt = wait_json(state / "reader-ready.json", lambda value: value["sequence"] == reader_sequence, [host, reader])
            if args.heap_control:
                validate(f"control-reader-{reader_sequence}", validate_control_reader, receipt)
            return receipt

        def scan(label, host_state):
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
                # --outputGraph suppresses the text report. Decode that same
                # snapshot offline; do not sample the live heap a second time.
                target = str(graph)
            result = subprocess.run(["leaks", "--noContent", "--groupByType", "--nosources", "--fullStacks", target],
                                    capture_output=True, text=True, timeout=60)
            (records / f"{label}-leaks.txt").write_text(result.stdout + result.stderr)
            match = re.search(r"(\d+) leaks for (\d+) total leaked bytes", result.stdout)
            entry = {"label": label, "host": host_state, "exit_code": result.returncode,
                     "leak_nodes": int(match[1]) if match else None, "leak_bytes": int(match[2]) if match else None,
                     "destroyed_notification_stack_present": "_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification" in result.stdout}
            entry["groups"] = leak_groups(result.stdout)
            entry["unclassified_nodes"] = int(match[1]) - sum(group["tree_nodes"] or 0 for group in entry["groups"]) if match else None
            entry["scan_duration_seconds"] = round(time.monotonic() - started, 3)
            entry["since_observer_exit_seconds"] = round(started - observer_exited, 3) if observer_exited is not None else None
            results.append(entry)
            write_json(records / "scans.json", results)
            if not match or result.returncode not in (0, 1):
                raise RuntimeError(f"Full-heap scan was unavailable: {entry}")
            if not args.system_baseline:
                validate(label, validate_product_scan, entry, results[0] if label != "baseline" else None)

        try:
            host = subprocess.Popen([str(executable), str(state), *host_arguments], env=environment, stdout=host_log, stderr=host_log)
            initial = wait_json(state / "ready.json", lambda value: value["sequence"] == 0, [host])
            if args.heap_control:
                validate("control-host-0", validate_control_host, initial)
            if args.copy_lifetime:
                record_copy_lifetime_host(initial)
            if args.system_baseline:
                scan("baseline", initial)
            reader_arguments = ["--read-only"] if args.read_only else []
            reader = subprocess.Popen([str(reader_executable), str(host.pid), str(executable), str(state), *reader_arguments],
                                      stdout=reader_log, stderr=reader_log)
            if not args.system_baseline:
                # Establish AX/XPC setup before the baseline, with no owned test
                # buttons yet. All target destruction remains after this scan.
                warmed = observe()
                if not args.heap_control and (warmed["buttons"] or warmed["registrations"] or warmed["notifications"]):
                    raise RuntimeError(f"AX baseline warm-up was not empty: {warmed}")
                scan("baseline", command("checkpoint"))
            for cycle in range(1, args.cycles + 1):
                added = command("checkpoint" if args.heap_control else "add")
                if args.heap_diagnostics and cycle == 1:
                    # Split button construction from the first AX subscription;
                    # this remains subject to the original empty-window baseline.
                    scan("added-10", added)
                observed = observe()
                if not args.heap_control and (observed["buttons"] != 10 or observed["registrations"] != expected_registrations):
                    raise RuntimeError(f"AX registrations incomplete: {observed}")
                if not args.system_baseline and cycle == 1:
                    # Locate setup growth without replacing the empty baseline
                    # or destroying any target button before the first scan.
                    scan("registered-10", command("checkpoint"))
                removed = command("checkpoint" if args.heap_control else "remove")
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
                           "scope": "empty-window control with the diagnostic product checkpoint sequence and strict heap guard; "
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
                           "scope": "optimized production implementation, synthetic AppKit fixture; requires absent target AX groups and no increase over the non-AX startup baseline; not an installed-app or VoiceOver test"}
            if validation_errors:
                summary["coverage"] = "failed"
                summary["validation_errors"] = validation_errors
                write_json(records / "validation-errors.json", validation_errors)
            if args.heap_diagnostics:
                summary["mode"] = "heap-control" if args.heap_control else "product"
            write_json(records / "result.json", summary)
            print(json.dumps(summary))
        finally:
            if reader and reader.poll() is None:
                (state / "stop-reader").touch()
                try:
                    reader.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    reader.terminate()
                    reader.wait(timeout=5)
            if host and host.poll() is None:
                (state / "quit").touch()
                try:
                    host.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    host.terminate()
                    host.wait(timeout=5)
            subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                            "-u", str(app)], capture_output=True, timeout=15)
            if args.heap_diagnostics:
                collect_heap_diagnostics(graphs, records)
    return 1 if validation_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
