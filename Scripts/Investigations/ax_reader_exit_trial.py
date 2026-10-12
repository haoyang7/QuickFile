#!/usr/bin/env python3
"""Private, fixed-schedule ordinary-fixture Reader exit experiment."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback

from ax_external_receipt import (EXECUTABLES, fixture_sources, load_prepared_fixture,
    owned_child_receipt, read_procargs, require_fixture_hashes, validate_external_receipt)
from ax_process import reap_owned
from ax_probe_report import leak_groups

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ax_reader_exit_verify", Path(__file__).with_name("verify-ax-compatibility.py"))
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)
SCAN_SCHEDULE = (("baseline", 0), ("t20", 20), ("t40", 40), ("t60", 60), ("t80", 80), ("t110", 110))
EXIT_OFFSETS = {"keep": None, "early": 30, "late": 70}
SCAN_TIMEOUT = 12
CHECKPOINT_TIMEOUT = 5
STOP_TIMEOUT = 5
MAX_LATENESS_MS = 3000
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


class TrialFailure(RuntimeError):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def initial_trial(arm):
    return {"schema": 1, "arm": arm, "policy": {
        "schedule": [{"label": label, "offset_seconds": offset} for label, offset in SCAN_SCHEDULE],
        "exit_offset_seconds": EXIT_OFFSETS[arm], "scan_timeout_seconds": SCAN_TIMEOUT,
        "checkpoint_timeout_seconds": CHECKPOINT_TIMEOUT, "stop_timeout_seconds": STOP_TIMEOUT,
        "max_lateness_ms": MAX_LATENESS_MS}, "status": "failed", "reason": "execution_failed",
        "executables": None, "external_startup": None, "environments": {"host": None, "reader": None},
        "clock_markers": dict.fromkeys(("origin_monotonic", "host_start", "host_ready", "reader_start", "warm")),
        "exit_timing": {"target_offset_seconds": EXIT_OFFSETS[arm], "stop_requested": None,
            "wait_returned": None, "notification_received": None, "return_code": None, "phase": None},
        "scans": [], "warm_receipt": None, "completed_receipt": None,
        "strict_verdict": {"status": "not-evaluated", "failed_labels": []}, "cleanup": None}


class Trial:
    def __init__(self, prepared, work, records, arm):
        self.prepared, self.work, self.records = prepared, work, records
        self.state = work / "state"
        self.app = work / "AXCompatibilityFixture.app"
        self.data = initial_trial(arm)
        self.host = self.reader = None
        self.origin = None
        self.sequence = 0
        self.logs = []
        self.app_owned = False
        self.start_markers = {}

    def now(self):
        return time.monotonic() - self.origin if self.origin is not None else None

    def alive(self):
        return self.reader.poll() is None if self.reader is not None else None

    def window(self):
        return {"start": self.now(), "end": None, "reader_alive_before": self.alive(), "reader_alive_after": None}

    def end(self, window):
        window.update(end=self.now(), reader_alive_after=self.alive())

    def activity(self, validator, *args):
        try:
            validator(*args)
        except RuntimeError as error:
            raise TrialFailure("activity_violation") from error

    def liveness(self, expected):
        if self.alive() is not expected or self.host.poll() is not None:
            raise TrialFailure("reader_liveness")

    def on_time(self, started, target):
        if started < target or (started - target) * 1000 > MAX_LATENESS_MS:
            raise TrialFailure("timing_mismatch")

    def startup(self):
        hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in fixture_sources()}
        expected = load_prepared_fixture(self.prepared, hashes)
        self.data["executables"] = expected
        source_app = self.prepared / self.app.name
        if source_app.is_symlink() or any(path.is_symlink() for path in source_app.rglob("*")):
            raise TrialFailure("execution_failed")
        self.app_owned = True
        shutil.copytree(source_app, self.app)
        shutil.copy2(self.prepared / "ax-reader", self.work / "ax-reader")
        require_fixture_hashes(self.work, expected)
        base = dict(os.environ)
        for key in ("MallocScribble", "MallocStackLogging", "MallocStackLoggingNoCompact",
                    "QUICKFILE_DISABLE_AX_COMPATIBILITY", "QUICKFILE_AX_INSTALL_PROBE_MODE"):
            base.pop(key, None)
        environments = {"host": dict(base, MallocStackLogging="1", MallocStackLoggingNoCompact="1"), "reader": base}
        capabilities = {}
        for role, name in EXECUTABLES.items():
            result = subprocess.run([str(self.work / name), "--capabilities"], env=environments[role],
                capture_output=True, text=True, check=True, timeout=15)
            capabilities[role] = json.loads(result.stdout)
        VERIFY.write_json(self.records / "inputs.json", {"capabilities": capabilities, "sources": hashes})
        reason = VERIFY.preflight_reason(capabilities["host"], capabilities["reader"])
        if reason:
            self.data.update(status="not-covered", reason=reason)
            return False
        external = {"receipt_mode": "external-startup", "requested": "off", "host": None,
            "reader": None, "executables": expected, "binary_reuse_verified": False}
        self.data["external_startup"] = external
        markers = self.data["clock_markers"]
        for role, name in EXECUTABLES.items():
            path = self.work / name
            arguments = [str(path), str(self.state)] if role == "host" else [str(path), str(self.host.pid), str(self.work / EXECUTABLES["host"]), str(self.state)]
            log = (self.records / (role + ".log")).open("w")
            self.logs.append(log)
            self.start_markers[role + "_start"] = time.monotonic()
            process = subprocess.Popen(arguments, env=environments[role], stdout=log, stderr=log)
            setattr(self, role, process)
            if role == "host":
                ready = VERIFY.wait_json(self.state / "ready.json", lambda row: row["sequence"] == 0, [process])
                self.start_markers["host_ready"] = time.monotonic()
                self.activity(VERIFY.validate_control_host, ready)
            external[role] = owned_child_receipt(process, path, environments[role], "off", expected[role])
            _, _, actual = read_procargs(process.pid)
            for key in ("MallocStackLogging", "MallocStackLoggingNoCompact", "MallocScribble"):
                wanted = environments[role].get(key)
                if actual.get(key.encode()) != (wanted.encode() if wanted else None):
                    raise TrialFailure("environment_mismatch")
            if process.poll() is not None:
                raise TrialFailure("reader_liveness")
            self.data["environments"][role] = {key: environments[role].get(key, "unset") for key in
                ("MallocStackLogging", "MallocStackLoggingNoCompact", "MallocScribble")}
            VERIFY.write_json(self.records / "external-startup.json", external)
        VERIFY.write_json(self.state / "reader-command.json", {"sequence": 1})
        warm = VERIFY.wait_json(self.state / "reader-ready.json", lambda row: row["sequence"] == 1, [self.host, self.reader])
        self.origin = time.monotonic()
        markers.update(origin_monotonic=self.origin, warm=0)
        for key in ("host_start", "host_ready", "reader_start"):
            markers[key] = self.start_markers[key] - self.origin
        self.data["warm_receipt"] = warm
        self.activity(VERIFY.validate_control_reader, warm)
        return True

    def stop(self, phase):
        timing = self.data["exit_timing"]
        timing["phase"] = phase
        self.liveness(True)
        timing["stop_requested"] = self.now()
        (self.state / "stop-reader").touch()
        timing["return_code"] = self.reader.wait(timeout=STOP_TIMEOUT)
        timing["wait_returned"] = self.now()
        if timing["return_code"] != 0:
            raise TrialFailure("reader_liveness")
        completed = json.loads((self.state / "reader-completed.json").read_text())
        timing["notification_received"] = self.now()
        self.data["completed_receipt"] = completed
        VERIFY.write_json(self.records / "notifications.json", completed)
        self.activity(VERIFY.validate_notifications, completed, 0)
        self.activity(VERIFY.validate_control_reader, completed, True)
        if phase == "scheduled":
            self.on_time(timing["stop_requested"], timing["target_offset_seconds"])
            self.on_time(timing["wait_returned"], timing["target_offset_seconds"])

    def sample(self, label, target):
        expected_alive = self.data["exit_timing"]["return_code"] is None
        row = {"label": label, "target_offset_seconds": target, "host": None, "exit_code": None,
            "leak_nodes": None, "leak_bytes": None, "groups": None, "unclassified_nodes": None,
            "destroyed_notification_stack_present": None, "stdout_sha256": None,
            "checkpoint": self.window(), "scan": None}
        self.data["scans"].append(row)
        self.liveness(expected_alive)
        self.sequence += 1
        try:
            VERIFY.write_json(self.state / "command.json", {"sequence": self.sequence, "action": "checkpoint", "count": 0})
            row["host"] = VERIFY.wait_json(self.state / "ready.json", lambda value: value["sequence"] == self.sequence,
                [self.host], timeout=CHECKPOINT_TIMEOUT)
        finally:
            self.end(row["checkpoint"])
        self.activity(VERIFY.validate_control_host, row["host"])
        self.liveness(expected_alive)
        row["scan"] = self.window()
        try:
            result = subprocess.run(["leaks", "--noContent", "--groupByType", "--nosources", "--fullStacks", str(self.host.pid)],
                capture_output=True, text=True, timeout=SCAN_TIMEOUT)
        except subprocess.TimeoutExpired as error:
            if error.stdout is not None:
                raw = error.stdout.encode() if isinstance(error.stdout, str) else error.stdout
                (self.records / (label + "-original.stdout.txt")).write_bytes(raw)
                row["stdout_sha256"] = hashlib.sha256(raw).hexdigest()
            raise
        finally:
            self.end(row["scan"])
        raw = result.stdout.encode()
        (self.records / (label + "-original.stdout.txt")).write_bytes(raw)
        (self.records / (label + "-stderr.txt")).write_text(result.stderr)
        match = re.search(r"(\d+) leaks for (\d+) total leaked bytes", result.stdout)
        row.update(exit_code=result.returncode, stdout_sha256=hashlib.sha256(raw).hexdigest(), groups=leak_groups(result.stdout),
            destroyed_notification_stack_present="_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification" in result.stdout)
        if not match or result.returncode not in (0, 1):
            raise TrialFailure("scan_unavailable")
        row.update(leak_nodes=int(match[1]), leak_bytes=int(match[2]))
        row["unclassified_nodes"] = row["leak_nodes"] - sum(group["tree_nodes"] or 0 for group in row["groups"])
        verdict = self.data["strict_verdict"]
        try:
            VERIFY.validate_product_scan(row, self.data["scans"][0] if label != "baseline" else None)
        except RuntimeError:
            verdict["failed_labels"].append(label)
        verdict["status"] = "failed" if verdict["failed_labels"] else "passed"
        self.liveness(expected_alive)
        self.on_time(row["checkpoint"]["start"], target)
        self.on_time(row["scan"]["start"], target)

    def schedule(self):
        events = [(offset, label) for label, offset in SCAN_SCHEDULE]
        stop = self.data["exit_timing"]["target_offset_seconds"]
        if stop is not None:
            events.append((stop, None))
        for offset, label in sorted(events):
            time.sleep(max(0, offset - self.now()))
            if label is None:
                self.stop("scheduled")
            else:
                self.sample(label, offset)

    def cleanup(self):
        cleanup = {"reader": None, "host": None, "errors": [], "processes_exited": False}
        self.data["cleanup"] = cleanup
        if self.reader is not None and self.reader.poll() is None and self.data["exit_timing"]["stop_requested"] is None:
            try:
                self.stop("cleanup")
            except Exception:
                traceback.print_exc(file=self.error_log)
                cleanup["errors"].append("reader_stop")
        for role, stop in (("reader", "stop-reader"), ("host", "quit")):
            try:
                cleanup[role] = reap_owned(getattr(self, role), self.state / stop, timeout=STOP_TIMEOUT)
                if not cleanup[role]["exited"] or cleanup[role]["errors"]:
                    cleanup["errors"].append(role)
            except Exception:
                traceback.print_exc(file=self.error_log)
                cleanup["errors"].append(role)
        cleanup["processes_exited"] = all(cleanup[role] is not None and cleanup[role]["exited"] for role in ("reader", "host"))
        try:
            if self.app_owned and self.app.exists():
                subprocess.run([LSREGISTER, "-u", str(self.app)], capture_output=True, check=True, timeout=15)
        except Exception:
            traceback.print_exc(file=self.error_log)
            cleanup["errors"].append("launch_services")
        external = self.data["external_startup"]
        if external is not None:
            try:
                require_fixture_hashes(self.prepared, self.data["executables"])
                require_fixture_hashes(self.work, self.data["executables"])
                external["binary_reuse_verified"] = cleanup["processes_exited"]
                validate_external_receipt(external, "off", self.data["executables"])
            except Exception:
                traceback.print_exc(file=self.error_log)
                external["binary_reuse_verified"] = False
                cleanup["errors"].append("external_receipt")
            VERIFY.write_json(self.records / "external-startup.json", external)
        for log in self.logs:
            log.close()
        VERIFY.write_json(self.records / "process-cleanup.json", cleanup)
        if cleanup["errors"]:
            self.data.update(status="failed", reason="cleanup_failed")

    def run(self):
        self.records.mkdir(parents=True, exist_ok=True)
        with (self.records / "private-errors.log").open("a") as self.error_log:
            try:
                self.work.mkdir(parents=True, exist_ok=False)
                self.state.mkdir()
                if self.startup():
                    self.schedule()
                    self.data.update(status="complete", reason=None)
            except Exception as error:
                traceback.print_exc(file=self.error_log)
                self.data.update(status="failed", reason=error.reason if isinstance(error, TrialFailure) else "execution_failed")
            finally:
                try:
                    self.cleanup()
                except Exception:
                    traceback.print_exc(file=self.error_log)
                    self.data.update(status="failed", reason="cleanup_failed")
                finally:
                    VERIFY.write_json(self.records / "trial.json", self.data)
        if self.data["status"] == "not-covered":
            return 77
        if self.data["status"] != "complete":
            return 2
        return 1 if self.data["strict_verdict"]["status"] == "failed" else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("prepared-fixture-directory", "work-directory", "records-directory"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--arm", choices=EXIT_OFFSETS, required=True)
    args = parser.parse_args(argv)
    paths = [getattr(args, key).resolve() for key in ("prepared_fixture_directory", "work_directory", "records_directory")]
    root = (ROOT / ".build/Temporary").resolve()
    if any(path == root or not path.is_relative_to(root) for path in paths):
        parser.error("Directories must be below .build/Temporary")
    if any(a == b or a.is_relative_to(b) or b.is_relative_to(a) for i, a in enumerate(paths) for b in paths[i + 1:]):
        parser.error("Directories must be disjoint")
    return Trial(*paths, args.arm).run()


if __name__ == "__main__":
    raise SystemExit(main())
