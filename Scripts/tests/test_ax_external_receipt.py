import contextlib
import ctypes
import io
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from test_ax_compatibility import EXTERNAL, PROBE, REPORT, ROOT


def procargs(environment, arguments=(b"/synthetic/host",), suffix=b""):
    return (struct.pack("=i", len(arguments)) + b"/synthetic/host\0\0\0"
            + b"\0".join(arguments) + b"\0" + b"\0".join(environment) + b"\0\0" + suffix)


class AXExternalStartupTests(unittest.TestCase):
    def test_invalid_owned_pid_and_unavailable_library_are_distinct(self):
        for pid in (True, 0, -1, "123"):
            with mock.patch.object(EXTERNAL.sys, "platform", "darwin"), mock.patch.object(EXTERNAL.ctypes, "CDLL") as load:
                with self.assertRaises(EXTERNAL.StartupReceiptError) as caught:
                    EXTERNAL.read_procargs(pid)
                load.assert_not_called()
            self.assertEqual(EXTERNAL.startup_failure("external-startup-reader", caught.exception)["reason"], "owned_pid")
        with mock.patch.object(EXTERNAL.sys, "platform", "darwin"), \
                mock.patch.object(EXTERNAL.ctypes, "CDLL", side_effect=OSError(2, "/private/secret")):
            with self.assertRaises(EXTERNAL.StartupReceiptError) as caught:
                EXTERNAL.read_procargs(123)
        self.assertEqual(EXTERNAL.startup_failure("external-startup-reader", caught.exception),
            {"stage": "external-startup-reader", "reason": "sysctl_library", "errno": 2})

    def test_syscall_failures_keep_immediate_errno_and_call_site(self):
        for failed_call, number in ((2, 13), (3, 22), (3, 0)):
            calls = []
            def sysctl(mib, count, output, size, *_):
                calls.append(count)
                self.assertEqual(ctypes.get_errno(), 0)
                if count == failed_call:
                    ctypes.set_errno(number)
                    return -1
                output._obj.value = 4096
                size._obj.value = 4
                ctypes.set_errno(91)
                return 0
            library = mock.Mock(); library.sysctl.side_effect = sysctl
            ctypes.set_errno(99)
            with mock.patch.object(EXTERNAL.sys, "platform", "darwin"), mock.patch.object(EXTERNAL.ctypes, "CDLL", return_value=library):
                with self.assertRaises(EXTERNAL.StartupReceiptError) as caught:
                    EXTERNAL.read_procargs(123)
            self.assertEqual(calls, [2] if failed_call == 2 else [2, 3])
            ctypes.set_errno(77)
            self.assertEqual(EXTERNAL.startup_failure("external-startup-reader", caught.exception), {
                "stage": "external-startup-reader", "reason": "sysctl_capacity" if failed_call == 2 else "sysctl_procargs", "errno": number})

    def test_failure_projection_never_uses_exception_text_and_rejects_bad_fields(self):
        for error in (RuntimeError("/private/secret"), ValueError("PATH=secret"), OSError(13, "secret"),
                      EXTERNAL.StartupReceiptError("/private/secret", "secret", 13)):
            self.assertEqual(EXTERNAL.startup_failure("external-startup-host", error),
                {"stage": "external-startup-host", "reason": "unclassified", "errno": None})
        initial = {"stage": "external-startup-reader", "reason": "sysctl_procargs", "errno": 22}
        complete = {"stage": "external-startup-complete", "reason": "receipt_incomplete", "errno": None}
        final = dict(complete, stage="external-startup-final")
        EXTERNAL.validate_startup_failures([initial, complete, final])
        EXTERNAL.validate_startup_failures([])
        bad = [None, {}, [initial] * 5, [initial, initial], [final, initial],
            [dict(initial, extra="secret")], [dict(initial, stage="secret")],
            [dict(initial, reason="secret")], [dict(initial, reason=[])], [dict(initial, errno=True)],
            [dict(initial, errno=-1)], [dict(initial, errno=4096)], [dict(initial, errno="22")],
            [dict(initial, errno=None)], [dict(initial, reason="parse_argc")],
            [dict(complete, errno=22)], [dict(initial, reason="receipt_incomplete", errno=None)],
            [dict(complete, reason="parse_argc")], [dict(initial, stage=True)]]
        for value in bad:
            with self.subTest(value=value), self.assertRaises(ValueError) as caught:
                EXTERNAL.validate_startup_failures(value)
            self.assertNotIn("secret", str(caught.exception))

    def test_hash_io_failure_projection_requires_fixed_reason_stage_and_errno(self):
        for stage, reason in (("external-startup-complete", "prepared_hash"),
                              ("external-startup-final", "working_hash")):
            error = PermissionError(13, "private-secret", "/private/secret")
            error._startup_hash_reason = reason
            self.assertEqual(EXTERNAL.startup_failure(stage, error),
                {"stage": stage, "reason": reason, "errno": 13})
            self.assertEqual(type(error), PermissionError)
            self.assertEqual(str(error), "[Errno 13] private-secret: '/private/secret'")
        for stage, reason, number in (("external-startup-host", "prepared_hash", 13),
                ("external-startup-final", "sysctl_procargs", 13),
                ("external-startup-final", "/private/secret", 13),
                ("external-startup-final", ["working_hash"], 13),
                ("external-startup-final", "working_hash", True),
                ("external-startup-final", "working_hash", -1),
                ("external-startup-final", "working_hash", 4096)):
            error = PermissionError(13, "private-secret")
            error._startup_hash_reason, error.errno = reason, number
            self.assertEqual(EXTERNAL.startup_failure(stage, error),
                {"stage": stage, "reason": "unclassified", "errno": None})

    def test_parse_failures_identify_shape_without_exporting_contents(self):
        for raw, reason in ((b"", "parse_size"), (struct.pack("=i", 0) + b"path\0", "parse_argc"),
                (struct.pack("=i", 1) + b"\0", "parse_executable"),
                (struct.pack("=i", 1) + b"private-secret", "parse_terminator"),
                (procargs([b"PATH=x", b"PATH=secret"]), "parse_environment"),
                (procargs([]), "environment_not_visible")):
            with self.assertRaises(EXTERNAL.StartupReceiptError) as caught:
                EXTERNAL.parse_procargs(raw)
            evidence = EXTERNAL.startup_failure("external-startup-host", caught.exception)
            self.assertEqual(evidence["reason"], reason)
            self.assertIsNone(evidence["errno"])
            self.assertNotIn("secret", json.dumps(evidence))

    @unittest.skipUnless(sys.platform == "darwin", "Darwin owned-child startup metadata")
    def test_native_owned_child_success_and_injected_syscall_failure(self):
        temporary = ROOT / ".build/Temporary"
        temporary.mkdir(parents=True, exist_ok=True)
        parent = Path(tempfile.gettempdir()).resolve()
        if not parent.is_relative_to(temporary): parent = temporary
        with tempfile.TemporaryDirectory(prefix="ax-owned-child-", dir=parent) as directory:
            executable = Path(directory) / "owned-child"
            # macOS framework Python can re-exec another binary after Popen.
            # This fixture has one executable identity for the entire check.
            source = '#include <stdio.h>\nint main(void) { puts("ready"); fflush(stdout); return getchar() == EOF ? 0 : 1; }\n'
            subprocess.run(["xcrun", "clang", "-x", "c", "-", "-o", str(executable)],
                           input=source, text=True, capture_output=True, check=True, timeout=30)
            environment = dict(os.environ, QUICKFILE_AX_INSTALL_PROBE_MODE="installed")
            environment.pop("MallocScribble", None)
            child = subprocess.Popen([str(executable)], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, env=environment)
            try:
                self.assertTrue(select.select([child.stdout], [], [], 10)[0], "Owned child did not become ready")
                self.assertEqual(child.stdout.readline(), b"ready\n")
                digest = EXTERNAL.executable_hash(executable)
                receipt = EXTERNAL.owned_child_receipt(child, executable, environment, "off", digest, "installed")
                self.assertEqual(receipt["malloc_scribble"], "unset")
                self.assertEqual(receipt["install_gate"], "installed")
                def sysctl(mib, count, output, size, *_):
                    if count == 2:
                        output._obj.value = 4096; size._obj.value = 4
                        return 0
                    ctypes.set_errno(13)
                    return -1
                library = mock.Mock(); library.sysctl.side_effect = sysctl
                with mock.patch.object(EXTERNAL.ctypes, "CDLL", return_value=library), self.assertRaises(EXTERNAL.StartupReceiptError) as caught:
                    EXTERNAL.owned_child_receipt(child, executable, environment, "off", digest, "installed")
                self.assertEqual(EXTERNAL.startup_failure("external-startup-host", caught.exception),
                    {"stage": "external-startup-host", "reason": "sysctl_procargs", "errno": 13})
                self.assertIsNone(child.poll())
            finally:
                try:
                    child.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill(); child.communicate(timeout=5)
            self.assertEqual(child.returncode, 0)

    def test_install_gate_startup_requires_exact_setting_and_public_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "host"
            path.write_bytes(b"owned"); path.chmod(0o700)
            digest = EXTERNAL.executable_hash(path)
            for mode in EXTERNAL.INSTALL_MODES:
                environment = {"PATH": "/synthetic/bin", EXTERNAL.INSTALL_ENV: mode}
                for actual_mode in (mode, None, "secret", "preflight-only" if mode == "installed" else "installed"):
                    actual = {b"PATH": b"/synthetic/bin"}
                    if actual_mode is not None:
                        actual[EXTERNAL.INSTALL_ENV.encode()] = actual_mode.encode()
                    process = mock.Mock(args=[str(path)], pid=123)
                    process.poll.return_value = None
                    with mock.patch.object(EXTERNAL, "read_procargs", return_value=(os.fsencode(path), [os.fsencode(path)], actual)):
                        if actual_mode != mode:
                            with self.assertRaises(RuntimeError) as error:
                                EXTERNAL.owned_child_receipt(process, path, environment, "off", digest, mode)
                            self.assertNotIn("secret", str(error.exception))
                            self.assertEqual(EXTERNAL.startup_failure("external-startup-host", error.exception)["reason"], "install_setting")
                        else:
                            entry = EXTERNAL.owned_child_receipt(process, path, environment, "off", digest, mode)
                            self.assertEqual(entry["install_gate"], mode)
                hashes = {"host": digest, "reader": digest}
                value = {"receipt_mode": "external-startup", "requested": "off", "host": dict(entry), "reader": dict(entry),
                         "executables": hashes, "binary_reuse_verified": True, "install_gate": mode}
                EXTERNAL.validate_external_receipt(value, "off", hashes, mode)
                with self.assertRaises(RuntimeError):
                    EXTERNAL.validate_external_receipt(value, "off", hashes)
                for change in (lambda v: v.pop("install_gate"), lambda v: v["host"].pop("install_gate"),
                               lambda v: v["reader"].update(install_gate="secret"), lambda v: v.update(install_gate="secret")):
                    altered = json.loads(json.dumps(value)); change(altered)
                    with self.assertRaises(RuntimeError) as error:
                        EXTERNAL.validate_external_receipt(altered, "off", hashes, mode)
                    self.assertNotIn("secret", str(error.exception))

    def test_sysctl_capacity_result_bounds_and_errors_fail_closed(self):
        raw = procargs([b"PATH=/synthetic/bin"])
        for failure in (None, "capacity-error", "capacity-size", "capacity-bound", "read-error", "result-size", "malformed"):
            def sysctl(mib, count, output, size, *_):
                if count == 2:
                    output._obj.value = EXTERNAL.ARGUMENT_LIMIT + 1 if failure == "capacity-bound" else 4096
                    size._obj.value = 1 if failure == "capacity-size" else 4
                    return int(failure == "capacity-error")
                if failure == "read-error":
                    return -1
                data = b"bad" if failure == "malformed" else raw
                output.raw = data
                size._obj.value = 4097 if failure == "result-size" else len(data)
                return 0

            library = mock.Mock()
            library.sysctl.side_effect = sysctl
            with self.subTest(failure=failure), mock.patch.object(EXTERNAL.sys, "platform", "darwin"), \
                    mock.patch.object(EXTERNAL.ctypes, "CDLL", return_value=library):
                if failure:
                    with self.assertRaises(RuntimeError) as caught:
                        EXTERNAL.read_procargs(123)
                    self.assertEqual(EXTERNAL.startup_failure("external-startup-host", caught.exception)["reason"], {
                        "capacity-error": "sysctl_capacity", "capacity-size": "capacity_shape", "capacity-bound": "capacity_shape",
                        "read-error": "sysctl_procargs", "result-size": "result_size", "malformed": "result_size"}[failure])
                else:
                    self.assertEqual(EXTERNAL.read_procargs(123)[2], {b"PATH": b"/synthetic/bin"})

    def test_procargs_preserves_empty_argument_and_stops_at_environment_terminator(self):
        raw = procargs([b"PATH=/synthetic/bin", b"MallocScribble=1", b"OTHER=a=b"],
                       (b"/synthetic/host", b"", b"last"), b"outside-environment")
        executable, arguments, environment = EXTERNAL.parse_procargs(raw)
        self.assertEqual(executable, b"/synthetic/host")
        self.assertEqual(arguments, [b"/synthetic/host", b"", b"last"])
        self.assertEqual(environment, {b"PATH": b"/synthetic/bin", b"MallocScribble": b"1", b"OTHER": b"a=b"})

    def test_complete_environment_accepts_final_entry_nul_at_eof(self):
        raw = procargs([b"PATH=/synthetic/bin", b"EMPTY=", b"OTHER=a=b"],
                       (b"/synthetic/host", b"", b"last"))
        expected = (b"/synthetic/host", [b"/synthetic/host", b"", b"last"],
                    {b"PATH": b"/synthetic/bin", b"EMPTY": b"", b"OTHER": b"a=b"})
        for data in (raw, raw[:-1]):
            with self.subTest(extra_empty_entry=data == raw):
                self.assertEqual(EXTERNAL.parse_procargs(data), expected)

    def test_zero_padding_apple_tail_keeps_strict_entry_and_empty_entry_rules(self):
        environment = procargs([b"PATH=/synthetic/bin"])[:-1]
        apple = b"executable_path=/synthetic/host\0"
        for padding in (b"", b"\0"):
            with self.subTest(padding=bool(padding)):
                self.assertEqual(EXTERNAL.parse_procargs(environment + apple + padding)[2],
                    {b"PATH": b"/synthetic/bin", b"executable_path": b"/synthetic/host"})
        for tail in (b"unterminated-secret", b"secret-without-equals\0", b"=secret\0", b"PATH=secret\0"):
            with self.subTest(tail=tail):
                with self.assertRaises(EXTERNAL.StartupReceiptError) as caught:
                    EXTERNAL.parse_procargs(environment + tail)
                self.assertEqual(caught.exception.reason, "parse_terminator" if not tail.endswith(b"\0") else "parse_environment")
                self.assertNotIn("secret", str(caught.exception))
                # An extra empty entry still ends parsing before arbitrary tail bytes.
                self.assertEqual(EXTERNAL.parse_procargs(environment + b"\0" + tail)[2],
                    {b"PATH": b"/synthetic/bin"})

    def test_capacity_filling_sysctl_data_cannot_form_an_off_receipt(self):
        with tempfile.TemporaryDirectory(prefix="ax-procargs-") as directory:
            executable = Path(directory).resolve() / "synthetic-host"
            executable.write_bytes(b"synthetic fixture identity")
            executable.chmod(0o700)
            digest = EXTERNAL.executable_hash(executable)
            path = os.fsencode(executable)
            complete = struct.pack("=i", 1) + path + b"\0\0" + path + b"\0PATH=/synthetic/bin\0"
            for extra_empty_entry in (False, True):
                data = complete + (b"\0" if extra_empty_entry else b"")
                for spare_capacity in (0, 1):
                    capacity = len(data) + spare_capacity
                    calls = []
                    def sysctl(mib, count, output, size, *_):
                        calls.append((tuple(mib), size._obj.value))
                        if count == 2:
                            output._obj.value = capacity
                            size._obj.value = 4
                        else:
                            self.assertEqual(size._obj.value, capacity)
                            output.raw = data
                            size._obj.value = len(data)
                        return 0
                    library = mock.Mock(); library.sysctl.side_effect = sysctl
                    process = mock.Mock(pid=123, args=[str(executable)])
                    process.poll.return_value = None
                    with self.subTest(extra_empty_entry=extra_empty_entry, spare_capacity=spare_capacity), \
                            mock.patch.object(EXTERNAL.sys, "platform", "darwin"), \
                            mock.patch.object(EXTERNAL.ctypes, "CDLL", return_value=library), \
                            mock.patch.object(EXTERNAL, "parse_procargs", wraps=EXTERNAL.parse_procargs) as parse:
                        if not spare_capacity:
                            with self.assertRaises(EXTERNAL.StartupReceiptError) as caught:
                                EXTERNAL.owned_child_receipt(process, executable, {"PATH": "/synthetic/bin"}, "off", digest)
                            self.assertEqual(EXTERNAL.startup_failure("external-startup-reader", caught.exception),
                                {"stage": "external-startup-reader", "reason": "result_size", "errno": None})
                            parse.assert_not_called()
                        else:
                            receipt = EXTERNAL.owned_child_receipt(process, executable, {"PATH": "/synthetic/bin"}, "off", digest)
                            self.assertEqual(receipt, {"malloc_scribble": "unset", "path_matches": True,
                                "startup_executable_matches": True, "alive_during_check": True, "executable_sha256": digest})
                            parse.assert_called_once_with(data)
                    self.assertEqual(calls, [((1, 8), 4), ((1, 49, 123), capacity)])

    def test_malformed_or_invisible_environment_is_never_unset(self):
        argv_only = struct.pack("=i", 1) + b"/synthetic/host\0\0/synthetic/host\0"
        bad = [b"", struct.pack("=i", 0) + b"path\0", struct.pack("=i", 4097) + b"path\0",
               struct.pack("=i", 1) + b"\0", argv_only, argv_only + b"\0", procargs([]), procargs([b"PATH=x", b"PATH=y"]),
               procargs([b"secret-entry-without-equals"]), procargs([b"=secret"]),
               procargs([b"PATH=x"])[:-2], procargs([b"PATH=x"])[:-3],
               struct.pack("=i", 1) + b"unterminated-secret"]
        for raw in bad:
            with self.subTest(length=len(raw)), self.assertRaises(RuntimeError) as error:
                EXTERNAL.parse_procargs(raw)
            self.assertNotIn("secret", str(error.exception))

    def test_owned_startup_identity_visibility_liveness_and_hash_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "host"
            path.write_bytes(b"executable")
            path.chmod(0o700)
            alias = Path(directory) / "alias"
            alias.symlink_to(path)
            digest = EXTERNAL.executable_hash(path)
            for failure in (None, "before-exit", "after-exit", "launch", "startup", "argv", "path", "empty-path", "setting", "hash", "read", "poll-error"):
                process = mock.Mock(args=[str(alias)], pid=123)
                process.poll.side_effect = [1] if failure == "before-exit" else [None, 1 if failure == "after-exit" else None]
                if failure == "poll-error":
                    process.poll.side_effect = OSError(13, "/private/secret")
                environment = {"PATH": "/synthetic/bin"}
                actual = {b"PATH": b"/synthetic/bin"}
                executable, arguments = os.fsencode(alias), [os.fsencode(alias)]
                if failure == "launch":
                    process.args = ["/missing/private"]
                if failure == "startup":
                    executable = b"/missing/private"
                if failure == "argv":
                    arguments = [b"/missing/private"]
                if failure == "path":
                    actual[b"PATH"] = b"/private/secret"
                if failure == "empty-path":
                    environment["PATH"] = ""
                if failure == "setting":
                    actual[b"MallocScribble"] = b"/private/secret"
                with self.subTest(failure=failure), mock.patch.object(EXTERNAL, "read_procargs",
                        return_value=(executable, arguments, actual),
                        side_effect=RuntimeError("Startup environment unavailable") if failure == "read" else None):
                    if failure:
                        with self.assertRaises(RuntimeError) as error:
                            EXTERNAL.owned_child_receipt(process, path, environment, "off", "0" * 64 if failure == "hash" else digest)
                        self.assertNotIn("private", str(error.exception))
                        reason = {"before-exit": "child_not_alive", "after-exit": "child_exited", "launch": "launch_path",
                            "startup": "startup_path", "argv": "startup_argv", "path": "path_visibility",
                            "empty-path": "path_visibility", "setting": "allocator_setting", "hash": "executable_hash",
                            "read": "unclassified", "poll-error": "unclassified"}[failure]
                        evidence = EXTERNAL.startup_failure("external-startup-host", error.exception)
                        self.assertEqual(evidence["reason"], reason)
                        self.assertEqual(evidence["errno"], 2 if failure in ("launch", "startup", "argv") else None)
                    else:
                        value = EXTERNAL.owned_child_receipt(process, path, environment, "off", digest)
                        self.assertEqual(value["malloc_scribble"], "unset")
                        self.assertTrue(value["startup_executable_matches"])

    def test_public_receipt_rejects_missing_extra_and_unverified_fields(self):
        hashes = {"host": "a" * 64, "reader": "b" * 64}
        for setting in ("off", "on"):
            value = {"receipt_mode": "external-startup", "requested": setting, "executables": hashes,
                     "binary_reuse_verified": True}
            for role in hashes:
                value[role] = {"malloc_scribble": "1" if setting == "on" else "unset", "path_matches": True,
                    "startup_executable_matches": True, "alive_during_check": True, "executable_sha256": hashes[role]}
            EXTERNAL.validate_external_receipt(value, setting, hashes)
            mutations = [lambda v: v.update(extra="/private/secret"), lambda v: v.update(binary_reuse_verified=1),
                lambda v: v.update(receipt_mode="internal"), lambda v: v.update(host=None),
                lambda v: v["reader"].update(path_matches=False), lambda v: v["host"].update(alive_during_check=1),
                lambda v: v["reader"].update(executable_sha256="c" * 64), lambda v: v["reader"].pop("malloc_scribble")]
            for change in mutations:
                candidate = json.loads(json.dumps(value))
                change(candidate)
                with self.assertRaises(RuntimeError):
                    EXTERNAL.validate_external_receipt(candidate, setting, hashes)


