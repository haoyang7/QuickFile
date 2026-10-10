"""A standalone SPI capability check, independent of AX measurements."""
import copy
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Scripts/tests/fixtures/SharedCacheCapability.c"
TEMPORARY_ROOT = ROOT / ".build/Temporary"
SPEC = importlib.util.spec_from_file_location("shared_cache_process", ROOT / "Scripts/Investigations/ax_process.py")
PROCESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROCESS)
OUTPUT_LIMIT = 16384
IMAGE_LIMIT = 16384
SAMPLE_LIMIT = 8
COUNTS = {
    "callbacks", "version_1", "version_2", "path_excluded", "membership_excluded",
    "duplicate_uuid_groups", "duplicate_rows", "duplicate_excluded_rows",
    "unique_system_uuid_count", "unique_system_loaded", "unique_system_not_loaded",
}
FAILURE_REASONS = {
    "loaded_inventory_invalid", "image_budget", "callback_schema", "active_uuid_changed",
    "loaded_inventory_changed", "enumeration_incomplete", "api_failed",
}


def invalid_output():
    # Never put child output or decoder exceptions into unittest's public log.
    raise ValueError("Invalid shared-cache capability output") from None


def integer(value, minimum, maximum):
    return type(value) is int and minimum <= value <= maximum


def identifier(value):
    return (type(value) is str and re.fullmatch(r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}", value)
            and value != "00000000-0000-0000-0000-000000000000")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            invalid_output()
        result[key] = value
    return result


def decode_output(raw, mode="probe"):
    if type(raw) is not bytes or not 0 < len(raw) <= OUTPUT_LIMIT:
        invalid_output()
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    except (ValueError, UnicodeError, RecursionError):
        invalid_output()
    if type(value) is not dict:
        invalid_output()
    expected = {
        "self-test": {"mode": "self-test", "tests": 9, "passed": True},
        "invalid-schema": {"mode": "invalid-schema", "reason": "callback_schema"},
        "timeout": {"mode": "timeout"},
    }
    if mode in expected:
        # Equality alone would accept true in place of integer 1.
        if (value != expected[mode] or any(type(value[k]) is not type(v) for k, v in expected[mode].items())):
            invalid_output()
        return value
    if mode != "probe":
        invalid_output()
    if value.get("status") == "unavailable":
        if (set(value) != {"status", "reason"}
                or value["reason"] not in ("spi_missing", "active_uuid_unavailable")):
            invalid_output()
        return value
    if value.get("status") == "failed":
        if (set(value) != {"status", "reason", "api_return_code", "callbacks"}
                or type(value["reason"]) is not str or value["reason"] not in FAILURE_REASONS
                or not integer(value["api_return_code"], -(2 ** 31), 2 ** 31 - 1)
                or not integer(value["callbacks"], 0, 2 ** 31 - 1)):
            invalid_output()
        return value
    keys = COUNTS | {"schema", "status", "active_cache_uuid", "active_uuid_unchanged",
                     "loaded_inventory_unchanged", "api_return_code", "image_budget",
                     "loaded_uuid_records", "loaded_samples", "not_loaded_samples"}
    if (set(value) != keys or not integer(value["schema"], 1, 1) or value["status"] != "complete"
            or not identifier(value["active_cache_uuid"]) or value["active_uuid_unchanged"] is not True
            or value["loaded_inventory_unchanged"] is not True
            or not integer(value["api_return_code"], 0, 0)
            or not integer(value["image_budget"], IMAGE_LIMIT, IMAGE_LIMIT)
            or not integer(value["loaded_uuid_records"], 1, 512)
            or any(not integer(value[k], 0, IMAGE_LIMIT) for k in COUNTS)):
        invalid_output()
    excluded = value["path_excluded"] + value["membership_excluded"]
    duplicates = value["duplicate_rows"]
    overlap = value["duplicate_excluded_rows"]
    if (not value["callbacks"] or value["version_1"] + value["version_2"] != value["callbacks"]
            or excluded > value["callbacks"] or duplicates > value["callbacks"]
            or (duplicates == 0) != (value["duplicate_uuid_groups"] == 0)
            or 2 * value["duplicate_uuid_groups"] > duplicates or overlap > min(duplicates, excluded)
            or value["unique_system_uuid_count"] + excluded + duplicates - overlap != value["callbacks"]
            or value["unique_system_loaded"] + value["unique_system_not_loaded"] != value["unique_system_uuid_count"]
            or value["unique_system_loaded"] > value["loaded_uuid_records"]):
        invalid_output()
    seen = set()
    for key, count_key in (("loaded_samples", "unique_system_loaded"), ("not_loaded_samples", "unique_system_not_loaded")):
        samples = value[key]
        if type(samples) is not list or len(samples) != min(SAMPLE_LIMIT, value[count_key]):
            invalid_output()
        for sample in samples:
            if (type(sample) is not dict or set(sample) != {"basename", "uuid"}
                    or type(sample["basename"]) is not str
                    or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.+\-]{0,95}", sample["basename"])
                    or not identifier(sample["uuid"]) or sample["uuid"] in seen):
                invalid_output()
            seen.add(sample["uuid"])
    return value


