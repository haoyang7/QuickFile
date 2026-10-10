"""Startup metadata for this runner's owned fixture children; never target memory.

KERN_PROCARGS2 is a startup-environment observation, not a current getenv or
mapped-image query. Unreadable metadata must not be interpreted as an unset key.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys


EXECUTABLES = {"host": "AXCompatibilityFixture.app/Contents/MacOS/AXCompatibilityFixture",
               "reader": "ax-reader"}
ARGUMENT_LIMIT = 8 * 1024 * 1024
FIXTURE_SOURCES = ("Scripts/tests/fixtures/AXCompatibilityNotifications.m", "Scripts/tests/fixtures/AXCompatibilityReader.swift")
PRODUCTION_SOURCES = ("QuickFileApp/AXCompatibility.m", "QuickFileApp/AXCompatibility.h")
INSTALL_MODES = ("installed", "preflight-only")
INSTALL_ENV = "QUICKFILE_AX_INSTALL_PROBE_MODE"


def fixture_sources(build_mode="ordinary"):
    if build_mode not in ("ordinary", "patched", "pure-appkit", "install-gate"):
        raise RuntimeError("Unknown fixture build mode")
    return list((() if build_mode == "pure-appkit" else PRODUCTION_SOURCES) + FIXTURE_SOURCES)


def validate_empty_control_build(value, mode):
    """Only fixed build inputs and bounded symbol counts may be published."""
    expected_inputs = {"host": [FIXTURE_SOURCES[0]] + (["AXCompatibility.o"] if mode == "patched" else []),
                       "reader": [FIXTURE_SOURCES[1]]}
    if (mode not in ("patched", "pure-appkit") or type(value) is not dict
            or set(value) != {"link_inputs", "production_ax_symbol_counts"} or value["link_inputs"] != expected_inputs):
        raise RuntimeError("Invalid empty-control build evidence")
    counts = value["production_ax_symbol_counts"]
    if (type(counts) is not dict or set(counts) != set(EXECUTABLES)
            or any(type(count) is not int or not 0 <= count <= 64 for count in counts.values())
            or counts["reader"] != 0 or (counts["host"] != 0 if mode == "pure-appkit" else counts["host"] < 4)):
        raise RuntimeError("Unexpected production AX symbols in empty-control build")


def validate_install_gate_build(value):
    expected = {"link_inputs": {"host": [FIXTURE_SOURCES[0], "AXCompatibility.o"], "reader": [FIXTURE_SOURCES[1]]},
        "compile_definitions": {"production": ["QUICKFILE_AX_INSTALL_PROBE"], "host": ["QUICKFILE_AX_INSTALL_PROBE"], "reader": []},
        "gate_symbol_present": {"host": True, "reader": False}}
    if type(value) is not dict or value != expected or any(type(value["gate_symbol_present"][role]) is not bool for role in EXECUTABLES):
        raise RuntimeError("Invalid install-gate build evidence")


def validate_install_gate_state(value, mode):
    expected_imp = "replacement" if mode == "installed" else "saved"
    if (mode not in INSTALL_MODES or type(value) is not dict
            or set(value) != {"mode", "preflight_completed", "gate_calls", "copy_imp", "mutable_copy_imp"}
            or value["mode"] != mode or value["preflight_completed"] is not True
            or type(value["gate_calls"]) is not int or value["gate_calls"] != 1
            or value["copy_imp"] != expected_imp or value["mutable_copy_imp"] != expected_imp):
        raise RuntimeError("Install-gate preflight or current method state differs")


def executable_hash(path):
    if path.is_symlink() or not path.is_file() or not os.access(path, os.X_OK) or not 0 < path.stat().st_size <= 128 * 1024 * 1024:
        raise RuntimeError("Fixture executable unavailable")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fixture_hashes(directory):
    return {role: executable_hash(directory / name) for role, name in EXECUTABLES.items()}


def validate_hashes(value):
    if (type(value) is not dict or set(value) != set(EXECUTABLES)
            or any(type(item) is not str or not re.fullmatch(r"[0-9a-f]{64}", item) for item in value.values())):
        raise RuntimeError("Invalid fixture executable hashes")


def require_fixture_hashes(directory, expected):
    validate_hashes(expected)
    if fixture_hashes(directory) != expected:
        raise RuntimeError("Fixture executable bytes changed")


def load_prepared_build(directory, sources, build_mode="ordinary"):
    manifest = directory / "fixture-build.json"
    if manifest.is_symlink() or not manifest.is_file() or manifest.stat().st_size > 16384:
        raise RuntimeError("Prepared fixture manifest unavailable")
    try:
        value = json.loads(manifest.read_text())
    except (ValueError, UnicodeError):
        raise RuntimeError("Invalid prepared fixture manifest") from None
    fixture_sources(build_mode)
    fields = {"schema", "build_mode", "sources", "executables"}
    if build_mode != "ordinary":
        fields.add("build_evidence")
    if (type(value) is not dict or set(value) != fields
            or type(value["schema"]) is not int or value["schema"] != (1 if build_mode == "ordinary" else 3 if build_mode == "install-gate" else 2)
            or value["build_mode"] != build_mode
            or value["sources"] != sources):
        raise RuntimeError("Prepared fixture differs from expected source build")
    if build_mode != "ordinary":
        if (type(sources) is not dict or set(sources) != set(fixture_sources(build_mode))
                or any(type(item) is not str or not re.fullmatch(r"[0-9a-f]{64}", item) for item in sources.values())):
            raise RuntimeError("Invalid empty-control source hashes")
        if build_mode == "install-gate":
            validate_install_gate_build(value["build_evidence"])
        else:
            validate_empty_control_build(value["build_evidence"], build_mode)
    require_fixture_hashes(directory, value["executables"])
    return value


def load_prepared_fixture(directory, sources, build_mode="ordinary"):
    return load_prepared_build(directory, sources, build_mode)["executables"]


def parse_procargs(raw):
    """Decode Darwin's bounded argc / exec path / argv / envp byte layout."""
    if type(raw) is not bytes or not 5 <= len(raw) <= ARGUMENT_LIMIT:
        raise RuntimeError("Invalid startup metadata size")
    argc = struct.unpack_from("=i", raw)[0]
    if not 1 <= argc <= 4096:
        raise RuntimeError("Invalid startup argument count")
    offset = 4

    def take():
        nonlocal offset
        end = raw.find(b"\0", offset)
        if end < 0:
            raise RuntimeError("Unterminated startup metadata")
        result, offset = raw[offset:end], end + 1
        return result

    executable = take()
    if not executable:
        raise RuntimeError("Missing startup executable")
    while offset < len(raw) and raw[offset] == 0:
        offset += 1
    arguments = [take() for _ in range(argc)]
    environment = {}
    terminated = False
    while offset < len(raw):
        entry = take()
        if not entry:
            terminated = True
            # Darwin copies a saved stack region, not a serialized env dictionary.
            # Bytes beyond envp's empty terminator are not environment entries.
            break
        key, separator, value = entry.partition(b"=")
        if not separator or not key or key in environment:
            raise RuntimeError("Invalid startup environment entry")
        environment[key] = value
    if not terminated or not environment:
        raise RuntimeError("Startup environment is not visible")
    return executable, arguments, environment


