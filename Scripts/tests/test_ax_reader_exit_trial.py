"""Behavioral tests with a virtual clock and owned-process doubles; no AX calls."""
import contextlib
import io
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
DIRECTORY = ROOT / "Scripts/Investigations"
SPEC = importlib.util.spec_from_file_location("reader_exit_trial_test_target", DIRECTORY / "ax_reader_exit_trial.py")
T = importlib.util.module_from_spec(SPEC)
with mock.patch.object(sys, "path", [str(DIRECTORY), *sys.path]):
    SPEC.loader.exec_module(T)


def reader_receipt():
    return dict.fromkeys(("buttons", "registrations", "notifications", "all_notifications", "unmatched_notifications", "tracked_buttons"), 0) | {"sequence": 1, "target_notification_counts": []}


def host_receipt():
    return dict.fromkeys(("buttons", "allocatedButtons", "destroyedButtons", "compensations", "mutableCompensations"), 0)


def gate_receipt(mode):
    imp = "replacement" if mode == "installed" else "saved"
    return {"mode": mode, "preflight_completed": True, "gate_calls": 1,
            "copy_imp": imp, "mutable_copy_imp": imp}


class Clock:
    value = 1000.0

    def now(self):
        return self.value

    def sleep(self, seconds):
        self.value += seconds


class Process:
    pid = 123
    returncode = None

    def poll(self):
        return self.returncode

    def wait(self, timeout):
        self.returncode = 0
        return 0


