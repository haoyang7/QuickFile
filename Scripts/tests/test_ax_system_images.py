import ctypes
import importlib.util
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

SOURCE = Path(__file__).resolve().parents[1] / "Investigations/ax_system_images.py"
SPEC = importlib.util.spec_from_file_location("ax_system_images_tested", SOURCE)
IMAGES = importlib.util.module_from_spec(SPEC)
with mock.patch.object(sys, "path", [str(SOURCE.parent), *sys.path]):
    SPEC.loader.exec_module(IMAGES)
IDENTIFIER = "12345678-1234-1234-1234-123456789ABC"
SECOND = "22345678-1234-1234-1234-123456789ABC"


def macho(identifier=IDENTIFIER):
    import uuid
    commands = struct.pack("<II", 0x1b, 24) + uuid.UUID(identifier).bytes
    return struct.pack("<8I", 0xfeedfacf, 0, 0, 6, 1, len(commands), 0x80000000, 0), commands


class AXSystemImageTests(unittest.TestCase):
    def test_macho_uuid_requires_complete_bounded_unambiguous_cache_dylib(self):
        header, commands = macho()
        self.assertEqual(IMAGES.image_uuid(header, commands), IDENTIFIER)
        cases = [(header[:-1], commands), (header, commands[:-1]), (header, commands + b"padding!")]
        for field, value in ((0, 0), (3, 2), (4, 0), (4, 4), (5, 65544), (6, 0)):
            fields = list(struct.unpack("<8I", header)); fields[field] = value
            cases.append((struct.pack("<8I", *fields), commands))
        for length in (0, 7, 16, 25, 32):
            cases.append((header, struct.pack("<II", 0x1b, length) + commands[8:]))
        cases += [(header, struct.pack("<II", 0x19, 24) + commands[8:]),
                  (header, commands[:8] + bytes(16)),
                  (struct.pack("<8I", 0xfeedfacf, 0, 0, 6, 2, 48, 0x80000000, 0), commands * 2)]
        for bad_header, bad_commands in cases:
            with self.subTest(header=bad_header, commands=bad_commands), self.assertRaises(ValueError):
                IMAGES.image_uuid(bad_header, bad_commands)

    def test_paths_and_public_identity_have_no_arbitrary_tokens(self):
        self.assertEqual(IMAGES.system_basename("/usr/lib/system/libsystem_pthread.dylib"), "libsystem_pthread.dylib")
        self.assertEqual(IMAGES.system_basename("/System/Library/PrivateFrameworks/Foo.framework/Versions/A/Foo"), "Foo")
        for path in ("/Users/private/Foo", "/System/LibraryFake/Foo", "/usr/lib/../private/Foo",
                     "/usr/lib//Foo", "/usr/lib/./Foo", "/usr/lib/Foo\nsecret", "/usr/lib/Foo secret",
                     "/usr/lib/" + "a" * 97, "/usr/lib/é", None):
            self.assertIsNone(IMAGES.system_basename(path))
        for row in ({"basename": "Foo", "uuid": IDENTIFIER, "path": "secret"},
                    {"basename": "/Foo", "uuid": IDENTIFIER}, {"basename": "Foo", "uuid": "secret"},
                    {"basename": "Foo", "uuid": "00000000-0000-0000-0000-000000000000"}):
            self.assertFalse(IMAGES.safe_identity(row))

    @staticmethod
    def report(rows):
        return "private report\nBinary Images:\n" + "\n".join(
            f" {start:#x} - {end:#x} +private-label (1.2 - 3) <{identifier}> /private/path" for start, end, identifier in rows) + "\n"

    def test_target_intervals_and_uuid_conflicts_are_not_disambiguated_by_names(self):
        report = self.report([(0x1000, 0x10ff, IDENTIFIER), (0x2000, 0x20ff, SECOND)])
        self.assertEqual(IMAGES.report_images(report), [(0x1000, 0x10ff, IDENTIFIER), (0x2000, 0x20ff, SECOND)])
        duplicates = self.report([(0x1000, 0x10ff, IDENTIFIER), (0x2000, 0x20ff, IDENTIFIER), (0x3000, 0x30ff, SECOND)])
        self.assertEqual(IMAGES.report_images(duplicates), [(0x1000, 0x10ff, None), (0x2000, 0x20ff, None), (0x3000, 0x30ff, SECOND)])
        for rows in ([(0x1000, 0x2000, IDENTIFIER), (0x2000, 0x3000, SECOND)],
                     [(0x1000, 0x3000, IDENTIFIER), (0x1100, 0x1200, SECOND)],
                     [(0x2000, 0x1000, IDENTIFIER)], [(0, 0x1000, IDENTIFIER)]):
            with self.assertRaises(ValueError):
                IMAGES.report_images(self.report(rows))
        for bad in (report + "arbitrary trailer", report + "\nBinary Images:\n", report.replace(IDENTIFIER, "x" * 36), "no table"):
            with self.assertRaises(ValueError):
                IMAGES.report_images(bad)
        with mock.patch.object(IMAGES, "IMAGE_LIMIT", 1), self.assertRaises(ValueError):
            IMAGES.report_images(report)

    def fake_library(self, images, change=None):
        buffers = [ctypes.create_string_buffer(b"".join(macho(identifier))) for _, identifier, _ in images]
        records = {ctypes.addressof(buffer): row for buffer, row in zip(buffers, images)}
        library = mock.Mock()
        def lookup(address, info):
            info._obj.path = records[address][0].encode()
            info._obj.base = address
            return 1
        library.dladdr.side_effect = lookup
        library._dyld_shared_cache_contains_path.side_effect = lambda path: next(row[2] for row in images if row[0].encode() == path)
        def add(callback):
            for address in records:
                callback(address, 0)
            if change == "removed":
                library._dyld_register_func_for_remove_image.call_args.args[0](next(iter(records)), 0)
            if change == "duplicate_header":
                callback(next(iter(records)), 0)
        library._dyld_register_func_for_add_image.side_effect = add
        return library, buffers

    def test_local_cache_membership_uuid_conflicts_and_callback_failures(self):
        rows = [("/usr/lib/liboah.dylib", IDENTIFIER, True), ("/usr/lib/libRosetta.dylib", IDENTIFIER, True),
                ("/usr/lib/system/libsystem_pthread.dylib", SECOND, True), ("/private/secret", IDENTIFIER, True),
                ("/usr/lib/NotCached.dylib", IDENTIFIER, False)]
        library, buffers = self.fake_library(rows)
        callbacks = []
        with mock.patch.object(IMAGES.ctypes, "CDLL", return_value=library) as load:
            result, keepalive = IMAGES._loaded_images(callbacks)
        self.assertEqual(result["images"], [{"basename": "libsystem_pthread.dylib", "uuid": SECOND}])
        self.assertEqual(len(callbacks), 2)
        self.assertEqual([call.args for call in load.call_args_list],
                         [("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",), (None,)])
        callbacks[0](ctypes.addressof(buffers[0]), 0)  # Late add invalidates the already-closed snapshot.
        self.assertTrue(keepalive[2]["failed"])
        for change in ("removed", "duplicate_header"):
            library, buffers = self.fake_library(rows, change)
            with mock.patch.object(IMAGES.ctypes, "CDLL", return_value=library), self.assertRaises(ValueError):
                IMAGES._loaded_images([])
        library, buffers = self.fake_library(rows)
        library.dladdr.side_effect = RuntimeError("private failure")
        with mock.patch.object(IMAGES.ctypes, "CDLL", return_value=library), self.assertRaisesRegex(ValueError, "Unstable"):
            IMAGES._loaded_images([])

    def test_worker_writes_all_bytes_before_raw_exit_and_retains_callbacks(self):
        class RawExit(BaseException):
            pass
        callbacks_seen, chunks = [], []
        result = {"schema": 1, "images": [{"basename": "Foo", "uuid": IDENTIFIER}]}
        def loaded(callbacks):
            callbacks.extend((object(), object()))
            callbacks_seen.append(callbacks)
            return result, (None, None, {"failed": False})
        def write(fd, payload):
            chunks.append(payload[:3]); return min(3, len(payload))
        def raw_exit(code):
            self.assertEqual(code, 0)
            self.assertEqual(len(callbacks_seen[0]), 2)
            raise RawExit()
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(IMAGES, "_loaded_images", side_effect=loaded), mock.patch.object(IMAGES.os, "write", side_effect=write), \
                mock.patch.object(IMAGES.os, "_exit", side_effect=raw_exit), self.assertRaises(RawExit):
            IMAGES._worker_entry(Path(directory) / "catalog.json")
        self.assertEqual(json.loads(b"".join(chunks)), result)
        for failure in (OSError("private error"), 0):
            with tempfile.TemporaryDirectory() as directory, mock.patch.object(IMAGES, "_loaded_images", side_effect=loaded), \
                    mock.patch.object(IMAGES.os, "write", side_effect=failure if isinstance(failure, Exception) else None, return_value=0), \
                    mock.patch.object(IMAGES.os, "_exit", side_effect=RawExit) as leave, self.assertRaises(RawExit):
                IMAGES._worker_entry(Path(directory) / "catalog.json")
            leave.assert_called_once_with(1)

    def test_worker_output_close_cannot_hide_late_inventory_change_or_error(self):
        class RawExit(BaseException):
            pass
        close = os.close
        for failure in ("changed", "close-error"):
            state = {"failed": False}
            result = {"schema": 1, "images": [{"basename": "Foo", "uuid": IDENTIFIER}]}
            def finish(descriptor):
                close(descriptor)
                if failure == "close-error":
                    raise OSError("private close error")
                state["failed"] = True
            with tempfile.TemporaryDirectory() as directory:
                with mock.patch.object(IMAGES, "_loaded_images", return_value=(result, (None, None, state))), \
                        mock.patch.object(IMAGES.os, "close", side_effect=finish), \
                        mock.patch.object(IMAGES.os, "_exit", side_effect=RawExit) as leave, self.assertRaises(RawExit):
                    IMAGES._worker_entry(Path(directory) / "catalog.json")
                leave.assert_called_once_with(1)
                self.assertEqual(json.loads((Path(directory) / "catalog.json").read_text()), result)

    def test_worker_protocol_rejects_partial_duplicate_and_private_output(self):
        image = {"basename": "Foo", "uuid": IDENTIFIER}
        encode = lambda value: json.dumps(value, separators=(",", ":")).encode() + b"\n"
        good = encode({"schema": 1, "images": [image]})
        outputs = [(1, good), (0, good + b"secret"), (0, good[:-2]),
                   (0, encode({"schema": 1, "images": [image, image]})),
                   (0, encode({"schema": True, "images": [image]})),
                   (0, encode({"schema": 1, "images": [{**image, "path": "secret"}]}))]
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(IMAGES, "WORKER_ROOT", Path(directory)):
            for code, payload in [*outputs, (0, good)]:
                def run(command, log, environment, timeout):
                    log.write_bytes(b"")
                    Path(command[-1]).write_bytes(payload)
                    self.assertEqual(command[-2], "--worker")
                    self.assertEqual(environment["TMPDIR"], str(log.parent))
                    self.assertEqual(timeout, IMAGES.WORKER_SECONDS)
                    return {"status": "completed", "return_code": code, "cleanup": {"complete": True}}
                with mock.patch.object(IMAGES.ax_process, "run_owned", side_effect=run):
                    self.assertEqual(IMAGES.loaded_system_images(), {IDENTIFIER: image} if (code, payload) == (0, good) else None)
                    with mock.patch.object(IMAGES, "CATALOG_BYTE_LIMIT", 1):
                        self.assertIsNone(IMAGES.loaded_system_images())
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_combined_log_must_be_empty_even_for_whitespace_stderr(self):
        good = {"schema": 1, "images": [{"basename": "Foo", "uuid": IDENTIFIER}]}
        for errors in (b" ", b"\n", b"private error"):
            with self.subTest(errors=errors), tempfile.TemporaryDirectory() as directory, \
                    mock.patch.object(IMAGES, "WORKER_ROOT", Path(directory)):
                def run(command, log, environment, timeout):
                    log.write_bytes(errors)
                    Path(command[-1]).write_text(json.dumps(good, separators=(",", ":")) + "\n")
                    return {"status": "completed", "return_code": 0, "cleanup": {"complete": True}}
                with mock.patch.object(IMAGES.ax_process, "run_owned", side_effect=run):
                    self.assertIsNone(IMAGES.loaded_system_images())
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_confirmed_timeout_and_known_spawn_failure_degrade_without_poisoning_next_worker(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(IMAGES, "WORKER_ROOT", Path(directory)):
            receipt = Path(directory) / "cleanup.json"
            IMAGES.write_worker_cleanup(receipt, True)
            for status in ("timeout", "start_failed", "protocol_failed"):
                with mock.patch.object(IMAGES.ax_process, "run_owned", return_value={
                        "status": status, "return_code": 124, "cleanup": {"complete": True}}) as run:
                    self.assertIsNone(IMAGES.loaded_system_images(receipt))
                    self.assertTrue(IMAGES.worker_cleanup_confirmed(receipt))
                    run.assert_called_once()
            self.assertEqual(list(Path(directory).iterdir()), [receipt])

    def test_missing_exit_receipt_is_fatal_and_blocks_every_later_helper(self):
        for failure in (OSError("private reap error"), {"cleanup": {"complete": False}}, {}):
            with self.subTest(failure=type(failure).__name__), tempfile.TemporaryDirectory() as directory, \
                    mock.patch.object(IMAGES, "WORKER_ROOT", Path(directory)), \
                    mock.patch.object(IMAGES, "_cleanup_unconfirmed", False):
                receipt = Path(directory) / "cleanup.json"
                IMAGES.write_worker_cleanup(receipt, True)
                kwargs = {"side_effect": failure} if isinstance(failure, Exception) else {"return_value": failure}
                with mock.patch.object(IMAGES.ax_process, "run_owned", **kwargs) as run:
                    with self.assertRaises(IMAGES.ImageWorkerCleanupError) as error:
                        IMAGES.loaded_system_images(receipt)
                    if isinstance(failure, Exception):
                        self.assertIs(error.exception.__cause__, failure)
                    self.assertFalse(IMAGES.worker_cleanup_confirmed(receipt))
                    self.assertFalse(json.loads(receipt.read_text())["cleanup_confirmed"])
                    with self.assertRaises(IMAGES.ImageWorkerCleanupError):
                        IMAGES.loaded_system_images()  # Also blocks a caller without a sidecar.
                    run.assert_called_once()
                self.assertEqual(len(list(Path(directory).glob("ax-system-images-*"))), 1)  # Unknown ownership keeps private evidence.

    def test_confirmed_process_with_artifact_failure_is_distinct_and_retains_directory(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(IMAGES, "WORKER_ROOT", Path(directory)):
            receipt = Path(directory) / "cleanup.json"
            IMAGES.write_worker_cleanup(receipt, True)
            error = PermissionError(13, "private directory")
            with mock.patch.object(IMAGES.ax_process, "run_owned", return_value={
                    "status": "completed", "return_code": 1, "cleanup": {"complete": True}}), \
                    mock.patch.object(IMAGES.shutil, "rmtree", side_effect=error), \
                    self.assertRaises(IMAGES.ImageWorkerArtifactError) as raised:
                IMAGES.loaded_system_images(receipt)
            self.assertIs(raised.exception.__cause__, error)
            self.assertNotIn("private", str(raised.exception))
            self.assertEqual(IMAGES.worker_cleanup_state(receipt), (True, False))
            self.assertFalse(IMAGES._cleanup_unconfirmed)
            self.assertEqual(len(list(Path(directory).glob("ax-system-images-*"))), 1)
            with mock.patch.object(IMAGES.ax_process, "run_owned") as run, self.assertRaises(IMAGES.ImageWorkerArtifactError):
                IMAGES.loaded_system_images(receipt)
            run.assert_not_called()

    def test_failed_receipt_write_is_not_retried_or_replaced_by_cleanup_error(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(IMAGES, "WORKER_ROOT", Path(directory)):
            receipt = Path(directory) / "cleanup.json"
            IMAGES.write_worker_cleanup(receipt, True)
            error = PermissionError(13, "private receipt")
            with mock.patch.object(Path, "write_text", side_effect=error) as write, \
                    mock.patch.object(IMAGES.shutil, "rmtree", side_effect=OSError("private cleanup")), \
                    mock.patch.object(IMAGES.ax_process, "run_owned") as run, self.assertRaises(IMAGES.ImageWorkerArtifactError) as raised:
                IMAGES.loaded_system_images(receipt)
            self.assertIs(raised.exception.__cause__, error)
            self.assertNotIn("private", str(raised.exception))
            write.assert_called_once()
            run.assert_not_called()
            self.assertTrue(IMAGES.worker_cleanup_confirmed(receipt))  # No child was attempted.

    def test_nonregular_receipts_are_rejected_before_read_or_worker_start(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fifo = root / "fifo"
            os.mkfifo(fifo)
            for path in (root, fifo):
                with self.subTest(kind=path.name), mock.patch.object(Path, "open") as read, \
                        mock.patch.object(IMAGES.ax_process, "run_owned") as run:
                    self.assertFalse(IMAGES.worker_cleanup_confirmed(path))
                    with self.assertRaises(IMAGES.ImageWorkerCleanupError):
                        IMAGES.loaded_system_images(path)
                read.assert_not_called()
                run.assert_not_called()

    def test_receipt_read_is_bounded_even_if_file_grows_after_stat(self):
        value = {"schema": 2, "cleanup_confirmed": True, "artifacts_cleaned": True}
        data = json.dumps(value).encode()
        class Stream(io.BytesIO):
            def read(self, size=-1):
                self.requested = size
                return super().read(size)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.json"
            path.write_bytes(data)
            for length in (128, 129, 10000):
                stream = Stream(data + b" " * (length - len(data)))
                with mock.patch.object(Path, "open", return_value=stream):
                    self.assertEqual(IMAGES.worker_cleanup_state(path), (True, True) if length == 128 else (False, False))
                self.assertEqual(stream.requested, 129)
            for key in ("cleanup_confirmed", "artifacts_cleaned"):
                for bad in (1, None, "true"):
                    path.write_text(json.dumps(dict(value, **{key: bad})))
                    self.assertEqual(IMAGES.worker_cleanup_state(path), (False, False))

    def test_cleanup_receipt_rejects_missing_malformed_or_private_fields_before_spawn(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "cleanup.json"
            values = [None, {}, {"schema": True, "cleanup_confirmed": True, "artifacts_cleaned": True},
                      {"schema": 2, "cleanup_confirmed": 1, "artifacts_cleaned": True},
                      {"schema": 2, "cleanup_confirmed": False, "artifacts_cleaned": True},
                      {"schema": 2, "cleanup_confirmed": False, "artifacts_cleaned": False},
                      {"schema": 2, "cleanup_confirmed": True, "artifacts_cleaned": True, "secret": "private"}, "x" * 129]
            for value in values:
                if value is not None:
                    receipt.write_text(json.dumps(value))
                with mock.patch.object(IMAGES.ax_process, "run_owned") as run, self.assertRaises(IMAGES.ImageWorkerCleanupError):
                    IMAGES.loaded_system_images(receipt)
                run.assert_not_called()
            receipt.unlink()
            receipt.symlink_to(Path(directory) / "absent")
            self.assertFalse(IMAGES.worker_cleanup_confirmed(receipt))


@unittest.skipUnless(sys.platform == "darwin", "dyld capability is macOS-only")
class AXSystemImageNativeTests(unittest.TestCase):
    def test_owned_worker_normal_failure_timeout_are_reaped(self):
        real_run, real_popen = IMAGES.ax_process.run_owned, subprocess.Popen
        leaders, receipts = [], []
        def spawn(command, **kwargs):
            child = real_popen(command, **kwargs)
            if "--supervise" in command:
                leaders.append(child)
            return child
        with tempfile.TemporaryDirectory(prefix="ax-images-native-", dir=IMAGES.WORKER_ROOT) as directory, \
                mock.patch.object(IMAGES, "WORKER_ROOT", Path(directory)), \
                mock.patch.object(IMAGES.ax_process.subprocess, "Popen", side_effect=spawn):
            cleanup = Path(directory) / "cleanup.json"
            IMAGES.write_worker_cleanup(cleanup, True)
            for mode in ("normal", "failure", "timeout"):
                def run(command, log, environment, timeout):
                    if mode != "normal":
                        command = [sys.executable, "-B", "-c", "import time;time.sleep(60)" if mode == "timeout" else "raise SystemExit(1)"]
                    result = real_run(command, log, environment, timeout=timeout)
                    receipts.append(result)
                    return result
                with mock.patch.object(IMAGES.ax_process, "run_owned", side_effect=run), \
                        mock.patch.object(IMAGES, "WORKER_SECONDS", 0.2 if mode == "timeout" else 10):
                    catalog = IMAGES.loaded_system_images(cleanup)
                if mode == "normal":
                    self.assertTrue(catalog and any(row["basename"] == "libsystem_pthread.dylib" for row in catalog.values()))
                else:
                    self.assertIsNone(catalog)
                self.assertEqual(IMAGES.worker_cleanup_state(cleanup), (True, True))
                self.assertEqual(list(Path(directory).iterdir()), [cleanup])
            self.assertEqual([row["status"] for row in receipts], ["completed", "completed", "timeout"])
            self.assertEqual([row["return_code"] for row in receipts], [0, 1, 124])
            self.assertTrue(all(row["cleanup"]["complete"] for row in receipts))
            self.assertEqual(len(leaders), 3)
            for child in leaders:
                self.assertIsNotNone(child.returncode)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child.pid, 0)


if __name__ == "__main__":
    unittest.main()