class AXPreparedFixtureTests(unittest.TestCase):
    def test_preparation_rejects_measurement_and_external_rejects_incompatible_modes(self):
        invalid = [["--prepare-external-fixture", flag] for flag in ("--heap-control", "--heap-diagnostics", "--copy-lifetime", "--system-baseline", "--external-startup-receipt")]
        invalid += [["--external-startup-receipt"], ["--malloc-scribble", "off", "--external-startup-receipt"],
                    ["--prepared-fixture-directory", "/synthetic"]]
        invalid += [["--external-startup-receipt", "--prepared-fixture-directory", "/synthetic", "--malloc-scribble", "off", flag]
                    for flag in ("--heap-diagnostics", "--copy-lifetime", "--system-baseline", "--read-only", "--ownership-trace", "--balance-copies")]
        for arguments in invalid:
            with mock.patch.object(sys, "argv", ["probe", "--work-directory", "/synthetic/work", "--records-directory", "/synthetic/records", *arguments]), \
                    mock.patch.object(PROBE.subprocess, "run") as run, contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as error:
                PROBE.main()
            self.assertEqual(error.exception.code, 2)
            run.assert_not_called()

    def test_prepare_build_has_no_receipt_macro_and_detects_byte_or_source_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            work, records = root / "fixture", root / "records"
            class ProbeRoot:
                def __truediv__(self, child):
                    return root if child == ".build/Temporary" else ROOT / child

            commands = []
            def run(command, **kwargs):
                commands.append(command)
                if "-o" in command:
                    output = Path(command[command.index("-o") + 1])
                    output.write_bytes(output.name.encode())
                    output.chmod(0o700)
                return subprocess.CompletedProcess(command, 0, "", "")

            with mock.patch.object(PROBE, "ROOT", ProbeRoot()), mock.patch.object(PROBE.subprocess, "run", side_effect=run), \
                    mock.patch.object(PROBE.subprocess, "Popen") as start, contextlib.redirect_stdout(io.StringIO()), \
                    mock.patch.object(sys, "argv", ["probe", "--prepare-external-fixture", "--work-directory", str(work), "--records-directory", str(records)]):
                self.assertEqual(PROBE.main(), 0)
            start.assert_not_called()
            self.assertEqual(sum("swiftc" in command for command in commands), 1)
            self.assertEqual(sum("-fobjc-arc" in command for command in commands), 1)
            self.assertFalse(any("--capabilities" in command or any("QUICKFILE_AX_" in item for item in command) for command in commands))
            manifest = json.loads((work / "fixture-build.json").read_text())
            EXTERNAL.load_prepared_fixture(work, manifest["sources"])
            with self.assertRaises(RuntimeError):
                EXTERNAL.load_prepared_fixture(work, {})
            for role, name in EXTERNAL.EXECUTABLES.items():
                path = work / name
                original = path.read_bytes()
                path.write_bytes(b"changed executable")
                with self.assertRaises(RuntimeError):
                    EXTERNAL.load_prepared_fixture(work, manifest["sources"])
                path.write_bytes(original)
            manifest["build_mode"] = "internal"
            (work / "fixture-build.json").write_text(json.dumps(manifest))
            with self.assertRaises(RuntimeError):
                EXTERNAL.load_prepared_fixture(work, manifest["sources"])


class AXValidationClassificationTests(unittest.TestCase):
    def test_all_private_stages_project_to_fixed_counts(self):
        stages = ["baseline", "registered-10", "control-host-0", "control-reader-7", "notifications",
                  "compensation-branches", "malloc-scribble", "external-startup-final", "/private/secret"]
        result = {"coverage": "failed", "validation_errors": [{"stage": stage, "message": "/private/secret"} for stage in stages]}
        counts = REPORT.validation_failure_counts(result)
        self.assertEqual(counts, {"heap_baseline": 2, "control_activity": 2, "notifications": 1,
                                  "compensation_branches": 1, "allocator_environment": 2, "other": 1})
        self.assertNotIn("secret", json.dumps(counts))

    def test_missing_or_malformed_failure_accounting_is_incomplete(self):
        for result in ({}, {"coverage": "failed"}, {"coverage": "passed", "validation_errors": [None]},
                       {"coverage": "failed", "validation_errors": [{"stage": False}]},
                       {"coverage": "failed", "validation_errors": [{"stage": "x"}] * 65}):
            with self.assertRaises(ValueError):
                REPORT.validation_failure_counts(result)
