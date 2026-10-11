"""Exercise delivery identity, exact asset boundaries and source drift rejection."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("community_provenance", ROOT / "Scripts/community-provenance.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CommunityProvenanceTests(unittest.TestCase):
    def setUp(self):
        temporary = ROOT / ".build/Temporary"
        temporary.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="community-provenance-tests-", dir=temporary)
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.delivery = self.base / "delivery"
        self.delivery.mkdir()
        self.tag = "v0.1.0-beta.1"
        self.image = f"QuickFile-{self.tag}.dmg"
        data = b"synthetic DMG fixture"
        self.sha = hashlib.sha256(data).hexdigest()
        (self.delivery / self.image).write_bytes(data)
        (self.delivery / (self.image + ".sha256")).write_text(self.sha + "  " + self.image + "\n")
        (self.delivery / "INSTALL.txt").write_text("synthetic instructions")
        self.receipt = {"verdict": "pass", "trust": "ad-hoc/unnotarized", "version": "0.1.0", "build": "78",
                        "archive": self.image, "archive_sha256": self.sha, "archive_bytes": len(data)}
        self.write_receipt()
        self.env = dict(RELEASE_TAG=self.tag, GITHUB_SHA="a" * 40, WORKFLOW_SHA="a" * 40,
                        GITHUB_REF="refs/heads/codex/example", GITHUB_EVENT_NAME="push",
                        GITHUB_REPOSITORY="example/QuickFile", GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="2",
                        GITHUB_SERVER_URL="https://github.com", RUNNER_OS="macOS", RUNNER_ARCH="ARM64",
                        DEVELOPER_DIR="/Applications/Xcode_26.3.app/Contents/Developer",
                        GITHUB_OUTPUT=str(self.base / "outputs"), PRIVATE_ENV="DO-NOT-PUBLISH")
        self.commands = {("git", "rev-parse", "--verify", "HEAD"): "a" * 40,
                         ("git", "status", "--porcelain", "--untracked-files=normal"): "",
                         ("sw_vers", "-productVersion"): "15.7.1", ("uname", "-m"): "arm64",
                         ("xcodebuild", "-version"): "Xcode 26.3\nBuild version 17C529",
                         ("xcodegen", "version"): "Version: 2.46.0"}

    def write_receipt(self):
        (self.delivery / "artifact-check.json").write_text(json.dumps(self.receipt))

    def write(self):
        with patch.object(MODULE, "output", side_effect=lambda command: self.commands[tuple(command)]):
            return MODULE.write(self.delivery, self.env)

    def test_receipt_binds_exact_assets_to_commit_run_tools_and_internal_build(self):
        payload = self.write()
        self.assertEqual(payload["source_commit"], self.env["GITHUB_SHA"])
        self.assertEqual(payload["release_tag"], self.tag)
        self.assertEqual(payload["internal_build"], "78")
        self.assertEqual(payload["run"]["run_url"], "https://github.com/example/QuickFile/actions/runs/123/attempts/2")
        self.assertEqual(payload["runner"]["xcodegen_version"], "2.46.0")
        self.assertEqual(len(payload["assets"]), 4)
        self.assertEqual(len(list(self.delivery.iterdir())), 5)
        for asset in payload["assets"]:
            data = (self.delivery / asset["name"]).read_bytes()
            self.assertEqual(asset["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(asset["bytes"], len(data))
        receipt = (self.delivery / "build-provenance.json").read_text()
        self.assertNotIn(str(self.base), receipt)
        self.assertNotIn("DO-NOT-PUBLISH", receipt)
        outputs = Path(self.env["GITHUB_OUTPUT"]).read_text()
        self.assertIn("quickfile-community-" + "a" * 40 + "-123-attempt-2", outputs)

    def test_rejects_extra_missing_and_nonregular_assets(self):
        extra = self.delivery / "private-build.log"
        extra.write_text("private")
        with self.assertRaises(ValueError):
            self.write()
        extra.unlink()
        install = self.delivery / "INSTALL.txt"
        install.unlink()
        with self.assertRaises(ValueError):
            self.write()
        install.mkdir()
        with self.assertRaises(ValueError):
            self.write()

    def test_rejects_symlinked_assets_or_delivery(self):
        install = self.delivery / "INSTALL.txt"
        install.unlink()
        install.symlink_to(self.delivery / self.image)
        with self.assertRaises(ValueError):
            self.write()
        install.unlink()
        install.write_text("fixture")
        alias = self.base / "alias"
        alias.symlink_to(self.delivery, target_is_directory=True)
        with self.assertRaises(ValueError):
            MODULE.assets(alias, self.tag)

    def test_rejects_changed_image_checksum_receipt_or_marketing_version(self):
        for key, value in (("archive_sha256", "b" * 64), ("archive_bytes", 0), ("version", "0.2.0"),
                           ("verdict", "fail"), ("trust", "Developer ID"), ("archive", "../private.dmg")):
            original = self.receipt[key]
            self.receipt[key] = value
            self.write_receipt()
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.write()
            self.receipt[key] = original
        self.write_receipt()
        (self.delivery / (self.image + ".sha256")).write_text("incorrect checksum")
        with self.assertRaises(ValueError):
            self.write()

    def test_refuses_event_commit_mismatch_and_tracked_or_untracked_drift(self):
        self.commands[("git", "rev-parse", "--verify", "HEAD")] = "b" * 40
        with self.assertRaises(ValueError):
            self.write()
        self.commands[("git", "rev-parse", "--verify", "HEAD")] = "a" * 40
        for status in (" M project.yml", "?? unexpected-source.swift"):
            self.commands[("git", "status", "--porcelain", "--untracked-files=normal")] = status
            with self.assertRaises(ValueError):
                self.write()
        self.assertFalse((self.delivery / "build-provenance.json").exists())

    def test_git_source_check_rejects_real_worktree_changes_and_wrong_head(self):
        repository = self.base / "repository"
        repository.mkdir()
        def git(*arguments):
            return subprocess.run(["git", "-C", str(repository), *arguments], capture_output=True, text=True, check=True).stdout.strip()
        git("init", "--quiet")
        source = repository / "source.txt"
        source.write_text("original")
        git("add", "source.txt")
        git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "fixture")
        expected = {"GITHUB_SHA": git("rev-parse", "HEAD")}
        original_output = MODULE.output
        with patch.object(MODULE, "output", side_effect=lambda command: original_output(["git", "-C", str(repository), *command[1:]])):
            self.assertEqual(MODULE.verify_source(expected), expected["GITHUB_SHA"])
            source.write_text("changed")
            with self.assertRaises(ValueError):
                MODULE.verify_source(expected)
            source.write_text("original")
            (repository / "unexpected.txt").write_text("untracked")
            with self.assertRaises(ValueError):
                MODULE.verify_source(expected)
            with self.assertRaises(ValueError):
                MODULE.verify_source({"GITHUB_SHA": "b" * 40})

    def test_rejects_injected_tags_and_tag_event_mismatch(self):
        for tag in ("v0.1.0;echo injected", "v0.1.0/../../secret", "v0.1.0\nother=value", "$(echo injected)",
                    "v0.1.0-beta.0", "v0.1.0-rc.1"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                MODULE.release_tag({**self.env, "RELEASE_TAG": tag})
        with self.assertRaises(ValueError):
            MODULE.release_tag({**self.env, "GITHUB_REF": "refs/tags/v0.1.0-beta.2"})
        for tag in ("v0.1.0", "v0.1.0-beta.1"):
            self.assertEqual(MODULE.release_tag({**self.env, "RELEASE_TAG": tag, "GITHUB_REF": "refs/tags/" + tag}), tag)

    def test_rejects_wrong_host_or_tool_version_before_build(self):
        for command, wrong in ((("uname", "-m"), "x86_64"), (("sw_vers", "-productVersion"), "26.0"),
                               (("xcodebuild", "-version"), "Xcode 26.4\nBuild version 17D10"),
                               (("xcodegen", "version"), "Version: 2.47.0")):
            original = self.commands[command]
            self.commands[command] = wrong
            with self.subTest(command=command), self.assertRaises(ValueError):
                self.write()
            self.commands[command] = original

    def test_rejects_stale_provenance_and_metadata_injection(self):
        (self.delivery / "build-provenance.json").write_text("stale")
        with self.assertRaises(ValueError):
            self.write()
        for key, value in (("GITHUB_RUN_ID", "1\nother=value"), ("WORKFLOW_SHA", "short"),
                           ("GITHUB_REPOSITORY", "example/repo\nprivate"), ("GITHUB_EVENT_NAME", "pull_request")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                MODULE.metadata({**self.env, key: value})


if __name__ == "__main__":
    unittest.main()
