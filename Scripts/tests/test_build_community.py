"""Exercise the build script's actual cleanup heredoc on owned product fixtures."""
import json
import importlib.util
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "build-community.sh"
TEMPORARY = ROOT / ".build" / "Temporary"


def load_script(name, filename):
    specification = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / filename)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


PROVENANCE = load_script("build_test_provenance", "community-provenance.py")
ARTIFACT = load_script("build_test_artifact", "verify-community-artifact.py")


def release_tag_cases():
    for number, accepted in (("0", True), ("999999999999999999", True),
                             ("01", False), ("1000000000000000000", False),
                             ("０", False), ("١", False)):
        for index in range(3):
            parts = ["0", "1", "0"]
            parts[index] = number
            yield "v" + ".".join(parts), accepted
    for number, accepted in (("1", True), ("999999999999999999", True), ("0", False),
                             ("01", False), ("1000000000000000000", False), ("１", False), ("١", False)):
        yield "v0.1.0-beta." + number, accepted
    for tag in ("v0.1.0\n", "v0.1.0-beta.1\n", "v0.1.0-rc.1", "0.1.0", ""):
        yield tag, False


class CommunityBuildArgumentsTests(unittest.TestCase):
    def setUp(self):
        TEMPORARY.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix="community-build-arguments-tests-", dir=TEMPORARY)
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.output = self.directory / "new output"
        self.record = self.directory / "package-arguments"
        tools = self.directory / "tools"
        tools.mkdir()
        python = tools / "python3"
        python.write_text(
            '#!/bin/bash\n'
            'if [[ "$1" == Scripts/package-community.py ]]; then\n'
            '    printf "%s\\0" "$@" > "$QUICKFILE_TEST_PACKAGE_ARGUMENTS"\n'
            'else\n'
            f'    exec {shlex.quote(sys.executable)} "$@"\n'
            'fi\n'
        )
        python.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], QUICKFILE_TEST_PACKAGE_ARGUMENTS=str(self.record))
        source = SCRIPT.read_text()
        # Execute the real argument handling and package invocation, without the
        # Xcode build, signature tools or host registration side effects.
        self.program = source.split("command -v xcodegen", 1)[0] + \
            "TASK_DIRECTORY=" + shlex.quote(str(self.directory / "build")) + "\n" + \
            source[source.index("PACKAGE_ARGUMENTS=("):]

    def run_arguments(self, *arguments):
        return subprocess.run(["/bin/bash", "-c", self.program, str(SCRIPT), *arguments], env=self.environment, capture_output=True, text=True)

    def test_old_interface_passes_only_app_and_output(self):
        result = self.run_arguments("--output", str(self.output))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.record.read_bytes().split(b"\0")[:-1], [
            b"Scripts/package-community.py", b"--app", os.fsencode(self.directory / "build/DerivedData/Build/Products/Release/QuickFile.app"),
            b"--output", os.fsencode(self.output),
        ])

    def test_release_tag_is_passed_as_one_argument(self):
        for tag in ("v0.1.0", "v0.1.0-beta.1", "v0.1.0-beta.12"):
            with self.subTest(tag=tag):
                result = self.run_arguments("--output", str(self.output), "--release-tag", tag)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.record.read_bytes().split(b"\0")[-3:], [b"--release-tag", tag.encode(), b""])

    def test_tag_boundaries_agree_before_build_resolve_check_and_artifact_verification(self):
        environment_file = self.directory / "github-environment"
        project = self.directory / "project.yml"
        for tag, accepted in release_tag_cases():
            with self.subTest(tag=tag):
                self.record.unlink(missing_ok=True)
                environment_file.unlink(missing_ok=True)
                with self.subTest(entry="build"):
                    result = self.run_arguments("--output", str(self.output), "--release-tag", tag)
                    self.assertEqual(result.returncode, 0 if accepted else 2, result.stderr)
                    self.assertEqual(self.record.exists(), accepted)
                    self.assertFalse(self.output.exists())
                env = {"RELEASE_TAG": tag, "GITHUB_EVENT_NAME": "workflow_dispatch",
                       "GITHUB_ENV": str(environment_file)}
                version = tag[1:].split("-beta.")[0]
                with self.subTest(entry="resolve"):
                    if accepted:
                        self.assertEqual(PROVENANCE.resolve(env, project), tag)
                        self.assertEqual(environment_file.read_text(), "RELEASE_TAG=" + tag + "\n")
                    else:
                        with self.assertRaises(ValueError):
                            PROVENANCE.resolve(env, project)
                        self.assertFalse(environment_file.exists())
                with self.subTest(entry="artifact"):
                    if accepted:
                        ARTIFACT.validate_release_tag(tag, version)
                    else:
                        with self.assertRaises(ValueError):
                            ARTIFACT.validate_release_tag(tag, version)
                with self.subTest(entry="check"), patch.object(PROVENANCE, "verify_source") as source, \
                        patch.object(PROVENANCE, "verify_host"), patch.object(PROVENANCE, "metadata"):
                    if accepted:
                        PROVENANCE.check(env)
                        source.assert_called_once_with(env)
                    else:
                        with self.assertRaises(ValueError):
                            PROVENANCE.check(env)
                        source.assert_not_called()
                if "-" not in tag and "\n" not in tag:
                    environment_file.unlink(missing_ok=True)
                    project.write_text('MARKETING_VERSION: "' + version + '"\n')
                    branch = dict(env, GITHUB_EVENT_NAME="push", GITHUB_REF="refs/heads/codex/fixture")
                    with self.subTest(entry="branch-project"):
                        if accepted:
                            self.assertEqual(PROVENANCE.resolve(branch, project), tag)
                        else:
                            with self.assertRaises(ValueError):
                                PROVENANCE.resolve(branch, project)
                            self.assertFalse(environment_file.exists())

    def test_rejects_invalid_tags_and_option_shapes_before_packaging(self):
        invalid = [(), ("--unknown", str(self.output)), ("--output",),
                   ("--output", str(self.output), "--unknown", "v0.1.0"),
                   ("--output", str(self.output), "--release-tag")]
        invalid += [("--output", str(self.output), "--release-tag", tag) for tag in (
            "", "0.1.0", "v0.1.0-beta.0", "v0.1.0-beta.01", "v0.1.0-rc.1", "../v0.1.0", "v0.1.0\n", "v0.1.0;touch unwanted",
        )]
        for arguments in invalid:
            with self.subTest(arguments=arguments):
                result = self.run_arguments(*arguments)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.record.exists())
                self.assertFalse(self.output.exists())


class CommunityDebugSymbolsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        match = re.search(r'python3 - "\$TASK_DIRECTORY" <<\'PY\'\n(.*?)\nPY(?:\n|$)',
                          SCRIPT.read_text(), re.DOTALL)
        if match is None:
            raise AssertionError("Debug symbol archive block was not found")
        cls.archive_code = compile(match.group(1), str(SCRIPT), "exec")

    def setUp(self):
        TEMPORARY.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix="community-debug-symbol-tests-", dir=TEMPORARY)
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        (self.directory / "records").mkdir()
        self.products = self.directory / "DerivedData/Build/Products/Release"
        self.products.mkdir(parents=True)
        self.commands = []

    def archive(self, mismatch=False):
        def run(arguments, **kwargs):
            self.commands.append(arguments)
            if arguments[:3] == ["/usr/bin/xcrun", "dwarfdump", "--uuid"]:
                identifier = "11111111-1111-1111-1111-111111111111"
                if mismatch and arguments[-1].endswith("FinderExtension.appex.dSYM"):
                    identifier = "33333333-3333-3333-3333-333333333333"
                return subprocess.CompletedProcess(arguments, 0,
                    f"UUID: {identifier} (arm64) fixture\nUUID: 22222222-2222-2222-2222-222222222222 (x86_64) fixture\n", "")
            self.assertEqual(arguments[:5], ["/usr/bin/ditto", "-c", "-k", "--keepParent", arguments[4]])
            Path(arguments[-1]).write_bytes(b"synthetic symbol archive")
            return subprocess.CompletedProcess(arguments, 0, b"", b"")
        with patch.object(subprocess, "run", side_effect=run), \
                patch.object(sys, "argv", [str(SCRIPT), str(self.directory)]):
            exec(self.archive_code, {"__name__": "__main__"})

    def test_retains_archives_with_both_matching_architecture_uuids(self):
        self.archive()
        report = json.loads((self.directory / "records/debug-symbols.json").read_text())
        self.assertEqual(report["schema_version"], 1)
        self.assertEqual([row["archive"] for row in report["components"]],
                         ["QuickFile.app.dSYM.zip", "FinderExtension.appex.dSYM.zip"])
        for row in report["components"]:
            self.assertEqual(set(row["uuids"]), {"arm64", "x86_64"})
            self.assertEqual(row["bytes"], len(b"synthetic symbol archive"))
            self.assertEqual(len(row["sha256"]), 64)
        self.assertEqual([Path(command[0]).name for command in self.commands],
                         ["xcrun"] * 4 + ["ditto"] * 2)
        self.assertNotIn(str(self.directory), json.dumps(report))

    def test_rejects_mismatched_symbols_before_archiving_any_component(self):
        with self.assertRaisesRegex(ValueError, "do not match"):
            self.archive(mismatch=True)
        self.assertFalse((self.directory / "records/debug-symbols.json").exists())
        self.assertEqual(list((self.directory / "records").glob("*.zip")), [])
        self.assertTrue(all(Path(command[0]).name == "xcrun" for command in self.commands))


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
