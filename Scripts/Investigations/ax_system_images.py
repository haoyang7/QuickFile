"""Offline, image-only identity evidence for terminal root frames.

The dyld callbacks have no unregister API. They exist only in a short-lived
owned worker, remain strongly referenced, and never survive Python teardown:
every worker path uses os._exit. No report path or target address is loaded or
dereferenced. Each public gate obtains a fresh worker catalog.
"""
import ctypes
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import sys
import tempfile
import uuid
import ax_process

IMAGE_LIMIT = 2048
COMMAND_LIMIT = 65536
CATALOG_BYTE_LIMIT = 262144
WORKER_SECONDS = 10
WORKER_ROOT = Path(__file__).resolve().parents[2] / ".build/Temporary"
CACHE_SOURCE = Path(__file__).resolve().parents[2] / "Scripts/tests/fixtures/SharedCacheCapability.c"
CACHE_REQUEST_LIMIT = 96
CACHE_OUTPUT_LIMIT = 24576
CACHE_REASONS = ("verified", "uuid_missing", "uuid_duplicate", "image_excluded")
_cleanup_unconfirmed = False
UUID = r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}"
BASENAME = r"[A-Za-z0-9_][A-Za-z0-9_.+-]{0,95}"
IMAGE_LINE = re.compile(r"\s*(0x[0-9a-fA-F]{1,16}) -\s*(0x[0-9a-fA-F]{1,16})\s+\+?\S+ "
                        r"\([^\n()]*\) <([0-9A-Fa-f-]{36})> /[^\n]+")
REASONS = ("report_images_invalid", "report_range_missing", "report_uuid_ambiguous", "local_catalog_unavailable",
           "uuid_not_verified", "budget_omitted")


def safe_identity(value):
    return (type(value) is dict and set(value) == {"basename", "uuid"}
            and type(value["basename"]) is str and re.fullmatch(BASENAME, value["basename"]) is not None
            and type(value["uuid"]) is str and re.fullmatch(UUID, value["uuid"]) is not None
            and value["uuid"] != "00000000-0000-0000-0000-000000000000")


def system_basename(path):
    """Lexical OS path check; shared-cache paths need not exist on disk."""
    if (type(path) is not str or len(path) > 1024
            or not path.startswith(("/System/Library/", "/usr/lib/"))):
        return None
    parts = path[1:].split("/")
    if any(part in ("", ".", "..") or re.fullmatch(BASENAME, part) is None for part in parts):
        return None
    return parts[-1]


def image_uuid(header, commands):
    """Parse only a bounded 64-bit, shared-cache dylib's LC_UUID."""
    if len(header) != 32:
        raise ValueError("Invalid image header")
    magic, _, _, kind, count, size, flags, _ = struct.unpack("<8I", header)
    if (magic != 0xfeedfacf or kind != 6 or not flags & 0x80000000
            or not 1 <= count <= COMMAND_LIMIT // 8 or not 8 <= size <= COMMAND_LIMIT
            or len(commands) != size or count * 8 > size):
        raise ValueError("Invalid image commands")
    position, identifiers = 0, []
    for _ in range(count):
        if position + 8 > size:
            raise ValueError("Truncated image command")
        command, length = struct.unpack_from("<II", commands, position)
        if length < 8 or length % 8 or position + length > size:
            raise ValueError("Invalid image command size")
        if command == 0x1b:
            if length != 24:
                raise ValueError("Invalid image UUID command")
            identifiers.append(str(uuid.UUID(bytes=commands[position + 8:position + 24])).upper())
        position += length
    if position != size or len(identifiers) != 1 or identifiers[0] == str(uuid.UUID(int=0)).upper():
        raise ValueError("Ambiguous image UUID")
    return identifiers[0]


def report_images(report):
    """Private target ranges only; report names and paths never leave here."""
    sections = report.split("\nBinary Images:")
    if len(sections) != 2:
        raise ValueError("Missing image table")
    lines = [line for line in sections[1].splitlines() if line.strip()]
    if not 1 <= len(lines) <= IMAGE_LIMIT:
        raise ValueError("Invalid image table size")
    ranges, identifiers, ambiguous = [], set(), set()
    for line in lines:
        match = IMAGE_LINE.fullmatch(line)
        if not match:
            raise ValueError("Invalid image table row")
        start, end = int(match[1], 16), int(match[2], 16)
        identifier = match[3].upper()
        if (not 0 < start <= end < 2**64 or re.fullmatch(UUID, identifier) is None
                or identifier == str(uuid.UUID(int=0)).upper()):
            raise ValueError("Ambiguous image table row")
        if identifier in identifiers:
            ambiguous.add(identifier)
        identifiers.add(identifier)
        ranges.append((start, end, identifier))
    ranges.sort()
    if any(left[1] >= right[0] for left, right in zip(ranges, ranges[1:])):
        raise ValueError("Overlapping image ranges")
    return [(start, end, None if identifier in ambiguous else identifier) for start, end, identifier in ranges]


