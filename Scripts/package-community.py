#!/usr/bin/env python3
"""Package an unsigned Release QuickFile.app as an experimental ad-hoc DMG."""

from __future__ import annotations

import argparse
import ctypes
import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("community_artifact", Path(__file__).with_name("verify-community-artifact.py"))
ARTIFACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ARTIFACT)
DMG_SPEC = importlib.util.spec_from_file_location("community_dmg", Path(__file__).with_name("community_dmg.py"))
DMG = importlib.util.module_from_spec(DMG_SPEC)
DMG_SPEC.loader.exec_module(DMG)
TEMPORARY = Path(__file__).resolve().parents[1] / ".build/Temporary"


def expand_entitlements(value, identifier: str):
    if isinstance(value, str):
        expanded = value.replace("$(PRODUCT_BUNDLE_IDENTIFIER)", identifier)
        if "$" in expanded:
            raise ValueError("unknown entitlement placeholder")
        return expanded
    if isinstance(value, list):
        return [expand_entitlements(item, identifier) for item in value]
    if isinstance(value, dict):
        return {expand_entitlements(key, identifier): expand_entitlements(item, identifier) for key, item in value.items()}
    return value


def signing_entitlements() -> dict[str, dict]:
    root = Path(__file__).resolve().parents[1]
    result = {label: ARTIFACT.expected_entitlements(label) for label, _, _ in ARTIFACT.COMPONENTS}
    for label, source, identifier in (
        ("app", "QuickFileApp/QuickFile.entitlements", ARTIFACT.APP_ID),
        ("finder_extension", "FinderExtension/FinderExtension.entitlements", ARTIFACT.EXTENSION_ID),
    ):
        result[label] = expand_entitlements(ARTIFACT.read_plist(root / source), identifier)
        if label == "app":
            services = result[label].pop("com.apple.security.temporary-exception.mach-lookup.global-name", None)
            if services != [ARTIFACT.APP_ID + "-spks", ARTIFACT.APP_ID + "-spki"]:
                raise ValueError("project Sparkle service entitlements differ from the controlled contract")
        if not ARTIFACT.exact_entitlements(result[label], ARTIFACT.expected_entitlements(label)):
            raise ValueError("project entitlements differ from the controlled community contract")
    return result


def run(arguments: list[str]) -> None:
    subprocess.run(arguments, check=True, timeout=300, capture_output=True)


def publish_directory(source: Path, destination: Path) -> None:
    """Atomically publish on the same filesystem, refusing even an empty target."""
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        operation = library.renamex_np
        operation.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        arguments = (os.fsencode(source), os.fsencode(destination), 0x4)  # RENAME_EXCL
    elif sys.platform.startswith("linux"):
        operation = library.renameat2
        operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        arguments = (-100, os.fsencode(source), -100, os.fsencode(destination), 1)  # RENAME_NOREPLACE
    else:
        raise ValueError("atomic no-overwrite publication requires macOS or Linux")
    operation.restype = ctypes.c_int
    if operation(*arguments) != 0:
        number = ctypes.get_errno()
        raise OSError(number, "could not publish community output without overwriting")


def unsigned_build_component(component: Path, architecture: str) -> bool:
    result = ARTIFACT.run_command(["/usr/bin/codesign", "-d", "--arch", architecture, "--verbose=4", str(component)])
    if result.returncode != 0:
        return b"code object is not signed at all" in result.stderr
    text = (result.stdout + b"\n" + result.stderr).decode(errors="replace")
    fields = dict(line.split("=", 1) for line in text.splitlines() if "=" in line and not line.startswith("CodeDirectory "))
    flags = re.search(r"^CodeDirectory .*\bflags=0x([0-9a-fA-F]+)\b", text, re.MULTILINE)
    # The linker may add a minimal ad-hoc CodeDirectory even when Xcode bundle
    # signing is disabled. It binds neither Info.plist nor resources/entitlements.
    linker_signed = (
        flags is not None and int(flags[1], 16) == 0x20002
        and fields.get("Signature") == "adhoc" and fields.get("TeamIdentifier") == "not set"
        and fields.get("Info.plist") == "not bound" and fields.get("Sealed Resources") == "none"
        and not any(line.startswith("Authority=") for line in text.splitlines())
    )
    if not linker_signed:
        return False
    entitlements = ARTIFACT.signature_entitlements(ARTIFACT.run_command([
        "/usr/bin/codesign", "-d", "--arch", architecture, "--entitlements", ":-", str(component),
    ]))
    return entitlements == {}


