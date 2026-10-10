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
    "path_excluded", "membership_excluded",
    "duplicate_uuid_groups", "duplicate_rows", "duplicate_excluded_rows",
    "unique_system_uuid_count", "unique_system_loaded", "unique_system_not_loaded",
}
PHASES = ("observer_registration", "setup", "census", "enumeration", "formatting")
PASS_ERRORS = ("not-run", "none", "callback_schema", "image_budget", "enumeration_incomplete")
SELF_TESTS = 33


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


def validate_traversal(value):
    keys = {"calls", "api_return_code", "callbacks", "records", "version_1", "version_2",
            "schema_error", "active_uuid_unchanged"}
    if (type(value) is not dict or set(value) != keys or not integer(value["calls"], 0, 1)
            or not integer(value["callbacks"], 0, IMAGE_LIMIT + 1)
            or any(not integer(value[k], 0, IMAGE_LIMIT) for k in ("records", "version_1", "version_2"))
            or value["version_1"] + value["version_2"] != value["records"]
            or type(value["active_uuid_unchanged"]) is not bool or value["schema_error"] not in PASS_ERRORS):
        invalid_output()
    if not value["calls"]:
        if (value["api_return_code"] is not None or value["schema_error"] != "not-run"
                or value["callbacks"] or value["records"] or value["active_uuid_unchanged"]):
            invalid_output()
        return False
    if not integer(value["api_return_code"], -(2 ** 31), 2 ** 31 - 1):
        invalid_output()
    error, calls, records = value["schema_error"], value["callbacks"], value["records"]
    if (error == "not-run" or error == "none" and not 0 < calls == records <= IMAGE_LIMIT
            or error == "callback_schema" and not records < calls
            or error == "image_budget" and (records != IMAGE_LIMIT or calls != IMAGE_LIMIT + 1)
            or error == "enumeration_incomplete" and (calls or records)):
        invalid_output()
    return error == "none" and value["api_return_code"] == 0 and value["active_uuid_unchanged"]


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
        "self-test": {"mode": "self-test", "tests": SELF_TESTS, "passed": True},
        "invalid-schema": {"mode": "invalid-schema", "reason": "callback_schema"},
        "timeout": {"mode": "timeout"},
    }
    if mode in expected:
        if value != expected[mode] or any(type(value[k]) is not type(v) for k, v in expected[mode].items()):
            invalid_output()
        return value
    if mode != "probe":
        invalid_output()
    if value.get("status") == "unavailable":
        if (set(value) != {"status", "reason"}
                or value["reason"] not in ("spi_missing", "active_uuid_unavailable")):
            invalid_output()
        return value
    keys = {"schema", "status", "active_cache_uuid", "image_budget", "setup", "measurement",
            "loaded_uuid_records", "loaded_inventory_valid", "loaded_inventory_unchanged", "format_complete",
            "final_active_uuid_unchanged", "measurement_closed", "event_overflow", "events", "result"}
    if (set(value) != keys or not integer(value["schema"], 2, 2) or value["status"] not in ("complete", "failed")
            or not identifier(value["active_cache_uuid"]) or not integer(value["image_budget"], IMAGE_LIMIT, IMAGE_LIMIT)
            or not integer(value["loaded_uuid_records"], 0, 512) or value["measurement_closed"] is not True
            or any(type(value[k]) is not bool for k in ("format_complete", "final_active_uuid_unchanged", "event_overflow"))
            or any(value[k] is not None and type(value[k]) is not bool
                   for k in ("loaded_inventory_valid", "loaded_inventory_unchanged"))):
        invalid_output()
    setup_ok = validate_traversal(value["setup"])
    measured_ok = value["measurement"] is not None and validate_traversal(value["measurement"])
    events = value["events"]
    if type(events) is not dict or set(events) != set(PHASES):
        invalid_output()
    for event in events.values():
        if (type(event) is not dict or set(event) != {"add", "remove"}
                or any(not integer(count, 0, IMAGE_LIMIT) for count in event.values())):
            invalid_output()
    if value["event_overflow"] and not any(IMAGE_LIMIT in e.values() for e in events.values()):
        invalid_output()
    changed = any(any(events[phase].values()) for phase in PHASES[2:])
    census = value["loaded_inventory_valid"]
    if census is None:
        if (value["loaded_inventory_unchanged"] is not None or value["loaded_uuid_records"]
                or value["measurement"] is not None or any(events[phase][key] for phase in ("census", "enumeration") for key in ("add", "remove"))
                or setup_ok and not value["event_overflow"]):
            invalid_output()
    elif (not setup_ok or value["loaded_inventory_unchanged"] is not (not changed)
          or census and not value["loaded_uuid_records"]):
        invalid_output()
    if value["measurement"] is not None and (census is not True or any(events["census"].values())):
        invalid_output()
    if value["measurement"] is None and any(events["enumeration"].values()):
        invalid_output()
    if (value["measurement"] is None and census is True and not any(events["census"].values())
            and not value["event_overflow"]):
        invalid_output()
    complete = (setup_ok and measured_ok and census is True and not changed and not value["event_overflow"]
                and value["format_complete"] and value["final_active_uuid_unchanged"])
    if (value["status"] == "complete") != complete:
        invalid_output()
    result = value["result"]
    if not complete:
        if result is not None:
            invalid_output()
        return value
    if (type(result) is not dict or set(result) != COUNTS | {"loaded_samples", "not_loaded_samples"}
            or any(not integer(result[k], 0, IMAGE_LIMIT) for k in COUNTS)):
        invalid_output()
    excluded = result["path_excluded"] + result["membership_excluded"]
    duplicates = result["duplicate_rows"]
    overlap = result["duplicate_excluded_rows"]
    callbacks = value["measurement"]["callbacks"]
    if (excluded > callbacks or duplicates > callbacks
            or (duplicates == 0) != (result["duplicate_uuid_groups"] == 0)
            or 2 * result["duplicate_uuid_groups"] > duplicates or overlap > min(duplicates, excluded)
            or result["unique_system_uuid_count"] + excluded + duplicates - overlap != callbacks
            or result["unique_system_loaded"] + result["unique_system_not_loaded"] != result["unique_system_uuid_count"]
            or result["unique_system_loaded"] > value["loaded_uuid_records"]):
        invalid_output()
    seen = set()
    for key, count_key in (("loaded_samples", "unique_system_loaded"), ("not_loaded_samples", "unique_system_not_loaded")):
        samples = result[key]
        if type(samples) is not list or len(samples) != min(SAMPLE_LIMIT, result[count_key]):
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