class DlInfo(ctypes.Structure):
    _fields_ = [("path", ctypes.c_char_p), ("base", ctypes.c_void_p),
                ("symbol", ctypes.c_char_p), ("address", ctypes.c_void_p)]


def _loaded_images(callbacks):
    # Fixed dependency only, loaded before callbacks. Never use a report path.
    appkit = ctypes.CDLL("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit")
    library = ctypes.CDLL(None)
    library.dladdr.argtypes = [ctypes.c_void_p, ctypes.POINTER(DlInfo)]
    library.dladdr.restype = ctypes.c_int
    library._dyld_shared_cache_contains_path.argtypes = [ctypes.c_char_p]
    library._dyld_shared_cache_contains_path.restype = ctypes.c_bool
    callback_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_ssize_t)
    for name in ("_dyld_register_func_for_add_image", "_dyld_register_func_for_remove_image"):
        function = getattr(library, name)
        function.argtypes, function.restype = [callback_type], None
    entries, seen, ambiguous = {}, set(), set()
    state = {"failed": False, "closed": False}

    def added(address, slide):
        try:
            if state["closed"] or address in seen or len(seen) >= IMAGE_LIMIT:
                raise ValueError("Changed or excessive image inventory")
            seen.add(address)
            info = DlInfo()
            if not library.dladdr(address, ctypes.byref(info)) or info.base != address or not info.path:
                raise ValueError("Unavailable loaded image")
            path = info.path.decode("ascii")
            basename = system_basename(path)
            if basename is None or not library._dyld_shared_cache_contains_path(info.path):
                return
            # Only dyld-supplied, currently mapped, OS-cache headers are read.
            # Both the native read and each individual command are bounded.
            header = ctypes.string_at(address, 32)
            fields = struct.unpack("<8I", header)
            if fields[0] != 0xfeedfacf or fields[3] != 6 or not fields[6] & 0x80000000:
                return
            if not 8 <= fields[5] <= COMMAND_LIMIT:
                raise ValueError("Excessive image commands")
            identifier = image_uuid(header, ctypes.string_at(address + 32, fields[5]))
            if identifier in entries or identifier in ambiguous:
                ambiguous.add(identifier)
                entries.pop(identifier, None)
            else:
                entries[identifier] = {"basename": basename, "uuid": identifier}
        except BaseException:
            # Exceptions must not be swallowed by ctypes callback dispatch.
            state["failed"] = True

    def removed(address, slide):
        state["failed"] = True

    callbacks.extend((callback_type(added), callback_type(removed)))
    library._dyld_register_func_for_remove_image(callbacks[1])
    library._dyld_register_func_for_add_image(callbacks[0])
    state["closed"] = True
    if state["failed"] or not entries:
        raise ValueError("Unstable image inventory")
    result = {"schema": 1, "images": sorted(entries.values(), key=lambda item: item["uuid"])}
    # Keep all callback dependencies alive through the final write and _exit.
    return result, (appkit, library, state)


def _worker_entry(output):
    callbacks, keepalive = [], None
    code, descriptor = 1, None
    try:
        result, keepalive = _loaded_images(callbacks)
        payload = json.dumps(result, separators=(",", ":")).encode() + b"\n"
        if len(payload) > CATALOG_BYTE_LIMIT or keepalive[2]["failed"]:
            raise ValueError("Invalid image inventory")
        descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        while payload:
            written = os.write(descriptor, payload)
            if written <= 0:
                raise OSError("Incomplete inventory write")
            payload = payload[written:]
        code = 0 if not keepalive[2]["failed"] else 1
    except BaseException:
        pass
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                code = 1
        if keepalive is not None and keepalive[2]["failed"]:
            code = 1
        # No Python finalization can dispose a still-registered CFUNCTYPE.
        os._exit(code)


class ImageWorkerCleanupError(RuntimeError):
    def __init__(self):
        super().__init__("Image worker exit unconfirmed")


class ImageWorkerArtifactError(RuntimeError):
    def __init__(self):
        super().__init__("Image worker artifact handling failed")


def write_worker_cleanup(path, confirmed, artifacts_cleaned=None):
    if artifacts_cleaned is None:
        artifacts_cleaned = confirmed
    try:
        path.write_text(json.dumps({"schema": 2, "cleanup_confirmed": confirmed,
                                    "artifacts_cleaned": artifacts_cleaned}) + "\n")
    except OSError as error:
        raise ImageWorkerArtifactError() from error