def package(arguments: argparse.Namespace) -> dict:
    raw_output = arguments.output.absolute()
    if raw_output.exists() or raw_output.is_symlink():
        raise ValueError("output directory already exists")
    app = arguments.app.resolve()
    output = raw_output.resolve()
    if output == app or app in output.parents or output in app.parents:
        raise ValueError("input and output paths must not overlap")
    applications = Path("/Applications")
    if app.is_relative_to(applications) or output.is_relative_to(applications):
        raise ValueError("community packaging must use paths outside /Applications")
    input_manifest = ARTIFACT.validate_layout(app, allow_sparkle=True)
    info = ARTIFACT.validate_configuration(app, allow_sparkle_services=True)
    for label, relative, binary_relative in ARTIFACT.COMPONENTS:
        binary = app / relative / binary_relative
        for architecture in ARTIFACT.ARCHITECTURES:
            if not unsigned_build_component(app / relative, architecture):
                raise ValueError("community input must have an unsigned or bare linker-signed host and Finder extension; use Scripts/build-community.sh")
            if not ARTIFACT.system_dependencies(binary, architecture):
                raise ValueError("community input still links Sparkle or non-system code; rebuild with Scripts/build-community.sh")
    entitlements = signing_entitlements()
    output.parent.mkdir(parents=True, exist_ok=True)
    TEMPORARY.mkdir(parents=True, exist_ok=True)
    # Keep app copies in the repository's temporary area; delivery staging must
    # share the destination filesystem for atomic no-overwrite publication.
    with tempfile.TemporaryDirectory(prefix="community-package-", dir=TEMPORARY) as temporary, \
            tempfile.TemporaryDirectory(prefix=".quickfile-community-", dir=output.parent) as delivery_temporary:
        staging = Path(temporary)
        copied = staging / "signed" / "QuickFile.app"
        copied.parent.mkdir()
        run(["/usr/bin/ditto", str(app), str(copied)])
        if ARTIFACT.tree_manifest(copied) != input_manifest:
            raise ValueError("input copy did not preserve bundle bytes and symlinks")
        sparkle = copied / ARTIFACT.SPARKLE
        if sparkle.exists():
            shutil.rmtree(sparkle)
        copied_info = ARTIFACT.read_plist(copied / "Contents/Info.plist")
        copied_info.update({"SUEnableInstallerLauncherService": False, "SUEnableDownloaderService": False})
        (copied / "Contents/Info.plist").write_bytes(plistlib.dumps(copied_info))
        ARTIFACT.validate_layout(copied)
        for label, relative, _ in ARTIFACT.COMPONENTS:
            configuration = staging / (label + ".entitlements")
            configuration.write_bytes(plistlib.dumps(entitlements[label]))
            identifier = ARTIFACT.bundle_info(copied, label, relative)["CFBundleIdentifier"]
            run([
                "/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none",
                "--identifier", identifier, "--entitlements", str(configuration), str(copied / relative),
            ])
        report = ARTIFACT.inspect_artifact(copied)
        if report["verdict"] != "pass":
            raise ValueError("signed community artifact failed verification")
        delivery = Path(delivery_temporary) / "delivery"
        delivery.mkdir()
        filename = f"QuickFile-community-{info['CFBundleShortVersionString']}-{info['CFBundleVersion']}.dmg"
        image = delivery / filename
        # A failed detach must preserve its backing image and workspace, outside
        # the automatically removed signing and delivery staging directories.
        image_workspace = Path(tempfile.mkdtemp(prefix="community-dmg-", dir=TEMPORARY))
        dmg_report = DMG.create_dmg(copied, image, image_workspace)
        image_workspace.rmdir()
        if ARTIFACT.tree_manifest(app) != input_manifest:
            raise ValueError("input bundle changed during packaging")
        digest = ARTIFACT.sha256(image)
        shutil.rmtree(copied.parent)
        for configuration in staging.glob("*.entitlements"):
            configuration.unlink()
        report.update({"archive": filename, "archive_sha256": digest, "archive_bytes": image.stat().st_size, "dmg": dmg_report, "cleanup": "DMG detached; temporary signing and image copies removed before publication"})
        (delivery / (filename + ".sha256")).write_text(digest + "  " + filename + "\n", encoding="utf-8")
        (delivery / "artifact-check.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        (delivery / "INSTALL.txt").write_text(
            "QuickFile experimental community build\n\n"
            "The application is ad-hoc signed and unnotarized. Artifact checks do not prove\n"
            "cross-machine launch, Finder integration, upgrades or Gatekeeper acceptance.\n"
            "Verify the DMG against its .sha256 file, then open the disk image.\n"
            "Keep a backup before replacing an existing QuickFile installation.\n"
            "Quit QuickFile, then drag QuickFile.app onto Applications and eject the image.\n"
            "Open QuickFile; macOS may block this unnotarized application. Follow only\n"
            "the system's explicit per-application approval flow if you trust this build.\n"
            "Enable QuickFile's Finder extension in System Settings, then use the app's\n"
            "Finder integration verification. Online updates are disabled; upgrades are manual.\n",
            encoding="utf-8",
        )
        publish_directory(delivery, output)
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="unsigned Release QuickFile.app with updates disabled")
    parser.add_argument("--output", type=Path, required=True, help="new output directory; never overwritten")
    arguments = parser.parse_args(argv)
    try:
        package(arguments)
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        # Do not expose command arguments, local paths or raw signing diagnostics in public receipts.
        print("community packaging failed: " + (str(error) if isinstance(error, ValueError) else type(error).__name__), file=sys.stderr)
        return 1
    print("community DMG, SHA256, artifact receipt and installation instructions created")
    return 0


if __name__ == "__main__":
    sys.exit(main())
