#!/usr/bin/env python3
"""Small synthetic CI receipts. Never copy logs, environment dumps or xcresult data.

Raw result bundles stay beside (not inside) the upload directory on the runner.
This is provenance for one CI job, not signed release or real-device evidence.
"""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

MAX_FILE_BYTES = 16 * 1024
UPLOAD_FILES = frozenset({"identity.json", "verification.json"})
VERSION = r"[0-9]{1,3}(?:\.[0-9]{1,4}){1,3}"
SHA = r"[0-9a-f]{40}"
APPLE_BUILD = r"[0-9]{2}[A-Z][0-9]{1,5}[a-z]?"
OUTCOMES = frozenset({"success", "failure", "cancelled", "skipped"})
LANES = {
    ("macos-15", "15", "arm64", "26.3"),
    ("macos-15-intel", "15", "x86_64", "26.3"),
    ("macos-26", "26", "arm64", "26.3"),
    ("xcode-27", "27", "arm64", "27.0"),
}


def checked(value, pattern, label):
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        raise ValueError(f"invalid {label}")
    return value


def output(command):
    # Do not relay stderr or unrecognized output into an artifact or error message.
    result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=30)
    if len(result.stdout) > MAX_FILE_BYTES:
        raise ValueError("tool version output exceeds limit")
    return result.stdout.strip()


def optional_tool(command, pattern):
    try:
        return checked(output(command), pattern, "tool version")
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def no_symlinks(path):
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError("symlink in evidence path")


def write_json(path, payload):
    data = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
    if len(data) > MAX_FILE_BYTES:
        raise ValueError("receipt exceeds size limit")
    no_symlinks(path)
    # Exclusive creation prevents stale evidence reuse and accidental overwrite.
    with path.open("xb") as stream:
        stream.write(data)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate receipt field")
        result[key] = value
    return result


def read_json(path):
    no_symlinks(path)
    # Bind validation and bounded reads to the same descriptor. O_NOFOLLOW
    # rejects a raced leaf symlink; O_NONBLOCK avoids blocking on a raced FIFO.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > MAX_FILE_BYTES:
            raise ValueError("invalid receipt file")
        data = bytearray()
        while len(data) <= MAX_FILE_BYTES:
            chunk = os.read(descriptor, MAX_FILE_BYTES + 1 - len(data))
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > MAX_FILE_BYTES:
                raise ValueError("receipt exceeds size limit")
        return json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    finally:
        os.close(descriptor)


def expected_identity(env):
    lane = tuple(env.get(key, "") for key in (
        "EXPECTED_RUNNER", "EXPECTED_MACOS_MAJOR", "EXPECTED_ARCHITECTURE", "EXPECTED_XCODE_VERSION"))
    if lane not in LANES:
        raise ValueError("unrecognized CI matrix identity")
    runner, major, arch, xcode = lane
    developer = f"/Applications/Xcode_{xcode}.app/Contents/Developer"
    if env.get("DEVELOPER_DIR") != developer:
        raise ValueError("unexpected developer directory")
    return {"runner": runner, "macos_major": major, "architecture": arch,
            "xcode": xcode, "developer_directory": developer}


def actual_identity():
    xcode_output = optional_tool(["xcodebuild", "-version"], rf"Xcode ({VERSION})\nBuild version ({APPLE_BUILD})")
    xcode = re.fullmatch(rf"Xcode ({VERSION})\nBuild version ({APPLE_BUILD})", xcode_output) if xcode_output else None
    swift_output = optional_tool(["xcrun", "swift", "--version"], r"[A-Za-z0-9 .()_\-\n:]{1,500}")
    swift = re.search(rf"Apple Swift version ({VERSION})[^\n]*\((swiftlang-[A-Za-z0-9._-]+) (clang-[A-Za-z0-9._-]+)\)", swift_output or "")
    return {
        "macos_version": optional_tool(["sw_vers", "-productVersion"], VERSION),
        "macos_build": optional_tool(["sw_vers", "-buildVersion"], APPLE_BUILD),
        "architecture": optional_tool(["uname", "-m"], r"arm64|x86_64"),
        "xcode": xcode.group(1) if xcode else None,
        "xcode_build": xcode.group(2) if xcode else None,
        "macos_sdk": optional_tool(["xcrun", "--sdk", "macosx", "--show-sdk-version"], VERSION),
        "swift_version": swift.group(1) if swift else None,
        "swift_build": swift.group(2) if swift else None,
        "clang_build": swift.group(3) if swift else None,
        "python": ".".join(map(str, sys.version_info[:3])),
    }


