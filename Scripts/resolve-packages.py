#!/usr/bin/env python3
"""Resolve pinned SwiftPM packages, retrying only binary download timeouts."""

import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import time


BINARY_DOWNLOAD_TIMEOUT = re.compile(
    r"failed downloading '[^'\r\n]+' which is required by binary target '[^'\r\n]+': "
    r'downloadError\("The request timed out\."\)'
)
RESOLUTION_ERROR = "xcodebuild: error: Could not resolve package dependencies:"
OTHER_ERROR = re.compile(
    r"\b(?:error:|fatalerror\b|failed\b|failure\b|downloaderror\b|"
    r"checksum.*(?:mismatch|does not match)|invalid.*manifest|conflict\b|"
    r"HTTP\s+[45]\d\d\b|forbidden\b|unauthorized\b|permission denied\b|"
    r"operation not permitted\b|no space left\b|disk full\b)",
    re.IGNORECASE,
)


def lock_is_unchanged(package_lock: Path, expected_hash: str) -> bool:
    try:
        with package_lock.open("rb") as stream:
            digest = hashlib.sha256()
            for chunk in iter(lambda: stream.read(65536), b""):
                digest.update(chunk)
    except OSError:
        print("error: Package.resolved is missing or unreadable after package resolution", file=sys.stderr)
        return False
    if digest.hexdigest() != expected_hash:
        print("error: Package.resolved changed during package resolution", file=sys.stderr)
        return False
    return True


def resolve_packages(xcodebuild: str, project: str, package_directory: str,
                     package_lock: Path, expected_hash: str,
                     derived_data_path=None) -> int:
    command = [
        xcodebuild, "-resolvePackageDependencies", "-project", project,
        "-scheme", "QuickFile", "-clonedSourcePackagesDirPath", package_directory,
        "-disableAutomaticPackageResolution",
    ]
    if derived_data_path is not None:
        command.extend(["-derivedDataPath", derived_data_path])
    for attempt in range(1, 4):
        print(f"Resolving pinned packages (attempt {attempt}/3)", flush=True)
        timeout_seen = False
        other_error_seen = False
        resolution_error_seen = False
        # Stream and classify each line; never retain whole attempts in memory.
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, errors="replace") as process:
            assert process.stdout is not None
            for line in process.stdout:
                print(line, end="", flush=True)
                diagnostic = line.strip()
                if diagnostic == RESOLUTION_ERROR:
                    resolution_error_seen = True
                elif BINARY_DOWNLOAD_TIMEOUT.fullmatch(diagnostic):
                    timeout_seen = True
                elif diagnostic == "fatalError":
                    # SwiftPM appends this summary to the specific diagnostics.
                    pass
                elif ((resolution_error_seen and diagnostic)
                      or OTHER_ERROR.search(diagnostic)):
                    other_error_seen = True
            returncode = process.wait()

        # Check every completed attempt before accepting success or retrying.
        if not lock_is_unchanged(package_lock, expected_hash):
            return 1
        if returncode < 0:
            return 128 - returncode
        if returncode == 0:
            return 0
        if not timeout_seen or other_error_seen or attempt == 3:
            return returncode
        delay = attempt * 2
        print(f"Binary package download timed out; retrying in {delay} seconds", flush=True)
        time.sleep(delay)
    raise AssertionError("unreachable package resolution attempt")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcodebuild", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--package-directory", required=True)
    parser.add_argument("--derived-data-path")
    parser.add_argument("--package-lock", required=True, type=Path)
    parser.add_argument("--expected-lock-hash", required=True)
    args = parser.parse_args()
    return resolve_packages(args.xcodebuild, args.project, args.package_directory,
                            args.package_lock, args.expected_lock_hash, args.derived_data_path)


if __name__ == "__main__":
    sys.exit(main())