def read_procargs(pid):
    if sys.platform != "darwin" or type(pid) is not int or pid <= 0:
        raise RuntimeError("Startup environment requires an owned Darwin child")
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    library.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                              ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
    library.sysctl.restype = ctypes.c_int
    maximum = ctypes.c_int()
    size = ctypes.c_size_t(ctypes.sizeof(maximum))
    if library.sysctl((ctypes.c_int * 2)(1, 8), 2, ctypes.byref(maximum), ctypes.byref(size), None, 0):
        raise RuntimeError("Startup metadata capacity unavailable")
    if size.value != ctypes.sizeof(maximum) or not 5 <= maximum.value <= ARGUMENT_LIMIT:
        raise RuntimeError("Invalid startup metadata capacity")
    buffer = ctypes.create_string_buffer(maximum.value)
    size = ctypes.c_size_t(len(buffer))
    if library.sysctl((ctypes.c_int * 3)(1, 49, pid), 3, buffer, ctypes.byref(size), None, 0):
        raise RuntimeError("Owned child startup environment unavailable")
    if not 5 <= size.value <= len(buffer):
        raise RuntimeError("Invalid startup metadata result size")
    return parse_procargs(buffer.raw[:size.value])


def owned_child_receipt(process, executable, environment, requested, expected_hash, install_gate=None):
    """Only the runner's actual Popen handle is accepted, never a PID CLI input.

    samefile accepts symlink spellings in startup metadata. The hash describes
    that on-disk executable; this does not claim to inspect mapped process bytes.
    """
    try:
        if requested not in ("off", "on") or process.poll() is not None:
            raise RuntimeError("Owned fixture child is not alive")
        if (type(process.args) not in (list, tuple) or not process.args
                or not os.path.samefile(process.args[0], executable)):
            raise RuntimeError("Owned fixture launch identity differs")
        startup_executable, arguments, actual = read_procargs(process.pid)
        if (not arguments or not arguments[0]
                or not os.path.samefile(os.fsdecode(startup_executable), executable)
                or not os.path.samefile(os.fsdecode(arguments[0]), executable)):
            raise RuntimeError("Owned fixture startup identity differs")
        path = environment.get("PATH")
        if not path or actual.get(b"PATH") != os.fsencode(path):
            raise RuntimeError("Owned fixture startup environment visibility unconfirmed")
        expected = b"1" if requested == "on" else None
        if actual.get(b"MallocScribble") != expected:
            raise RuntimeError("Owned fixture startup allocator setting differs")
        if install_gate is not None and (install_gate not in INSTALL_MODES or requested != "off"
                or environment.get(INSTALL_ENV) != install_gate or actual.get(INSTALL_ENV.encode()) != install_gate.encode()):
            raise RuntimeError("Owned fixture startup install gate differs")
        if executable_hash(Path(executable)) != expected_hash or process.poll() is not None:
            raise RuntimeError("Owned fixture identity or liveness changed")
    except OSError:
        raise RuntimeError("Owned fixture startup identity unavailable") from None
    receipt = {"malloc_scribble": "1" if requested == "on" else "unset", "path_matches": True,
               "startup_executable_matches": True, "alive_during_check": True, "executable_sha256": expected_hash}
    if install_gate is not None:
        receipt["install_gate"] = install_gate
    return receipt


