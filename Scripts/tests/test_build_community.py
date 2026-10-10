"""Exercise the build script's actual cleanup heredoc on owned product fixtures."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "build-community.sh"
TEMPORARY = ROOT / ".build" / "Temporary"


class CommunityBuildCleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        match = re.search(
            r'python3 - "\$TASK_DIRECTORY" "\$result" <<\'PY\'[^\n]*\n(.*?)\nPY(?:\n|$)',
            SCRIPT.read_text(), re.DOTALL,
        )
        if match is None:
            raise AssertionError("Build cleanup Python heredoc was not found")
        cls.cleanup_code = compile(match.group(1), str(SCRIPT), "exec")

    def setUp(self):
        TEMPORARY.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="community-build-cleanup-tests-", dir=TEMPORARY)
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.products = [self.directory / name for name in ("DerivedData", "SourcePackages", "Release.xcresult")]
        for product in self.products:
            product.mkdir()
            (product / "keep-on-error.txt").write_text("owned fixture")
        records = self.directory / "records"
        records.mkdir()
        (records / "build.log").write_text("RegisterWithLaunchServices owned/QuickFile.app\n")
        self.app = self.directory / "DerivedData/Build/Products/Release/QuickFile.app"
        framework = self.app / "Contents/Frameworks/Sparkle.framework"
        self.updater = framework / "Versions/B/Updater.app"
        self.updater.mkdir(parents=True)
        (framework / "Versions/Current").symlink_to("B", target_is_directory=True)
        self.alias = framework / "Updater.app"
        self.alias.symlink_to("Versions/Current/Updater.app", target_is_directory=True)
        self.commands = []

    def run_cleanup(self, *, failed_path=None, build_exit_code=0):
        def run(arguments, **kwargs):
            # No system command executes: only the registration calls used by
            # cleanup are accepted, and an alias is modeled as a failed unregister.
            tool = Path(arguments[0]).name
            self.assertIn(tool, ("lsregister", "pluginkit"))
            self.commands.append(arguments)
            failed = arguments[-1] == str(self.alias) or arguments[-1] == str(failed_path)
            return subprocess.CompletedProcess(arguments, int(failed), "", "unregister failed" if failed else "")

        original_exists = Path.exists
        installed = Path("/Applications/QuickFile.app")

        def exists(path):
            # Isolate installed-app inspection without reading the user's app.
            return False if path == installed else original_exists(path)

        with patch.object(subprocess, "run", side_effect=run), \
                patch.object(Path, "exists", autospec=True, side_effect=exists), \
                patch.object(sys, "argv", [str(SCRIPT), str(self.directory), str(build_exit_code)]):
            with self.assertRaises(SystemExit) as exited:
                exec(self.cleanup_code, {"__name__": "__main__"})
        report = json.loads((self.directory / "records/cleanup.json").read_text())
        return exited.exception.code, report

    def assert_owned_unregisters(self, report):
        self.assertEqual([command[1:] for command in self.commands], [
            ["-u", str(self.updater)], ["-u", str(self.app)],
        ])
        self.assertEqual(sum(command[-1] == str(self.updater) for command in self.commands), 1)
        self.assertFalse(any(command[-1] == str(self.alias) for command in self.commands))
        self.assertEqual([action["command"] for action in report["registration_actions"]], self.commands)

    def test_unregisters_real_updater_once_skips_alias_and_removes_products(self):
        self.assertTrue(self.alias.is_symlink())
        self.assertTrue(self.alias.exists())
        exit_code, report = self.run_cleanup()
        self.assertEqual(exit_code, 0)
        self.assert_owned_unregisters(report)
        self.assertEqual([action["exit_code"] for action in report["registration_actions"]], [0, 0])
        self.assertTrue(report["build_products_removed"])
        self.assertEqual(report["cleanup_errors"], [])
        self.assertEqual(report["build_exit_code"], 0)
        self.assertFalse(report["installed"])
        self.assertFalse(report["published"])
        self.assertTrue(all(not product.exists() for product in self.products))
        self.assertTrue((self.directory / "records/build.log").exists())

    def test_unregister_failure_preserves_products_and_records_error(self):
        exit_code, report = self.run_cleanup(failed_path=self.updater, build_exit_code=65)
        self.assertNotEqual(exit_code, 0)
        self.assert_owned_unregisters(report)
        self.assertEqual([action["exit_code"] for action in report["registration_actions"]], [1, 0])
        self.assertEqual(report["registration_actions"][0]["output"], "unregister failed")
        self.assertFalse(report["build_products_removed"])
        self.assertEqual(report["cleanup_errors"], ["registration cleanup failed"])
        self.assertEqual(report["build_exit_code"], 65)
        self.assertTrue(self.alias.is_symlink())
        for product in self.products:
            self.assertEqual((product / "keep-on-error.txt").read_text(), "owned fixture")


if __name__ == "__main__":
    unittest.main()