def read_output(path, mode):
    with path.open("rb") as stream:
        return decode_output(stream.read(OUTPUT_LIMIT + 1), mode)


def sample_output():
    return {
        "schema": 1, "status": "complete", "active_cache_uuid": "12345678-1234-1234-1234-123456789ABC",
        "active_uuid_unchanged": True, "loaded_inventory_unchanged": True, "api_return_code": 0,
        "callbacks": 7, "image_budget": IMAGE_LIMIT, "version_1": 0, "version_2": 7,
        "path_excluded": 2, "membership_excluded": 1, "duplicate_uuid_groups": 1,
        "duplicate_rows": 2, "duplicate_excluded_rows": 1, "unique_system_uuid_count": 3,
        "loaded_uuid_records": 3, "unique_system_loaded": 1, "unique_system_not_loaded": 2,
        "loaded_samples": [{"basename": "libSystem.B.dylib", "uuid": "11111111-1111-1111-1111-111111111111"}],
        "not_loaded_samples": [{"basename": "Foundation", "uuid": "22222222-2222-2222-2222-222222222222"},
                               {"basename": "AppKit", "uuid": "33333333-3333-3333-3333-333333333333"}],
    }


class SharedCacheOutputTests(unittest.TestCase):
    def test_counts_conserve_with_duplicate_filter_overlap_and_loaded_records(self):
        value = sample_output()
        self.assertEqual(decode_output(json.dumps(value).encode()), value)
        # Loaded callback records may include duplicate UUIDs and non-cache images.
        value["loaded_uuid_records"] = 5
        self.assertEqual(decode_output(json.dumps(value).encode()), value)
        for field in COUNTS:
            bad = copy.deepcopy(value)
            bad[field] = True
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "^Invalid shared-cache capability output$"):
                decode_output(json.dumps(bad).encode())

    def test_schema_conservation_and_sample_privacy_fail_closed(self):
        mutations = [lambda x: x.update(pid=1), lambda x: x.update(schema=True),
                     lambda x: x.update(active_uuid_unchanged=1), lambda x: x.update(version_2=6),
                     lambda x: x.update(duplicate_excluded_rows=0), lambda x: x.update(duplicate_uuid_groups=0),
                     lambda x: x.update(unique_system_not_loaded=3), lambda x: x.update(loaded_uuid_records=0),
                     lambda x: x.update(callbacks=IMAGE_LIMIT + 1), lambda x: x.update(active_cache_uuid="private"),
                     lambda x: x["not_loaded_samples"].pop(),
                     lambda x: x["not_loaded_samples"][0].update(uuid=x["loaded_samples"][0]["uuid"]),
                     lambda x: x["not_loaded_samples"][0].update(path="/private/secret"),
                     lambda x: x["loaded_samples"][0].update(basename="/private/secret"),
                     lambda x: x["loaded_samples"][0].update(basename="é"),
                     lambda x: x["loaded_samples"][0].update(basename="x\nsecret"),
                     lambda x: x["loaded_samples"][0].update(basename="x" * 97),
                     lambda x: x["loaded_samples"][0].update(uuid="00000000-0000-0000-0000-000000000000")]
        for index, mutate in enumerate(mutations):
            value = sample_output(); mutate(value)
            with self.subTest(case=index), self.assertRaisesRegex(ValueError, "^Invalid shared-cache capability output$"):
                decode_output(json.dumps(value).encode())
        for raw in (b"", b"[]", b"{", b"\xff", b'{"status":"complete","status":"failed"}',
                    json.dumps(sample_output()).encode() + b"\nprivate", b" " * (OUTPUT_LIMIT + 1)):
            with self.assertRaisesRegex(ValueError, "^Invalid shared-cache capability output$"):
                decode_output(raw)

    def test_fixed_failures_remain_failures_and_modes_do_not_mix(self):
        for reason in ("spi_missing", "active_uuid_unavailable"):
            value = {"status": "unavailable", "reason": reason}
            self.assertEqual(decode_output(json.dumps(value).encode()), value)
        for reason in FAILURE_REASONS:
            value = {"status": "failed", "reason": reason, "callbacks": 3, "api_return_code": -1}
            self.assertEqual(decode_output(json.dumps(value).encode()), value)
        for value in ({"status": "failed", "reason": "private", "callbacks": 3, "api_return_code": -1},
                      {"status": "unavailable", "reason": "spi_missing", "path": "private"}):
            with self.assertRaises(ValueError):
                decode_output(json.dumps(value).encode())
        for mode, value in (("self-test", {"mode": "self-test", "tests": 9, "passed": True}),
                            ("invalid-schema", {"mode": "invalid-schema", "reason": "callback_schema"}),
                            ("timeout", {"mode": "timeout"})):
            self.assertEqual(decode_output(json.dumps(value).encode(), mode), value)
            with self.assertRaises(ValueError):
                decode_output(json.dumps(value).encode())

    def test_native_failure_receipt_never_prints_unvalidated_child_output(self):
        TEMPORARY_ROOT.mkdir(parents=True, exist_ok=True)
        for failure in ("private-output", "unavailable", "compile", "cleanup"):
            with self.subTest(case=failure), tempfile.TemporaryDirectory(dir=TEMPORARY_ROOT) as directory:
                output = io.StringIO()
                calls = []
                def run(command, log_path, environment, timeout):
                    stage = log_path.stem
                    calls.append(stage)
                    code = 1 if failure == "compile" or stage == "probe" else 0
                    if stage == "compile" and failure != "compile":
                        Path(command[-1]).write_bytes(b"synthetic binary")
                    raw = (b'{"status":"unavailable","reason":"spi_missing"}' if failure == "unavailable"
                           else b"PRIVATE_CHILD_OUTPUT /private/secret pid=123")
                    log_path.write_bytes(raw)
                    return {"return_code": code, "command_return_code": code, "status": "completed",
                            "cleanup": {"group_signal": "sent", "group_members_exited": failure != "cleanup",
                                        "group_inspection": "running" if failure == "cleanup" else "exited",
                                        "leader_reaped": True, "complete": failure != "cleanup"}}
                with mock.patch(__name__ + ".TEMPORARY_ROOT", Path(directory)), \
                        mock.patch.object(PROCESS, "run_owned", side_effect=run), \
                        mock.patch.object(platform, "mac_ver", return_value=("15.0", (), "")), \
                        mock.patch.object(platform, "machine", return_value="arm64"), redirect_stdout(output), \
                        self.assertRaises(AssertionError):
                    SharedCacheNativeTests().test_native_capability_and_bounded_failure_cleanup()
                public = output.getvalue()
                self.assertNotIn("PRIVATE_CHILD_OUTPUT", public)
                self.assertNotIn("/private/secret", public)
                self.assertNotIn("pid=", public)
                receipt = json.loads(public.removeprefix("shared-cache-capability "))
                self.assertEqual(receipt["status"], "failed")
                self.assertEqual(receipt["cleanup_complete"], failure != "cleanup")
                self.assertEqual(calls, ["compile"] if failure in ("compile", "cleanup") else ["compile", "probe"])
                if failure == "unavailable":
                    self.assertEqual(receipt["capability"], {"status": "unavailable", "reason": "spi_missing"})
                else:
                    self.assertIsNone(receipt["capability"])