def validate_external_receipt(value, requested, expected_hashes, install_gate=None):
    """Exact public allowlist; failed/incomplete observations never pass."""
    validate_hashes(expected_hashes)
    extra = {"install_gate"} if install_gate is not None else set()
    if (type(value) is not dict or set(value) != {"receipt_mode", "requested", "host", "reader", "executables", "binary_reuse_verified"} | extra
            or value["receipt_mode"] != "external-startup" or requested not in ("off", "on")
            or value["requested"] != requested or value["executables"] != expected_hashes
            or value["binary_reuse_verified"] is not True):
        raise RuntimeError("External startup receipt incomplete")
    if install_gate is not None and (install_gate not in INSTALL_MODES or requested != "off" or value["install_gate"] != install_gate):
        raise RuntimeError("External startup install gate incomplete")
    for role in EXECUTABLES:
        entry = value[role]
        if (type(entry) is not dict or set(entry) != {"malloc_scribble", "path_matches", "startup_executable_matches", "alive_during_check", "executable_sha256"} | extra
                or entry["malloc_scribble"] != ("1" if requested == "on" else "unset")
                or any(entry[key] is not True for key in ("path_matches", "startup_executable_matches", "alive_during_check"))
                or entry["executable_sha256"] != expected_hashes[role]):
            raise RuntimeError("External startup receipt incomplete")
        if install_gate is not None and entry["install_gate"] != install_gate:
            raise RuntimeError("External startup install gate incomplete")
