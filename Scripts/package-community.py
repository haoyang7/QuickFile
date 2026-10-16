#!/usr/bin/env python3
"""Package an unsigned Release QuickFile.app as an experimental ad-hoc DMG."""

from __future__ import annotations

import argparse
import codecs
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
from xml.parsers.expat import ExpatError

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


def archive_filename(info: dict, release_tag: str | None) -> str:
    version = info["CFBundleShortVersionString"]
    if release_tag is None:
        return f"QuickFile-community-{version}-{info['CFBundleVersion']}.dmg"
    ARTIFACT.validate_release_tag(release_tag, version)
    return f"QuickFile-{release_tag}.dmg"


def encode_localization_resources(app: Path) -> dict:
    files = {}
    for _, relative, _ in ARTIFACT.COMPONENTS:
        resources = app / relative / "Contents/Resources"
        for path in sorted(resources.glob("*.lproj/*")):
            if path.suffix not in (".strings", ".stringsdict") or not path.is_file() or path.is_symlink():
                continue
            original = path.read_bytes()
            data = original
            # Xcode emits UTF-16 XML; normalize its declaration for plistlib,
            # matching the compiled-resource reader in verify-localizations.py.
            try:
                if data.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
                    data = data.decode("utf-16").replace('encoding="UTF-16"', 'encoding="UTF-8"', 1).encode("utf-8")
                values = plistlib.loads(data)
            except (plistlib.InvalidFileException, ExpatError, UnicodeError, ValueError):
                raise ValueError("invalid compiled localization resource") from None
            if not isinstance(values, dict):
                raise ValueError("compiled localization resource must be a dictionary")
            encoded = plistlib.dumps(values, fmt=plistlib.FMT_BINARY, sort_keys=True)
            if plistlib.loads(encoded) != values:
                raise ValueError("localization resource encoding changed its values")
            if len(encoded) < len(original):
                path.write_bytes(encoded)
            files[path.relative_to(app).as_posix()] = {
                "before_bytes": len(original), "after_bytes": min(len(encoded), len(original)),
            }
    return {"format": "binary plist when smaller", "stage": "private copy before signing", "files": files}


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
    info = ARTIFACT.validate_configuration(app, allow_sparkle_services=True, check_release_tag=False)
    release_tag = getattr(arguments, "release_tag", None)
    filename = archive_filename(info, release_tag)
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
        for label, relative, _ in ARTIFACT.COMPONENTS:
            path = copied / relative / "Contents/Info.plist"
            values = ARTIFACT.read_plist(path)
            if label == "app":
                values.update({"SUEnableInstallerLauncherService": False, "SUEnableDownloaderService": False})
            values.pop("QuickFileReleaseTag", None)
            if release_tag is not None:
                values["QuickFileReleaseTag"] = release_tag
            path.write_bytes(plistlib.dumps(values))
        ARTIFACT.validate_layout(copied)
        resource_encoding = encode_localization_resources(copied)
        stripped_binaries = {}
        # Strip only non-global symbols from the private copy before signing.
        # The unchanged build input remains paired with its external dSYMs.
        for label, relative, binary_relative in ARTIFACT.COMPONENTS:
            binary = copied / relative / binary_relative
            before_bytes = binary.stat().st_size
            run(["/usr/bin/xcrun", "strip", "-x", str(binary)])
            stripped_binaries[label] = {
                "binary": binary.relative_to(copied).as_posix(),
                "before_bytes": before_bytes, "after_bytes": binary.stat().st_size,
            }
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
        image = delivery / filename
        installation_notes = (
            "QuickFile Community 安装说明\n\n"
            "1. 从可信的 QuickFile 官方 GitHub Release 下载 DMG 和同名 .sha256 文件。\n"
            "   在下载目录中运行下列命令；只有显示 OK 且来源可信时继续：\n"
            f"   shasum -a 256 -c {filename}.sha256\n"
            "2. 升级前备份 QuickFile 数据与旧版本，然后退出 QuickFile。\n"
            "   先阅读该版本发布说明的已知限制；干净安装、同路线升级和签名路线切换须分别验证。\n"
            "   从开发签名或 Developer ID 版本切换到 Community 时，不应假定旧权限和数据访问已完成迁移。\n"
            "3. 打开 DMG，将 QuickFile.app 拖入 Applications；升级时确认替换旧版本。\n"
            "4. 关闭安装说明并推出磁盘映像，再从 /Applications 启动 QuickFile。\n\n"
            "此版本采用 ad-hoc 签名，未经 Apple 公证，macOS 可能阻止首次启动。\n"
            "请先尝试系统针对该应用提供的“仍要打开”等逐应用批准流程。\n"
            "确认下载来源可信且 SHA-256 校验通过后，如需移除隔离属性，优先运行：\n"
            "   xattr -dr com.apple.quarantine /Applications/QuickFile.app\n"
            "另一命令会递归清除所有扩展属性，影响范围更广：\n"
            "   xattr -cr /Applications/QuickFile.app\n"
            "两条 xattr 命令都不提供签名、公证或目录访问授权。无需全局关闭 Gatekeeper 或 SIP。\n\n"
            "在系统设置中启用 QuickFile 的 Finder 扩展，再在应用内验证 Finder 集成。\n"
            "Finder 扩展开关与目录授权是独立步骤；按应用提示授权需要使用的目录。\n"
            "QuickFile 无需“完全磁盘访问”。可在“检查更新…”中手动查询 GitHub Release；\n"
            "预发布版本需开启“接收 Beta 版本”。升级仍需从发行页手动下载、校验并安装。\n"
            "Community 与新版 Developer ID 共用本地数据目录；旧 App Group 模板可通过导出、导入转移。\n"
            "若模板或授权交接队列持续加载，停止创建验收，保留旧版和数据备份，不删除共享目录或旧 App Group 数据。\n"
            "记录升级前后版本/build、分发路线、macOS 版本和等待时长，按发布页反馈；不要上传书签或私人日志。\n"
            "回退原 App 后仍须重新验证模板、授权和 Finder 创建；恢复旧二进制不代表完整恢复。\n"
            "产物检查不代表已在干净机器验证启动、Finder 集成或完整权限迁移。\n"
        ).encode("utf-8")
        # A failed detach must preserve its backing image and workspace, outside
        # the automatically removed signing and delivery staging directories.
        image_workspace = Path(tempfile.mkdtemp(prefix="community-dmg-", dir=TEMPORARY))
        dmg_report = DMG.create_dmg(copied, image, image_workspace, installation_notes)
        image_workspace.rmdir()
        if ARTIFACT.tree_manifest(app) != input_manifest:
            raise ValueError("input bundle changed during packaging")
        digest = ARTIFACT.sha256(image)
        shutil.rmtree(copied.parent)
        for configuration in staging.glob("*.entitlements"):
            configuration.unlink()
        report.update({"archive": filename, "archive_sha256": digest, "archive_bytes": image.stat().st_size, "dmg": dmg_report, "resource_encoding": resource_encoding, "symbol_stripping": {"tool": "xcrun strip", "flags": ["-x"], "stage": "private copy before signing", "components": stripped_binaries}, "cleanup": "DMG detached; temporary signing and image copies removed before publication"})
        (delivery / (filename + ".sha256")).write_text(digest + "  " + filename + "\n", encoding="utf-8")
        (delivery / "artifact-check.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        (delivery / "INSTALL.txt").write_bytes(installation_notes)
        publish_directory(delivery, output)
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="unsigned Release QuickFile.app with updates disabled")
    parser.add_argument("--output", type=Path, required=True, help="new output directory; never overwritten")
    parser.add_argument("--release-tag", help="vVERSION or vVERSION-beta.N matching the app marketing version")
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
