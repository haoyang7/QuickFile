import contextlib
import io
import json
import os
from pathlib import Path
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
                    with self.assertRaises(RuntimeError):
                        EXTERNAL.read_procargs(123)
                else:
                    self.assertEqual(EXTERNAL.read_procargs(123)[2], {b"PATH": b"/synthetic/bin"})

    def test_procargs_preserves_empty_argument_and_stops_at_environment_terminator(self):
        raw = procargs([b"PATH=/synthetic/bin", b"MallocScribble=1", b"OTHER=a=b"],
                       (b"/synthetic/host", b"", b"last"), b"outside-environment")
        executable, arguments, environment = EXTERNAL.parse_procargs(raw)
        self.assertEqual(executable, b"/synthetic/host")
        self.assertEqual(arguments, [b"/synthetic/host", b"", b"last"])
        self.assertEqual(environment, {b"PATH": b"/synthetic/bin", b"MallocScribble": b"1", b"OTHER": b"a=b"})

    def test_malformed_or_invisible_environment_is_never_unset(self):
        bad = [b"", struct.pack("=i", 0) + b"path\0", struct.pack("=i", 4097) + b"path\0",
               struct.pack("=i", 1) + b"\0", procargs([]), procargs([b"PATH=x", b"PATH=y"]),
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
            for failure in (None, "before-exit", "after-exit", "launch", "startup", "argv", "path", "empty-path", "setting", "hash", "read"):
                process = mock.Mock(args=[str(alias)], pid=123)
                process.poll.side_effect = [1] if failure == "before-exit" else [None, 1 if failure == "after-exit" else None]
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