def sample_traversal():
    return {"calls": 1, "api_return_code": 0, "callbacks": 7, "records": 7, "version_1": 0,
            "version_2": 7, "schema_error": "none", "active_uuid_unchanged": True}


def sample_output():
    return {
        "schema": 2, "status": "complete", "active_cache_uuid": "12345678-1234-1234-1234-123456789ABC",
        "image_budget": IMAGE_LIMIT, "setup": sample_traversal(), "measurement": sample_traversal(),
        "loaded_uuid_records": 3, "loaded_inventory_valid": True, "loaded_inventory_unchanged": True,
        "format_complete": True, "final_active_uuid_unchanged": True, "measurement_closed": True,
        "event_overflow": False, "events": {phase: {"add": 3 if phase == "observer_registration" else 0, "remove": 0} for phase in PHASES},
        "result": {"path_excluded": 2, "membership_excluded": 1, "duplicate_uuid_groups": 1,
            "duplicate_rows": 2, "duplicate_excluded_rows": 1, "unique_system_uuid_count": 3,
            "unique_system_loaded": 1, "unique_system_not_loaded": 2,
            "loaded_samples": [{"basename": "libSystem.B.dylib", "uuid": "11111111-1111-1111-1111-111111111111"}],
            "not_loaded_samples": [{"basename": "Foundation", "uuid": "22222222-2222-2222-2222-222222222222"},
                                   {"basename": "AppKit", "uuid": "33333333-3333-3333-3333-333333333333"}]},
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
            bad["result"][field] = True
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "^Invalid shared-cache capability output$"):
                decode_output(json.dumps(bad).encode())

    def test_schema_conservation_and_sample_privacy_fail_closed(self):
        mutations = [lambda x: x.update(pid=1), lambda x: x.update(schema=True),
                     lambda x: x["setup"].update(active_uuid_unchanged=1), lambda x: x["measurement"].update(version_2=6),
                     lambda x: x["result"].update(duplicate_excluded_rows=0), lambda x: x["result"].update(duplicate_uuid_groups=0),
                     lambda x: x["result"].update(unique_system_not_loaded=3), lambda x: x.update(loaded_uuid_records=0),
                     lambda x: x["measurement"].update(callbacks=IMAGE_LIMIT + 1), lambda x: x.update(active_cache_uuid="private"),
                     lambda x: x["result"]["not_loaded_samples"].pop(),
                     lambda x: x["result"]["not_loaded_samples"][0].update(uuid=x["result"]["loaded_samples"][0]["uuid"]),
                     lambda x: x["result"]["not_loaded_samples"][0].update(path="/private/secret"),
                     lambda x: x["result"]["loaded_samples"][0].update(basename="/private/secret"),
                     lambda x: x["result"]["loaded_samples"][0].update(basename="é"),
                     lambda x: x["result"]["loaded_samples"][0].update(basename="x\nsecret"),
                     lambda x: x["result"]["loaded_samples"][0].update(basename="x" * 97),
                     lambda x: x["result"]["loaded_samples"][0].update(uuid="00000000-0000-0000-0000-000000000000")]
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
        value = sample_output()
        value.update(status="failed", result=None, loaded_inventory_unchanged=False)
        value["measurement"].update(api_return_code=-1, active_uuid_unchanged=False, schema_error="callback_schema", records=0, version_2=0)
        value["events"]["enumeration"].update(add=1, remove=1)
        self.assertEqual(decode_output(json.dumps(value).encode()), value)
        bad = copy.deepcopy(value); bad["measurement"]["schema_error"] = "private"
        with self.assertRaises(ValueError):
            decode_output(json.dumps(bad).encode())
        for mode, value in (("self-test", {"mode": "self-test", "tests": SELF_TESTS, "passed": True}),
                            ("invalid-schema", {"mode": "invalid-schema", "reason": "callback_schema"}),
                            ("timeout", {"mode": "timeout"})):
            self.assertEqual(decode_output(json.dumps(value).encode(), mode), value)
            with self.assertRaises(ValueError):
                decode_output(json.dumps(value).encode())

    def test_setup_and_closed_measurement_are_distinct_and_failures_cannot_continue(self):
        value = sample_output()
        value["events"]["setup"] = {"add": 2, "remove": 1}
        self.assertEqual(decode_output(json.dumps(value).encode()), value)
        for phase in ("census", "enumeration", "formatting"):
            for direction in ("add", "remove"):
                changed = copy.deepcopy(value)
                changed["events"][phase][direction] = 1
                with self.subTest(phase=phase, direction=direction), self.assertRaises(ValueError):
                    decode_output(json.dumps(changed).encode())
                changed.update(status="failed", result=None, loaded_inventory_unchanged=False)
                if phase == "census":
                    changed["measurement"] = None
                self.assertEqual(decode_output(json.dumps(changed).encode()), changed)
        for key, setting in (("api_return_code", -1), ("active_uuid_unchanged", False)):
            stopped = copy.deepcopy(value)
            stopped["setup"][key] = setting
            stopped.update(status="failed", result=None, measurement=None, loaded_uuid_records=0,
                           loaded_inventory_valid=None, loaded_inventory_unchanged=None)
            self.assertEqual(decode_output(json.dumps(stopped).encode()), stopped)
            stopped["measurement"] = sample_traversal()
            with self.assertRaises(ValueError):
                decode_output(json.dumps(stopped).encode())
        for mutate in (lambda x: x.update(measurement_closed=False),
                       lambda x: x["events"]["setup"].update(add=True),
                       lambda x: x["events"]["setup"].update(add=IMAGE_LIMIT + 1),
                       lambda x: x["events"].update(private={"add": 0, "remove": 0}),
                       lambda x: x["setup"].update(calls=2),
                       lambda x: x["measurement"].update(api_return_code=True),
                       lambda x: x.update(final_active_uuid_unchanged=False)):
            bad = copy.deepcopy(value); mutate(bad)
            with self.assertRaisesRegex(ValueError, "^Invalid shared-cache capability output$"):
                decode_output(json.dumps(bad).encode())
        bad = copy.deepcopy(value)
        bad.update(status="failed", result=None, measurement=None)
        with self.assertRaises(ValueError):
            decode_output(json.dumps(bad).encode())
        not_run = {"calls": 0, "api_return_code": None, "callbacks": 0, "records": 0,
                   "version_1": 0, "version_2": 0, "schema_error": "not-run", "active_uuid_unchanged": False}
        for stage in ("setup", "measurement"):
            stopped = copy.deepcopy(value)
            stopped.update(status="failed", result=None)
            stopped[stage] = not_run
            if stage == "setup":
                stopped.update(measurement=None, loaded_uuid_records=0,
                               loaded_inventory_valid=None, loaded_inventory_unchanged=None)
            self.assertEqual(decode_output(json.dumps(stopped).encode()), stopped)

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
                    if stage == "self-test":
                        raw = json.dumps({"mode": "self-test", "tests": SELF_TESTS, "passed": True}).encode()
                    if stage in ("census-race-add", "census-race-remove"):
                        packet = sample_output()
                        packet.update(status="failed", result=None, measurement=None, loaded_inventory_unchanged=False)
                        packet["events"]["census"][stage.removeprefix("census-race-")] = 1
                        raw, code = json.dumps(packet).encode(), 1
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
                self.assertEqual(calls, ["compile"] if failure in ("compile", "cleanup") else
                                 ["compile", "self-test", "census-race-add", "census-race-remove", "probe"])
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
                   "capability": None, "census_transition_checks": {},
                   "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
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
                        ("self-test", [str(binary), "--self-test"], 10, 0),
                        ("census-race-add", [str(binary), "--census-race-add"], 10, 1),
                        ("census-race-remove", [str(binary), "--census-race-remove"], 10, 1),
                        ("probe", [str(binary), "--probe"], 20, 0),
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
                    census_case = stage in ("census-race-add", "census-race-remove")
                    output = read_output(records / (stage + ".log"), "probe" if census_case else stage)
                    if census_case:
                        direction = stage.removeprefix("census-race-")
                        receipt["census_transition_checks"][direction] = output
                        if (output["status"] != "failed" or not validate_traversal(output["setup"])
                                or output["measurement"] is not None or output["loaded_inventory_valid"] is not True
                                or output["loaded_inventory_unchanged"] is not False
                                or output["events"]["census"] != {"add": int(direction == "add"), "remove": int(direction == "remove")}
                                or any(output["events"]["enumeration"].values())):
                            raise ValueError("Census transition regression")
                    if stage == "probe":
                        receipt["capability"] = output
                        if (output["status"] != "complete" or not output["result"]["unique_system_loaded"]
                                or not output["result"]["unique_system_not_loaded"]):
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