def identity_matches(expected, actual):
    return (all(value is not None for value in actual.values())
            and actual["macos_version"].split(".")[0] == expected["macos_major"]
            and actual["architecture"] == expected["architecture"]
            and actual["xcode"] == expected["xcode"])


def canonical_runner_temp(directory):
    # RUNNER_TEMP is a trusted runner-provided base, not an evidence path. macOS
    # may spell it through /var -> /private/var or /tmp -> /private/tmp. Resolve
    # that platform alias once; all new descendants still reject every symlink.
    path = Path(directory)
    if not path.is_absolute() or ".." in path.parts or "\n" in str(path) or "\r" in str(path):
        raise ValueError("invalid runner temporary root")
    canonical = path.resolve(strict=True)
    if not canonical.is_dir():
        raise ValueError("runner temporary root is not a directory")
    return canonical


def initialize(env):
    expected = expected_identity(env)
    metadata = {
        "repository": checked(env.get("GITHUB_REPOSITORY"), r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}", "repository"),
        "run_id": checked(env.get("GITHUB_RUN_ID"), r"[0-9]{1,20}", "run ID"),
        "run_attempt": checked(env.get("GITHUB_RUN_ATTEMPT"), r"[0-9]{1,6}", "run attempt"),
        "job": checked(env.get("GITHUB_JOB"), r"macos|compatibility", "job"),
        "workflow": checked(env.get("GITHUB_WORKFLOW"), r"CI|macOS 27 compatibility", "workflow"),
        "event": checked(env.get("GITHUB_EVENT_NAME"), r"push|pull_request|workflow_dispatch", "event"),
        "checkout_sha": checked(output(["git", "rev-parse", "--verify", "HEAD"]), SHA, "checkout SHA"),
        "event_sha": checked(env.get("GITHUB_SHA"), SHA, "event SHA"),
        "workflow_sha": checked(env.get("WORKFLOW_SHA"), SHA, "workflow SHA"),
        "pr_head_sha": checked(env["PR_HEAD_SHA"], SHA, "PR head SHA") if env.get("PR_HEAD_SHA") else None,
        "pr_base_sha": checked(env["PR_BASE_SHA"], SHA, "PR base SHA") if env.get("PR_BASE_SHA") else None,
    }
    metadata["run_url"] = f"https://github.com/{metadata['repository']}/actions/runs/{metadata['run_id']}/attempts/{metadata['run_attempt']}"
    actual = actual_identity()
    payload = {"schema_version": 1, "scope": "synthetic-ci-only", "expected": expected,
               "actual": actual, "source": metadata, "identity_verified": identity_matches(expected, actual)}
    base = canonical_runner_temp(env["RUNNER_TEMP"])
    root = Path(tempfile.mkdtemp(prefix="quickfile-ci-", dir=base))
    (root / "upload").mkdir()
    write_json(root / "upload" / "identity.json", payload)
    artifact = (f"quickfile-{metadata['job']}-macos-{expected['macos_major']}-{expected['architecture']}"
                f"-xcode-{expected['xcode']}-{metadata['run_id']}-attempt-{metadata['run_attempt']}")
    with open(env["GITHUB_OUTPUT"], "a") as stream:
        stream.write(f"root={root}\nartifact_name={artifact}\n")
    if not payload["identity_verified"]:
        print("error: observed host/tool identity does not match the explicit matrix; see sanitized receipts", file=sys.stderr)
        return 1
    return 0


def prepare_results(directory):
    path = Path(directory)
    if not path.is_absolute() or "\n" in str(path) or "\r" in str(path) or ".." in path.parts:
        raise ValueError("result directory must be a clean absolute path")
    no_symlinks(path)
    # Never delete or reuse an old bundle, including one from a failed run.
    path.mkdir(mode=0o700, exist_ok=False)
    return path


