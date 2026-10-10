import importlib.util
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("community_dmg", Path(__file__).parents[1] / "community_dmg.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
FIXTURE_SPEC = importlib.util.spec_from_file_location("dmg_artifact_fixture", Path(__file__).with_name("test_verify_community_artifact.py"))
FIXTURE = importlib.util.module_from_spec(FIXTURE_SPEC)
FIXTURE_SPEC.loader.exec_module(FIXTURE)
TEMPORARY = Path(__file__).parents[2] / ".build/Temporary/community-dmg-tests"


class CommunityDMGTests(unittest.TestCase):
    def setUp(self):
        TEMPORARY.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="dmg-tests-", dir=TEMPORARY)
        self.directory = Path(self.temporary.name).resolve()
        self.app = FIXTURE.make_fixture(self.directory / "input")
        resources = self.app / "Contents/Resources"
        resources.mkdir()
        (resources / "fixture.txt").write_text("signed resource fixture")
        (resources / "fixture.txt").chmod(0o600)
        (resources / "fixture-link").symlink_to("fixture.txt")
        self.workspace = self.directory / "workspace"
        self.workspace.mkdir()
        self.delivery = self.directory / "delivery"
        self.delivery.mkdir()
        self.image = self.delivery / "QuickFile-community.dmg"
        self.mount = self.workspace / "mount"
        self.private_image = self.workspace / "community.dmg"
        self.commands = []
        self.attached = False
        self.mounted = False
        self.fail = None
        self.after_attach = None
        self.after_create = None
        self.after_detach = None
        self.partial_attach = False
        self.detach_without_effect = False
        self.inspect_passes = True

    def tearDown(self):
        # These are ordinary fixture directories; no real volume was attached.
        self.temporary.cleanup()

    def tool(self, command):
        self.commands.append(command)
        tool = Path(command[0]).name
        operation = command[1] if tool == "hdiutil" else tool
        if self.fail == operation:
            if operation == "attach" and self.partial_attach:
                self.attach_fixture()
            raise subprocess.CalledProcessError(1, command)
        if tool == "ditto":
            shutil.copytree(command[-2], command[-1], symlinks=True)
        elif operation == "create":
            self.private_image.write_bytes(b"compressed read-only DMG fixture")
            if self.after_create:
                self.after_create()
        elif operation == "verify":
            self.assertEqual(Path(command[-1]), self.private_image)
        elif operation == "attach":
            self.attach_fixture()
            if self.after_attach:
                self.after_attach()
        elif operation == "info":
            images = [{"image-path": "/example/unrelated.dmg", "system-entities": [{"dev-entry": "/dev/disk99", "mount-point": "/Volumes/Unrelated"}]}]
            if self.attached:
                entities = [{"dev-entry": "/dev/disk42"}]
                if self.mounted:
                    entities.append({"dev-entry": "/dev/disk42s1", "mount-point": str(self.mount)})
                images.append({"image-path": str(self.private_image), "system-entities": entities})
            return subprocess.CompletedProcess(command, 0, plistlib.dumps({"images": images}), b"")
        elif operation == "detach":
            self.assertIn(command[-1], (str(self.mount), "/dev/disk42"))
            self.assertNotIn("-force", command)
            if not self.detach_without_effect:
                for entry in self.mount.iterdir():
                    if entry.is_symlink() or entry.is_file():
                        entry.unlink()
                    else:
                        shutil.rmtree(entry)
                self.attached = False
                self.mounted = False
            if self.after_detach:
                self.after_detach()
        else:
            raise AssertionError(command)
        return subprocess.CompletedProcess(command, 0, b"", b"")

    def attach_fixture(self):
        self.attached = True
        self.mounted = True
        shutil.copytree(self.workspace / "source", self.mount, symlinks=True, dirs_exist_ok=True)

    def inspect(self, app):
        return {"verdict": "pass" if self.inspect_passes else "fail"}

    def create(self):
        with patch.object(MODULE, "run", side_effect=self.tool), patch.object(MODULE.ARTIFACT, "inspect_artifact", side_effect=self.inspect), patch.object(MODULE.os.path, "ismount", side_effect=lambda path: Path(path) == self.mount and self.mounted):
            return MODULE.create_dmg(self.app, self.image, self.workspace)

    def assert_clean_failure(self):
        self.assertFalse(self.image.exists())
        self.assertEqual(list(self.workspace.iterdir()), [])
        self.assertFalse(self.attached)

    def test_success_checks_every_byte_mode_link_and_detaches_before_publication(self):
        before = MODULE.ARTIFACT.tree_manifest(self.app)
        self.after_detach = lambda: self.assertFalse(self.image.exists())
        report = self.create()
        self.assertEqual(before, MODULE.ARTIFACT.tree_manifest(self.app))
        self.assertEqual(list(self.workspace.iterdir()), [])
        self.assertFalse(self.attached)
        self.assertEqual(report["image_sha256"], MODULE.ARTIFACT.sha256(self.image))
        self.assertEqual(report["image_bytes"], self.image.stat().st_size)
        self.assertEqual(report["format"], "UDZO")
        self.assertEqual(report["filesystem"], "HFS+")
        self.assertEqual(report["trust"], "ad-hoc/unnotarized")
        self.assertNotIn(str(self.directory), json.dumps(report))
        create = next(command for command in self.commands if command[1] == "create")
        self.assertIn("UDZO", create)
        self.assertIn("HFS+", create)
        self.assertNotIn("-ov", create)
        attach = next(command for command in self.commands if command[1] == "attach")
        for flag in ("-readonly", "-nobrowse", "-noautoopen", "-mountpoint"):
            self.assertIn(flag, attach)
        self.assertEqual(attach[attach.index("-mountpoint") + 1], str(self.mount))
        operations = [command[1] for command in self.commands if Path(command[0]).name == "hdiutil"]
        self.assertLess(operations.index("verify"), operations.index("attach"))
        self.assertEqual(operations.count("detach"), 1)
        self.assertFalse(any(Path(command[0]).name in ("codesign", "open") for command in self.commands))

    def test_mount_byte_or_mode_tampering_detaches_and_rejects(self):
        for change in ("bytes", "mode"):
            with self.subTest(change=change):
                def tamper():
                    binary = self.mount / "QuickFile.app/Contents/MacOS/QuickFile"
                    if change == "bytes":
                        binary.write_bytes(binary.read_bytes() + b"tampered")
                    else:
                        binary.chmod(0o644)
                self.after_attach = tamper
                with self.assertRaisesRegex(ValueError, "differs"):
                    self.create()
                self.assert_clean_failure()

    def test_mounted_signature_failure_detaches_and_rejects(self):
        self.inspect_passes = False
        with self.assertRaisesRegex(ValueError, "artifact verification"):
            self.create()
        self.assert_clean_failure()

    def test_wrong_applications_link_detaches_and_rejects(self):
        def tamper():
            shortcut = self.mount / "Applications"
            shortcut.unlink()
            shortcut.symlink_to("/unexpected")
        self.after_attach = tamper
        with self.assertRaisesRegex(ValueError, "shortcut"):
            self.create()
        self.assert_clean_failure()

    def test_create_verify_and_attach_failures_clean_confirmed_unmounted_workspace(self):
        for operation in ("create", "verify", "attach"):
            with self.subTest(operation=operation):
                self.fail = operation
                with self.assertRaises(subprocess.CalledProcessError):
                    self.create()
                self.assert_clean_failure()
        self.assertFalse(any(command[1] == "detach" for command in self.commands if Path(command[0]).name == "hdiutil"))

    def test_partial_attach_failure_detaches_only_own_volume(self):
        self.fail = "attach"
        self.partial_attach = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.create()
        self.assert_clean_failure()
        detach = [command for command in self.commands if command[1] == "detach"]
        self.assertEqual(detach, [["/usr/bin/hdiutil", "detach", str(self.mount)]])

    def test_detach_failure_preserves_private_image_mount_and_record_without_delivery(self):
        self.fail = "detach"
        with self.assertRaises(MODULE.DMGCleanupError) as caught:
            self.create()
        self.assertTrue(caught.exception.preserve_workspace)
        self.assertTrue(self.private_image.is_file())
        self.assertTrue((self.mount / "QuickFile.app").is_dir())
        self.assertTrue((self.workspace / "source").is_dir())
        self.assertFalse(self.image.exists())
        record = json.loads((self.workspace / "mount-state.json").read_text())
        self.assertEqual(record["cleanup"], "failed or unconfirmed")
        self.assertNotIn(str(self.directory), json.dumps(record))

    def test_unconfirmed_detach_preserves_workspace(self):
        self.detach_without_effect = True
        with self.assertRaisesRegex(MODULE.DMGCleanupError, "unconfirmed"):
            self.create()
        self.assertTrue(self.private_image.exists())
        self.assertTrue((self.workspace / "mount-state.json").exists())
        self.assertFalse(self.image.exists())

    def test_unknown_attachment_state_preserves_workspace_and_never_detaches_unrelated_image(self):
        self.fail = "info"
        with self.assertRaisesRegex(MODULE.DMGCleanupError, "state is unknown"):
            self.create()
        self.assertTrue(self.private_image.exists())
        self.assertTrue((self.mount / "QuickFile.app").is_dir())
        self.assertFalse(any(command[1] == "detach" for command in self.commands if Path(command[0]).name == "hdiutil"))
        self.assertFalse(self.image.exists())

    def test_detach_success_with_unknown_confirmation_preserves_private_image(self):
        self.after_detach = lambda: setattr(self, "fail", "info")
        with self.assertRaisesRegex(MODULE.DMGCleanupError, "state is unknown"):
            self.create()
        self.assertFalse(self.mounted)
        self.assertTrue(self.private_image.is_file())
        self.assertTrue((self.workspace / "mount-state.json").is_file())
        self.assertFalse(self.image.exists())

    def test_failed_attach_with_an_unmounted_own_device_detaches_only_that_device(self):
        self.fail = "attach"
        self.partial_attach = True
        def device_only():
            self.attached = True
            self.mounted = False
        with patch.object(self, "attach_fixture", side_effect=device_only):
            with self.assertRaises(subprocess.CalledProcessError):
                self.create()
        self.assert_clean_failure()
        detach = [command for command in self.commands if command[1] == "detach"]
        self.assertEqual(detach, [["/usr/bin/hdiutil", "detach", "/dev/disk42"]])

    def test_partial_publication_failure_removes_only_its_own_partial_image(self):
        def interrupted(stream, output, **kwargs):
            output.write(b"partial")
            raise OSError("copy interrupted")
        with patch.object(MODULE.shutil, "copyfileobj", side_effect=interrupted):
            with self.assertRaisesRegex(OSError, "interrupted"):
                self.create()
        self.assert_clean_failure()

    def test_published_image_byte_mismatch_is_rejected_and_removed(self):
        def corrupt(stream, output, **kwargs):
            output.write(b"wrong image bytes")
        with patch.object(MODULE.shutil, "copyfileobj", side_effect=corrupt):
            with self.assertRaisesRegex(ValueError, "published DMG bytes differ"):
                self.create()
        self.assert_clean_failure()

    def test_source_changed_during_creation_is_detected_without_helper_mutating_input(self):
        def external_change():
            (self.app / "Contents/Resources/fixture.txt").write_text("external mutation")
        self.after_create = external_change
        with self.assertRaisesRegex(ValueError, "input application changed"):
            self.create()
        self.assert_clean_failure()
        self.assertEqual((self.app / "Contents/Resources/fixture.txt").read_text(), "external mutation")

    def test_existing_output_and_publication_race_never_overwrite_other_owners(self):
        self.image.symlink_to(self.delivery / "missing")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.create()
        self.assertTrue(self.image.is_symlink())
        self.assertEqual(self.commands, [])
        self.image.unlink()
        self.image.write_bytes(b"existing")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.create()
        self.assertEqual(self.image.read_bytes(), b"existing")
        self.image.unlink()
        self.after_detach = lambda: self.image.write_bytes(b"other owner")
        with self.assertRaises(FileExistsError):
            self.create()
        self.assertEqual(self.image.read_bytes(), b"other owner")
        self.assertEqual(list(self.workspace.iterdir()), [])

    def test_workspace_must_be_empty_and_outside_the_app(self):
        marker = self.workspace / "other-owner"
        marker.write_text("keep")
        with self.assertRaisesRegex(ValueError, "empty"):
            self.create()
        self.assertEqual(marker.read_text(), "keep")
        self.assertEqual(self.commands, [])
        marker.unlink()
        self.workspace = self.app / "Contents/temporary"
        self.workspace.mkdir()
        with self.assertRaisesRegex(ValueError, "overlap"):
            self.create()
        self.assertEqual(self.commands, [])


if __name__ == "__main__":
    unittest.main()
