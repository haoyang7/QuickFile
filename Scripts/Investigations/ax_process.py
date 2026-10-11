"""Bounded cleanup for owned AX fixtures and isolated investigation runners."""
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time


def reap_owned(process, stop_file, timeout=5):
    """Never let one child's cleanup prevent the other child's cleanup."""
    receipt = {"started": process is not None, "exited": process is None,
               "terminate_sent": False, "kill_sent": False, "return_code": None, "errors": []}
    if process is None:
        return receipt
    try:
        stop_file.touch()
    except OSError:
        receipt["errors"].append("stop_request_failed")
    for action in (None, "terminate", "kill"):
        if action:
            try:
                getattr(process, action)()
                receipt[action + "_sent"] = True
            except ProcessLookupError:
                pass
            except OSError:
                receipt["errors"].append(action + "_failed")
        try:
            receipt["return_code"] = process.wait(timeout=timeout)
            receipt["exited"] = True
            break
        except subprocess.TimeoutExpired:
            if action == "kill":
                receipt["errors"].append("wait_timeout")
        except OSError:
            receipt["errors"].append("wait_failed")
    return receipt


def group_exit_status(pgid, timeout=5):
    """Inspect only the pinned group; never retain the raw process table.

    The caller has not reaped its leader. A zombie has exited, but may still
    await its own parent's wait. A successful signal alone is not this proof.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = subprocess.run(["/bin/ps", "-axo", "pid=,pgid=,stat="],
                                    capture_output=True, text=True, timeout=min(1, timeout))
            if result.returncode != 0 or not result.stdout.strip():
                return "query_failed"
            alive = False
            leader_seen = False
            for line in result.stdout.splitlines():
                fields = line.split()
                # macOS ps uses '?' when task/thread state is unavailable.
                # An owned unknown state must still wait for confirmed exit.
                if (len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit()
                        or not re.fullmatch(r"[A-Z?][A-Za-z0-9+<>Ns-]*", fields[2])):
                    return "parse_failed"
                pid, group = int(fields[0]), int(fields[1])
                if pid == pgid:
                    if leader_seen or group != pgid:
                        return "leader_unverified"
                    leader_seen = True
                if group == pgid and not fields[2].startswith("Z"):
                    alive = True
            if not leader_seen:
                return "leader_unverified"
            if not alive:
                return "exited"
        except subprocess.TimeoutExpired:
            return "query_timeout"
        except (OSError, subprocess.SubprocessError, UnicodeError):
            return "query_failed"
        time.sleep(0.025)
    return "running"


def finish_group(leader, timeout=5):
    """Signal before *any* poll/wait: the unreaped leader pins this PGID.

    No other owner may wait this Popen. Never signal the group after reaping
    it, including error paths. The supervisor and runner never leave the group.
    """
    receipt = {"group_signal": "failed", "group_members_exited": False, "group_inspection": "query_failed",
               "leader_reaped": False, "complete": False}
    try:
        os.killpg(leader.pid, signal.SIGKILL)
        receipt["group_signal"] = "sent"
    except ProcessLookupError:
        receipt["group_signal"] = "absent"
    except OSError:
        pass
    try:
        receipt["group_inspection"] = group_exit_status(leader.pid, timeout)
    except Exception:
        # Even an unexpected inspection failure must not skip the owned wait.
        pass
    receipt["group_members_exited"] = receipt["group_inspection"] == "exited"
    if receipt["group_signal"] == "failed":
        # No further group signals follow this Popen operation, which may reap.
        try:
            leader.kill()
        except OSError:
            pass
    try:
        leader.wait(timeout=timeout)
        receipt["leader_reaped"] = True
    except (OSError, subprocess.SubprocessError):
        pass
    receipt["complete"] = (receipt["group_signal"] != "failed"
                           and receipt["group_members_exited"] and receipt["leader_reaped"])
    return receipt


def run_owned(command, log_path, environment, timeout=180):
    """A private supervisor retains group identity after the runner exits.

    Only the supervisor owns/reaps the runner. It sends a bounded completion
    message, then stays alive until this caller cleans the entire private group.
    """
    result = {"return_code": 126, "command_return_code": None, "status": "start_failed",
              "cleanup": {"group_signal": "not_started", "group_members_exited": True, "group_inspection": "not_started",
                          "leader_reaped": True, "complete": True}}
    leader = None
    try:
        read_fd, write_fd = os.pipe()
    except OSError:
        return result
    try:
        try:
            with log_path.open("w") as log:
                leader = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                    "--supervise", str(write_fd), *command], env=environment, stdout=log, stderr=log,
                    start_new_session=True, pass_fds=(write_fd,))
        except OSError:
            return result
        # A failed close may already have released/reused the descriptor number.
        closing_fd, write_fd = write_fd, None
        os.close(closing_fd)
        result.update(return_code=124, status="timeout")
        deadline = time.monotonic() + timeout
        message = b""
        while time.monotonic() < deadline:
            if not select.select([read_fd], [], [], max(0, deadline - time.monotonic()))[0]:
                break
            chunk = os.read(read_fd, 32)
            message += chunk
            if not chunk or b"\n" in message or len(message) >= 32:
                result.update(return_code=125, status="protocol_failed")
                if re.fullmatch(rb"-?\d{1,3}\n", message):
                    code = int(message)
                    if -127 <= code <= 255:
                        result.update(return_code=code, command_return_code=code, status="completed")
                elif message == b"start_failed\n":
                    result.update(return_code=126, status="start_failed")
                break
    except OSError:
        result.update(return_code=125, status="protocol_failed")
    finally:
        if leader is not None:
            result["cleanup"] = finish_group(leader)
            if not result["cleanup"]["complete"] and result["return_code"] == 0:
                result["return_code"] = 125
        for fd in (read_fd, write_fd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    result["status"] = "protocol_failed"
                    if result["return_code"] == 0:
                        result["return_code"] = 125
    return result


def supervise(fd, command):
    os.set_inheritable(fd, False)
    try:
        code = subprocess.Popen(command).wait()
        message = (str(code) + "\n").encode("ascii")
    except OSError:
        message = b"start_failed\n"
    os.write(fd, message)
    os.close(fd)
    while True:
        signal.pause()


if __name__ == "__main__":
    if len(sys.argv) < 4 or sys.argv[1] != "--supervise":
        raise SystemExit(2)
    supervise(int(sys.argv[2]), sys.argv[3:])