def run_native(root, command):
    root = Path(root)
    no_symlinks(root)
    identity = read_json(root / "upload" / "identity.json")
    if identity.get("identity_verified") is not True:
        raise ValueError("native verification requires validated identity")
    results = root / "results"
    # The verification script creates this directory exclusively before xcodebuild.
    if results.exists() or results.is_symlink():
        raise ValueError("result directory already exists")
    env = dict(os.environ, QUICKFILE_RESULT_DIRECTORY=str(results))
    try:
        code = subprocess.run(command, env=env, check=False).returncode
        code = 128 - code if code < 0 else code
    except OSError:
        code = 127
    # Recheck after execution too: a command may have replaced the result parent.
    # Do not follow it even just to report whether a bundle exists elsewhere.
    try:
        no_symlinks(results)
        bundles = {name: (results / f"{name}.xcresult").is_dir()
                   and not (results / f"{name}.xcresult").is_symlink() for name in ("tests", "release")}
    except ValueError:
        bundles = {"tests": False, "release": False}
    # A zero exit without the explicitly requested result bundles is incomplete.
    receipt = {"exit_code": code, "result_bundles_present": bundles}
    write_json(root / "native-exit.json", receipt)
    return code if code else (0 if all(bundles.values()) else 1)


def validate_identity(payload):
    if set(payload) != {"schema_version", "scope", "expected", "actual", "source", "identity_verified"}:
        raise ValueError("unexpected identity fields")
    if type(payload["schema_version"]) is not int or payload["schema_version"] != 1 or payload["scope"] != "synthetic-ci-only":
        raise ValueError("invalid identity schema")
    expected = payload["expected"]
    if set(expected) != {"runner", "macos_major", "architecture", "xcode", "developer_directory"}:
        raise ValueError("unexpected matrix fields")
    expected_identity(dict(zip(("EXPECTED_RUNNER", "EXPECTED_MACOS_MAJOR", "EXPECTED_ARCHITECTURE", "EXPECTED_XCODE_VERSION", "DEVELOPER_DIR"),
                              (expected[key] for key in ("runner", "macos_major", "architecture", "xcode", "developer_directory")))))
    patterns = {"macos_version": VERSION, "macos_build": APPLE_BUILD, "architecture": r"arm64|x86_64", "xcode": VERSION,
                "xcode_build": APPLE_BUILD, "macos_sdk": VERSION, "swift_version": VERSION,
                "swift_build": r"swiftlang-[A-Za-z0-9._-]{1,100}", "clang_build": r"clang-[A-Za-z0-9._-]{1,100}", "python": VERSION}
    if set(payload["actual"]) != set(patterns):
        raise ValueError("unexpected tool fields")
    for key, pattern in patterns.items():
        if payload["actual"][key] is not None:
            checked(payload["actual"][key], pattern, key)
    source = payload["source"]
    patterns = {"repository": r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}", "run_id": r"[0-9]{1,20}",
                "run_attempt": r"[0-9]{1,6}", "job": r"macos|compatibility", "workflow": r"CI|macOS 27 compatibility",
                "event": r"push|pull_request|workflow_dispatch", "checkout_sha": SHA, "event_sha": SHA,
                "workflow_sha": SHA, "pr_head_sha": SHA, "pr_base_sha": SHA, "run_url": r"https://github\.com/[A-Za-z0-9_./-]{1,300}"}
    if set(source) != set(patterns):
        raise ValueError("unexpected source fields")
    for key, pattern in patterns.items():
        if key in {"pr_head_sha", "pr_base_sha"} and source[key] is None:
            continue
        checked(source[key], pattern, key)
    if source["run_url"] != f"https://github.com/{source['repository']}/actions/runs/{source['run_id']}/attempts/{source['run_attempt']}":
        raise ValueError("inconsistent run URL")
    if type(payload["identity_verified"]) is not bool or payload["identity_verified"] != identity_matches(expected, payload["actual"]):
        raise ValueError("inconsistent identity verification")


def validate_native(payload):
    if set(payload) != {"exit_code", "result_bundles_present"}:
        raise ValueError("unexpected native receipt fields")
    if type(payload["exit_code"]) is not int or not 0 <= payload["exit_code"] <= 255:
        raise ValueError("invalid native exit code")
    bundles = payload["result_bundles_present"]
    if set(bundles) != {"tests", "release"} or any(type(v) is not bool for v in bundles.values()):
        raise ValueError("invalid result bundle receipt")


