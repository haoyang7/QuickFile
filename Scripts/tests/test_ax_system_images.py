import ctypes
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "Investigations/ax_system_images.py"
SPEC = importlib.util.spec_from_file_location("ax_system_images_tested", SOURCE)
IMAGES = importlib.util.module_from_spec(SPEC)
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
        with mock.patch.object(IMAGES, "_loaded_images", side_effect=loaded), mock.patch.object(IMAGES.os, "write", side_effect=write), \
                mock.patch.object(IMAGES.os, "_exit", side_effect=raw_exit), self.assertRaises(RawExit):
            IMAGES._worker_entry()
        self.assertEqual(json.loads(b"".join(chunks)), result)
        for failure in (OSError("private error"), 0):
            with mock.patch.object(IMAGES, "_loaded_images", side_effect=loaded), \
                    mock.patch.object(IMAGES.os, "write", side_effect=failure if isinstance(failure, Exception) else None, return_value=0), \
                    mock.patch.object(IMAGES.os, "_exit", side_effect=RawExit) as leave, self.assertRaises(RawExit):
                IMAGES._worker_entry()
            leave.assert_called_once_with(1)

    def test_worker_protocol_rejects_partial_duplicate_and_private_output(self):
        image = {"basename": "Foo", "uuid": IDENTIFIER}
        good = json.dumps({"schema": 1, "images": [image]}).encode()
        results = [(1, good, b""), (0, good, b"secret"), (0, good[:-1], b""),
                   (0, json.dumps({"schema": 1, "images": [image, image]}).encode(), b""),
                   (0, json.dumps({"schema": True, "images": [image]}).encode(), b""),
                   (0, json.dumps({"schema": 1, "images": [{**image, "path": "secret"}]}).encode(), b"")]
        for code, output, errors in results:
            with mock.patch.object(IMAGES.subprocess, "run", return_value=subprocess.CompletedProcess([], code, output, errors)):
                self.assertIsNone(IMAGES.loaded_system_images())
        with mock.patch.object(IMAGES.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, good, b"")):
            self.assertEqual(IMAGES.loaded_system_images(), {IDENTIFIER: image})
            with mock.patch.object(IMAGES, "CATALOG_BYTE_LIMIT", 1):
                self.assertIsNone(IMAGES.loaded_system_images())
        with mock.patch.object(IMAGES.subprocess, "Popen", side_effect=OSError("private spawn error")):
            self.assertIsNone(IMAGES.loaded_system_images())


@unittest.skipUnless(sys.platform == "darwin", "dyld capability is macOS-only")
class AXSystemImageNativeTests(unittest.TestCase):
    def test_owned_worker_normal_failure_timeout_are_reaped(self):
        real_run, real_popen = subprocess.run, subprocess.Popen
        children = []
        def spawn(*args, **kwargs):
            child = real_popen(*args, **kwargs); children.append(child); return child
        catalogs = []
        with mock.patch.object(IMAGES.subprocess, "Popen", side_effect=spawn):
            for _ in range(2):
                catalogs.append(IMAGES.loaded_system_images())
        self.assertTrue(all(catalog and any(row["basename"] == "libsystem_pthread.dylib" for row in catalog.values()) for catalog in catalogs))
        self.assertEqual(catalogs[0], catalogs[1])
        for mode in ("failure", "timeout"):
            def run(command, **kwargs):
                code = ("import time;time.sleep(60)" if mode == "timeout" else
                        "import runpy;d=runpy.run_path(" + repr(str(SOURCE)) + ");"
                        "d['_worker_entry'].__globals__['_loaded_images']=lambda _:(_ for _ in ()).throw(ValueError('secret'));d['_worker_entry']()")
                return real_run([sys.executable, "-B", "-c", code], **kwargs)
            with mock.patch.object(IMAGES.subprocess, "run", side_effect=run), \
                    mock.patch.object(IMAGES.subprocess, "Popen", side_effect=spawn), \
                    mock.patch.object(IMAGES, "WORKER_SECONDS", 0.2 if mode == "timeout" else 10):
                self.assertIsNone(IMAGES.loaded_system_images())
        self.assertEqual([child.returncode for child in children], [0, 0, 1, -9])
        for child in children:
            with self.assertRaises(ProcessLookupError):
                os.kill(child.pid, 0)


if __name__ == "__main__":
    unittest.main()
