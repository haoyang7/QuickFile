#!/usr/bin/env python3
"""Bind a Community DMG delivery to its clean GitHub checkout and pinned tools."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

SHA = r"[0-9a-f]{40}"
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"
TAG = rf"v({VERSION})(?:-beta\.[1-9][0-9]*)?"


def checked(value, pattern, label):
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        raise ValueError(f"invalid {label}")
    return value


def output(command):
    result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=30)
    if len(result.stdout) > 16 * 1024:
        raise ValueError("unexpected command output size")
    return result.stdout.strip()


def release_tag(env):
    tag = checked(env.get("RELEASE_TAG"), TAG, "release tag")
    if env.get("GITHUB_REF", "").startswith("refs/tags/") and env["GITHUB_REF"] != "refs/tags/" + tag:
        raise ValueError("release tag does not match event tag")
    return tag


def resolve(env, project=Path("project.yml")):
    if env.get("GITHUB_REF", "").startswith("refs/tags/") or env.get("GITHUB_EVENT_NAME") == "workflow_dispatch":
        tag = release_tag(env)
    elif env.get("GITHUB_EVENT_NAME") == "push" and re.fullmatch(r"refs/heads/codex/.+", env.get("GITHUB_REF", "")):
        # The checked-in XcodeGen format has one shared marketing version. Refuse
        # missing, duplicate or malformed declarations instead of guessing a tag.
        values = re.findall(r"^\s*MARKETING_VERSION\s*:\s*([^\r\n]*)$", project.read_text(encoding="utf-8"), re.MULTILINE)
        if len(values) != 1:
            raise ValueError("project must declare exactly one marketing version")
        value = values[0].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        tag = checked("v" + checked(value, VERSION, "marketing version"), TAG, "release tag")
    else:
        raise ValueError("cannot resolve release tag for this event")
    destination = env.get("GITHUB_ENV")
    if not isinstance(destination, str) or not destination:
        raise ValueError("missing GitHub environment file")
    with open(destination, "a", encoding="utf-8") as stream:
        stream.write(f"RELEASE_TAG={tag}\n")
    return tag


def verify_source(env):
    sha = checked(env.get("GITHUB_SHA"), SHA, "event commit")
    if output(["git", "rev-parse", "--verify", "HEAD"]) != sha:
        raise ValueError("checkout does not match event commit")
    if output(["git", "status", "--porcelain", "--untracked-files=normal"]):
        raise ValueError("source worktree changed; refusing to upload")
    return sha


def verify_host(env):
    if env.get("RUNNER_OS") != "macOS" or env.get("RUNNER_ARCH") != "ARM64":
        raise ValueError("unexpected GitHub runner identity")
    if env.get("DEVELOPER_DIR") != "/Applications/Xcode_26.3.app/Contents/Developer":
        raise ValueError("unexpected selected Xcode")
    macos = checked(output(["sw_vers", "-productVersion"]), r"15\.[0-9]+(?:\.[0-9]+)?", "macOS version")
    architecture = checked(output(["uname", "-m"]), "arm64", "architecture")
    xcode = checked(output(["xcodebuild", "-version"]), r"Xcode 26\.3\nBuild version ([0-9]{2}[A-Z][0-9]+[a-z]?)", "Xcode version")
    checked(output(["xcodegen", "version"]), r"Version: 2\.46\.0", "XcodeGen version")
    return {"os": "macOS", "macos_version": macos, "architecture": architecture,
            "xcode_version": "26.3", "xcode_build": xcode.split("Build version ")[1],
            "xcodegen_version": "2.46.0"}


def metadata(env):
    repository = checked(env.get("GITHUB_REPOSITORY"), r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}", "repository")
    run_id = checked(env.get("GITHUB_RUN_ID"), r"[1-9][0-9]{0,19}", "run ID")
    attempt = checked(env.get("GITHUB_RUN_ATTEMPT"), r"[1-9][0-9]{0,5}", "run attempt")
    checked(env.get("GITHUB_SERVER_URL"), "https://github.com", "GitHub server")
    return {"repository": repository,
            "event": checked(env.get("GITHUB_EVENT_NAME"), r"push|workflow_dispatch", "event"),
            "workflow_commit": checked(env.get("WORKFLOW_SHA"), SHA, "workflow commit"),
            "run_id": run_id, "run_attempt": attempt,
            "run_url": f"https://github.com/{repository}/actions/runs/{run_id}/attempts/{attempt}"}


def regular_file(path):
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError("symlink in delivery")
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("delivery asset must be a regular owned file")
    return info


def digest(path):
    info = regular_file(path)
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return {"name": path.name, "sha256": value.hexdigest(), "bytes": info.st_size}


def assets(directory, tag):
    image = f"QuickFile-{tag}.dmg"
    names = {image, image + ".sha256", "artifact-check.json", "INSTALL.txt"}
    if directory.is_symlink() or {path.name for path in directory.iterdir()} != names:
        raise ValueError("delivery must contain exactly the four Community assets")
    receipt_path = directory / "artifact-check.json"
    if regular_file(receipt_path).st_size > 1024 * 1024:
        raise ValueError("artifact receipt exceeds size limit")
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    version = re.fullmatch(TAG, tag).group(1)
    if receipt.get("verdict") != "pass" or receipt.get("trust") != "ad-hoc/unnotarized":
        raise ValueError("Community artifact did not pass its trust checks")
    if receipt.get("version") != version or receipt.get("archive") != image:
        raise ValueError("release tag does not match the artifact version or filename")
    build = checked(receipt.get("build"), r"[0-9]+", "internal build")
    records = [digest(directory / name) for name in sorted(names)]
    dmg = next(record for record in records if record["name"] == image)
    if receipt.get("archive_sha256") != dmg["sha256"] or receipt.get("archive_bytes") != dmg["bytes"]:
        raise ValueError("DMG differs from the verified artifact receipt")
    checksum = directory / (image + ".sha256")
    if regular_file(checksum).st_size > 1024 or checksum.read_text(encoding="utf-8") != dmg["sha256"] + "  " + image + "\n":
        raise ValueError("DMG checksum file does not match")
    return records, build


def check(env):
    release_tag(env)
    verify_source(env)
    verify_host(env)
    metadata(env)


def write(directory, env):
    tag = release_tag(env)
    sha = verify_source(env)
    host = verify_host(env)
    run = metadata(env)
    records, build = assets(directory, tag)
    payload = {"schema_version": 1, "scope": "GitHub source build and artifact checks only",
               "trust": "ad-hoc/unnotarized", "source_commit": sha, "source_worktree_clean": True,
               "release_tag": tag, "internal_build": build, "run": run, "runner": host, "assets": records,
               "unproven": ["cross-machine launch", "Finder integration", "upgrades", "Gatekeeper acceptance"]}
    with (directory / "build-provenance.json").open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    artifact = f"quickfile-community-{sha}-{run['run_id']}-attempt-{run['run_attempt']}"
    with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
        stream.write(f"artifact_name={artifact}\n")
        stream.write(f"dmg={directory / ('QuickFile-' + tag + '.dmg')}\n")
        stream.write(f"checksum={directory / ('QuickFile-' + tag + '.dmg.sha256')}\n")
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("resolve", "check", "write"))
    parser.add_argument("--directory", type=Path)
    arguments = parser.parse_args()
    if arguments.command == "write" and arguments.directory is None:
        parser.error("write requires --directory")
    try:
        if arguments.command == "resolve":
            resolve(os.environ)
        elif arguments.command == "check":
            check(os.environ)
        else:
            write(arguments.directory, os.environ)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("Community provenance failed: " + (str(error) if isinstance(error, ValueError) else type(error).__name__), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