class TrialTests(unittest.TestCase):
    def setUp(self):
        temporary = ROOT / ".build/Temporary"
        temporary.mkdir(parents=True, exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(prefix="reader-exit-unit-", dir=temporary)
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.clock = Clock()
        self.clock.value = 1000.0
        self.enterContext(mock.patch.object(T.time, "monotonic", self.clock.now))
        self.enterContext(mock.patch.object(T.time, "sleep", self.clock.sleep))
        self.calls = []
        self.growth = False
        self.scan_duration = 0.5
        self.host_value = host_receipt()
        self.enterContext(mock.patch.object(T.VERIFY, "wait_json", self.wait_json))
        self.enterContext(mock.patch.object(T.subprocess, "run", self.subprocess))

    def wait_json(self, path, predicate, processes, timeout):
        self.assertEqual(timeout, 5)
        value = self.host_value | {"sequence": json.loads((path.parent / "command.json").read_text())["sequence"]}
        self.assertTrue(predicate(value))
        self.clock.sleep(0.1)
        return value

    def subprocess(self, command, **kwargs):
        if command[0] != "leaks":
            return mock.Mock(returncode=0)
        self.assertEqual(kwargs["timeout"], 12)
        self.assertNotIn("--outputGraph", " ".join(command))
        self.calls.append((self.clock.now(), self.trial.reader.poll()))
        self.clock.sleep(self.scan_duration)
        count = 2 if self.growth and len(self.calls) > 1 else 1
        report = f"{count} leaks for {48 * count} total leaked bytes\nSTACK OF {count} INSTANCES OF 'ROOT LEAK: NSXPCConnection':\n {count} ({48 * count} bytes) ROOT LEAK:\n"
        return mock.Mock(returncode=1, stdout=report, stderr="")

    def make(self, arm, timing_control=None, install_gate=None):
        self.trial = T.Trial(self.root / "prepared", self.root / "work", self.root / "records", arm, timing_control, install_gate)
        trial = self.trial
        trial.work.mkdir()
        trial.state.mkdir()
        trial.records.mkdir()
        trial.host, trial.reader = Process(), Process()
        trial.origin = self.clock.now()
        T.VERIFY.write_json(trial.state / "reader-completed.json", reader_receipt())
        return trial

    def test_matched_schedule_and_reader_exit_order(self):
        for arm, alive in (("early", [True, True, False, False, False, False]),
                           ("late", [True, True, True, True, False, False]),
                           ("keep", [True] * 6)):
            with self.subTest(arm=arm), tempfile.TemporaryDirectory(dir=self.root) as nested:
                old = self.root
                self.root = Path(nested)
                trial = self.make(arm)
                self.calls.clear()
                trial.schedule()
                self.assertEqual([row["label"] for row in trial.data["scans"]], [x[0] for x in T.SCAN_SCHEDULE])
                self.assertEqual([code is None for _, code in self.calls], alive)
                self.assertEqual([round(at - trial.origin, 1) for at, _ in self.calls], [0.1, 20.1, 40.1, 60.1, 80.1, 110.1])
                self.assertEqual(trial.data["exit_timing"]["stop_requested"], T.EXIT_OFFSETS[arm])
                self.assertEqual(trial.data["strict_verdict"]["status"], "passed")
                if arm == "keep":
                    trial.stop("cleanup")
                    self.assertGreater(trial.data["exit_timing"]["stop_requested"], 110)
                self.root = old

    def test_growth_does_not_interrupt_later_scans(self):
        trial = self.make("early")
        self.growth = True
        trial.schedule()
        self.assertEqual(len(self.calls), 6)
        self.assertEqual(trial.data["strict_verdict"], {"status": "failed", "failed_labels": ["t20", "t40", "t60", "t80", "t110"]})

    def test_scan_overlap_makes_exit_late(self):
        trial = self.make("early")
        self.scan_duration = 14
        with self.assertRaisesRegex(T.TrialFailure, "timing_mismatch"):
            trial.schedule()
        self.assertGreater(trial.data["exit_timing"]["stop_requested"], 33)
        self.assertEqual(len(trial.data["scans"]), 2)

    def test_dead_reader_rejected_during_keep(self):
        trial = self.make("keep")
        trial.reader.returncode = 0
        with self.assertRaisesRegex(T.TrialFailure, "reader_liveness"):
            trial.schedule()

    def test_zero_activity_violation(self):
        trial = self.make("keep")
        self.host_value["allocatedButtons"] = 1
        with self.assertRaisesRegex(T.TrialFailure, "activity_violation"):
            trial.schedule()
        self.assertEqual(self.calls, [])

    def test_notification_violation(self):
        trial = self.make("early")
        receipt = reader_receipt() | {"all_notifications": 1, "unmatched_notifications": 1}
        T.VERIFY.write_json(trial.state / "reader-completed.json", receipt)
        with self.assertRaisesRegex(T.TrialFailure, "activity_violation"):
            trial.schedule()
        self.assertEqual(len(self.calls), 2)

    def test_timeout_preserves_partial_window(self):
        trial = self.make("keep")
        with mock.patch.object(T.subprocess, "run", side_effect=T.subprocess.TimeoutExpired("leaks", 12)):
            with self.assertRaises(T.subprocess.TimeoutExpired):
                trial.schedule()
        self.assertIsNotNone(trial.data["scans"][0]["scan"]["end"])
        self.assertIsNone(trial.data["scans"][0]["leak_nodes"])

    def check_startup(self, mode=None, invalid=None):
        prepared = self.root / "prepared"
        for name in T.EXECUTABLES.values():
            path = prepared / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture executable")
        trial = T.Trial(prepared, self.root / "work", self.root / "records", "keep" if mode else "early",
                        "twice" if mode else None, mode)
        trial.work.mkdir()
        trial.state.mkdir()
        trial.records.mkdir()
        environments = {}
        processes = []
        reads = []

        def launch(arguments, env, **kwargs):
            process = Process()
            process.pid = len(processes) + 1
            processes.append(process)
            environments[process.pid] = env
            self.assertEqual(len(arguments), 2 if process.pid == 1 else 4)
            return process

        def ready(path, predicate, processes, **kwargs):
            reads.append(path.name)
            value = reader_receipt() if path.name == "reader-ready.json" else host_receipt() | {"sequence": 0}
            if mode and path.name == "ready.json":
                value["install_probe"] = gate_receipt(mode)
                if invalid == "initial":
                    value["install_probe"]["gate_calls"] = 2
            self.assertTrue(predicate(value))
            return value

        def capabilities(command, **kwargs):
            value = {"status": "enabled", "enabled": True} if command[0].endswith("AXCompatibilityFixture") else {"trusted": True}
            if mode and command[0].endswith("AXCompatibilityFixture"):
                value = {"status": "enabled" if mode == "installed" else "probe-preflight-only",
                         "enabled": mode == "installed", "install_probe": gate_receipt(mode)}
                if invalid == "capabilities":
                    value["install_probe"]["gate_calls"] = 2
            return mock.Mock(stdout=json.dumps(value))

        def procargs(pid):
            env = {key.encode(): value.encode() for key, value in environments[pid].items()}
            if invalid == "environment":
                env.pop(T.INSTALL_ENV.encode())
            return b"", [], env

        with mock.patch.object(T, "load_prepared_fixture", return_value={"host": "a" * 64, "reader": "b" * 64}) as load, mock.patch.object(T, "require_fixture_hashes") as hashes, mock.patch.object(T.subprocess, "Popen", launch), mock.patch.object(T.subprocess, "run", capabilities), mock.patch.object(T.VERIFY, "wait_json", ready), mock.patch.object(T, "owned_child_receipt", return_value={}) as owned, mock.patch.object(T, "read_procargs", procargs):
            self.addCleanup(lambda: [log.close() for log in trial.logs])
            if invalid:
                with self.assertRaises(RuntimeError):
                    trial.startup()
                if invalid == "initial":
                    self.assertIsNotNone(trial.data["initial_host_receipt"])
                return
            self.assertTrue(trial.startup())
            self.assertEqual(load.call_args.kwargs["build_mode"], "install-gate" if mode else "ordinary")
            self.assertTrue(all(call.args[-1] == mode for call in owned.call_args_list))
            if mode:
                self.assertEqual(trial.data["initial_host_receipt"]["install_probe"], gate_receipt(mode))
                self.assertEqual(trial.data["external_startup"]["install_gate"], mode)
                self.assertTrue(all(env[T.INSTALL_ENV] == mode for env in environments.values()))
        self.addCleanup(lambda: [log.close() for log in trial.logs])
        self.assertEqual(load.call_count, 1)
        self.assertEqual(hashes.call_count, 1)
        self.assertEqual(reads, ["ready.json", "reader-ready.json"])
        self.assertEqual(environments[1]["MallocStackLogging"], "1")
        self.assertEqual(environments[1]["MallocStackLoggingNoCompact"], "1")
        self.assertNotIn("MallocStackLogging", environments[2])
        self.assertNotIn("MallocStackLoggingNoCompact", environments[2])
        self.assertTrue(all("MallocScribble" not in env for env in environments.values()))
        self.assertEqual(json.loads((trial.state / "reader-command.json").read_text()), {"sequence": 1})
        self.assertEqual(trial.data["clock_markers"]["warm"], 0)

    def test_startup_uses_ordinary_binaries_and_only_one_observe(self):
        self.check_startup()

    def test_startup_installed_gate(self):
        self.check_startup("installed")

    def test_startup_preflight_gate(self):
        self.check_startup("preflight-only")

    def test_startup_rejects_bad_initial_gate(self):
        self.check_startup("installed", "initial")

    def test_startup_rejects_bad_capability_gate(self):
        self.check_startup("installed", "capabilities")

    def test_startup_rejects_actual_gate_environment_mismatch(self):
        self.check_startup("installed", "environment")

    def test_timing_controls_share_two_checkpoints_and_hold_reader(self):
        for control, offsets in (("early-only", [0.1]), ("late-only", [20.1]), ("twice", [0.1, 20.1])):
            with self.subTest(control=control), tempfile.TemporaryDirectory(dir=self.root) as directory:
                old, self.root = self.root, Path(directory)
                trial = self.make("keep", control, "installed")
                self.host_value["install_probe"] = gate_receipt("installed")
                self.calls.clear()
                trial.schedule()
                self.assertEqual(trial.data["schema"], 2)
                self.assertEqual([(point["label"], point["checkpoint"]["start"]) for point in trial.data["checkpoints"]], [("t0", 0), ("t20", 20)])
                self.assertEqual(trial.sequence, 2)
                self.assertEqual([round(at - trial.origin, 1) for at, _ in self.calls], offsets)
                self.assertTrue(all(code is None for _, code in self.calls))
                for point in trial.data["checkpoints"]:
                    self.assertTrue(point["checkpoint"]["reader_alive_before"])
                    self.assertTrue(point["checkpoint"]["reader_alive_after"])
                self.assertEqual(trial.data["scans"][0]["target_offset_seconds"], 20 if control == "late-only" else 0)
                self.assertEqual(trial.data["exit_timing"]["stop_requested"], 40)
                self.assertEqual(trial.data["exit_timing"]["phase"], "cleanup")
                self.root = old

    def test_timing_twice_growth_is_strict_failure_without_shortening_hold(self):
        trial = self.make("keep", "twice", "installed")
        self.host_value["install_probe"] = gate_receipt("installed")
        self.growth = True
        trial.schedule()
        self.assertEqual(trial.data["strict_verdict"], {"status": "failed", "failed_labels": ["t20"]})
        self.assertEqual(len(trial.data["scans"]), 2)
        self.assertEqual(trial.data["exit_timing"]["stop_requested"], 40)

    def test_timing_single_late_applies_classification(self):
        trial = self.make("keep", "late-only", "installed")
        self.host_value["install_probe"] = gate_receipt("installed")
        original = self.subprocess

        def unexpected_root(*args, **kwargs):
            result = original(*args, **kwargs)
            result.stdout = result.stdout.replace("NSXPCConnection", "UnexpectedRoot")
            return result

        with mock.patch.object(T.subprocess, "run", unexpected_root):
            trial.schedule()
        self.assertEqual(trial.data["strict_verdict"], {"status": "failed", "failed_labels": ["baseline"]})
        self.assertEqual(trial.data["scans"][0]["target_offset_seconds"], 20)
        self.assertEqual(trial.data["exit_timing"]["stop_requested"], 40)

    def test_timing_checkpoint_gate_checked_without_scan(self):
        trial = self.make("keep", "early-only", "preflight-only")
        self.host_value["install_probe"] = gate_receipt("preflight-only")
        ordinary = self.wait_json

        def changed_gate(*args, **kwargs):
            result = ordinary(*args, **kwargs)
            if trial.sequence == 2:
                result["install_probe"] = gate_receipt("installed")
            return result

        with mock.patch.object(T.VERIFY, "wait_json", changed_gate):
            with self.assertRaisesRegex(T.TrialFailure, "activity_violation"):
                trial.schedule()
        self.assertEqual(len(trial.data["scans"]), 1)
        self.assertEqual(len(trial.data["checkpoints"]), 2)
        self.assertEqual(trial.data["checkpoints"][1]["host"]["install_probe"], gate_receipt("installed"))

    def test_timing_cli_requires_paired_options_and_keep(self):
        base = ["--prepared-fixture-directory", str(self.root / "prepared"),
                "--work-directory", str(self.root / "work"),
                "--records-directory", str(self.root / "records")]
        for flags in (("--arm", "keep", "--timing-control", "twice"),
                      ("--arm", "keep", "--install-gate", "installed"),
                      ("--arm", "early", "--timing-control", "twice", "--install-gate", "installed")):
            with self.subTest(flags=flags), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    T.main(base + list(flags))
                self.assertEqual(error.exception.code, 2)
        with mock.patch.object(T.Trial, "run", return_value=0) as run:
            self.assertEqual(T.main(base + ["--arm", "keep", "--timing-control", "late-only", "--install-gate", "preflight-only"]), 0)
            self.assertEqual(run.call_count, 1)

    def test_timing_failure_cleanup_does_not_hold_until_40(self):
        trial = T.Trial(self.root / "prepared", self.root / "work", self.root / "records", "keep", "twice", "installed")
        self.trial = trial

        def startup():
            trial.host, trial.reader = Process(), Process()
            trial.origin = self.clock.now()
            T.VERIFY.write_json(trial.state / "reader-completed.json", reader_receipt())
            return True

        def reap(process, stop, timeout):
            return {"started": True, "exited": True, "return_code": 0, "errors": []}

        self.host_value["install_probe"] = gate_receipt("installed")
        error = T.subprocess.TimeoutExpired("leaks", 12, output=b"incomplete")
        with mock.patch.object(trial, "startup", startup), mock.patch.object(T, "reap_owned", reap), mock.patch.object(T.subprocess, "run", side_effect=error):
            self.assertEqual(trial.run(), 2)
        result = json.loads((trial.records / "trial.json").read_text())
        self.assertEqual(result["reason"], "execution_failed")
        self.assertLess(result["exit_timing"]["stop_requested"], 40)
        self.assertTrue(result["cleanup"]["processes_exited"])
        self.assertEqual(len(result["checkpoints"]), 1)
        self.assertIsNone(result["scans"][0]["exit_code"])

    def test_timing_late_checkpoint_block_retains_checkpoint(self):
        trial = self.make("keep", "late-only", "installed")
        self.host_value["install_probe"] = gate_receipt("installed")
        ordinary = self.wait_json

        def blocking(*args, **kwargs):
            result = ordinary(*args, **kwargs)
            if trial.sequence == 2:
                self.clock.sleep(4)
            return result

        with mock.patch.object(T.VERIFY, "wait_json", blocking):
            with self.assertRaisesRegex(T.TrialFailure, "timing_mismatch"):
                trial.schedule()
        self.assertEqual(len(trial.data["checkpoints"]), 2)
        self.assertEqual(len(trial.data["scans"]), 1)
        self.assertGreater(trial.data["scans"][0]["scan"]["start"], 23)

    def test_timing_failed_scan_retains_independent_checkpoint(self):
        trial = self.make("keep", "late-only", "installed")
        self.host_value["install_probe"] = gate_receipt("installed")
        error = T.subprocess.TimeoutExpired("leaks", 12, output=b"partial late scan")
        with mock.patch.object(T.subprocess, "run", side_effect=error):
            with self.assertRaises(T.subprocess.TimeoutExpired):
                trial.schedule()
        self.assertEqual(len(trial.data["checkpoints"]), 2)
        self.assertEqual(trial.sequence, 2)
        self.assertIsNone(trial.data["scans"][0]["leak_nodes"])
        self.assertEqual((trial.records / "baseline-original.stdout.txt").read_bytes(), b"partial late scan")

    def test_timing_exit_late_within_wait_budget_rejected(self):
        trial = self.make("keep", "twice", "installed")
        self.host_value["install_probe"] = gate_receipt("installed")

        def delayed_wait(timeout):
            self.clock.sleep(4.9)
            trial.reader.returncode = 0
            return 0

        trial.reader.wait = delayed_wait
        with self.assertRaisesRegex(T.TrialFailure, "timing_mismatch"):
            trial.schedule()
        self.assertEqual(trial.data["exit_timing"]["stop_requested"], 40)
        self.assertAlmostEqual(trial.data["exit_timing"]["wait_returned"], 44.9)
        self.assertIsNotNone(trial.data["completed_receipt"])

    def test_checkpoint_timeout_has_no_fabricated_scan(self):
        trial = self.make("keep")
        with mock.patch.object(T.VERIFY, "wait_json", side_effect=TimeoutError("checkpoint")):
            with self.assertRaises(TimeoutError):
                trial.schedule()
        row = trial.data["scans"][0]
        self.assertIsNotNone(row["checkpoint"]["end"])
        self.assertIsNone(row["scan"])
        self.assertEqual(self.calls, [])

    def test_exit_within_wait_budget_but_late_retains_failure_receipts(self):
        trial = T.Trial(self.root / "prepared", self.root / "work", self.root / "records", "early")
        self.trial = trial

        def startup():
            trial.host, trial.reader = Process(), Process()
            trial.origin = self.clock.now()
            T.VERIFY.write_json(trial.state / "reader-completed.json", reader_receipt())

            def delayed_wait(timeout):
                self.assertEqual(timeout, 5)
                self.clock.sleep(4.9)
                trial.reader.returncode = 0
                return 0

            trial.reader.wait = delayed_wait
            return True

        def reap(process, stop, timeout):
            return {"started": True, "exited": True, "return_code": 0, "errors": []}

        with mock.patch.object(trial, "startup", startup), mock.patch.object(T, "reap_owned", reap):
            self.assertEqual(trial.run(), 2)
        result = json.loads((trial.records / "trial.json").read_text())
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["reason"], "timing_mismatch")
        self.assertEqual(result["exit_timing"]["stop_requested"], 30)
        self.assertAlmostEqual(result["exit_timing"]["wait_returned"], 34.9)
        self.assertAlmostEqual(result["exit_timing"]["notification_received"], 34.9)
        self.assertEqual(result["exit_timing"]["return_code"], 0)
        self.assertEqual(result["completed_receipt"], reader_receipt())
        self.assertTrue((trial.records / "notifications.json").exists())
        self.assertEqual(len(result["scans"]), 2)

    def test_stop_timeout_does_not_claim_wait_return_or_completion(self):
        trial = self.make("early")
        with mock.patch.object(trial.reader, "wait", side_effect=T.subprocess.TimeoutExpired("reader", 5)):
            with self.assertRaises(T.subprocess.TimeoutExpired):
                trial.schedule()
        timing = trial.data["exit_timing"]
        self.assertEqual(timing["stop_requested"], 30)
        self.assertIsNone(timing["wait_returned"])
        self.assertIsNone(timing["return_code"])
        self.assertIsNone(trial.data["completed_receipt"])

    def test_timeout_partial_stdout_retained(self):
        trial = self.make("keep")
        error = T.subprocess.TimeoutExpired("leaks", 12, output=b"partial output")
        with mock.patch.object(T.subprocess, "run", side_effect=error):
            with self.assertRaises(T.subprocess.TimeoutExpired):
                trial.schedule()
        self.assertEqual((trial.records / "baseline-original.stdout.txt").read_bytes(), b"partial output")
        self.assertIsNone(trial.data["scans"][0]["exit_code"])

    def test_run_exit_codes_and_error_receipts(self):
        for outcome, code in (("passed", 0), ("failed", 1), ("not-covered", 77), ("timeout", 2)):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory(dir=self.root) as folder:
                root = Path(folder)
                trial = T.Trial(root / "prepared", root / "work", root / "records", "keep")

                def startup():
                    if outcome == "not-covered":
                        trial.data.update(status="not-covered", reason="reader-not-trusted")
                        return False
                    return True

                def schedule():
                    if outcome == "timeout":
                        raise TimeoutError("private native detail")
                    trial.data["strict_verdict"]["status"] = outcome

                with mock.patch.object(trial, "startup", startup), mock.patch.object(trial, "schedule", schedule):
                    self.assertEqual(trial.run(), code)
                result = json.loads((trial.records / "trial.json").read_text())
                self.assertNotIn("private native detail", json.dumps(result))
                self.assertTrue(result["cleanup"]["processes_exited"])
                self.assertEqual(result["cleanup"]["reader"]["started"], False)

    def test_cleanup_failure_writes_failure_and_cleans_both(self):
        trial = T.Trial(self.root / "prepared", self.root / "work", self.root / "records", "keep")
        calls = []

        def startup():
            trial.host, trial.reader = Process(), Process()
            trial.origin = self.clock.now()
            T.VERIFY.write_json(trial.state / "reader-completed.json", reader_receipt())
            return True

        def reap(process, stop, timeout):
            calls.append(stop.name)
            if stop.name == "stop-reader":
                raise OSError("private detail")
            return {"exited": True, "errors": []}

        with mock.patch.object(trial, "startup", startup), mock.patch.object(trial, "schedule"), mock.patch.object(T, "reap_owned", reap):
            self.assertEqual(trial.run(), 2)
        self.assertEqual(calls, ["stop-reader", "quit"])
        result = json.loads((trial.records / "trial.json").read_text())
        self.assertEqual(result["reason"], "cleanup_failed")
        self.assertFalse(result["cleanup"]["processes_exited"])
        self.assertNotIn("private detail", json.dumps(result))
        self.assertTrue((trial.records / "process-cleanup.json").exists())


if __name__ == "__main__":
    unittest.main()
