"""Create and verify a community DMG without signing, installing or launching it."""

from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("community_dmg_artifact", Path(__file__).with_name("verify-community-artifact.py"))
ARTIFACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ARTIFACT)


class DMGCleanupError(ValueError):
    """The caller must preserve workspace; it may still contain a mounted image."""

    preserve_workspace = True


def run(arguments: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(arguments, check=True, capture_output=True, timeout=300)


def own_attachment(image: Path) -> dict | None:
    """Identify only this invocation's private image in the current device list."""
    try:
        value = plistlib.loads(run(["/usr/bin/hdiutil", "info", "-plist"]).stdout)
        images = value["images"]
        if not isinstance(images, list):
            raise ValueError("invalid images list")
        matching = []
        for entry in images:
            if not isinstance(entry, dict) or not isinstance(entry.get("image-path"), str):
                raise ValueError("invalid image identity")
            if Path(entry["image-path"]).resolve() == image:
                if not isinstance(entry.get("system-entities"), list):
                    raise ValueError("invalid image devices")
                matching.append(entry)
        if len(matching) > 1:
            raise ValueError("ambiguous attachment")
        return matching[0] if matching else None
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        raise DMGCleanupError("DMG attachment state is unknown; preserve the caller-owned workspace") from error


def detach_own_image(image: Path, mount: Path) -> None:
    attachment = own_attachment(image)
    if attachment is None:
        if os.path.ismount(mount):
            raise DMGCleanupError("DMG mount ownership is unknown; preserve the caller-owned workspace")
        return
    entities = attachment["system-entities"]
    if any(isinstance(entry, dict) and entry.get("mount-point") == str(mount) for entry in entities):
        target = str(mount)
    else:
        devices = [entry.get("dev-entry") for entry in entities if isinstance(entry, dict)]
        target = next((device for device in devices if isinstance(device, str) and re.fullmatch(r"/dev/disk[0-9]+", device)), None)
        if target is None:
            raise DMGCleanupError("DMG has no confirmed detach target; preserve the caller-owned workspace")
    try:
        run(["/usr/bin/hdiutil", "detach", target])
    except (OSError, subprocess.SubprocessError) as error:
        raise DMGCleanupError("DMG detach failed; preserve the caller-owned workspace and its private image") from error
    if own_attachment(image) is not None or os.path.ismount(mount):
        raise DMGCleanupError("DMG detach is unconfirmed; preserve the caller-owned workspace and its private image")


def publish_image(source: Path, image: Path) -> None:
    """Use exclusive creation, including when delivery is on another filesystem."""
    identity = None
    try:
        with image.open("xb") as output:
            identity = os.fstat(output.fileno())
            with source.open("rb") as stream:
                shutil.copyfileobj(stream, output, length=1024 * 1024)
        if ARTIFACT.sha256(source) != ARTIFACT.sha256(image):
            raise ValueError("published DMG bytes differ from the verified private image")
    except Exception:
        # Do not delete a replacement created by another writer after our failure.
        if identity is not None:
            try:
                if os.path.samestat(identity, image.stat()):
                    image.unlink()
            except OSError:
                pass
        raise


def create_dmg(app: Path, image: Path, workspace: Path) -> dict:
    """Publish a verified DMG; leave only an empty workspace on normal completion.

    On DMGCleanupError, preserve workspace: community.dmg, mount and a small
    mount-state.json record remain available. No delivery image is published.
    The caller must not recursively remove the workspace after any failure.
    """
    if image.exists() or image.is_symlink():
        raise ValueError("DMG output already exists")
    if image.suffix.lower() != ".dmg" or not image.parent.is_dir():
        raise ValueError("DMG output requires a .dmg filename in an existing delivery directory")
    if not workspace.is_dir() or workspace.is_symlink() or any(workspace.iterdir()):
        raise ValueError("DMG workspace must be an existing, empty, caller-owned directory")
    app = app.resolve()
    image = image.absolute()
    workspace = workspace.resolve()
    if workspace.is_relative_to(app) or app.is_relative_to(workspace) or image.resolve().is_relative_to(app) or image.resolve().is_relative_to(workspace):
        raise ValueError("DMG input, delivery and workspace paths must not overlap")
    manifest = ARTIFACT.validate_layout(app)
    source = workspace / "source"
    mount = workspace / "mount"
    private_image = workspace / "community.dmg"
    safe_to_clean = True
    source.mkdir()
    try:
        copied = source / "QuickFile.app"
        run(["/usr/bin/ditto", str(app), str(copied)])
        if ARTIFACT.tree_manifest(copied) != manifest:
            raise ValueError("DMG staging changed application bytes, modes or symlinks")
        (source / "Applications").symlink_to("/Applications")
        run([
            "/usr/bin/hdiutil", "create", "-srcfolder", str(source), "-format", "UDZO", "-fs", "HFS+",
            "-volname", "QuickFile Community", str(private_image),
        ])
        run(["/usr/bin/hdiutil", "verify", str(private_image)])
        mount.mkdir()
        safe_to_clean = False
        try:
            run([
                "/usr/bin/hdiutil", "attach", str(private_image), "-readonly", "-nobrowse", "-noautoopen",
                "-mount", "required", "-mountpoint", str(mount), "-plist",
            ])
            attachment = own_attachment(private_image)
            if attachment is None or not any(
                isinstance(entry, dict) and entry.get("mount-point") == str(mount)
                for entry in attachment["system-entities"]
            ) or not os.path.ismount(mount):
                raise ValueError("DMG did not mount at the private verification mount point")
            if ARTIFACT.tree_manifest(mount / "QuickFile.app") != manifest:
                raise ValueError("mounted DMG application differs from its verified input")
            report = ARTIFACT.inspect_artifact(mount / "QuickFile.app")
            if report["verdict"] != "pass":
                raise ValueError("mounted DMG application failed community artifact verification")
            applications = mount / "Applications"
            if not applications.is_symlink() or os.readlink(applications) != "/Applications":
                raise ValueError("mounted DMG Applications shortcut has an unexpected target")
            if ARTIFACT.tree_manifest(app) != manifest:
                raise ValueError("DMG input application changed during image creation")
        finally:
            detach_own_image(private_image, mount)
            safe_to_clean = True
        publish_image(private_image, image)
        return {
            "image": image.name, "image_sha256": ARTIFACT.sha256(image), "image_bytes": image.stat().st_size,
            "format": "UDZO", "filesystem": "HFS+", "scope": "DMG contents and mounted artifact only",
            "trust": "ad-hoc/unnotarized", "hdiutil_verify": "pass", "readonly_mount": "pass",
            "mounted_manifest": "matches all input bytes, modes and symlinks", "mounted_artifact_verdict": "pass",
            "applications_link": "/Applications", "input_unchanged": True,
            "cleanup": "own image detached; private image, source and mount removed",
            "unproven": ["cross-machine launch", "Finder integration", "upgrades", "Gatekeeper acceptance"],
        }
    finally:
        if safe_to_clean:
            shutil.rmtree(source)
            if mount.exists():
                mount.rmdir()
            if private_image.exists():
                private_image.unlink()
        else:
            (workspace / "mount-state.json").write_text(json.dumps({
                "image": "community.dmg", "mount": "mount", "cleanup": "failed or unconfirmed",
                "preserve_workspace": True,
            }, indent=2) + "\n", encoding="utf-8")
