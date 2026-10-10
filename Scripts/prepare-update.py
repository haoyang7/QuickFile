#!/usr/bin/env python3
"""Prepare a signed QuickFile update and appcast locally; never upload or notarize."""

from __future__ import annotations

import argparse
import base64
import binascii
import fcntl
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def enabled(value: object) -> bool:
    return value is True or value == "YES"


def https_url(value: str) -> str:
    url = urllib.parse.urlsplit(value)
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment:
        raise ValueError("update URLs must use HTTPS without credentials or fragments")
    return value


def version_tuple(value: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise ValueError("versions and builds must contain one to three numeric components")
    parts = [int(part) for part in value.split(".")]
    return tuple((parts + [0, 0])[:3])


def read_configuration(app: Path) -> dict:
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    with (app / "Contents/PlugIns/FinderExtension.appex/Contents/Info.plist").open("rb") as stream:
        extension = plistlib.load(stream)
    if not enabled(info.get("QuickFileUpdatesEnabled")):
        raise ValueError("this app was built with online updates disabled")
    https_url(info.get("SUFeedURL", ""))
    try:
        key = base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)
    except binascii.Error as error:
        raise ValueError("invalid EdDSA public key") from error
    if len(key) != 32:
        raise ValueError("EdDSA public key must decode to 32 bytes")
    for field in ("CFBundleShortVersionString", "CFBundleVersion"):
        version_tuple(info.get(field, ""))
        if info[field] != extension.get(field):
            raise ValueError("app and Finder extension versions must match")
    for field in ("SUEnableInstallerLauncherService", "SUEnableDownloaderService"):
        if not enabled(info.get(field)):
            raise ValueError(f"sandboxed updates require {field}")
    for field in ("SUAllowsAutomaticUpdates", "SUEnableSystemProfiling", "SUSendProfileInfo", "SUEnableJavaScript"):
        if enabled(info.get(field)):
            raise ValueError(f"this release policy requires {field} to be disabled")
    return info


def item_version(item: ET.Element) -> str:
    enclosure = item.find("enclosure")
    return item.findtext(SPARKLE + "version") or (
        enclosure.get(SPARKLE + "version", "") if enclosure is not None else ""
    )


def check_new_build(feed: Path, build: str) -> None:
    if feed.exists():
        for item in ET.parse(feed).findall("./channel/item"):
            if version_tuple(build) <= version_tuple(item_version(item)):
                raise ValueError("new build must be greater than every existing stable or beta build")


def check_generated_feed(feed: Path, archive: Path, info: dict, prefix: str, channel: str) -> str:
    items = [item for item in ET.parse(feed).findall("./channel/item") if item_version(item) == info["CFBundleVersion"]]
    if len(items) != 1:
        raise ValueError("generated feed must contain exactly one entry for this build")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("generated update has no download enclosure")
    signature = enclosure.get(SPARKLE + "edSignature", "")
    try:
        signature_data = base64.b64decode(signature, validate=True)
    except binascii.Error as error:
        raise ValueError("generated update has an invalid EdDSA signature") from error
    if len(signature_data) != 64:
        raise ValueError("update was not signed; check that the Keychain key matches SUPublicEDKey")
    expected_url = prefix.rstrip("/") + "/" + urllib.parse.quote(archive.name)
    if enclosure.get("url") != expected_url or enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("generated update URL or length does not match the final archive")
    if (item.findtext(SPARKLE + "channel") or "stable") != channel:
        raise ValueError("generated update channel does not match the requested channel")
    return signature


def feed_is_uncommitted(staged_feed: Path, target_feed: Path, identity: os.stat_result) -> bool:
    """Require filesystem evidence before removing artifacts after a failed commit."""
    try:
        if os.path.samestat(identity, target_feed.stat()):
            return False
    except FileNotFoundError:
        pass
    except OSError:
        return False
    try:
        # An atomic rename removes this source. If it is gone or its identity is
        # uncertain, preserve the artifacts: the feed may already reference them.
        return os.path.samestat(identity, staged_feed.stat())
    except OSError:
        return False