def validate_verification(payload):
    if set(payload) != {"schema_version", "scope", "outcomes", "native", "xcodegen_version", "raw_results_uploaded"}:
        raise ValueError("unexpected verification fields")
    if type(payload["schema_version"]) is not int or payload["schema_version"] != 1 or payload["scope"] != "synthetic-ci-only" or payload["raw_results_uploaded"] is not False:
        raise ValueError("invalid verification schema")
    if set(payload["outcomes"]) != {"identity", "tools", "scripts", "native", "job_before_upload"}:
        raise ValueError("unexpected outcome fields")
    if any(value not in OUTCOMES for value in payload["outcomes"].values()):
        raise ValueError("invalid step outcome")
    if payload["native"] is not None:
        validate_native(payload["native"])
    if payload["xcodegen_version"] is not None:
        checked(payload["xcodegen_version"], VERSION, "XcodeGen version")


def check_upload(root):
    directory = Path(root) / "upload"
    no_symlinks(directory)
    if {path.name for path in directory.iterdir()} != UPLOAD_FILES:
        raise ValueError("upload directory is not the exact file allowlist")
    validate_identity(read_json(directory / "identity.json"))
    validate_verification(read_json(directory / "verification.json"))


def finish(root, env):
    root = Path(root)
    identity = read_json(root / "upload" / "identity.json")
    validate_identity(identity)
    native_file = root / "native-exit.json"
    native = read_json(native_file) if native_file.exists() else None
    version_output = optional_tool(["xcodegen", "version"], rf"(?:Version: )?{VERSION}")
    version = re.search(VERSION, version_output).group() if version_output else None
    outcomes = {key: env.get(variable, "skipped") for key, variable in (
        ("identity", "IDENTITY_OUTCOME"), ("tools", "TOOLS_OUTCOME"), ("scripts", "SCRIPTS_OUTCOME"),
        ("native", "NATIVE_OUTCOME"), ("job_before_upload", "JOB_STATUS"))}
    payload = {"schema_version": 1, "scope": "synthetic-ci-only", "outcomes": outcomes,
               "native": native, "xcodegen_version": version, "raw_results_uploaded": False}
    validate_verification(payload)
    write_json(root / "upload" / "verification.json", payload)
    check_upload(root)
    source = identity["source"]
    actual = identity["actual"]
    with open(env["GITHUB_STEP_SUMMARY"], "a") as stream:
        stream.write("### Synthetic macOS CI evidence\n\n")
        for key in ("checkout_sha", "event_sha", "workflow_sha", "pr_head_sha", "pr_base_sha", "job", "run_attempt", "run_url"):
            stream.write(f"- {key}: `{source[key]}`\n")
        stream.write(f"- Actual macOS / architecture / Xcode: `{actual['macos_version']}` / `{actual['architecture']}` / `{actual['xcode']}` (build `{actual['xcode_build']}`)\n")
        stream.write(f"- Step outcomes before upload: `{json.dumps(outcomes, sort_keys=True)}`\n")
        stream.write("\nOnly bounded identity/verification JSON receipts are retained for 7 days. Raw xcresult, workspace/user paths, test names, messages and attachments are not uploaded.\n")
        stream.write("\nScope: script tests, native Swift tests, unsigned Universal build and bundle/security checks. Remaining gates: signed installation, Finder interaction, memory/recovery, real latency, hardware and storage environments.\n")
    # Missing/mismatched evidence must not make a nominally green job credible.
    if outcomes["native"] == "success" and (native is None or native["exit_code"] != 0 or not all(native["result_bundles_present"].values())):
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("initialize")
    prepare = commands.add_parser("prepare-results")
    prepare.add_argument("directory")
    run = commands.add_parser("run-native")
    run.add_argument("root")
    run.add_argument("command", nargs=argparse.REMAINDER)
    for name in ("finish", "check-upload"):
        commands.add_parser(name).add_argument("root")
    args = parser.parse_args()
    try:
        if args.action == "initialize":
            return initialize(os.environ)
        if args.action == "prepare-results":
            print(prepare_results(args.directory))
        elif args.action == "run-native":
            command = args.command[1:] if args.command[:1] == ["--"] else args.command
            if not command:
                raise ValueError("missing native command")
            return run_native(args.root, command)
        elif args.action == "finish":
            return finish(args.root, os.environ)
        else:
            check_upload(args.root)
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # Neither command output nor arbitrary file contents enter failure logs.
        print("error: CI evidence validation failed; inspect the failing workflow step", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
