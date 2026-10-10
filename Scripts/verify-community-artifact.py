#!/usr/bin/env python3
"""Read-only checks of experimental, ad-hoc QuickFile community artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
from pathlib import Path

APP_ID = "com.haoyoung.QuickFile"
EXTENSION_ID = APP_ID + ".FinderExtension"
APP_GROUP = "group." + APP_ID
ARCHITECTURES = ("arm64", "x86_64")
SPARKLE = "Contents/Frameworks/Sparkle.framework"
SPARKLE_COMPONENTS = (
    ("installer", SPARKLE + "/Versions/B/XPCServices/Installer.xpc", "Contents/MacOS/Installer"),
    ("downloader", SPARKLE + "/Versions/B/XPCServices/Downloader.xpc", "Contents/MacOS/Downloader"),
    ("autoupdate", SPARKLE + "/Versions/B/Autoupdate", ""),
    ("updater", SPARKLE + "/Versions/B/Updater.app", "Contents/MacOS/Updater"),
    ("framework", SPARKLE, "Versions/B/Sparkle"),
)
COMPONENTS = (
    ("finder_extension", "Contents/PlugIns/FinderExtension.appex", "Contents/MacOS/FinderExtension"),
    ("app", "", "Contents/MacOS/QuickFile"),
)
FORBIDDEN_CLAIMS = {
    "com.apple.developer.team-identifier", "com.apple.application-identifier",
    "application-identifier", "get-task-allow", "com.apple.security.get-task-allow",
}
MACHO_MAGIC = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}


def run_command(arguments: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(arguments, capture_output=True, check=False, timeout=30)


def read_plist(path: Path) -> dict:
    with path.open("rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        raise ValueError("plist must contain a dictionary")
    return value


def expected_entitlements(label: str) -> dict:
    if label in ("app", "finder_extension"):
        value = {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.application-groups": [APP_GROUP],
            "com.apple.security.files.bookmarks.app-scope": True,
        }
        if label == "app":
            value["com.apple.security.files.user-selected.read-write"] = True
        return value
    return {}


def exact_entitlements(actual: dict, expected: dict) -> bool:
    # Python equality treats 1 as True; entitlement types are part of the contract.
    return plistlib.dumps(actual, sort_keys=True) == plistlib.dumps(expected, sort_keys=True)


def signature_entitlements(result: subprocess.CompletedProcess) -> dict:
    if result.returncode != 0:
        raise ValueError("codesign could not read entitlements")
    for data in (result.stdout, result.stderr):
        for marker in (b"<?xml", b"bplist00"):
            start = data.find(marker)
            if start >= 0:
                value = plistlib.loads(data[start:])
                if not isinstance(value, dict):
                    raise ValueError("invalid entitlement dictionary")
                return value
    if result.stdout.strip():
        raise ValueError("invalid entitlement output")
    return {}


def bundle_info(app: Path, label: str, relative: str) -> dict:
    if label == "autoupdate":
        return {"CFBundleIdentifier": "org.sparkle-project.Sparkle.Autoupdate", "CFBundleExecutable": "Autoupdate"}
    path = app / relative / ("Versions/B/Resources/Info.plist" if label == "framework" else "Contents/Info.plist")
    return read_plist(path)


def validate_configuration(app: Path, *, allow_sparkle_services=False) -> dict:
    info = read_plist(app / "Contents/Info.plist")
    extension = read_plist(app / "Contents/PlugIns/FinderExtension.appex/Contents/Info.plist")
    for values, identifier, executable in ((info, APP_ID, "QuickFile"), (extension, EXTENSION_ID, "FinderExtension")):
        if values.get("CFBundleIdentifier") != identifier or values.get("CFBundleExecutable") != executable:
            raise ValueError("unexpected QuickFile bundle identity")
        if values.get("LSMinimumSystemVersion") != "13.0":
            raise ValueError("minimum system version must be 13.0")
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            value = values.get(key)
            if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
                raise ValueError("invalid version or build")
            if value != info.get(key):
                raise ValueError("app and extension versions must match")
    if info.get("QuickFileUpdatesEnabled") not in (False, "NO") or type(info.get("QuickFileUpdatesEnabled")) not in (bool, str):
        raise ValueError("online updates must be explicitly disabled")
    for key in ("SUFeedURL", "SUPublicEDKey"):
        if info.get(key) != "":
            raise ValueError("community update feed and public key must be empty")
    for key in ("SUEnableAutomaticChecks", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling", "SUSendProfileInfo", "SUEnableJavaScript"):
        if info.get(key) is not False:
            raise ValueError("automatic update and profiling settings must be disabled")
    if not allow_sparkle_services:
        for key in ("SUEnableInstallerLauncherService", "SUEnableDownloaderService"):
            if info.get(key) is not False:
                raise ValueError("unused Sparkle services must be explicitly disabled")
    return info


def tree_manifest(app: Path) -> dict[str, dict]:
    """Include every regular byte and symlink, without following directory links."""
    root = app.resolve()
    manifest = {}
    def unreadable(error):
        raise error

    for directory, directories, files in os.walk(app, followlinks=False, onerror=unreadable):
        for name in sorted(directories + files):
            path = Path(directory) / name
            relative = path.relative_to(app).as_posix()
            mode = path.lstat().st_mode
            if path.is_symlink():
                target = os.readlink(path)
                if Path(target).is_absolute() or not path.resolve().is_relative_to(root) or not path.exists():
                    raise ValueError("bundle has an escaping or broken symlink")
                manifest[relative] = {"symlink": target}
            elif stat.S_ISREG(mode):
                manifest[relative] = {"sha256": sha256(path), "mode": stat.S_IMODE(mode)}
            elif stat.S_ISDIR(mode):
                manifest[relative] = {"directory": True, "mode": stat.S_IMODE(mode)}
            else:
                raise ValueError("unsupported bundle filesystem entry")
    return manifest


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_layout(app: Path, *, allow_sparkle=False) -> dict[str, dict]:
    if app.name != "QuickFile.app" or not app.is_dir() or app.is_symlink():
        raise ValueError("expected a QuickFile.app directory")
    manifest = tree_manifest(app)
    if any(Path(path).name == "embedded.provisionprofile" for path in manifest):
        raise ValueError("embedded provisioning profiles are forbidden")
    has_sparkle = allow_sparkle and (app / SPARKLE).exists()
    components = COMPONENTS + (SPARKLE_COMPONENTS if has_sparkle else ())
    expected_binaries = set()
    expected_bundles = {relative for label, relative, _ in components if relative and label != "autoupdate"}
    updater_alias = SPARKLE + "/Updater.app"
    if has_sparkle and updater_alias in manifest:
        entry = manifest[updater_alias]
        target = app.resolve() / SPARKLE / "Versions/B/Updater.app"
        if entry.get("symlink") != "Versions/Current/Updater.app" or (app / updater_alias).resolve() != target:
            raise ValueError("unexpected Sparkle Updater.app alias target")
        expected_bundles.add(updater_alias)
    for label, relative, binary in components:
        component = app / relative
        executable = component / binary if binary else component
        if not executable.is_file() or not component.exists():
            raise ValueError("missing required nested executable")
        expected_binaries.add(executable.relative_to(app).as_posix())
        info = bundle_info(app, label, relative)
        identifier = info.get("CFBundleIdentifier")
        if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9.-]+", identifier):
            raise ValueError("invalid nested bundle identifier")
        if info.get("CFBundleExecutable") != executable.name:
            raise ValueError("unexpected nested bundle executable")
    for relative, entry in manifest.items():
        path = Path(relative)
        if path.suffix in (".app", ".appex", ".xpc", ".framework") and relative not in expected_bundles:
            raise ValueError("unexpected nested code bundle")
        if "sha256" in entry:
            if entry["mode"] & 0o111 and relative not in expected_binaries:
                raise ValueError("unexpected executable file")
            with (app / relative).open("rb") as stream:
                if stream.read(4) in MACHO_MAGIC and relative not in expected_binaries:
                    raise ValueError("unexpected Mach-O executable")
    return manifest


def system_dependencies(binary: Path, architecture: str, runner=run_command) -> bool:
    result = runner(["/usr/bin/otool", "-arch", architecture, "-L", str(binary)])
    if result.returncode != 0:
        return False
    dependencies = []
    for line in result.stdout.decode().splitlines():
        if not line.strip() or line.rstrip().endswith(":"):
            continue
        match = re.fullmatch(r"\s+(.+) \(compatibility version .+, current version .+\)", line)
        if match is None:
            return False
        dependency = match[1]
        if not dependency.startswith(("/System/Library/", "/usr/lib/")) or ".." in Path(dependency).parts or "Sparkle" in dependency:
            return False
        dependencies.append(dependency)
    return bool(dependencies)


def inspect_artifact(app: Path, runner=run_command) -> dict:
    checks = []
    components = {}
    info = {}
    manifest = None

    def check(name: str, action):
        try:
            passed = action()
            checks.append({"name": name, "status": "pass" if passed else "fail"})
        except (OSError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError):
            checks.append({"name": name, "status": "fail"})

    try:
        manifest = validate_layout(app)
        info = validate_configuration(app)
        checks.append({"name": "configuration_and_layout", "status": "pass"})
    except (OSError, ValueError, plistlib.InvalidFileException):
        checks.append({"name": "configuration_and_layout", "status": "fail"})
    for label, relative, binary_relative in COMPONENTS:
        component = app / relative
        binary = component / binary_relative if binary_relative else component
        check(label + ".strict_signature", lambda component=component: runner([
            "/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "--verbose=2", str(component)
        ]).returncode == 0)
        check(label + ".architectures", lambda binary=binary: (
            (result := runner(["/usr/bin/lipo", "-archs", str(binary)])).returncode == 0
            and set(result.stdout.decode().split()) == set(ARCHITECTURES)
        ))
        try:
            identifier = bundle_info(app, label, relative)["CFBundleIdentifier"]
            components[label] = {"binary_sha256": sha256(binary)}
        except (OSError, ValueError, KeyError, plistlib.InvalidFileException):
            identifier = None
        for architecture in ARCHITECTURES:
            check(label + "." + architecture + ".system_dependencies", lambda binary=binary, architecture=architecture: system_dependencies(binary, architecture, runner))
            def metadata(component=component, identifier=identifier, architecture=architecture):
                result = runner(["/usr/bin/codesign", "-d", "--arch", architecture, "--verbose=4", str(component)])
                text = (result.stdout + b"\n" + result.stderr).decode(errors="replace")
                fields = dict(line.split("=", 1) for line in text.splitlines() if "=" in line and not line.startswith("CodeDirectory "))
                flags = re.search(r"^CodeDirectory .*\bflags=0x([0-9a-fA-F]+)\b", text, re.MULTILINE)
                return (
                    result.returncode == 0 and identifier is not None
                    and fields.get("Identifier") == identifier and fields.get("Signature") == "adhoc"
                    and fields.get("TeamIdentifier") == "not set"
                    and not any(line.startswith("Authority=") for line in text.splitlines())
                    and flags is not None and int(flags[1], 16) & 0x10000 != 0
                )
            check(label + "." + architecture + ".ad_hoc_runtime", metadata)
            def entitlements(component=component, label=label, architecture=architecture):
                actual = signature_entitlements(runner([
                    "/usr/bin/codesign", "-d", "--arch", architecture, "--entitlements", ":-", str(component)
                ]))
                return not FORBIDDEN_CLAIMS.intersection(actual) and exact_entitlements(actual, expected_entitlements(label))
            check(label + "." + architecture + ".entitlements", entitlements)
    return {
        "schema_version": 1, "scope": "artifact only", "trust": "ad-hoc/unnotarized",
        "verdict": "pass" if all(item["status"] == "pass" for item in checks) else "fail",
        "artifact": "QuickFile.app", "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
        "unproven": ["cross-machine launch", "Finder integration", "upgrades", "Gatekeeper acceptance"],
        "components": components, "checks": checks,
        "manifest_sha256": hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest() if manifest is not None else None,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args(argv)
    if arguments.output.resolve().is_relative_to(arguments.app.resolve()):
        parser.error("--output must be outside the application bundle")
    report = inspect_artifact(arguments.app)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(report["verdict"] + ": community artifact checks")
    return 0 if report["verdict"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
