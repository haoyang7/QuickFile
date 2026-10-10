import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HELPER = Path(__file__).resolve().parents[1] / "Investigations/ax_process.py"
SPEC = importlib.util.spec_from_file_location("ax_process_test", HELPER)
PROCESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROCESS)


class AXOwnedProcessTests(unittest.TestCase):
    def test_each_wait_is_bounded_and_kill_is_attempted_after_repeated_timeout(self):
        for terminal in (-9, subprocess.TimeoutExpired("owned", 5), OSError("private")):
            with self.subTest(terminal=type(terminal).__name__):
                child = mock.Mock()
                child.wait.side_effect = [subprocess.TimeoutExpired("owned", 5), subprocess.TimeoutExpired("owned", 5), terminal]
                value = PROCESS.reap_owned(child, mock.Mock())
                self.assertEqual(child.wait.call_args_list, [mock.call(timeout=5)] * 3)
                child.terminate.assert_called_once_with()
                child.kill.assert_called_once_with()
                self.assertEqual(value["exited"], terminal == -9)
                self.assertNotIn("private", json.dumps(value))

    def test_stop_or_signal_failure_does_not_skip_wait_or_kill(self):
        child, stop = mock.Mock(), mock.Mock()
        stop.touch.side_effect = OSError("private")
        child.terminate.side_effect = PermissionError("private")
        child.wait.side_effect = [subprocess.TimeoutExpired("owned", 5), OSError("private"), -9]
        value = PROCESS.reap_owned(child, stop)
        self.assertTrue(value["exited"])
        self.assertEqual(value["errors"], ["stop_request_failed", "terminate_failed", "wait_failed"])
        self.assertEqual(PROCESS.reap_owned(None, stop)["started"], False)

    def test_group_signal_and_membership_check_precede_any_reap(self):
        for pid, signal_error in ((2345, None), (6789, ProcessLookupError()), (9012, PermissionError())):
            events = []
            leader = mock.Mock(pid=pid)
            leader.wait.side_effect = lambda **_: events.append("wait")
            leader.kill.side_effect = lambda: events.append("leader-kill")
            def killpg(group, sig):
                self.assertEqual((group, sig), (pid, signal.SIGKILL))
                self.assertEqual(events, [])
                events.append("signal")
                if signal_error:
                    raise signal_error
            def members(group, timeout):
                self.assertEqual(events, ["signal"])
                self.assertEqual(group, pid)
                events.append("members")
                return "exited"
            with mock.patch.object(PROCESS.os, "killpg", side_effect=killpg), \
                    mock.patch.object(PROCESS, "group_exit_status", side_effect=members):
                receipt = PROCESS.finish_group(leader)
            leader.poll.assert_not_called()
            self.assertEqual(events[-1], "wait")
            self.assertEqual(receipt["complete"], not isinstance(signal_error, PermissionError))

    def test_unconfirmed_members_or_leader_exit_is_never_complete(self):
        for members, wait_error in ((False, None), (True, subprocess.TimeoutExpired("owned", 5)), (True, OSError())):
            leader = mock.Mock(pid=123)
            if wait_error:
                leader.wait.side_effect = wait_error
            with mock.patch.object(PROCESS.os, "killpg") as signal_group, \
                    mock.patch.object(PROCESS, "group_exit_status", return_value="exited" if members else "running"):
                receipt = PROCESS.finish_group(leader)
            self.assertFalse(receipt["complete"])
            signal_group.assert_called_once_with(123, signal.SIGKILL)

    def test_process_table_is_scoped_and_fail_closed(self):
        for stdout, expected in (("123 123 Z\n12 999 R+\n", "exited"),
                                 ("123 123 S\n", "running"), ("", "query_failed"), ("11 private Z\n", "parse_failed"),
                                 ("11 123 /private/secret\n", "parse_failed")):
            with mock.patch.object(PROCESS.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=stdout)), \
                    mock.patch.object(PROCESS.time, "monotonic", side_effect=[0, 0, 6]), \
                    mock.patch.object(PROCESS.time, "sleep"):
                self.assertEqual(PROCESS.group_exit_status(123), expected)
        for error in (OSError(), subprocess.TimeoutExpired("ps", 1)):
            with mock.patch.object(PROCESS.subprocess, "run", side_effect=error):
                self.assertEqual(PROCESS.group_exit_status(123), "query_timeout" if isinstance(error, subprocess.TimeoutExpired) else "query_failed")

    def test_group_exit_requires_one_visible_leader_with_matching_pgid(self):
        for table in ("11 999 S\n", "11 123 Z\n", "123 999 Z\n", "123 123 Z\n123 123 Z\n",
                      "123 123 Z\n123 123 S\n", "123 123 Z\n123 999 Z\n"):
            with self.subTest(table=table):
                leader = mock.Mock(pid=123)
                with mock.patch.object(PROCESS.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=table)), \
                        mock.patch.object(PROCESS.os, "killpg") as signal_group:
                    receipt = PROCESS.finish_group(leader)
                self.assertEqual(receipt["group_inspection"], "leader_unverified")
                self.assertFalse(receipt["group_members_exited"])
                self.assertFalse(receipt["complete"])
                leader.poll.assert_not_called()
                leader.wait.assert_called_once_with(timeout=5)
                signal_group.assert_called_once_with(123, signal.SIGKILL)

    def test_start_failure_never_signals_an_unowned_group(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(PROCESS.subprocess, "Popen", side_effect=OSError("private")), \
                mock.patch.object(PROCESS.os, "killpg") as signal_group:
            receipt = PROCESS.run_owned(["private-command"], Path(directory) / "run.log", dict(os.environ))
        signal_group.assert_not_called()
        self.assertEqual(receipt["status"], "start_failed")
        self.assertEqual(receipt["return_code"], 126)
        self.assertTrue(receipt["cleanup"]["complete"])
        self.assertNotIn("private", json.dumps(receipt))

    def test_pipe_errors_and_timeouts_still_clean_before_reaping(self):
        cases = [(b"1\n", 1, "completed"), (b"", 125, "protocol_failed"),
                 (b"/private/secret\n", 125, "protocol_failed"), (b"999\n", 125, "protocol_failed"),
                 (b"start_failed\n", 126, "start_failed"), (None, 124, "timeout"),
                 (OSError("private"), 125, "protocol_failed")]
        for message, code, status in cases:
            with self.subTest(status=status, code=code), tempfile.TemporaryDirectory() as directory:
                leader = mock.Mock(pid=123)
                with mock.patch.object(PROCESS.subprocess, "Popen", return_value=leader), \
                        mock.patch.object(PROCESS.select, "select", return_value=([1] if message is not None else [], [], [])), \
                        mock.patch.object(PROCESS.os, "read", side_effect=message if isinstance(message, Exception) else None,
                                          return_value=message), \
                        mock.patch.object(PROCESS.os, "killpg") as signal_group, \
                        mock.patch.object(PROCESS, "group_exit_status", return_value="exited"):
                    receipt = PROCESS.run_owned(["owned"], Path(directory) / "run.log", {})
                self.assertEqual((receipt["return_code"], receipt["status"]), (code, status))
                self.assertTrue(receipt["cleanup"]["complete"])
                leader.poll.assert_not_called()
                leader.wait.assert_called_once_with(timeout=5)
                signal_group.assert_called_once_with(123, signal.SIGKILL)
                self.assertNotIn("private", json.dumps(receipt))

    def test_cleanup_failure_preserves_command_failure_and_changes_success(self):
        for code in (0, 7):
            with tempfile.TemporaryDirectory() as directory, \
                    mock.patch.object(PROCESS.subprocess, "Popen", return_value=mock.Mock(pid=123)), \
                    mock.patch.object(PROCESS.select, "select", return_value=([1], [], [])), \
                    mock.patch.object(PROCESS.os, "read", return_value=(str(code) + "\n").encode()), \
                    mock.patch.object(PROCESS, "finish_group", return_value={"complete": False}):
                receipt = PROCESS.run_owned(["owned"], Path(directory) / "run.log", {})
            self.assertEqual(receipt["command_return_code"], code)
            self.assertEqual(receipt["return_code"], code or 125)

    def test_pipe_close_failure_cannot_skip_group_cleanup(self):
        close = os.close
        pipe = os.pipe
        calls = []
        descriptors = []
        sentinel_fds = []
        def owned_pipe():
            pair = pipe()
            descriptors.extend(pair)
            return pair
        def close_then_fail_once(fd):
            close(fd)
            calls.append(fd)
            if len(calls) == 1:
                # A real successful close followed by an exception must never
                # cause the caller to close this newly reused descriptor.
                sentinel_fds.append(os.open(str(sentinel_path), os.O_CREAT | os.O_RDWR, 0o600))
                self.assertEqual(sentinel_fds[0], fd)
                raise OSError("private")
        with tempfile.TemporaryDirectory() as directory:
            sentinel_path = Path(directory) / "sentinel"
            try:
                with mock.patch.object(PROCESS.subprocess, "Popen", return_value=mock.Mock(pid=123)), \
                        mock.patch.object(PROCESS.os, "pipe", side_effect=owned_pipe), \
                        mock.patch.object(PROCESS.os, "close", side_effect=close_then_fail_once), \
                        mock.patch.object(PROCESS.os, "killpg") as signal_group, \
                        mock.patch.object(PROCESS, "group_exit_status", return_value="exited"):
                    receipt = PROCESS.run_owned(["owned"], Path(directory) / "run.log", {})
                with self.assertRaises(OSError):
                    os.fstat(descriptors[0])
                self.assertEqual(calls.count(descriptors[1]), 1)
                self.assertEqual(os.write(sentinel_fds[0], b"still owned"), 11)
                self.assertEqual(os.fstat(sentinel_fds[0]).st_size, 11)
            finally:
                for fd in sentinel_fds:
                    try:
                        close(fd)
                    except OSError:
                        pass
        self.assertIs(PROCESS.os.close, close)
        self.assertIs(PROCESS.os.pipe, pipe)
        signal_group.assert_called_once_with(123, signal.SIGKILL)
        self.assertTrue(receipt["cleanup"]["complete"])
        self.assertEqual(receipt["status"], "protocol_failed")
        self.assertEqual(receipt["return_code"], 125)

    def test_real_early_exit_and_timeout_remove_descendants_and_use_distinct_groups(self):
        groups = []
        real_start = subprocess.Popen
        def start(*args, **kwargs):
            child = real_start(*args, **kwargs)
            if kwargs.get("start_new_session"):
                groups.append(child.pid)
            return child
        with tempfile.TemporaryDirectory(prefix="ax-owned-process-") as directory:
            root = Path(directory)
            for index, ending in enumerate(("raise SystemExit(7)", "time.sleep(30)")):
                pid_file = root / (str(index) + ".pid")
                child_code = "import os,signal,time; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); Path(%r).write_text(str(os.getpid())); time.sleep(30)" % str(pid_file)
                script = root / (str(index) + ".py")
                script.write_text("import subprocess,sys,time\nfrom pathlib import Path\n"
                    + "subprocess.Popen([sys.executable, '-c', %r])\n" % child_code
                    + "while not Path(%r).exists(): time.sleep(0.01)\n" % str(pid_file)
                    + ending + "\n")
                with mock.patch.object(PROCESS.subprocess, "Popen", side_effect=start):
                    receipt = PROCESS.run_owned([sys.executable, str(script)], root / (str(index) + ".log"),
                                                dict(os.environ), timeout=3)
                self.assertEqual(receipt["return_code"], 7 if index == 0 else 124)
                self.assertTrue(receipt["cleanup"]["complete"], receipt)
                self.assertTrue(pid_file.exists())
                status = subprocess.run(["/bin/ps", "-p", pid_file.read_text(), "-o", "stat="], capture_output=True, text=True)
                self.assertTrue(not status.stdout.strip() or status.stdout.strip().startswith("Z"), status.stdout)
            self.assertEqual(len(set(groups)), 2)


if __name__ == "__main__":
    unittest.main()
