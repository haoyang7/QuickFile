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
import struct
import subprocess
import sys
import uuid

IMAGE_LIMIT = 2048
COMMAND_LIMIT = 65536
CATALOG_BYTE_LIMIT = 262144
WORKER_SECONDS = 10
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


def _worker_entry():
    callbacks, keepalive = [], None
    code = 1
    try:
        result, keepalive = _loaded_images(callbacks)
        payload = json.dumps(result, separators=(",", ":")).encode() + b"\n"
        if len(payload) > CATALOG_BYTE_LIMIT or keepalive[2]["failed"]:
            raise ValueError("Invalid image inventory")
        while payload:
            written = os.write(1, payload)
            if written <= 0:
                raise OSError("Incomplete inventory write")
            payload = payload[written:]
        code = 0 if not keepalive[2]["failed"] else 1
    except BaseException:
        pass
    finally:
        # No Python finalization can dispose a still-registered CFUNCTYPE.
        os._exit(code)


def loaded_system_images():
    """Fresh owned verifier; timeout kills/reaps it before returning unknown."""
    try:
        output = subprocess.run([sys.executable, "-B", str(Path(__file__).resolve()), "--worker"],
                                capture_output=True, timeout=WORKER_SECONDS)
        if output.returncode or output.stderr or len(output.stdout) > CATALOG_BYTE_LIMIT:
            return None
        value = json.loads(output.stdout)
        if (type(value) is not dict or set(value) != {"schema", "images"}
                or type(value["schema"]) is not int or value["schema"] != 1
                or type(value["images"]) is not list or not 1 <= len(value["images"]) <= IMAGE_LIMIT
                or not all(safe_identity(image) for image in value["images"])):
            return None
        entries = {image["uuid"]: image for image in value["images"]}
        return entries if len(entries) == len(value["images"]) else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


if __name__ == "__main__":
    if sys.argv[1:] != ["--worker"]:
        raise SystemExit("Only --worker is supported")
    _worker_entry()
