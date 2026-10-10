import importlib.util
import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("verify_community", Path(__file__).parents[1] / "verify-community-artifact.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
TEMPORARY = Path(__file__).parents[2] / ".build/Temporary/community-artifact-tests"


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value))


def make_fixture(directory, *, include_sparkle=False):
    app = directory / "QuickFile.app"
    components = MODULE.COMPONENTS + (MODULE.SPARKLE_COMPONENTS if include_sparkle else ())
    for label, relative, binary_relative in components:
        component = app / relative
        binary = component / binary_relative if binary_relative else component
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(bytes.fromhex("cffaedfe") + label.encode())
        binary.chmod(0o755)
        if label == "autoupdate":
            continue
        identifier = {"app": MODULE.APP_ID, "finder_extension": MODULE.EXTENSION_ID}.get(label, "org.sparkle-project." + label)
        info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": binary.name}
        if label in ("app", "finder_extension"):
            info.update({"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "70", "LSMinimumSystemVersion": "13.0"})
        if label == "app":
            info.update({"QuickFileUpdatesEnabled": "NO", "SUFeedURL": "", "SUPublicEDKey": ""})
            for key in ("SUEnableAutomaticChecks", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling", "SUSendProfileInfo", "SUEnableJavaScript", "SUEnableInstallerLauncherService", "SUEnableDownloaderService"):
                info[key] = False
        write_plist(component / ("Versions/B/Resources/Info.plist" if label == "framework" else "Contents/Info.plist"), info)
    if include_sparkle:
        framework = app / MODULE.SPARKLE
        (framework / "Versions/Current").symlink_to("B")
        (framework / "Sparkle").symlink_to("Versions/Current/Sparkle")
        (framework / "Resources").symlink_to("Versions/Current/Resources")
        (framework / "Updater.app").symlink_to("Versions/Current/Updater.app")
    return app


class FakeRunner:
    def __init__(self, app):
        self.app = app
        self.calls = []
        self.architectures = "arm64 x86_64"
        self.flags = "0x10002(adhoc,runtime)"
        self.team = "not set"
        self.authority = ""
        self.signature = "adhoc"
        self.identifiers = {}
        self.entitlements = {}
        self.bad_strict = set()
        self.bad_architecture = None
        self.dependencies = "/usr/lib/libSystem.B.dylib"

    def __call__(self, command):
        self.calls.append(command)
        if Path(command[0]).name == "otool":
            data = f"{command[-1]}:\n\t{self.dependencies} (compatibility version 1.0.0, current version 1351.0.0)\n"
            return subprocess.CompletedProcess(command, 0, data.encode(), b"")
        if Path(command[0]).name == "lipo":
            return subprocess.CompletedProcess(command, 0, self.architectures.encode(), b"")
        path = Path(command[-1])
        label, relative, _ = next(item for item in MODULE.COMPONENTS if self.app / item[1] == path)
        if "--verify" in command:
            return subprocess.CompletedProcess(command, int(label in self.bad_strict), b"", b"")
        if "--entitlements" in command:
            values = self.entitlements.get(label, MODULE.expected_entitlements(label))
            if command[command.index("--arch") + 1] == self.bad_architecture:
                values = {"get-task-allow": True}
            return subprocess.CompletedProcess(command, 0, plistlib.dumps(values), b"")
        identifier = self.identifiers.get(label, MODULE.bundle_info(self.app, label, relative)["CFBundleIdentifier"])
        text = f"Identifier={identifier}\nSignature={self.signature}\nTeamIdentifier={self.team}\nCodeDirectory v=20500 size=100 flags={self.flags}\n" + self.authority
        return subprocess.CompletedProcess(command, 0, b"", text.encode())


class CommunityArtifactTests(unittest.TestCase):
    def setUp(self):
        TEMPORARY.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="verifier-tests-", dir=TEMPORARY)
        self.directory = Path(self.temporary.name)
        self.app = make_fixture(self.directory)
        self.runner = FakeRunner(self.app)

    def tearDown(self):
        self.temporary.cleanup()

    def report(self):
        return MODULE.inspect_artifact(self.app, self.runner)

    def test_valid_artifact_checks_both_components_and_slices(self):
        report = self.report()
        self.assertEqual(report["verdict"], "pass")
        self.assertEqual(len(report["components"]), 2)
        self.assertEqual(len([c for c in self.runner.calls if "--entitlements" in c]), 4)
        self.assertTrue(all("--all-architectures" in c for c in self.runner.calls if "--verify" in c))
        serialized = json.dumps(report)
        self.assertNotIn(str(self.directory), serialized)
        self.assertEqual(report["scope"], "artifact only")
        self.assertEqual(report["trust"], "ad-hoc/unnotarized")
        self.assertIn("Finder integration", report["unproven"])

    def test_rejects_team_authority_missing_runtime_and_nonadhoc(self):
        for field, value in (("team", "FAKETEAM"), ("authority", "Authority=Developer ID Application: private name\n"), ("flags", "0x2(adhoc)"), ("signature", "signed")):
            with self.subTest(field=field):
                original = getattr(self.runner, field)
                setattr(self.runner, field, value)
                self.assertEqual(self.report()["verdict"], "fail")
                setattr(self.runner, field, original)

    def test_rejects_wrong_ids_and_versions(self):
        for key, value in (("CFBundleIdentifier", "wrong.id"), ("CFBundleVersion", "71"), ("CFBundleShortVersionString", "private text")):
            with self.subTest(key=key):
                path = self.app / "Contents/PlugIns/FinderExtension.appex/Contents/Info.plist"
                original = MODULE.read_plist(path)
                modified = dict(original, **{key: value})
                write_plist(path, modified)
                self.assertEqual(self.report()["verdict"], "fail")
                write_plist(path, original)
        self.runner.identifiers["finder_extension"] = "wrong.signature.id"
        self.assertEqual(self.report()["verdict"], "fail")

    def test_rejects_entitlement_changes_including_boolean_integer_and_second_slice(self):
        for label in ("app", "finder_extension"):
            for changes in ({"get-task-allow": False}, {"com.apple.developer.team-identifier": "FAKE"}, {"com.apple.security.network.server": True}):
                with self.subTest(label=label, changes=changes):
                    self.runner.entitlements[label] = dict(MODULE.expected_entitlements(label), **changes)
                    self.assertEqual(self.report()["verdict"], "fail")
                    self.runner.entitlements.clear()
        for key in MODULE.expected_entitlements("app"):
            altered = MODULE.expected_entitlements("app")
            altered.pop(key)
            self.runner.entitlements["app"] = altered
            self.assertEqual(self.report()["verdict"], "fail")
        self.runner.entitlements["app"] = dict(MODULE.expected_entitlements("app"), **{"com.apple.security.app-sandbox": 1})
        self.assertEqual(self.report()["verdict"], "fail")
        self.runner.entitlements.clear()
        self.runner.bad_architecture = "x86_64"
        self.assertEqual(self.report()["verdict"], "fail")

    def test_rejects_slices_and_each_nested_signature(self):
        for slices in ("arm64", "x86_64", "arm64 x86_64 i386", ""):
            self.runner.architectures = slices
            self.assertEqual(self.report()["verdict"], "fail")
        self.runner.architectures = "arm64 x86_64"
        for label, _, _ in MODULE.COMPONENTS:
            self.runner.bad_strict = {label}
            self.assertEqual(self.report()["verdict"], "fail")

    def test_rejects_profiles_anywhere_and_unexpected_code(self):
        profile = self.app / "Contents/Resources/nested/embedded.provisionprofile"
        profile.parent.mkdir(parents=True)
        profile.write_bytes(b"profile")
        self.assertEqual(self.report()["verdict"], "fail")
        profile.unlink()
        extra = self.app / "Contents/Resources/extra"
        extra.write_bytes(bytes.fromhex("cffaedfe"))
        self.assertEqual(self.report()["verdict"], "fail")
        extra.write_bytes(b"#!/bin/sh\n")
        extra.chmod(0o755)
        self.assertEqual(self.report()["verdict"], "fail")
        extra.unlink()
        alias = self.app / "Contents/PlugIns/Alias.appex"
        alias.symlink_to("FinderExtension.appex")
        self.assertEqual(self.report()["verdict"], "fail")
        alias.unlink()
        (self.app / "Contents/PlugIns/Other.appex").mkdir()
        self.assertEqual(self.report()["verdict"], "fail")

    def test_updates_must_be_explicitly_disabled_and_empty(self):
        path = self.app / "Contents/Info.plist"
        original = MODULE.read_plist(path)
        for key, value in (("QuickFileUpdatesEnabled", "YES"), ("QuickFileUpdatesEnabled", 0), ("SUFeedURL", "https://example.org/feed"), ("SUPublicEDKey", "key"), ("SUEnableAutomaticChecks", True)):
            write_plist(path, dict(original, **{key: value}))
            self.assertEqual(self.report()["verdict"], "fail")
        write_plist(path, original)

    def test_manifest_detects_every_byte_and_symlink_escape(self):
        before = MODULE.tree_manifest(self.app)
        binary = self.app / "Contents/MacOS/QuickFile"
        binary.write_bytes(binary.read_bytes() + b"changed")
        self.assertNotEqual(before, MODULE.tree_manifest(self.app))
        (self.app / "Contents/Resources").mkdir(parents=True, exist_ok=True)
        (self.app / "Contents/Resources/escape").symlink_to(self.directory)
        self.assertEqual(self.report()["verdict"], "fail")

    def test_rejects_sparkle_any_non_system_dependency_and_library_validation_bypass(self):
        for dependency in ("@rpath/Sparkle.framework/Versions/B/Sparkle", "@rpath/Other.framework/Other", "/usr/lib/../local/lib.dylib"):
            self.runner.dependencies = dependency
            self.assertEqual(self.report()["verdict"], "fail")
        self.runner.dependencies = "/usr/lib/libSystem.B.dylib"
        self.runner.entitlements["app"] = dict(MODULE.expected_entitlements("app"), **{"com.apple.security.cs.disable-library-validation": True})
        self.assertEqual(self.report()["verdict"], "fail")
        self.runner.entitlements.clear()
        (self.app / MODULE.SPARKLE).mkdir(parents=True)
        self.assertEqual(self.report()["verdict"], "fail")

    def test_allows_only_controlled_sparkle_updater_alias_before_removal(self):
        app = make_fixture(self.directory / "sparkle", include_sparkle=True)
        self.assertIsInstance(MODULE.validate_layout(app, allow_sparkle=True), dict)
        with self.assertRaises(ValueError):
            MODULE.validate_layout(app)
        alias = app / MODULE.SPARKLE / "Updater.app"
        alias.unlink()
        alias.symlink_to("Versions/B/Updater.app")
        with self.assertRaisesRegex(ValueError, "alias"):
            MODULE.validate_layout(app, allow_sparkle=True)
        alias.unlink()
        alias.mkdir()
        with self.assertRaisesRegex(ValueError, "alias"):
            MODULE.validate_layout(app, allow_sparkle=True)
        alias.rmdir()
        alias.symlink_to("Versions/Current/Updater.app")
        framework = app / MODULE.SPARKLE
        current = framework / "Versions/Current"
        current.unlink()
        current.symlink_to("B/Resources")
        (framework / "Versions/B/Resources/Updater.app").mkdir()
        (framework / "Versions/B/Resources/Resources").mkdir()
        (framework / "Versions/B/Resources/Sparkle").write_bytes(b"wrong alias target")
        with self.assertRaisesRegex(ValueError, "alias"):
            MODULE.validate_layout(app, allow_sparkle=True)
        (framework / "Versions/B/Resources/Updater.app").rmdir()
        (framework / "Versions/B/Resources/Resources").rmdir()
        (framework / "Versions/B/Resources/Sparkle").unlink()
        current.unlink()
        current.symlink_to("B")
        (framework / "Other.app").symlink_to("Versions/Current/Updater.app")
        with self.assertRaisesRegex(ValueError, "nested"):
            MODULE.validate_layout(app, allow_sparkle=True)

    def test_tool_failures_are_failed_anonymous_checks(self):
        def unavailable(command):
            raise OSError("private path")
        report = MODULE.inspect_artifact(self.app, unavailable)
        self.assertEqual(report["verdict"], "fail")
        self.assertNotIn("private path", json.dumps(report))


if __name__ == "__main__":
    unittest.main()