@unittest.skipUnless(sys.platform == "darwin", "Native shared-cache SPI capability requires macOS")
class SharedCacheNativeTests(unittest.TestCase):
    def test_native_capability_and_bounded_failure_cleanup(self):
        TEMPORARY_ROOT.mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix="shared-cache-capability-", dir=TEMPORARY_ROOT)).resolve()
        build, records = work / "build", work / "records"
        build.mkdir(); records.mkdir()
        binary = build / "SharedCacheCapability"
        environment = dict(os.environ, TMPDIR=str(build), CLANG_MODULE_CACHE_PATH=str(build / "cache"),
                           PYTHONDONTWRITEBYTECODE="1")
        receipt = {"schema": 1, "status": "failed", "failure_stage": "identity", "runs": {},
                   "capability": None, "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
                   "binary_sha256": None, "cleanup_complete": False}
        groups_exited = True
        stage = "identity"
        failed = False
        try:
            version, architecture = platform.mac_ver()[0], platform.machine()
            if not re.fullmatch(r"[0-9]{1,3}(?:\.[0-9]{1,3}){1,2}", version) or architecture not in ("arm64", "x86_64"):
                raise ValueError("Unsupported platform identity")
            receipt.update(os_version=version, architecture=architecture)
            commands = [("compile", ["xcrun", "clang", "-std=c11", "-fblocks", "-O1", "-g0", "-Wall", "-Wextra",
                                      "-Werror", "-fmodules-cache-path=" + str(build / "cache"), str(SOURCE), "-o", str(binary)], 60, 0),
                        ("probe", [str(binary), "--probe"], 20, 0),
                        ("self-test", [str(binary), "--self-test"], 10, 0),
                        ("invalid-schema", [str(binary), "--invalid-schema"], 10, 1),
                        ("timeout", [str(binary), "--timeout"], 2, 124)]
            for stage, command, timeout, expected_code in commands:
                groups_exited = False
                result = PROCESS.run_owned(command, records / (stage + ".log"), environment, timeout=timeout)
                groups_exited = result["cleanup"]["complete"] is True
                receipt["runs"][stage] = result
                if not groups_exited:
                    raise ValueError("Owned group exit unconfirmed")
                if stage != "compile":
                    output = read_output(records / (stage + ".log"), stage)
                    if stage == "probe":
                        receipt["capability"] = output
                        if (output["status"] != "complete" or not output["unique_system_loaded"]
                                or not output["unique_system_not_loaded"]):
                            raise ValueError("Capability not established")
                if (result["return_code"] != expected_code
                        or result["status"] != ("timeout" if stage == "timeout" else "completed")):
                    raise ValueError("Unexpected owned command result")
                if stage == "compile":
                    receipt["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
            receipt.update(status="complete", failure_stage=None)
        except Exception:
            failed = True
            receipt["failure_stage"] = stage
        finally:
            # A failed exit check aborts later commands and retains owned artifacts.
            # Do not signal a historical PID or claim cleanup after an unconfirmed group.
            try:
                if groups_exited:
                    shutil.rmtree(build)
                    receipt["cleanup_complete"] = (not build.exists() and not list(work.rglob("*.app")))
                if receipt["status"] == "complete":
                    for log in records.glob("*.log"):
                        log.unlink()
            except OSError:
                receipt["cleanup_complete"] = False
            if not receipt["cleanup_complete"]:
                failed = True
                receipt.update(status="failed", failure_stage=receipt["failure_stage"] or "cleanup")
            encoded = json.dumps(receipt, sort_keys=True)
            (records / "receipt.json").write_text(encoded + "\n")
            print("shared-cache-capability " + encoded, flush=True)
        if failed:
            self.fail("Shared-cache capability failed at " + receipt["failure_stage"])


if __name__ == "__main__":
    unittest.main()
