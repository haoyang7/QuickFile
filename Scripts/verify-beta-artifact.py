#!/usr/bin/env python3
"""Read-only checks for a QuickFile beta application bundle."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable, Sequence


EXPECTED_APP_ID = "com.haoyoung.QuickFile"
EXPECTED_EXTENSION_ID = "com.haoyoung.QuickFile.FinderExtension"
EXPECTED_APP_GROUP = "group.com.haoyoung.QuickFile"
EXPECTED_ARCHITECTURES = {"arm64", "x86_64"}
EXPECTED_EXECUTABLES = {"app": "QuickFile", "finder_extension": "FinderExtension"}
COMMAND_TIMEOUT_SECONDS = 20


class CommandResult:
    def __init__(self, returncode: int, stdout: bytes = b"", stderr: bytes = b"", error: str | None = None):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.error = error


class CommandRunner:
    def run(self, arguments: Sequence[str]) -> CommandResult:
        try:
            completed = subprocess.run(
                list(arguments),
                capture_output=True,
                check=False,
                timeout=COMMAND_TIMEOUT_SECONDS,
            )
            return CommandResult(completed.returncode, completed.stdout, completed.stderr)
        except subprocess.TimeoutExpired:
            return CommandResult(-1, error="timeout")
        except OSError:
            return CommandResult(-1, error="unavailable")


def _text(result: CommandResult) -> str:
    return (result.stdout + b"\n" + result.stderr).decode("utf-8", errors="replace")


def _check(name: str, passed: bool | None, detail: str) -> dict[str, Any]:
    return {
        "name": name,
        "status": "pass" if passed is True else "fail" if passed is False else "unknown",
        "detail": detail,
    }


def _run_check(runner: CommandRunner, name: str, arguments: Sequence[str]) -> dict[str, Any]:
    result = runner.run(arguments)
    if result.error:
        return _check(name, None, result.error)
    return _check(name, result.returncode == 0, "accepted" if result.returncode == 0 else "rejected")


def _architecture_check(runner: CommandRunner, binary: Path, name: str) -> tuple[dict[str, Any], list[str]]:
    result = runner.run(["/usr/bin/lipo", "-archs", str(binary)])
    if result.error:
        return _check(name, None, result.error), []
    if result.returncode != 0:
        return _check(name, False, "lipo rejected binary"), []
    matches = set(_text(result).split()) == EXPECTED_ARCHITECTURES
    architectures = sorted(EXPECTED_ARCHITECTURES) if matches else ["invalid"]
    return _check(name, matches, "arm64 and x86_64" if matches else "must contain exactly arm64 and x86_64"), architectures


def _read_plist(path: Path) -> dict[str, Any] | None:
    try:
        with path.open("rb") as stream:
            value = plistlib.load(stream)
        return value if isinstance(value, dict) else None
    except (OSError, plistlib.InvalidFileException):
        return None


def _parse_plist(data: bytes) -> dict[str, Any] | None:
    try:
        value = plistlib.loads(data)
        return value if isinstance(value, dict) else None
    except (ValueError, plistlib.InvalidFileException):
        return None


def _signature_metadata(
    runner: CommandRunner, bundle: Path, architecture: str | None = None
) -> tuple[dict[str, str] | None, str | None]:
    result = runner.run(["/usr/bin/codesign", "-d", "--verbose=4", *(["--arch", architecture] if architecture else []), str(bundle)])
    if result.error:
        return None, result.error
    if result.returncode != 0:
        return None, "codesign rejected"
    values: dict[str, str] = {}
    authorities: list[str] = []
    for line in _text(result).splitlines():
        if line.startswith("Authority="):
            authorities.append(line.partition("=")[2])
        elif line.startswith("TeamIdentifier="):
            values["team"] = line.partition("=")[2]
        elif line.startswith("Identifier="):
            values["identifier"] = line.partition("=")[2]
        elif line.startswith("CodeDirectory "):
            flags = re.search(r"\bflags=0x([0-9a-fA-F]+)\b", line)
            values["hardened_runtime"] = "yes" if flags and int(flags[1], 16) & 0x10000 else "no"
    authority = authorities[0] if authorities else ""
    if authority.startswith("Developer ID Application:"):
        values["certificate_kind"] = "developer-id-application"
    elif authority.startswith("Apple Development:"):
        values["certificate_kind"] = "apple-development"
    elif authority.startswith("Apple Distribution:"):
        values["certificate_kind"] = "apple-distribution"
    else:
        values["certificate_kind"] = "other-or-unsigned"
    return values, None


def _entitlements(
    runner: CommandRunner, bundle: Path, architecture: str | None = None
) -> tuple[dict[str, Any] | None, str | None]:
    result = runner.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", *(["--arch", architecture] if architecture else []), str(bundle)])
    if result.error:
        return None, result.error
    if result.returncode != 0:
        return None, "codesign rejected"
    plist = _parse_plist(result.stdout)
    if plist is None:
        # Some codesign versions write the entitlement plist to stderr.
        start = result.stderr.find(b"<?xml")
        plist = _parse_plist(result.stderr[start:]) if start >= 0 else None
    return (plist, None) if plist is not None else (None, "invalid entitlements")


def _all_architecture_values(
    runner: CommandRunner,
    bundle: Path,
    read: Callable[..., tuple[dict[str, Any] | None, str | None]],
) -> tuple[dict[str, Any] | None, str | None]:
    # codesign display defaults to the native slice even after universal verification.
    results = [(architecture, *read(runner, bundle, architecture)) for architecture in sorted(EXPECTED_ARCHITECTURES)]
    errors = [f"{architecture}: {error or 'unavailable'}" for architecture, values, error in results if values is None]
    if errors:
        return None, "; ".join(errors)
    values = [value for _, value, _ in results if value is not None]
    # Existing gates can accept a value only if every slice agrees, including its
    # plist type (an integer 1 must not stand in for a boolean entitlement).
    def matches(key: str, value: Any, other: Any) -> bool:
        if type(other) is not type(value):
            return False
        # The updater gate defines this list as a set of permitted services.
        # Other arrays retain their existing ordered comparison.
        if (key == "com.apple.security.temporary-exception.mach-lookup.global-name"
                and isinstance(value, list) and all(isinstance(item, str) for item in value + other)):
            return set(other) == set(value)
        return other == value

    common = {
        key: value for key, value in values[0].items()
        if all(key in other and matches(key, value, other[key]) for other in values[1:])
    }
    return common, None


def _version_is_13(value: Any) -> bool:
    return isinstance(value, str) and value == "13.0"


def _safe_version(value: Any) -> str | None:
    if isinstance(value, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
        return value
    return None


def _safe_minimum_system_version(value: Any) -> str | int | float:
    # Preserve safe input and its type for diagnostics without echoing arbitrary
    # plist content. A numeric input is reportable but never a valid OS gate.
    if type(value) in (int, float) and math.isfinite(value):
        return value
    return _safe_version(value) or "invalid"


def _sha256(path: Path) -> str | None:
    try:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return None


def _profile_summary(
    runner: CommandRunner, path: Path, now: dt.datetime
) -> tuple[dict[str, Any], dict[str, Any] | None, str | None]:
    result = runner.run(["/usr/bin/security", "cms", "-D", "-i", str(path)])
    if result.error:
        return {"decode_status": "unknown", "error": result.error}, None, result.error
    if result.returncode != 0:
        return {"decode_status": "fail", "error": "decode rejected"}, None, "decode rejected"
    profile = _parse_plist(result.stdout)
    if profile is None:
        return {"decode_status": "unknown", "error": "invalid plist"}, None, "invalid plist"
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        return {"decode_status": "unknown", "error": "missing expiration"}, profile, "missing expiration"
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=dt.timezone.utc)
    remaining = (expiration - now).total_seconds() / 86400
    devices = profile.get("ProvisionedDevices")
    summary = {
        "decode_status": "pass",
        "expiration": expiration.isoformat(),
        "remaining_days": round(remaining, 3),
        "device_count": len(devices) if isinstance(devices, list) else 0,
        "all_devices": profile.get("ProvisionsAllDevices") is True,
    }
    return summary, profile, None


def _profile_groups(profile: dict[str, Any]) -> list[Any]:
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        return []
    groups = entitlements.get("com.apple.security.application-groups")
    return groups if isinstance(groups, list) else []


def _profile_teams(profile: dict[str, Any]) -> list[Any]:
    teams = profile.get("TeamIdentifier")
    return teams if isinstance(teams, list) else []


def _profile_application_identifier(profile: dict[str, Any]) -> str | None:
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        return None
    for key in ("com.apple.application-identifier", "application-identifier"):
        value = entitlements.get(key)
        if isinstance(value, str):
            return value
    return None


def _application_identifier_matches(allowed: str | None, signed: str | None) -> bool:
    if not allowed or not signed:
        return False
    if allowed == signed:
        return True
    if allowed.endswith(".*"):
        return signed.startswith(allowed[:-1])
    return False


def _leaf_certificate_matches_profile(
    runner: CommandRunner, bundle: Path, profile: dict[str, Any] | None, architecture: str | None = None
) -> tuple[bool | None, str]:
    certificates = profile.get("DeveloperCertificates") if profile else None
    if not isinstance(certificates, list) or not certificates or not all(isinstance(item, bytes) for item in certificates):
        return False, "profile developer certificates are missing or invalid"
    with tempfile.TemporaryDirectory(prefix="quickfile-beta-cert-") as directory:
        prefix = Path(directory) / "certificate"
        result = runner.run([
            "/usr/bin/codesign",
            "-d",
            f"--extract-certificates={prefix}",
            *(["--arch", architecture] if architecture else []),
            str(bundle),
        ])
        if result.error:
            return None, result.error
        if result.returncode != 0:
            return False, "leaf certificate extraction failed"
        try:
            leaf = Path(f"{prefix}0").read_bytes()
        except OSError:
            return False, "leaf certificate is missing or unreadable"
    if not leaf:
        return False, "leaf certificate is empty"
    matches = any(leaf == certificate for certificate in certificates)
    return matches, "signing leaf certificate is authorized by profile" if matches else "signing leaf certificate is not authorized by profile"


def inspect_artifact(
    app: Path,
    mode: str,
    runner: CommandRunner | None = None,
    now: dt.datetime | None = None,
    min_valid_days: float = 8,
) -> dict[str, Any]:
    runner = runner or CommandRunner()
    now = now or dt.datetime.now(dt.timezone.utc)
    extension = app / "Contents/PlugIns/FinderExtension.appex"
    bundles = [("app", app, EXPECTED_APP_ID), ("finder_extension", extension, EXPECTED_EXTENSION_ID)]
    checks: list[dict[str, Any]] = []
    components: dict[str, Any] = {}
    signed_entitlements: dict[str, dict[str, Any] | None] = {}

    for label, bundle, expected_id in bundles:
        info = _read_plist(bundle / "Contents/Info.plist")
        if info is None:
            checks.append(_check(f"{label}.bundle", None, "missing or invalid Info.plist"))
            components[label] = {"bundle_id": None, "minimum_system_version": None}
            continue
        bundle_id = info.get("CFBundleIdentifier")
        minimum = info.get("LSMinimumSystemVersion")
        version = _safe_version(info.get("CFBundleShortVersionString"))
        build = _safe_version(info.get("CFBundleVersion"))
        expected_executable = EXPECTED_EXECUTABLES[label]
        executable_matches = info.get("CFBundleExecutable") == expected_executable
        bundle_id_matches = bundle_id == expected_id
        version_matches = _version_is_13(minimum)
        components[label] = {
            "bundle_id": expected_id if bundle_id_matches else "invalid",
            "minimum_system_version": _safe_minimum_system_version(minimum),
            "version": version or "invalid",
            "build": build or "invalid",
            "executable": expected_executable if executable_matches else "invalid",
        }
        checks.append(_check(f"{label}.bundle_id", bundle_id_matches, "matches expected ID" if bundle_id_matches else "unexpected ID"))
        checks.append(_check(f"{label}.minimum_system_version", version_matches, "13.0" if version_matches else "must be the string 13.0"))
        checks.append(_check(f"{label}.version", version is not None, "valid" if version is not None else "missing or invalid version"))
        checks.append(_check(f"{label}.build", build is not None, "valid" if build is not None else "missing or invalid build"))
        checks.append(_check(f"{label}.executable", executable_matches, "matches expected executable" if executable_matches else "unexpected executable"))
        checks.append(_run_check(runner, f"{label}.strict_signature", ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "--verbose=2", str(bundle)]))

        metadata, metadata_error = _all_architecture_values(runner, bundle, _signature_metadata)
        if metadata is None:
            checks.append(_check(f"{label}.signature_metadata", None, metadata_error or "unavailable"))
            components[label].update({"signature_identifier": None, "certificate_kind": "unknown"})
        else:
            signature_identifier_matches = metadata.get("identifier") == expected_id
            components[label].update({
                "signature_identifier": expected_id if signature_identifier_matches else "invalid",
                "certificate_kind": metadata.get("certificate_kind", "invalid"),
                "_team": metadata.get("team"),
            })
            checks.append(_check(f"{label}.signature_identifier", signature_identifier_matches, "matches bundle ID" if signature_identifier_matches else "does not match bundle ID"))
        runtime = metadata is not None and metadata.get("hardened_runtime") == "yes"
        checks.append(_check(f"{label}.hardened_runtime", runtime if metadata is not None else None, "enabled" if runtime else metadata_error or "missing Hardened Runtime"))

        entitlements, entitlement_error = _all_architecture_values(runner, bundle, _entitlements)
        signed_entitlements[label] = entitlements
        groups = entitlements.get("com.apple.security.application-groups") if entitlements else None
        group_matches = isinstance(groups, list) and groups == [EXPECTED_APP_GROUP]
        checks.append(_check(f"{label}.app_group", group_matches if entitlements is not None else None, "matches expected App Group" if group_matches else entitlement_error or "unexpected App Group"))
        components[label]["app_group_matches"] = group_matches

        binary = bundle / "Contents/MacOS" / expected_executable
        binary_hash = _sha256(binary)
        components[label]["binary_sha256"] = binary_hash or "unavailable"
        checks.append(_check(f"{label}.binary_sha256", binary_hash is not None, "computed" if binary_hash is not None else "binary unavailable"))
        architecture_check, architectures = _architecture_check(runner, binary, f"{label}.architectures")
        checks.append(architecture_check)
        components[label]["architectures"] = architectures

    versions_match = (
        components.get("app", {}).get("version") != "invalid"
        and components.get("app", {}).get("version") == components.get("finder_extension", {}).get("version")
    )
    builds_match = (
        components.get("app", {}).get("build") != "invalid"
        and components.get("app", {}).get("build") == components.get("finder_extension", {}).get("build")
    )
    checks.append(_check("components.version_match", versions_match, "versions match" if versions_match else "app and extension versions differ"))
    checks.append(_check("components.build_match", builds_match, "builds match" if builds_match else "app and extension builds differ"))

    teams = [components.get(label, {}).get("_team") for label in ("app", "finder_extension")]
    same_team = bool(teams[0]) and teams[0] == teams[1]
    checks.append(_check("signing.same_team", same_team, "same signing team" if same_team else "missing or different signing team"))
    sparkle = app / "Contents/Frameworks/Sparkle.framework"
    app_info = _read_plist(app / "Contents/Info.plist") or {}
    if app_info.get("QuickFileUpdatesEnabled") in (True, "YES"):
        checks.append(_check("sparkle.framework_required", sparkle.exists(), "embedded" if sparkle.exists() else "online updates require Sparkle.framework"))
    if sparkle.exists():
        helpers = {
            "framework": sparkle,
            "installer": sparkle / "Versions/B/XPCServices/Installer.xpc",
            "downloader": sparkle / "Versions/B/XPCServices/Downloader.xpc",
            "autoupdate": sparkle / "Versions/B/Autoupdate",
            "updater": sparkle / "Versions/B/Updater.app",
        }
        binaries = {
            "framework": sparkle / "Versions/B/Sparkle",
            "installer": helpers["installer"] / "Contents/MacOS/Installer",
            "downloader": helpers["downloader"] / "Contents/MacOS/Downloader",
            "autoupdate": helpers["autoupdate"],
            "updater": helpers["updater"] / "Contents/MacOS/Updater",
        }
        for label, helper in helpers.items():
            name = f"sparkle.{label}"
            checks.append(_check(f"{name}.embedded", helper.exists(), "embedded" if helper.exists() else "missing helper"))
            if not helper.exists():
                continue
            architecture_check, _ = _architecture_check(runner, binaries[label], f"{name}.architectures")
            checks.append(architecture_check)
            checks.append(_run_check(runner, f"{name}.strict_signature", ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "--verbose=2", str(helper)]))
            metadata, error = _all_architecture_values(runner, helper, _signature_metadata)
            team_matches = metadata is not None and bool(teams[0]) and metadata.get("team") == teams[0]
            checks.append(_check(f"{name}.signing_team", team_matches if metadata is not None else None, "same signing team as app" if team_matches else error or "helper has missing or different signing team"))
            certificate_matches = metadata is not None and metadata.get("certificate_kind") == components["app"].get("certificate_kind")
            checks.append(_check(f"{name}.certificate_kind", certificate_matches if metadata is not None else None, "matches app distribution certificate kind" if certificate_matches else error or "helper certificate kind differs from app"))
            runtime = metadata is not None and metadata.get("hardened_runtime") == "yes"
            checks.append(_check(f"{name}.hardened_runtime", runtime if metadata is not None else None, "enabled" if runtime else error or "helper is missing Hardened Runtime"))
        app_entitlements = signed_entitlements.get("app")
        expected_services = {f"{EXPECTED_APP_ID}-spks", f"{EXPECTED_APP_ID}-spki"}
        actual_services = app_entitlements.get("com.apple.security.temporary-exception.mach-lookup.global-name", []) if app_entitlements else []
        mach_access = isinstance(actual_services, list) and set(actual_services) == expected_services
        checks.append(_check("sparkle.mach_lookup", mach_access, "only updater services allowed" if mach_access else "missing or unexpected updater service exceptions"))
    signed_application_identifiers: dict[str, str | None] = {}
    for label, _, expected_id in bundles:
        entitlements = signed_entitlements.get(label)
        actual = entitlements.get("com.apple.application-identifier") if entitlements else None
        expected = f"{components.get(label, {}).get('_team')}.{expected_id}"
        matches = isinstance(actual, str) and actual == expected
        signed_application_identifiers[label] = actual if isinstance(actual, str) else None
        checks.append(_check(f"{label}.signature_application_identifier", matches, "matches signing team and bundle ID" if matches else "missing or incorrect signed application identifier"))

    expected_certificate = "developer-id-application" if mode == "developer-id" else "apple-development"
    certificate_kinds = [components.get(label, {}).get("certificate_kind") for label in ("app", "finder_extension")]
    certificates_match = all(kind == expected_certificate for kind in certificate_kinds)
    checks.append(_check("distribution.certificate_kind", certificates_match, f"requires {expected_certificate}"))

    profiles: list[dict[str, Any]] = []
    decoded_profiles: list[tuple[str, dict[str, Any]]] = []
    for label, bundle, _ in bundles:
        profile_path = bundle / "Contents/embedded.provisionprofile"
        if not profile_path.exists():
            continue
        summary, decoded, error = _profile_summary(runner, profile_path, now)
        summary["component"] = label
        profiles.append(summary)
        if decoded is not None:
            decoded_profiles.append((label, decoded))
        expiration = decoded.get("ExpirationDate") if decoded else None
        if isinstance(expiration, dt.datetime) and expiration.tzinfo is None:
            expiration = expiration.replace(tzinfo=dt.timezone.utc)
        exact_remaining = (expiration - now).total_seconds() / 86400 if isinstance(expiration, dt.datetime) else None
        valid = isinstance(exact_remaining, float) and exact_remaining >= min_valid_days
        checks.append(_check(f"{label}.profile_validity", valid if error is None else None, f"at least {min_valid_days:g} days remaining" if valid else error or f"requires at least {min_valid_days:g} days remaining"))

    profiles_present = len(decoded_profiles) == 2
    checks.append(_check("distribution.embedded_profiles", profiles_present, "profiles present for app and extension" if profiles_present else "app and extension profiles are required for this App Group"))
    profile_group_match = profiles_present and all(
        EXPECTED_APP_GROUP in _profile_groups(profile)
        for _, profile in decoded_profiles
    )
    checks.append(_check("distribution.profile_app_group", profile_group_match, "profile App Groups authorize signed App Group" if profile_group_match else "profile App Group authorization is missing"))
    profile_team_match = profiles_present and all(
        components[label].get("_team") in _profile_teams(profile)
        for label, profile in decoded_profiles
    )
    checks.append(_check("distribution.profile_team", profile_team_match, "profile teams match signatures" if profile_team_match else "profile team does not match signature"))
    profile_app_id_match = profiles_present and all(
        _application_identifier_matches(
            _profile_application_identifier(profile),
            signed_application_identifiers.get(label),
        )
        for label, profile in decoded_profiles
    )
    checks.append(_check("distribution.profile_application_identifier", profile_app_id_match, "profile App IDs authorize signed identifiers" if profile_app_id_match else "profile App ID authorization is missing"))
    profiles_by_label = dict(decoded_profiles)
    for label, bundle, _ in bundles:
        certificate_results = [
            (architecture, *_leaf_certificate_matches_profile(runner, bundle, profiles_by_label.get(label), architecture))
            for architecture in sorted(EXPECTED_ARCHITECTURES)
        ]
        if any(match is False for _, match, _ in certificate_results):
            certificate_match = False
        elif any(match is None for _, match, _ in certificate_results):
            certificate_match = None
        else:
            certificate_match = True
        detail = "; ".join(f"{architecture}: {message}" for architecture, _, message in certificate_results)
        checks.append(_check(f"{label}.profile_leaf_certificate", certificate_match, detail))

    entitlement_requirements = {
        "app": {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.files.bookmarks.app-scope": True,
            "com.apple.security.files.user-selected.read-write": True,
        },
        "finder_extension": {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.files.bookmarks.app-scope": True,
        },
    }
    for label, bundle, _ in bundles:
        entitlements = signed_entitlements.get(label)
        error = None if entitlements is not None else "signed entitlements unavailable"
        for key, expected in entitlement_requirements[label].items():
            suffix = key.removeprefix("com.apple.security.").replace(".", "_")
            matches = entitlements is not None and entitlements.get(key) is expected
            checks.append(_check(f"{label}.entitlement.{suffix}", matches if entitlements is not None else None, "enabled" if matches else error or "required entitlement is missing"))

    intersection_count = 0
    if mode == "registered-devices":
        device_scoped = profiles_present and all(
            isinstance(profile.get("ProvisionedDevices"), list)
            and len(profile["ProvisionedDevices"]) > 0
            and profile.get("ProvisionsAllDevices") is not True
            for _, profile in decoded_profiles
        )
        checks.append(_check("distribution.registered_devices_only", device_scoped, "limited to registered devices" if device_scoped else "profile device scope is invalid"))
        if profiles_present:
            device_sets = [set(profile.get("ProvisionedDevices", [])) for _, profile in decoded_profiles]
            intersection_count = len(device_sets[0].intersection(device_sets[1]))
        checks.append(_check("distribution.registered_device_intersection", intersection_count > 0, "profiles share at least one registered device" if intersection_count > 0 else "profiles have no registered device in common"))
    else:
        status = runner.run(["/usr/sbin/spctl", "--status"])
        enabled = status.error is None and status.returncode == 0 and "assessments enabled" in _text(status).lower()
        checks.append(_check("gatekeeper.assessments_enabled", enabled if status.error is None else None, "enabled" if enabled else status.error or "disabled or indeterminate"))
        assessment = runner.run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", str(app)])
        assessment_text = _text(assessment).lower()
        accepted = assessment.error is None and assessment.returncode == 0 and "accepted" in assessment_text
        notarized = "source=notarized developer id" in assessment_text
        no_override = "override=" not in assessment_text
        # Neither a local policy override nor disabled global assessment can establish distribution readiness.
        effective = accepted and notarized and no_override and enabled
        checks.append(_check("gatekeeper.artifact_assessment", effective if assessment.error is None else None, "accepted as Notarized Developer ID with assessments enabled" if effective else assessment.error or "requires enabled assessment, no override, and Notarized Developer ID source"))

    for component in components.values():
        component.pop("_team", None)

    passed = all(check["status"] == "pass" for check in checks)
    return {
        "schema_version": 1,
        "checked_at": now.astimezone(dt.timezone.utc).isoformat(),
        "artifact": "QuickFile.app" if app.name == "QuickFile.app" else "invalid-app-bundle",
        "mode": mode,
        "minimum_profile_valid_days": min_valid_days,
        "verdict": "pass" if passed else "fail",
        "verdict_scope": "artifact checks only; this does not establish complete Beta readiness or success on other devices",
        "device_scope": "registered devices only" if mode == "registered-devices" else "artifact assessment on this Mac only",
        "registered_device_intersection_count": intersection_count if mode == "registered-devices" else None,
        "device_scope_limit": "does not establish coverage for every planned tester",
        "components": components,
        "profiles": profiles,
        "checks": checks,
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="path to QuickFile.app")
    parser.add_argument("--output", type=Path, required=True, help="JSON report path")
    parser.add_argument("--mode", choices=("developer-id", "registered-devices"), default="developer-id")
    parser.add_argument("--min-valid-days", type=float, default=8, help="minimum profile validity window (default: 8)")
    arguments = parser.parse_args(argv)
    if not math.isfinite(arguments.min_valid_days) or arguments.min_valid_days < 0:
        parser.error("--min-valid-days must be a finite non-negative number")
    try:
        arguments.output.resolve().relative_to(arguments.app.resolve())
    except ValueError:
        pass
    else:
        parser.error("--output must be outside the application bundle")
    report = inspect_artifact(arguments.app, arguments.mode, min_valid_days=arguments.min_valid_days)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"{report['verdict']}: wrote {arguments.output}")
    return 0 if report["verdict"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
