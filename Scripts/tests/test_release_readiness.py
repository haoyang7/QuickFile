import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("zsh"), "zsh is unavailable")
class ReleaseReadinessTests(unittest.TestCase):
    def setUp(self):
        temporary_root = ROOT / ".build/Temporary/release-readiness-tests"
        temporary_root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=temporary_root)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.scripts = self.root / "Scripts"
        self.scripts.mkdir()
        # Run the complete production flow; substitute only macOS inspection
        # tools so no real App, SDK build or Launch Services operation is used.
        source = (ROOT / "Scripts/verify-release-readiness.sh").read_text()
        for command in ("/usr/libexec/PlistBuddy", "/usr/bin/sips", "/usr/bin/lipo"):
            source = source.replace(command, str(self.root / "bin" / Path(command).name))
        (self.scripts / "verify-release-readiness.sh").write_text(source)
        for name in ("ci-evidence.py", "resolve-packages.py", "verify-build-settings.py"):
            shutil.copyfile(ROOT / "Scripts" / name, self.scripts / name)
        (self.scripts / "verify-architecture.py").write_text(
            "import os\nraise SystemExit(int(os.environ.get('ARCHITECTURE_EXIT', '0')))\n"
        )
        self.lock = self.root / "QuickFile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        self.lock.parent.mkdir(parents=True)
        self.lock.write_text("committed pinned packages\n")
        icons = self.root / "QuickFileApp/Assets.xcassets/AppIcon.appiconset"
        icons.mkdir(parents=True)
        for stem in ("16", "32", "128", "256", "512"):
            for suffix in ("", "@2x"):
                (icons / f"icon_{stem}x{stem}{suffix}.png").touch()
        bins = self.root / "bin"
        bins.mkdir()
        mock = bins / "mock"
        mock.write_text('''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import signal
import sys
name = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["FIXTURE_ROOT"])
def value(option):
    return args[args.index(option) + 1]
def record(stage):
    with (root / "calls.jsonl").open("a") as stream:
        stream.write(json.dumps({"stage": stage, "arguments": args}) + "\\n")
if name == "xcodegen":
    record("xcodegen-" + args[0])
    print("Version: 2.46.0")
elif name == "git":
    record("git")
    if "--quiet" in args and os.environ.get("PROJECT_DRIFT") == "1":
        sys.exit(1)
elif name == "PlistBuddy":
    key = args[1].removeprefix("Print :")
    values = {"com.apple.security.application-groups:0": "group.com.haoyoung.QuickFile",
              "com.apple.security.files.bookmarks.app-scope": "true",
              "CFBundleIdentifier": ("com.haoyoung.QuickFile.FinderExtension" if "FinderExtension" in args[-1] else "com.haoyoung.QuickFile"),
              "LSMinimumSystemVersion": "13.0", "CFBundleIconName": "AppIcon",
              "LSApplicationCategoryType": "public.app-category.utilities",
              "QuickFileUpdatesEnabled": "NO", "SUEnableInstallerLauncherService": "true",
              "SUEnableDownloaderService": "true", "SUEnableAutomaticChecks": "false",
              "SUAllowsAutomaticUpdates": "false", "SUSendProfileInfo": "false", "CFBundleVersion": "1"}
    print(values[key])
elif name == "sips":
    size = int(Path(args[-1]).name.split("_")[1].split("x")[0])
    if "@2x" in args[-1]: size *= 2
    print(f"{args[1]}: {size}")
elif name == "lipo":
    print("arm64 x86_64")
elif name == "xcodebuild":
    stage = ("resolve" if "-resolvePackageDependencies" in args else
             "settings" if "-showBuildSettings" in args else args[-1])
    record(stage)
    packages = Path(value("-clonedSourcePackagesDirPath"))
    packages.mkdir(parents=True, exist_ok=True)
    (packages / "cache").write_text("temporary")
    if stage == "test" and os.environ.get("CLEANUP_FAILURE") == "1":
        locked = packages / "locked"
        locked.mkdir()
        (locked / "cache").write_text("cannot be removed")
        locked.chmod(0o500)
    if "-derivedDataPath" in args:
        if "-alltargets" in args or "-scheme" not in args:
            raise SystemExit("DerivedData requires a scheme and is incompatible with alltargets")
        data = Path(value("-derivedDataPath"))
        data.mkdir(parents=True, exist_ok=True)
        (data / "cache").write_text("temporary")
    elif stage == "settings":
        products = next(arg.split("=", 1)[1] for arg in args if arg.startswith("SYMROOT="))
        intermediates = next(arg.split("=", 1)[1] for arg in args if arg.startswith("OBJROOT="))
        Path(products).mkdir(parents=True, exist_ok=True)
        Path(intermediates).mkdir(parents=True, exist_ok=True)
    if stage in ("test", "build"):
        result = Path(value("-resultBundlePath"))
        result.mkdir()
        (result / "diagnostic.txt").write_text("preserve this failed or successful result")
        app = data / "Build/Products" / ("Debug" if stage == "test" else "Release") / "QuickFile.app/Contents/Resources"
        app.mkdir(parents=True)
        (app / "AppIcon.icns").touch()
        # Xcode 26.3 still plans registration when the former, unsupported
        # REGISTER_APP_WITH_LAUNCH_SERVICES setting is supplied. Model that
        # side effect without accessing the machine's registration database.
        with (root / "registrations.jsonl").open("a") as stream:
            stream.write(json.dumps(str(app.parents[1])) + "\\n")
        if os.environ.get("PRODUCT_SYMLINK") == stage:
            shutil = __import__("shutil")
            shutil.rmtree(data)
            data.symlink_to(root / "external-cache", target_is_directory=True)
        if os.environ.get("SIGNAL_STAGE") == stage:
            os.kill(os.getppid(), int(os.environ.get("SIGNAL_NUMBER", signal.SIGTERM)))
    if stage == "settings":
        entries = []
        for target in ("QuickFile", "QuickFileCore", "QuickFileInfrastructure", "QuickFileApplication", "FinderExtension", "QuickFileTests"):
            settings = {"MACOSX_DEPLOYMENT_TARGET": "13.0"}
            if target in ("QuickFile", "FinderExtension"): settings["ENABLE_HARDENED_RUNTIME"] = "YES"
            if target not in ("QuickFile", "QuickFileTests"): settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
            if target == "QuickFile": settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
            if os.environ.get("UNSAFE_SETTINGS") == "1": settings["MACOSX_DEPLOYMENT_TARGET"] = "12.0"
            entries.append({"target": target, "buildSettings": settings})
        print(json.dumps(entries))
    if stage == "build" and os.environ.get("LOCK_DRIFT") == "1":
        lock = root / "QuickFile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        lock.write_text("unexpected drift")
    if os.environ.get("FAIL_STAGE") == stage:
        sys.exit(int(os.environ.get("FAIL_CODE", "65")))
else:
    raise SystemExit("unexpected fixture command")
''')
        mock.chmod(0o755)
        for name in ("xcodegen", "xcodebuild", "git", "PlistBuddy", "sips", "lipo"):
            (bins / name).symlink_to(mock)
        self.env = dict(os.environ, FIXTURE_ROOT=str(self.root),
                        PATH=str(bins) + os.pathsep + os.environ["PATH"])
        for name in ("QUICKFILE_RESULT_DIRECTORY", "GITHUB_ACTIONS"):
            self.env.pop(name, None)

    def run_verification(self, **environment):
        return subprocess.run(["zsh", str(self.scripts / "verify-release-readiness.sh")],
                              env=dict(self.env, **environment), capture_output=True, text=True,
                              timeout=30, check=False)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def xcode_calls(self):
        return [call for call in self.calls() if call["stage"] in ("resolve", "settings", "test", "build")]

    def receipts(self):
        return list((self.root / ".build/Temporary").glob("release-readiness.*/records/cleanup.json"))

    def assert_cleaned(self, code):
        receipts = self.receipts()
        self.assertEqual(len(receipts), 1)
        receipt = json.loads(receipts[0].read_text())
        self.assertEqual(receipt["verification_exit_code"], code)
        self.assertTrue(receipt["build_products_removed"])
        self.assertEqual(receipt["cleanup_errors"], [])
        task = receipts[0].parent.parent
        self.assertFalse(list(task.rglob("*.app")))
        for name in ("Tests", "Release", "SourcePackages"):
            self.assertFalse((task / name).exists())
        return task

    def test_success_uses_new_owned_paths_and_preserves_results(self):
        external = self.root / "external-results"
        result = self.run_verification(QUICKFILE_RESULT_DIRECTORY=str(external))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Unsigned release readiness verification passed", result.stdout)
        first_calls = self.xcode_calls()
        self.assertEqual([call["stage"] for call in first_calls], ["resolve", "settings", "test", "build"])
        task = self.assert_cleaned(0)
        for call in first_calls:
            arguments = call["arguments"]
            packages = Path(arguments[arguments.index("-clonedSourcePackagesDirPath") + 1])
            self.assertEqual(packages, task / "SourcePackages")
            if call["stage"] == "settings":
                self.assertIn("-alltargets", arguments)
                self.assertIn(f"SYMROOT={task / 'Release/Build/Products'}", arguments)
                self.assertIn(f"OBJROOT={task / 'Release/Build/Intermediates.noindex'}", arguments)
            else:
                derived = Path(arguments[arguments.index("-derivedDataPath") + 1])
                self.assertIn(derived, (task / "Tests", task / "Release"))
            if call["stage"] != "resolve":
                self.assertNotIn("REGISTER_APP_WITH_LAUNCH_SERVICES=NO", arguments)
        registrations = [json.loads(line) for line in (self.root / "registrations.jsonl").read_text().splitlines()]
        self.assertEqual(registrations, [
            str(task / "Tests/Build/Products/Debug/QuickFile.app"),
            str(task / "Release/Build/Products/Release/QuickFile.app"),
        ])
        # Cache cleanup cannot prove that Launch Services state was restored.
        self.assertTrue(all(not Path(path).exists() for path in registrations))
        for name in ("tests", "release"):
            self.assertTrue((external / f"{name}.xcresult/diagnostic.txt").is_file())
        # A second invocation must never reuse or delete the first invocation.
        sentinel = task / "records/previous.txt"
        sentinel.write_text("previous invocation")
        second = self.run_verification()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(len(self.receipts()), 2)
        self.assertEqual(sentinel.read_text(), "previous invocation")
        self.assertTrue((external / "tests.xcresult/diagnostic.txt").exists())

    def test_failures_keep_original_exit_and_results_but_remove_owned_products(self):
        for stage in ("resolve", "settings", "test", "build"):
            with self.subTest(stage=stage):
                # Each subcase gets its own complete independent mock project.
                if stage != "resolve":
                    self.temporary.cleanup()
                    self.setUp()
                result = self.run_verification(FAIL_STAGE=stage, FAIL_CODE="75")
                self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
                self.assertNotIn("Unsigned release readiness verification passed", result.stdout)
                task = self.assert_cleaned(75)
                self.assertEqual(self.xcode_calls()[-1]["stage"], stage)
                for name in ("tests", "release"):
                    expected = stage == "build" or (stage == "test" and name == "tests")
                    self.assertEqual((task / f"Results/{name}.xcresult/diagnostic.txt").exists(), expected)

    def test_signals_keep_signal_exit_and_cleanup(self):
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                if signum != signal.SIGHUP:
                    self.temporary.cleanup()
                    self.setUp()
                result = self.run_verification(SIGNAL_STAGE="test", SIGNAL_NUMBER=str(signum))
                self.assertEqual(result.returncode, 128 + signum, result.stdout + result.stderr)
                task = self.assert_cleaned(128 + signum)
                self.assertTrue((task / "Results/tests.xcresult/diagnostic.txt").exists())
                self.assertFalse((task / "Results/release.xcresult").exists())

    def test_existing_or_symlinked_external_results_are_not_reused_or_removed(self):
        external = self.root / "external-results"
        external.mkdir()
        sentinel = external / "user-data.txt"
        sentinel.write_text("user-owned")
        link = self.root / "linked-results"
        link.symlink_to(external, target_is_directory=True)
        for provided in (external, link, link / "new-results"):
            with self.subTest(path=provided):
                result = self.run_verification(QUICKFILE_RESULT_DIRECTORY=str(provided))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.xcode_calls(), [])
                self.assertEqual(sentinel.read_text(), "user-owned")
                self.assertTrue(link.is_symlink())
        self.assertEqual(list(external.iterdir()), [sentinel])

    def test_owned_symlink_cleanup_leaves_external_target_intact(self):
        external = self.root / "external-cache"
        external.mkdir()
        sentinel = external / "user-data.txt"
        sentinel.write_text("user-owned")
        result = self.run_verification(PRODUCT_SYMLINK="test", FAIL_STAGE="test")
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assert_cleaned(65)
        self.assertEqual(sentinel.read_text(), "user-owned")

    @unittest.skipIf(os.geteuid() == 0, "permission failures require a non-root user")
    def test_cleanup_error_fails_success_and_preserves_original_failure(self):
        for stage, expected in (("", 1), ("test", 65)):
            with self.subTest(stage=stage):
                if stage:
                    self.temporary.cleanup()
                    self.setUp()
                try:
                    result = self.run_verification(CLEANUP_FAILURE="1", FAIL_STAGE=stage)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                    self.assertNotIn("Unsigned release readiness verification passed", result.stdout)
                    receipt_path, = self.receipts()
                    receipt = json.loads(receipt_path.read_text())
                    self.assertEqual(receipt["verification_exit_code"], 65 if stage else 0)
                    self.assertFalse(receipt["build_products_removed"])
                    self.assertTrue(receipt["cleanup_errors"])
                    task = receipt_path.parent.parent
                    self.assertFalse((task / "Tests").exists())
                    self.assertFalse((task / "Release").exists())
                    self.assertTrue((task / "Results/tests.xcresult/diagnostic.txt").exists())
                finally:
                    for locked in (self.root / ".build/Temporary").glob("release-readiness.*/SourcePackages/locked"):
                        locked.chmod(0o700)

    def test_lock_and_security_gates_still_fail_and_cleanup(self):
        for setting in ("LOCK_DRIFT", "UNSAFE_SETTINGS", "PROJECT_DRIFT", "ARCHITECTURE_EXIT"):
            with self.subTest(gate=setting):
                if setting != "LOCK_DRIFT":
                    self.temporary.cleanup()
                    self.setUp()
                result = self.run_verification(**{setting: "1", "GITHUB_ACTIONS": "true"})
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assert_cleaned(1)
                if setting in ("PROJECT_DRIFT", "ARCHITECTURE_EXIT"):
                    self.assertEqual(self.xcode_calls(), [])


if __name__ == "__main__":
    unittest.main()