def prepare(arguments: argparse.Namespace) -> None:
    app = arguments.app.resolve()
    output = arguments.output.resolve()
    if output == app or app in output.parents:
        raise ValueError("output must be outside the application bundle")
    info = read_configuration(app)
    prefix = https_url(arguments.download_url_prefix).rstrip("/") + "/"
    filename = f"QuickFile-{info['CFBundleShortVersionString']}-{info['CFBundleVersion']}.zip"
    feed_name = Path(urllib.parse.urlsplit(info["SUFeedURL"]).path).name
    if not feed_name.endswith(".xml"):
        raise ValueError("SUFeedURL must have an XML filename")
    target_feed = output / feed_name
    target_archive = output / filename
    target_report = output / (target_archive.stem + ".artifact-check.json")
    generator = arguments.sparkle_bin.resolve() / "generate_appcast"
    verifier = arguments.sparkle_bin.resolve() / "sign_update"
    if not generator.is_file() or not verifier.is_file():
        raise ValueError("generate_appcast or sign_update is missing from --sparkle-bin")
    output.mkdir(parents=True, exist_ok=True)
    # Keep the lock file: unlinking it can let processes lock different inodes.
    with (output / ".quickfile-update.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("another update preparation is using this output directory; retry after it finishes") from error
        check_new_build(target_feed, info["CFBundleVersion"])
        for target in (target_archive, target_report):
            if target.exists() or target.is_symlink():
                raise ValueError(f"release artifact already exists: {target.name}")
        with tempfile.TemporaryDirectory(prefix=".quickfile-update-", dir=output) as temporary:
            staging = Path(temporary)
            report = staging / "artifact-check.json"
            subprocess.run([
                sys.executable, str(Path(__file__).with_name("verify-beta-artifact.py")), str(app),
                "--mode", "developer-id", "--output", str(report)
            ], check=True, timeout=300)
            archive = staging / filename
            subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True, timeout=300)
            staged_feed = staging / feed_name
            if target_feed.exists():
                shutil.copy2(target_feed, staged_feed)
            if arguments.release_notes:
                suffix = arguments.release_notes.suffix.lower()
                if suffix not in (".html", ".md", ".txt"):
                    raise ValueError("release notes must be HTML, Markdown or plain text")
                shutil.copy2(arguments.release_notes, archive.with_suffix(suffix))
            command = [
                str(generator), "--account", arguments.key_account,
                "--download-url-prefix", prefix, "--maximum-deltas", "0",
                "--maximum-versions", "0", "--versions", info["CFBundleVersion"],
                "--embed-release-notes", "-o", str(staged_feed)
            ]
            if arguments.channel == "beta":
                command += ["--channel", "beta"]
            subprocess.run(command + [str(staging)], check=True, timeout=300)
            signature = check_generated_feed(staged_feed, archive, info, prefix, arguments.channel)
            subprocess.run([str(verifier), "--account", arguments.key_account, "--verify", str(archive), signature], check=True, timeout=60)
            staged_feed_identity = staged_feed.stat()
            promoted = []
            try:
                # Staging shares the output filesystem; links refuse to overwrite existing files.
                for source, target in ((archive, target_archive), (report, target_report)):
                    os.link(source, target)
                    promoted.append(target)
                # The atomic feed replacement commits the release after both artifacts are ready.
                staged_feed.replace(target_feed)
            except BaseException:
                # replace() may commit and then be interrupted before returning.
                # A Python flag set after the call cannot close that window.
                if feed_is_uncommitted(staged_feed, target_feed, staged_feed_identity):
                    for target in reversed(promoted):
                        target.unlink()
                raise
    print(f"Prepared {filename} and {feed_name}; nothing was uploaded.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="local update history directory")
    parser.add_argument("--download-url-prefix", required=True, help="HTTPS directory hosting this release's archive")
    parser.add_argument("--sparkle-bin", type=Path, required=True)
    parser.add_argument("--key-account", default="ed25519", help="Sparkle signing key account in login Keychain")
    parser.add_argument("--channel", choices=("stable", "beta"), default="stable")
    parser.add_argument("--release-notes", type=Path)
    arguments = parser.parse_args()
    try:
        prepare(arguments)
    except (ValueError, OSError, ET.ParseError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
