#!/usr/bin/env python3
"""Verify release settings from one xcodebuild -alltargets -showBuildSettings -json run."""

from __future__ import annotations

import argparse
import json
import sys


TARGETS = (
    "QuickFile",
    "QuickFileCore",
    "QuickFileInfrastructure",
    "QuickFileApplication",
    "FinderExtension",
    "QuickFileTests",
)


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key in build settings JSON")
        result[key] = value
    return result


def verify_settings(payload: object, expected_macos_version: str) -> list[str]:
    if not isinstance(payload, list) or not payload:
        raise ValueError("build settings must be a non-empty array")

    targets = {}
    for entry in payload:
        if not isinstance(entry, dict):
            raise ValueError("invalid build settings entry")
        target = entry.get("target")
        settings = entry.get("buildSettings")
        if not isinstance(target, str) or not target or not isinstance(settings, dict):
            raise ValueError("each entry must contain a target and buildSettings object")
        # Xcode may emit a target more than once for an all-targets query.
        # Keep every occurrence so a valid entry cannot hide an invalid one.
        targets.setdefault(target, []).append(settings)

    checks = [
        ("QuickFile", "ENABLE_HARDENED_RUNTIME", "YES", "QuickFile Hardened Runtime"),
        ("FinderExtension", "ENABLE_HARDENED_RUNTIME", "YES", "FinderExtension Hardened Runtime"),
        ("QuickFile", "ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon", "QuickFile app icon set"),
    ]
    checks.extend(
        (target, "APPLICATION_EXTENSION_API_ONLY", "YES", f"{target} extension-safe APIs")
        for target in ("QuickFileCore", "QuickFileInfrastructure", "QuickFileApplication", "FinderExtension")
    )
    checks.extend(
        (target, "MACOSX_DEPLOYMENT_TARGET", expected_macos_version, f"{target} minimum macOS version")
        for target in TARGETS
    )
    results = []
    for target, setting, expected, label in checks:
        if target not in targets:
            raise ValueError(f"missing build settings for {target}")
        for settings in targets[target]:
            actual = settings.get(setting)
            if not isinstance(actual, str) or actual != expected:
                # Do not echo arbitrary values from the full settings payload.
                raise ValueError(f"{label} expected {expected}; setting is missing or mismatched")
        results.append(f"{label}: {expected}")
    return results


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-macos-version", required=True)
    arguments = parser.parse_args(argv)
    try:
        payload = json.load(sys.stdin, object_pairs_hook=unique_object)
        results = verify_settings(payload, arguments.expected_macos_version)
    except (ValueError, UnicodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    for result in results:
        print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
