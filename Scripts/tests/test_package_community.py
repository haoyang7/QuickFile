import importlib.util
import json
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

FIXTURE_SPEC = importlib.util.spec_from_file_location("community_fixture", Path(__file__).with_name("test_verify_community_artifact.py"))
FIXTURE = importlib.util.module_from_spec(FIXTURE_SPEC)
FIXTURE_SPEC.loader.exec_module(FIXTURE)
SPEC = importlib.util.spec_from_file_location("package_community", Path(__file__).parents[1] / "package-community.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CommunityPackagingTests(unittest.TestCase):
    def setUp(self):
        FIXTURE.TEMPORARY.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="packager-tests-", dir=FIXTURE.TEMPORARY)
        self.directory = Path(self.temporary.name)
        self.app = FIXTURE.make_fixture(self.directory / "input", include_sparkle=True)
        self.output = self.directory / "output"
        self.arguments = Namespace(app=self.app, output=self.output)
        self.commands = []
        self.original_inspect = MODULE.ARTIFACT.inspect_artifact
        self.workspaces = self.directory / "temporary"

    def tearDown(self):
        self.temporary.cleanup()

    def inspect(self, app):
        return self.original_inspect(app, FIXTURE.FakeRunner(app))

    def tool(self, command):
        self.commands.append(command)
        tool = Path(command[0]).name
        if tool == "codesign":
            component = Path(command[-1])
            signature = (component / "Contents/_CodeSignature/CodeResources") if component.is_dir() else component.with_name("Autoupdate.signature")
            signature.parent.mkdir(parents=True, exist_ok=True)
            signature.write_bytes(b"adhoc signature")
        elif tool == "ditto":
            shutil.copytree(Path(command[-2]), Path(command[-1]), symlinks=True)
        else:
            raise AssertionError(command)

    def create_dmg(self, app, image, workspace):
        self.assertEqual(self.inspect(app)["verdict"], "pass")
        self.assertTrue(workspace.is_relative_to(self.workspaces))
        image.write_bytes(b"mock verified dmg bytes")
        return {"image": image.name, "image_sha256": MODULE.ARTIFACT.sha256(image), "image_bytes": image.stat().st_size, "mounted_artifact_verdict": "pass", "cleanup": "own image detached; private image, source and mount removed"}

    def package(self, tool=None, inspect=None, input_signature=None, dmg=None):
        with patch.object(MODULE, "TEMPORARY", self.workspaces), patch.object(MODULE.DMG, "create_dmg", side_effect=dmg or self.create_dmg), patch.object(MODULE, "run", side_effect=tool or self.tool), patch.object(MODULE.ARTIFACT, "inspect_artifact", side_effect=inspect or self.inspect), patch.object(MODULE.ARTIFACT, "system_dependencies", return_value=True), patch.object(MODULE.ARTIFACT, "run_command", side_effect=input_signature or (lambda command: subprocess.CompletedProcess(command, 1, b"", b"code object is not signed at all"))):
            return MODULE.package(self.arguments)

    def assert_clean(self):
        self.assertEqual(list(self.directory.glob(".quickfile-community-*")), [])
        self.assertEqual(list(self.workspaces.glob("community-package-*")), [])

    def test_packages_without_mutating_input_and_delivers_only_verified_dmg(self):
        before = MODULE.ARTIFACT.tree_manifest(self.app)
        report = self.package()
        self.assertEqual(before, MODULE.ARTIFACT.tree_manifest(self.app))
        self.assertEqual(report["verdict"], "pass")
        archive, = self.output.glob("*.dmg")
        self.assertEqual(list(self.output.glob("*.zip")), [])
        checksum = archive.with_name(archive.name + ".sha256").read_text()
        self.assertEqual(checksum, MODULE.ARTIFACT.sha256(archive) + "  " + archive.name + "\n")
        self.assertEqual(json.loads((self.output / "artifact-check.json").read_text())["archive_sha256"], MODULE.ARTIFACT.sha256(archive))
        image, = self.output.glob("*.dmg")
        self.assertEqual(image.with_name(image.name + ".sha256").read_text(), MODULE.ARTIFACT.sha256(image) + "  " + image.name + "\n")
        self.assertEqual(report["dmg"]["image_sha256"], MODULE.ARTIFACT.sha256(image))
        self.assertEqual(list(self.workspaces.iterdir()), [])
        self.assertNotIn(str(self.directory), (self.output / "artifact-check.json").read_text())
        signatures = [command for command in self.commands if Path(command[0]).name == "codesign"]
        self.assertEqual([Path(c[-1]).name for c in signatures], ["FinderExtension.appex", "QuickFile.app"])
        self.assertFalse(any("Sparkle" in str(c[-1]) for c in signatures))
        for command in signatures:
            self.assertNotIn("--deep", command)
            self.assertEqual(command[command.index("--sign") + 1], "-")
            self.assertIn("runtime", command)
        self.assert_clean()

    def test_dmg_failure_does_not_publish_and_preserves_recovery_workspace(self):
        before = MODULE.ARTIFACT.tree_manifest(self.app)
        recovery = []
        def fails(app, image, workspace):
            recovery.append(workspace)
            (workspace / "community.dmg").write_bytes(b"preserve for detach recovery")
            raise ValueError("DMG detach failed")
        with self.assertRaisesRegex(ValueError, "detach failed"):
            self.package(dmg=fails)
        self.assertFalse(self.output.exists())
        self.assertEqual((recovery[0] / "community.dmg").read_bytes(), b"preserve for detach recovery")
        self.assertEqual(before, MODULE.ARTIFACT.tree_manifest(self.app))
        self.assert_clean()

    def test_removes_sparkle_and_signs_only_necessary_source_entitlements(self):
        configurations = {}
        def tool(command):
            if Path(command[0]).name == "codesign":
                path = Path(command[command.index("--entitlements") + 1])
                configurations[Path(command[-1]).name] = MODULE.ARTIFACT.read_plist(path)
            self.tool(command)
        self.package(tool)
        self.assertEqual(configurations["QuickFile.app"], MODULE.ARTIFACT.expected_entitlements("app"))
        self.assertEqual(configurations["FinderExtension.appex"], MODULE.ARTIFACT.expected_entitlements("finder_extension"))
        self.assertEqual(set(configurations), {"QuickFile.app", "FinderExtension.appex"})
        self.assertNotIn("com.apple.security.temporary-exception.mach-lookup.global-name", configurations["QuickFile.app"])
        for value in configurations.values():
            self.assertNotIn("$", json.dumps(value))
            self.assertFalse(MODULE.ARTIFACT.FORBIDDEN_CLAIMS.intersection(value))

    def test_rejects_profile_before_tools_and_preserves_input(self):
        profile = self.app / "Contents/embedded.provisionprofile"
        profile.write_bytes(b"original profile")
        before = MODULE.ARTIFACT.tree_manifest(self.app)
        with self.assertRaisesRegex(ValueError, "profiles"):
            self.package()
        self.assertEqual(self.commands, [])
        self.assertEqual(before, MODULE.ARTIFACT.tree_manifest(self.app))
        self.assertFalse(self.output.exists())

    def test_rejects_existing_output_directory_file_and_symlink(self):
        for kind in ("directory", "file", "symlink"):
            with self.subTest(kind=kind):
                if kind == "directory":
                    self.output.mkdir()
                elif kind == "file":
                    self.output.write_text("keep")
                else:
                    self.output.symlink_to(self.directory / "missing")
                with self.assertRaisesRegex(ValueError, "already exists"):
                    self.package()
                self.assertTrue(self.output.exists() or self.output.is_symlink())
                if kind == "directory":
                    self.output.rmdir()
                else:
                    self.output.unlink()
        self.assertEqual(self.commands, [])

    def test_failure_at_signing_or_verification_cleans_only_staging(self):
        unrelated = self.directory / "unrelated.app"
        unrelated.mkdir()
        before = MODULE.ARTIFACT.tree_manifest(self.app)
        def fails(command):
            if Path(command[0]).name == "codesign":
                raise subprocess.CalledProcessError(1, command)
            self.tool(command)
        with self.assertRaises(subprocess.CalledProcessError):
            self.package(fails)
        with self.assertRaisesRegex(ValueError, "failed verification"):
            self.package(inspect=lambda app: {"verdict": "fail"})
        self.assertEqual(before, MODULE.ARTIFACT.tree_manifest(self.app))
        self.assertTrue(unrelated.exists())
        self.assertFalse(self.output.exists())
        self.assert_clean()

    def test_source_changed_during_dmg_creation_is_not_published(self):
        def changes(app, image, workspace):
            report = self.create_dmg(app, image, workspace)
            binary = self.app / "Contents/MacOS/QuickFile"
            binary.write_bytes(binary.read_bytes() + b"changed")
            return report
        with self.assertRaisesRegex(ValueError, "input bundle changed"):
            self.package(dmg=changes)
        self.assertFalse(self.output.exists())
        self.assert_clean()

    def test_copy_byte_change_is_rejected_before_signing(self):
        def changes(command):
            self.tool(command)
            if Path(command[0]).name == "ditto" and "-c" not in command and "-x" not in command:
                (Path(command[-1]) / "Contents/MacOS/QuickFile").write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "copy"):
            self.package(changes)
        self.assertFalse(any(Path(c[0]).name == "codesign" for c in self.commands))
        self.assert_clean()

    def test_output_created_during_preparation_is_never_overwritten(self):
        def racing(app, image, workspace):
            report = self.create_dmg(app, image, workspace)
            self.output.mkdir()
            (self.output / "other-owner").write_text("keep")
            return report
        with self.assertRaises(OSError):
            self.package(dmg=racing)
        self.assertEqual((self.output / "other-owner").read_text(), "keep")
        self.assertEqual(len(list(self.output.iterdir())), 1)
        self.assert_clean()

    def test_repeated_output_and_overlapping_paths_are_rejected(self):
        self.package()
        with self.assertRaises(ValueError):
            self.package()
        self.arguments.output = self.app / "output"
        with self.assertRaisesRegex(ValueError, "overlap"):
            self.package()

    def test_exact_placeholder_expansion_and_unknown_variables(self):
        result = MODULE.expand_entitlements({"services": ["$(PRODUCT_BUNDLE_IDENTIFIER)-spks", "$(PRODUCT_BUNDLE_IDENTIFIER)-spki"]}, MODULE.ARTIFACT.APP_ID)
        self.assertEqual(result["services"], [MODULE.ARTIFACT.APP_ID + "-spks", MODULE.ARTIFACT.APP_ID + "-spki"])
        for value in ("$(TEAM_IDENTIFIER)", "${PRODUCT_BUNDLE_IDENTIFIER}", "$(PRODUCT_BUNDLE_IDENTIFIER)-$(UNKNOWN)"):
            with self.assertRaisesRegex(ValueError, "placeholder"):
                MODULE.expand_entitlements(value, MODULE.ARTIFACT.APP_ID)

    def test_rejects_linked_sparkle_before_copy_or_deletion(self):
        before = MODULE.ARTIFACT.tree_manifest(self.app)
        with patch.object(MODULE.ARTIFACT, "system_dependencies", return_value=False), patch.object(MODULE.ARTIFACT, "run_command", return_value=subprocess.CompletedProcess([], 1, b"", b"code object is not signed at all")):
            with self.assertRaisesRegex(ValueError, "build-community"):
                MODULE.package(self.arguments)
        self.assertEqual(before, MODULE.ARTIFACT.tree_manifest(self.app))
        self.assertEqual(self.commands, [])

    def test_rejects_signed_input_and_indeterminate_signature(self):
        for result in (subprocess.CompletedProcess([], 0, b"", b"Signature=adhoc"), subprocess.CompletedProcess([], 1, b"", b"invalid code object")):
            with patch.object(MODULE.ARTIFACT, "run_command", return_value=result):
                with self.assertRaisesRegex(ValueError, "unsigned"):
                    MODULE.package(self.arguments)
        self.assertEqual(self.commands, [])
        self.assertFalse(self.output.exists())

    def linker_signature(self, command, **overrides):
        if "--entitlements" in command:
            return subprocess.CompletedProcess(command, 0, b"", b"Executable=fixture")
        fields = {
            "CodeDirectory v": "20400 size=100 flags=0x20002(adhoc,linker-signed) hashes=1+0 location=embedded",
            "Signature": "adhoc", "Info.plist": "not bound", "TeamIdentifier": "not set", "Sealed Resources": "none",
        }
        fields.update(overrides)
        metadata = "\n".join(key + "=" + value for key, value in fields.items())
        return subprocess.CompletedProcess(command, 0, b"", metadata.encode())

    def test_accepts_bare_linker_signature_in_each_slice(self):
        calls = []
        def input_signature(command):
            calls.append(command)
            return self.linker_signature(command)
        self.assertEqual(self.package(input_signature=input_signature)["verdict"], "pass")
        self.assertEqual(len(calls), 8)
        self.assertEqual([c[c.index("--arch") + 1] for c in calls].count("arm64"), 4)
        self.assertEqual([c[c.index("--arch") + 1] for c in calls].count("x86_64"), 4)

    def test_accepts_mixed_unsigned_and_bare_linker_signed_slices(self):
        def input_signature(command):
            if command[command.index("--arch") + 1] == "x86_64":
                return subprocess.CompletedProcess(command, 1, b"", b"code object is not signed at all")
            return self.linker_signature(command)
        self.assertEqual(self.package(input_signature=input_signature)["verdict"], "pass")

    def test_rejects_linker_signatures_with_team_authority_runtime_or_bundle_seal(self):
        for overrides in (
            {"TeamIdentifier": "FAKETEAM"}, {"Authority": "Developer ID Application: fixture"},
            {"CodeDirectory v": "20400 size=100 flags=0x30002(adhoc,runtime,linker-signed)"},
            {"CodeDirectory v": "20400 size=100 flags=0x10002(adhoc,runtime)"},
            {"Info.plist": "entries=10"}, {"Sealed Resources": "version=2 rules=13 files=20"},
            {"Signature": "signed"},
        ):
            with self.subTest(overrides=overrides):
                def input_signature(command):
                    # A bad Intel slice must reject even when the ARM slice is valid.
                    bad = command[command.index("--arch") + 1] == "x86_64"
                    return self.linker_signature(command, **(overrides if bad else {}))
                with self.assertRaisesRegex(ValueError, "bare linker-signed"):
                    self.package(input_signature=input_signature)
                self.assertEqual(self.commands, [])
                self.assertFalse(self.output.exists())
        self.assert_clean()

    def test_rejects_linker_signature_entitlements_and_failed_entitlement_read(self):
        for returncode, stdout in ((0, plistlib.dumps({"get-task-allow": False})), (1, b""), (0, b"invalid")):
            with self.subTest(returncode=returncode, stdout=stdout):
                def input_signature(command):
                    if "--entitlements" in command:
                        return subprocess.CompletedProcess(command, returncode, stdout, b"")
                    return self.linker_signature(command)
                with self.assertRaises(ValueError):
                    self.package(input_signature=input_signature)
                self.assertEqual(self.commands, [])
                self.assertFalse(self.output.exists())

    def test_rejects_unknown_project_entitlements(self):
        original = MODULE.ARTIFACT.read_plist
        def altered(path):
            value = original(path)
            if path.name == "QuickFile.entitlements":
                value["unexpected"] = True
            return value
        with patch.object(MODULE.ARTIFACT, "read_plist", side_effect=altered):
            with self.assertRaisesRegex(ValueError, "contract"):
                self.package()
        self.assertEqual(self.commands, [])


if __name__ == "__main__":
    unittest.main()
