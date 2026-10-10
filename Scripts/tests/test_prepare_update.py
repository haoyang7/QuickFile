import base64
import importlib.util
import multiprocessing
import os
import plistlib
import subprocess
import tempfile
import unittest
from argparse import Namespace
from unittest.mock import patch
import xml.etree.ElementTree as ET
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("prepare_update", Path(__file__).parents[1] / "prepare-update.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def run_successful_tools(command, **kwargs):
    """Supply fixture artifacts while exercising the real filesystem preparation."""
    tool = Path(command[0]).name
    if len(command) > 1 and Path(command[1]).name == "verify-beta-artifact.py":
        Path(command[command.index("--output") + 1]).write_text('{"status": "passed"}')
    elif tool == "ditto":
        Path(command[-1]).write_bytes(b"final archive")
    elif tool == "generate_appcast":
        feed = Path(command[command.index("-o") + 1])
        if feed.exists():
            root = ET.parse(feed).getroot()
        else:
            root = ET.Element("rss")
            ET.SubElement(root, "channel")
        item = ET.SubElement(root.find("channel"), "item")
        ET.SubElement(item, MODULE.SPARKLE + "version").text = command[command.index("--versions") + 1]
        if "--channel" in command:
            ET.SubElement(item, MODULE.SPARKLE + "channel").text = command[command.index("--channel") + 1]
        archive, = Path(command[-1]).glob("*.zip")
        ET.SubElement(item, "enclosure", {
            "url": command[command.index("--download-url-prefix") + 1] + archive.name,
            "length": str(archive.stat().st_size),
            MODULE.SPARKLE + "edSignature": base64.b64encode(bytes(64)).decode(),
        })
        ET.ElementTree(root).write(feed)
    elif tool != "sign_update":
        raise AssertionError(command)
    return subprocess.CompletedProcess(command, 0)


def prepare_in_process(arguments, started, proceed, result):
    def run(command, **kwargs):
        if Path(command[0]).name == "sign_update":
            started.set()
            if not proceed.wait(10):
                raise TimeoutError("fixture preparation was not released")
        return run_successful_tools(command, **kwargs)

    try:
        with patch.object(MODULE.subprocess, "run", side_effect=run):
            MODULE.prepare(arguments)
        result.put(None)
    except Exception as error:
        result.put(f"{type(error).__name__}: {error}")


class PrepareUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.app = self.directory / "QuickFile.app"
        self.info = {
            "QuickFileUpdatesEnabled": "YES",
            "SUFeedURL": "https://updates.example.org/appcast.xml",
            "SUPublicEDKey": base64.b64encode(bytes(32)).decode(),
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "8",
            "SUEnableInstallerLauncherService": True,
            "SUEnableDownloaderService": True,
        }
        self.write_bundle(self.info)

    def tearDown(self):
        self.temporary.cleanup()

    def write_bundle(self, info, extension_build="8", app=None):
        app = app or self.app
        for path, value in [
            (app / "Contents/Info.plist", info),
            (app / "Contents/PlugIns/FinderExtension.appex/Contents/Info.plist", {
                "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": extension_build
            }),
        ]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(plistlib.dumps(value))

    def arguments(self, build="8", channel="stable", output_name="updates", history=True):
        app = self.directory / f"QuickFile-{build}.app"
        self.write_bundle(dict(self.info, CFBundleVersion=build), extension_build=build, app=app)
        output = self.directory / output_name
        if not output.exists():
            output.mkdir()
            if history:
                (output / "appcast.xml").write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>7</sparkle:version></item></channel></rss>')
        tools = self.directory / "tools"
        tools.mkdir(exist_ok=True)
        for name in ["generate_appcast", "sign_update"]:
            (tools / name).touch()
        return Namespace(app=app, output=output, sparkle_bin=tools,
                         download_url_prefix="https://downloads.example.org/",
                         release_notes=None, key_account="fixture", channel=channel)

    def test_rejects_disabled_updates_and_mismatched_extension(self):
        self.assertEqual(MODULE.read_configuration(self.app)["CFBundleVersion"], "8")
        self.write_bundle(self.info, extension_build="7")
        with self.assertRaises(ValueError):
            MODULE.read_configuration(self.app)
        self.info["QuickFileUpdatesEnabled"] = "NO"
        self.write_bundle(self.info)
        with self.assertRaises(ValueError):
            MODULE.read_configuration(self.app)

    def test_rejects_insecure_feed_invalid_key_and_automatic_install(self):
        for field, value in [
            ("SUFeedURL", "http://updates.example.org/appcast.xml"),
            ("SUPublicEDKey", "invalid-key"),
            ("SUAllowsAutomaticUpdates", True),
            ("SUEnableDownloaderService", False),
        ]:
            with self.subTest(field=field):
                changed = dict(self.info, **{field: value})
                self.write_bundle(changed)
                with self.assertRaises(ValueError):
                    MODULE.read_configuration(self.app)

    def test_new_build_must_exceed_stable_and_beta_history(self):
        feed = self.directory / "appcast.xml"
        feed.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>8</sparkle:version><sparkle:channel>beta</sparkle:channel></item></channel></rss>')
        for build in ["7", "8", "8.0"]:
            with self.assertRaises(ValueError):
                MODULE.check_new_build(feed, build)
        MODULE.check_new_build(feed, "9")

    def test_generated_feed_requires_signature_exact_archive_and_channel(self):
        archive = self.directory / "QuickFile-0.1.0-8.zip"
        archive.write_bytes(b"final archive")
        feed = self.directory / "appcast.xml"
        root = ET.Element("rss")
        item = ET.SubElement(ET.SubElement(root, "channel"), "item")
        ET.SubElement(item, MODULE.SPARKLE + "version").text = "8"
        enclosure = ET.SubElement(item, "enclosure", {
            "url": "https://downloads.example.org/QuickFile-0.1.0-8.zip",
            "length": str(archive.stat().st_size),
            MODULE.SPARKLE + "edSignature": base64.b64encode(bytes(64)).decode(),
        })
        def check(channel="stable"):
            ET.ElementTree(root).write(feed)
            MODULE.check_generated_feed(feed, archive, self.info, "https://downloads.example.org/", channel)
        check()
        with self.assertRaises(ValueError):
            check("beta")
        enclosure.set(MODULE.SPARKLE + "edSignature", "")
        with self.assertRaises(ValueError):
            check()
        enclosure.set(MODULE.SPARKLE + "edSignature", base64.b64encode(bytes(64)).decode())
        archive.write_bytes(b"modified archive after signing")
        with self.assertRaises(ValueError):
            check()

    def test_late_signature_failures_preserve_history_and_allow_retry(self):
        # Exercise the Python publication boundary. These are injected tool failures,
        # not a substitute for running Sparkle's cryptographic verifier on macOS.
        for failure in ("unsigned-feed", "verification-rejected", "verification-timeout"):
            with self.subTest(failure=failure):
                arguments = self.arguments(output_name=f"updates-{failure}")
                output = arguments.output
                feed = output / "appcast.xml"
                previous = feed.read_bytes()
                sentinel = output / "QuickFile-0.1.0-7.zip"
                sentinel.write_bytes(b"previous signed release")

                def run(command, **kwargs):
                    tool = Path(command[0]).name
                    if tool == "sign_update":
                        if failure == "verification-rejected":
                            raise subprocess.CalledProcessError(1, command)
                        if failure == "verification-timeout":
                            raise subprocess.TimeoutExpired(command, kwargs["timeout"])
                    result = run_successful_tools(command, **kwargs)
                    if tool == "generate_appcast" and failure == "unsigned-feed":
                        staged_feed = Path(command[command.index("-o") + 1])
                        tree = ET.parse(staged_feed)
                        tree.findall("./channel/item")[-1].find("enclosure").attrib.pop(
                            MODULE.SPARKLE + "edSignature"
                        )
                        tree.write(staged_feed)
                    return result

                expected_error = ValueError if failure == "unsigned-feed" else subprocess.SubprocessError
                with patch.object(MODULE.subprocess, "run", side_effect=run):
                    with self.assertRaises(expected_error):
                        MODULE.prepare(arguments)
                self.assertEqual(feed.read_bytes(), previous)
                self.assertEqual(sentinel.read_bytes(), b"previous signed release")
                self.assertEqual(
                    {path.name for path in output.iterdir()},
                    {"appcast.xml", sentinel.name, ".quickfile-update.lock"},
                )
                # A failed preparation must not consume the build number or leave staging files.
                with patch.object(MODULE.subprocess, "run", side_effect=run_successful_tools):
                    MODULE.prepare(arguments)
                self.assertTrue((output / "QuickFile-0.1.0-8.zip").is_file())

    def test_final_archive_is_verified_before_publication(self):
        arguments = self.arguments()
        checked = []

        def run(command, **kwargs):
            if Path(command[0]).name == "sign_update":
                self.assertEqual(command[1:4], ["--account", "fixture", "--verify"])
                archive = Path(command[4])
                self.assertEqual(archive.read_bytes(), b"final archive")
                self.assertEqual(command[5], base64.b64encode(bytes(64)).decode())
                self.assertEqual(kwargs, {"check": True, "timeout": 60})
                self.assertFalse((arguments.output / archive.name).exists())
                versions = [MODULE.item_version(item) for item in ET.parse(
                    arguments.output / "appcast.xml"
                ).findall("./channel/item")]
                self.assertEqual(versions, ["7"])
                checked.append(archive.name)
            return run_successful_tools(command, **kwargs)

        with patch.object(MODULE.subprocess, "run", side_effect=run):
            MODULE.prepare(arguments)
        self.assertEqual(checked, ["QuickFile-0.1.0-8.zip"])

    def test_failed_artifact_check_leaves_existing_feed_and_archives_untouched(self):
        arguments = self.arguments()
        feed = arguments.output / "appcast.xml"
        previous = feed.read_bytes()
        with patch.object(MODULE.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["artifact-check"])):
            with self.assertRaises(subprocess.CalledProcessError):
                MODULE.prepare(arguments)
        self.assertEqual(feed.read_bytes(), previous)
        self.assertEqual({path.name for path in arguments.output.iterdir()}, {feed.name, ".quickfile-update.lock"})

    def test_concurrent_process_is_rejected_then_retry_preserves_beta_and_stable(self):
        beta = self.arguments(channel="beta")
        stable = self.arguments(build="9")
        previous = (beta.output / "appcast.xml").read_bytes()
        context = multiprocessing.get_context("spawn")
        started, proceed = context.Event(), context.Event()
        result = context.Queue()
        worker = context.Process(target=prepare_in_process, args=(beta, started, proceed, result))
        worker.start()
        try:
            self.assertTrue(started.wait(10), "preparation did not reach signature verification")
            with patch.object(MODULE.subprocess, "run", side_effect=run_successful_tools) as tools:
                with self.assertRaisesRegex(ValueError, "another update preparation"):
                    MODULE.prepare(stable)
                tools.assert_not_called()
            self.assertEqual((beta.output / "appcast.xml").read_bytes(), previous)
        finally:
            proceed.set()
            worker.join(10)
            if worker.is_alive():
                worker.terminate()
                worker.join(5)
        self.assertEqual(worker.exitcode, 0)
        self.assertIsNone(result.get(timeout=5))
        result.close()
        result.join_thread()
        with patch.object(MODULE.subprocess, "run", side_effect=run_successful_tools):
            MODULE.prepare(stable)
        items = ET.parse(stable.output / "appcast.xml").findall("./channel/item")
        self.assertEqual([item.findtext(MODULE.SPARKLE + "version") for item in items], ["7", "8", "9"])
        self.assertEqual([item.findtext(MODULE.SPARKLE + "channel") or "stable" for item in items], ["stable", "beta", "stable"])
        for build in ("8", "9"):
            self.assertEqual((stable.output / f"QuickFile-0.1.0-{build}.zip").read_bytes(), b"final archive")
        with patch.object(MODULE.subprocess, "run") as tools:
            with self.assertRaisesRegex(ValueError, "greater than every existing"):
                MODULE.prepare(beta)
            tools.assert_not_called()

    def test_failed_commit_rolls_back_and_allows_same_build_retry(self):
        real_link = os.link
        for history in (True, False):
            for failure in ("report", "feed", "interrupt"):
                with self.subTest(history=history, failure=failure):
                    arguments = self.arguments(output_name=f"updates-{history}-{failure}", history=history)
                    output = arguments.output
                    feed = output / "appcast.xml"
                    previous = feed.read_bytes() if history else None
                    sentinel = output / "QuickFile-0.1.0-7.zip"
                    sentinel.write_bytes(b"previous release")
                    def link(source, target):
                        if Path(source).name == "artifact-check.json":
                            raise OSError("fixture report promotion failure")
                        return real_link(source, target)
                    if failure == "report":
                        failing_commit = patch.object(os, "link", side_effect=link)
                        error_type = OSError
                    else:
                        error_type = KeyboardInterrupt if failure == "interrupt" else OSError
                        failing_commit = patch.object(Path, "replace", side_effect=error_type("fixture feed replacement failure"))
                    with patch.object(MODULE.subprocess, "run", side_effect=run_successful_tools), failing_commit:
                        with self.assertRaises(error_type):
                            MODULE.prepare(arguments)
                    self.assertEqual(feed.read_bytes() if feed.exists() else None, previous)
                    self.assertEqual(sentinel.read_bytes(), b"previous release")
                    self.assertFalse((output / "QuickFile-0.1.0-8.zip").exists())
                    self.assertFalse((output / "QuickFile-0.1.0-8.artifact-check.json").exists())
                    expected = {sentinel.name, ".quickfile-update.lock"}
                    if history:
                        expected.add(feed.name)
                    self.assertEqual({path.name for path in output.iterdir()}, expected)
                    with patch.object(MODULE.subprocess, "run", side_effect=run_successful_tools):
                        MODULE.prepare(arguments)
                    self.assertEqual((output / "QuickFile-0.1.0-8.zip").read_bytes(), b"final archive")
                    self.assertEqual((output / "QuickFile-0.1.0-8.artifact-check.json").read_text(), '{"status": "passed"}')
                    versions = [item.findtext(MODULE.SPARKLE + "version") for item in ET.parse(feed).findall("./channel/item")]
                    self.assertEqual(versions, ["7", "8"] if history else ["8"])

    def test_exception_after_feed_replace_preserves_committed_release(self):
        real_replace = Path.replace
        for history in (True, False):
            for error_type in (KeyboardInterrupt, OSError):
                with self.subTest(history=history, error_type=error_type):
                    arguments = self.arguments(output_name=f"committed-{history}-{error_type.__name__}", history=history)
                    output = arguments.output
                    feed = output / "appcast.xml"
                    sentinel = output / "QuickFile-0.1.0-7.zip"
                    sentinel.write_bytes(b"previous release")

                    def replace_then_raise(source, target):
                        real_replace(source, target)
                        # The filesystem has committed, but Path.replace has not
                        # returned: a boolean assigned after the call is too late.
                        raise error_type("fixture interruption after committed rename")

                    with patch.object(MODULE.subprocess, "run", side_effect=run_successful_tools), \
                            patch.object(Path, "replace", replace_then_raise):
                        with self.assertRaises(error_type):
                            MODULE.prepare(arguments)
                    archive = output / "QuickFile-0.1.0-8.zip"
                    report = output / "QuickFile-0.1.0-8.artifact-check.json"
                    self.assertTrue(archive.is_file(), "committed feed must retain its archive")
                    self.assertEqual(archive.read_bytes(), b"final archive")
                    self.assertEqual(report.read_text(), '{"status": "passed"}')
                    self.assertEqual(sentinel.read_bytes(), b"previous release")
                    self.assertEqual({path.name for path in output.iterdir()}, {
                        feed.name, archive.name, report.name, sentinel.name, ".quickfile-update.lock",
                    })
                    MODULE.check_generated_feed(feed, archive, self.info,
                                                arguments.download_url_prefix, arguments.channel)
                    versions = [MODULE.item_version(item) for item in ET.parse(feed).findall("./channel/item")]
                    self.assertEqual(versions, ["7", "8"] if history else ["8"])
                    # This build is complete, so retry must not overwrite it.
                    with patch.object(MODULE.subprocess, "run") as tools:
                        with self.assertRaisesRegex(ValueError, "greater than every existing"):
                            MODULE.prepare(arguments)
                        tools.assert_not_called()
                    next_arguments = self.arguments(build="9", output_name=output.name)
                    with patch.object(MODULE.subprocess, "run", side_effect=run_successful_tools):
                        MODULE.prepare(next_arguments)
                    self.assertEqual(archive.read_bytes(), b"final archive")
                    self.assertEqual(report.read_text(), '{"status": "passed"}')

    def test_uncertain_feed_identity_does_not_delete_promoted_artifacts(self):
        real_replace = Path.replace
        real_stat = Path.stat
        temporary_root = self.directory / "temporary-root"
        temporary_root.mkdir()
        aliased_root = self.directory / "aliased-temporary-root"
        aliased_root.symlink_to(temporary_root, target_is_directory=True)
        for root in (temporary_root, aliased_root):
            for committed in (False, True):
                with self.subTest(root=root.name, committed=committed):
                    with patch.object(self, "directory", root):
                        arguments = self.arguments(output_name=f"uncertain-{root.name}-{committed}")
                    # prepare() resolves the output directory, including macOS's
                    # /var -> /private/var alias. Resolve before patching stat so
                    # fault matching is canonical without recursive mocked calls.
                    feed = arguments.output.resolve() / "appcast.xml"
                    reconciling = False
                    faulted_paths = []

                    def replace_then_raise(source, target):
                        nonlocal reconciling
                        if committed:
                            real_replace(source, target)
                        reconciling = True
                        raise KeyboardInterrupt("fixture interruption with unreadable feed identity")

                    def stat(path, *args, **kwargs):
                        if reconciling and path == feed:
                            faulted_paths.append(path)
                            raise PermissionError("fixture feed stat denied")
                        return real_stat(path, *args, **kwargs)

                    with patch.object(MODULE.subprocess, "run", side_effect=run_successful_tools), \
                            patch.object(Path, "replace", replace_then_raise), patch.object(Path, "stat", stat):
                        with self.assertRaises(KeyboardInterrupt):
                            MODULE.prepare(arguments)
                    self.assertEqual(faulted_paths, [feed], "feed identity fault must actually be injected")
                    self.assertEqual((arguments.output / "QuickFile-0.1.0-8.zip").read_bytes(), b"final archive")
                    self.assertEqual((arguments.output / "QuickFile-0.1.0-8.artifact-check.json").read_text(), '{"status": "passed"}')
                    versions = [MODULE.item_version(item) for item in ET.parse(feed).findall("./channel/item")]
                    self.assertEqual(versions, ["7", "8"] if committed else ["7"])

    def test_rollback_requires_the_original_staged_feed_identity(self):
        staged = self.directory / "staged.xml"
        target = self.directory / "target.xml"
        staged.write_bytes(b"same feed bytes")
        target.write_bytes(staged.read_bytes())
        identity = staged.stat()
        # Equal bytes do not prove that the rename committed.
        self.assertTrue(MODULE.feed_is_uncommitted(staged, target, identity))
        replacement = self.directory / "replacement.xml"
        replacement.write_bytes(staged.read_bytes())
        replacement.replace(staged)
        self.assertFalse(MODULE.feed_is_uncommitted(staged, target, identity))
        staged.unlink()
        self.assertFalse(MODULE.feed_is_uncommitted(staged, target, identity))

    def test_existing_release_artifacts_are_preserved(self):
        for suffix in (".zip", ".artifact-check.json"):
            for symlink in (False, True):
                with self.subTest(suffix=suffix, symlink=symlink):
                    arguments = self.arguments(output_name=f"updates-{suffix}-{symlink}")
                    target = arguments.output / ("QuickFile-0.1.0-8" + suffix)
                    missing = self.directory / "missing"
                    if symlink:
                        target.symlink_to(missing)
                    else:
                        target.write_bytes(b"previous artifact")
                    previous = (arguments.output / "appcast.xml").read_bytes()
                    with patch.object(MODULE.subprocess, "run") as tools:
                        with self.assertRaisesRegex(ValueError, "release artifact already exists"):
                            MODULE.prepare(arguments)
                        tools.assert_not_called()
                    if symlink:
                        self.assertTrue(target.is_symlink())
                        self.assertEqual(target.readlink(), missing)
                    else:
                        self.assertEqual(target.read_bytes(), b"previous artifact")
                    self.assertEqual((arguments.output / "appcast.xml").read_bytes(), previous)

    def test_artifact_created_during_preparation_is_not_overwritten_or_rolled_back(self):
        for suffix in (".zip", ".artifact-check.json"):
            with self.subTest(suffix=suffix):
                arguments = self.arguments(output_name=f"updates-late-{suffix}")
                target = arguments.output / ("QuickFile-0.1.0-8" + suffix)
                previous = (arguments.output / "appcast.xml").read_bytes()
                def run(command, **kwargs):
                    if Path(command[0]).name == "sign_update":
                        target.write_bytes(b"concurrent artifact")
                    return run_successful_tools(command, **kwargs)
                with patch.object(MODULE.subprocess, "run", side_effect=run):
                    with self.assertRaises(FileExistsError):
                        MODULE.prepare(arguments)
                self.assertEqual(target.read_bytes(), b"concurrent artifact")
                self.assertEqual((arguments.output / "appcast.xml").read_bytes(), previous)
                self.assertEqual({path.name for path in arguments.output.iterdir()}, {target.name, "appcast.xml", ".quickfile-update.lock"})


if __name__ == "__main__":
    unittest.main()