def worker_cleanup_state(path):
    if _cleanup_unconfirmed:
        return False, False
    if path is None:
        return True, True
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 128:
            return False, False
        with path.open("rb") as stream:
            payload = stream.read(129)
        if len(payload) > 128:
            return False, False
        value = json.loads(payload)
        if (type(value) is dict and set(value) == {"schema", "cleanup_confirmed", "artifacts_cleaned"}
                and type(value["schema"]) is int and value["schema"] == 2
                and type(value["cleanup_confirmed"]) is bool and type(value["artifacts_cleaned"]) is bool
                and (not value["artifacts_cleaned"] or value["cleanup_confirmed"])):
            return value["cleanup_confirmed"], value["artifacts_cleaned"]
    except (OSError, ValueError):
        pass
    return False, False


def worker_cleanup_confirmed(path):
    return worker_cleanup_state(path)[0]


def loaded_system_images(cleanup_path=None):
    """Fresh private group; only confirmed cleanup may degrade to unknown."""
    global _cleanup_unconfirmed
    exited, artifacts_cleaned = worker_cleanup_state(cleanup_path)
    if not exited:
        raise ImageWorkerCleanupError()
    if not artifacts_cleaned:
        raise ImageWorkerArtifactError()
    try:
        WORKER_ROOT.mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix="ax-system-images-", dir=WORKER_ROOT))
    except OSError:
        return None  # No process was attempted.
    confirmed = True  # No process has been attempted yet.
    try:
        if cleanup_path is not None:
            write_worker_cleanup(cleanup_path, False, False)
        confirmed = False
        try:
            run = ax_process.run_owned([sys.executable, "-B", str(Path(__file__).resolve()), "--worker", str(work / "catalog.json")],
                work / "worker.log", dict(os.environ, PYTHONDONTWRITEBYTECODE="1", TMPDIR=str(work)), timeout=WORKER_SECONDS)
            confirmed = run["cleanup"]["complete"] is True
        except Exception as error:
            # An unexpected executor failure carries no proof of owned exit.
            raise ImageWorkerCleanupError() from error
        if cleanup_path is not None and confirmed:
            write_worker_cleanup(cleanup_path, True, False)
        try:
            (work / "process.json").write_text(json.dumps(run) + "\n")
        except OSError as error:
            raise (ImageWorkerArtifactError() if confirmed else ImageWorkerCleanupError()) from error
        if not confirmed:
            raise ImageWorkerCleanupError()
        if run["status"] != "completed" or run["return_code"]:
            return None
        # run_owned combines stdout/stderr. Keep the catalog separate so even
        # whitespace on either unexpected stream cannot become valid output.
        if (work / "worker.log").stat().st_size:
            return None
        with (work / "catalog.json").open("rb") as stream:
            payload = stream.read(CATALOG_BYTE_LIMIT + 1)
        if len(payload) > CATALOG_BYTE_LIMIT:
            return None
        value = json.loads(payload)
        if (type(value) is not dict or set(value) != {"schema", "images"}
                or type(value["schema"]) is not int or value["schema"] != 1
                or type(value["images"]) is not list or not 1 <= len(value["images"]) <= IMAGE_LIMIT
                or not all(safe_identity(image) for image in value["images"])):
            return None
        entries = {image["uuid"]: image for image in value["images"]}
        return entries if len(entries) == len(value["images"]) else None
    except ImageWorkerCleanupError:
        _cleanup_unconfirmed = True
        raise
    except (OSError, ValueError) as error:
        if not confirmed:
            _cleanup_unconfirmed = True
            raise ImageWorkerCleanupError() from error
        return None
    finally:
        if confirmed:
            original_error = sys.exc_info()[1]
            try:
                shutil.rmtree(work)
                if cleanup_path is not None and original_error is None:
                    write_worker_cleanup(cleanup_path, True)
            except (OSError, ImageWorkerArtifactError) as error:
                # Keep an earlier fixed error/cause; never retry a failed receipt.
                # A pre-cleanup sidecar already distinguishes exited from cleaned.
                if original_error is None:
                    raise ImageWorkerArtifactError() from error


def canonical_uuid(value):
    return (type(value) is str and re.fullmatch(UUID, value) is not None
            and value != "00000000-0000-0000-0000-000000000000")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate image field")
        result[key] = value
    return result


def validate_cache_lookup(value, identifiers):
    """Only a completed, closed native traversal can attest requested UUIDs."""
    integer = lambda v, lo, hi: type(v) is int and lo <= v <= hi
    if (type(value) is not dict or set(value) != {"schema", "mode", "status", "active_cache_uuid", "requests",
            "setup_calls", "measurement_calls", "callbacks", "measurement_closed", "result"}
            or not integer(value["schema"], 1, 1) or value["mode"] != "lookup" or value["status"] != "complete"
            or not canonical_uuid(value["active_cache_uuid"]) or not integer(value["requests"], len(identifiers), len(identifiers))
            or any(not integer(value[key], 1, 1) for key in ("setup_calls", "measurement_calls"))
            or not integer(value["callbacks"], 1, 16384) or value["measurement_closed"] is not True
            or type(value["result"]) is not list or len(value["result"]) != len(identifiers)):
        raise ValueError("Invalid shared-cache lookup")
    for index, row in enumerate(value["result"]):
        if (type(row) is not dict or row.get("reason") not in CACHE_REASONS
                or not integer(row.get("request_index"), index, index)):
            raise ValueError("Invalid shared-cache lookup row")
        verified = row["reason"] == "verified"
        if set(row) != ({"request_index", "reason", "basename", "uuid"} if verified else {"request_index", "reason"}):
            raise ValueError("Invalid shared-cache lookup fields")
        if verified and (not safe_identity({key: row[key] for key in ("basename", "uuid")}) or row["uuid"] != identifiers[index]):
            raise ValueError("Invalid shared-cache lookup identity")


def shared_cache_images(identifiers, cleanup_path):
    """Own compilation and one query; confirmed ordinary failures are optional."""
    global _cleanup_unconfirmed
    if (type(identifiers) is not list or not 1 <= len(identifiers) <= CACHE_REQUEST_LIMIT
            or not all(canonical_uuid(value) for value in identifiers) or len(set(identifiers)) != len(identifiers)):
        raise ValueError("Invalid shared-cache requests")
    exited, cleaned = worker_cleanup_state(cleanup_path)
    if not exited:
        raise ImageWorkerCleanupError()
    if not cleaned:
        raise ImageWorkerArtifactError()
    try:
        WORKER_ROOT.mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix="ax-cache-images-", dir=WORKER_ROOT))
    except OSError:
        return None
    confirmed = True
    try:
        binary, output = work / "SharedCacheLookup", work / "lookup.json"
        environment = dict(os.environ, TMPDIR=str(work), CLANG_MODULE_CACHE_PATH=str(work / "cache"), PYTHONDONTWRITEBYTECODE="1")
        commands = (("compile", ["xcrun", "clang", "-std=c11", "-fblocks", "-O1", "-g0", "-Wall", "-Wextra", "-Werror",
                     "-fmodules-cache-path=" + str(work / "cache"), str(CACHE_SOURCE), "-o", str(binary)], 60),
                    ("lookup", [str(binary), "--lookup", str(output), *identifiers], 20))
        for stage, command, timeout in commands:
            write_worker_cleanup(cleanup_path, False, False)
            confirmed = False
            try:
                run = ax_process.run_owned(command, work / (stage + ".log"), environment, timeout=timeout)
                confirmed = run["cleanup"]["complete"] is True
            except Exception as error:
                raise ImageWorkerCleanupError() from error
            if confirmed:
                write_worker_cleanup(cleanup_path, True, False)
            try:
                (work / (stage + "-process.json")).write_text(json.dumps(run) + "\n")
            except OSError as error:
                raise (ImageWorkerArtifactError() if confirmed else ImageWorkerCleanupError()) from error
            if not confirmed:
                raise ImageWorkerCleanupError()
            if run["status"] != "completed" or run["return_code"]:
                return None
        if (work / "lookup.log").stat().st_size:
            return None
        with output.open("rb") as stream:
            payload = stream.read(CACHE_OUTPUT_LIMIT + 1)
        if len(payload) > CACHE_OUTPUT_LIMIT:
            return None
        result = json.loads(payload, object_pairs_hook=unique_object)
        validate_cache_lookup(result, identifiers)
        return result
    except ImageWorkerCleanupError:
        _cleanup_unconfirmed = True
        raise
    except (OSError, ValueError, RecursionError):
        return None
    finally:
        if confirmed:
            original_error = sys.exc_info()[1]
            try:
                shutil.rmtree(work)
                if original_error is None:
                    write_worker_cleanup(cleanup_path, True)
            except (OSError, ImageWorkerArtifactError) as error:
                if original_error is None:
                    raise ImageWorkerArtifactError() from error


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "--worker":
        raise SystemExit("Only --worker OUTPUT is supported")
    _worker_entry(sys.argv[2])
