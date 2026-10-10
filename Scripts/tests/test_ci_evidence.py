import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


PROJECT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT / "Scripts" / "ci-evidence.py"
SPEC = importlib.util.spec_from_file_location("ci_evidence", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def environment(base):
    return dict(EXPECTED_RUNNER="macos-26", EXPECTED_MACOS_MAJOR="26", EXPECTED_ARCHITECTURE="arm64",
                EXPECTED_XCODE_VERSION="26.3", DEVELOPER_DIR="/Applications/Xcode_26.3.app/Contents/Developer",
                GITHUB_REPOSITORY="example/QuickFile", GITHUB_RUN_ID="12345", GITHUB_RUN_ATTEMPT="2",
                GITHUB_JOB="macos", GITHUB_WORKFLOW="CI", GITHUB_EVENT_NAME="pull_request",
                GITHUB_SHA="b" * 40, WORKFLOW_SHA="c" * 40, PR_HEAD_SHA="d" * 40, PR_BASE_SHA="e" * 40,
                RUNNER_TEMP=str(base), GITHUB_OUTPUT=str(base / "github-output"),
                GITHUB_STEP_SUMMARY=str(base / "github-summary"), IDENTITY_OUTCOME="success", TOOLS_OUTCOME="success",
                SCRIPTS_OUTCOME="success", NATIVE_OUTCOME="success", JOB_STATUS="success", PRIVATE_ENV="NEVER-UPLOAD-ME")


def actual():
    return dict(macos_version="26.6.2", macos_build="25G83", architecture="arm64", xcode="26.3", xcode_build="17C529",
                macos_sdk="26.2", swift_version="6.2.3", swift_build="swiftlang-6.2.3.3.2", clang_build="clang-1700.6.3.2",
                python="3.13.9")


class CIEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        # /var -> /private/var on macOS is a normal system alias; use canonical fixtures.
        self.base = Path(self.temporary.name).resolve()
        self.env = environment(self.base)

    def initialize(self, host=None):
        with patch.object(MODULE, "output", return_value="a" * 40), patch.object(MODULE, "actual_identity", return_value=host or actual()):
            code = MODULE.initialize(self.env)
        outputs = dict(line.split("=", 1) for line in Path(self.env["GITHUB_OUTPUT"]).read_text().splitlines())
        return code, Path(outputs["root"]), outputs["artifact_name"]

    def native(self, root, code=0, bundles=("tests", "release")):
        program = "\n".join([
            "import os; from pathlib import Path",
            "p=Path(os.environ['QUICKFILE_RESULT_DIRECTORY']); p.mkdir()",
            *[f"(p/'{name}.xcresult').mkdir(); (p/'{name}.xcresult'/'private.log').write_text('NEVER-UPLOAD-ME')" for name in bundles],
            f"raise SystemExit({code})",
        ])
        return MODULE.run_native(root, [sys.executable, "-c", program])

    def finish(self, root):
        with patch.object(MODULE, "optional_tool", return_value="Version: 2.46.0"):
            return MODULE.finish(root, self.env)

    def test_runner_temp_platform_alias_is_canonicalized_before_new_child_creation(self):
        private_var = self.base / "private" / "var"
        runner_temp = private_var / "runner-temp"
        runner_temp.mkdir(parents=True)
        var_alias = self.base / "var"
        var_alias.symlink_to(private_var, target_is_directory=True)
        self.env["RUNNER_TEMP"] = str(var_alias / "runner-temp")
        code, root, _ = self.initialize()
        self.assertEqual(code, 0)
        self.assertEqual(root.parent, runner_temp)
        self.assertNotIn(var_alias, root.parents)
        MODULE.no_symlinks(root)
        self.assertEqual(self.native(root), 0)
        self.assertEqual(self.finish(root), 0)
        MODULE.check_upload(root)

    def test_runner_temp_requires_existing_clean_absolute_directory(self):
        file_root = self.base / "regular-file"
        file_root.write_text("not a directory")
        for path in ("relative", self.base / ".." / self.base.name, self.base / "missing", file_root, str(self.base) + "\n"):
            with self.subTest(path=path), self.assertRaises((ValueError, OSError)):
                MODULE.canonical_runner_temp(path)

    def test_canonical_runner_base_does_not_allow_symlinked_evidence_children(self):
        _, root, _ = self.initialize()
        actual_upload = root / "original-upload"
        (root / "upload").rename(actual_upload)
        (root / "upload").symlink_to(actual_upload, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.native(root)
        with self.assertRaises(ValueError):
            self.finish(root)
        (root / "upload").unlink()
        actual_upload.rename(root / "upload")
        other_results = self.base / "other-results"
        other_results.mkdir()
        (root / "results").symlink_to(other_results, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.native(root)
        with self.assertRaises(ValueError):
            MODULE.prepare_results(root / "results")
        self.assertEqual(list(other_results.iterdir()), [])

    def test_every_matrix_lane_and_developer_directory_is_explicit(self):
        for runner, major, arch, xcode in MODULE.LANES:
            env = dict(self.env, EXPECTED_RUNNER=runner, EXPECTED_MACOS_MAJOR=major, EXPECTED_ARCHITECTURE=arch,
                       EXPECTED_XCODE_VERSION=xcode, DEVELOPER_DIR=f"/Applications/Xcode_{xcode}.app/Contents/Developer")
            self.assertEqual(MODULE.expected_identity(env)["runner"], runner)
        for key, value in (("EXPECTED_ARCHITECTURE", "x86_64"), ("EXPECTED_MACOS_MAJOR", "15"),
                           ("EXPECTED_XCODE_VERSION", "26.6"), ("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                MODULE.expected_identity(dict(self.env, **{key: value}))

    def test_os_architecture_and_actual_xcode_must_all_match(self):
        expected = MODULE.expected_identity(self.env)
        self.assertTrue(MODULE.identity_matches(expected, actual()))
        for key, value in (("macos_version", "15.7.9"), ("architecture", "x86_64"), ("xcode", "26.6"), ("xcode_build", None)):
            self.assertFalse(MODULE.identity_matches(expected, dict(actual(), **{key: value})))

    def test_actual_tool_versions_are_parsed_not_raw_copied(self):
        outputs = {
            ("xcodebuild", "-version"): "Xcode 26.3\nBuild version 17C529",
            ("sw_vers", "-productVersion"): "26.6.2", ("sw_vers", "-buildVersion"): "25G83",
            ("uname", "-m"): "arm64", ("xcrun", "--sdk", "macosx", "--show-sdk-version"): "26.2",
            ("xcrun", "swift", "--version"): "Apple Swift version 6.2.3 (swiftlang-6.2.3.3.2 clang-1700.6.3.2)\nTarget: arm64-apple-macosx26.0",
        }
        with patch.object(MODULE, "output", side_effect=lambda args: outputs[tuple(args)]):
            observed = MODULE.actual_identity()
        self.assertEqual(observed["swift_build"], actual()["swift_build"])
        self.assertEqual(observed["xcode"], "26.3")
        self.assertNotIn("Target", json.dumps(observed))
        outputs[("xcodebuild", "-version")] += "\nPRIVATE-SECRET"
        with patch.object(MODULE, "output", side_effect=lambda args: outputs[tuple(args)]):
            self.assertIsNone(MODULE.actual_identity()["xcode"])

    def test_receipts_bind_checkout_event_pr_and_job_identities(self):
        code, root, artifact = self.initialize()
        self.assertEqual(code, 0)
        self.assertIn("macos-26-arm64-xcode-26.3-12345-attempt-2", artifact)
        identity = MODULE.read_json(root / "upload" / "identity.json")
        self.assertEqual(identity["source"]["checkout_sha"], "a" * 40)
        self.assertEqual(identity["source"]["event_sha"], "b" * 40)
        self.assertEqual(identity["source"]["pr_head_sha"], "d" * 40)
        self.assertEqual(identity["source"]["pr_base_sha"], "e" * 40)
        self.assertEqual(identity["source"]["workflow_sha"], "c" * 40)
        self.assertEqual(identity["source"]["job"], "macos")
        MODULE.validate_identity(identity)
        self.assertNotIn("NEVER-UPLOAD-ME", json.dumps(identity))
        self.assertNotIn(str(self.base), json.dumps(identity))

    def test_attempts_and_matrix_lanes_get_distinct_artifact_names(self):
        _, root1, name1 = self.initialize()
        self.env["GITHUB_RUN_ATTEMPT"] = "3"
        _, root2, name2 = self.initialize()
        self.env.update(EXPECTED_RUNNER="macos-15", EXPECTED_MACOS_MAJOR="15")
        _, root3, name3 = self.initialize(dict(actual(), macos_version="15.7.9"))
        self.assertEqual(len({root1, root2, root3}), 3)
        self.assertEqual(len({name1, name2, name3}), 3)

    def test_identity_failure_still_leaves_bounded_failure_evidence(self):
        code, root, _ = self.initialize(dict(actual(), macos_version="26.6", xcode="26.6"))
        self.assertEqual(code, 1)
        with self.assertRaises(ValueError):
            self.native(root)
        self.env.update(IDENTITY_OUTCOME="failure", TOOLS_OUTCOME="skipped", SCRIPTS_OUTCOME="skipped", NATIVE_OUTCOME="skipped", JOB_STATUS="failure")
        self.assertEqual(self.finish(root), 0)
        MODULE.check_upload(root)
        self.assertEqual(MODULE.read_json(root / "upload" / "verification.json")["outcomes"]["identity"], "failure")

    def test_prepare_results_refuses_relative_parent_traversal_and_existing_paths(self):
        for path in ("relative", str(self.base / ".." / "escape"), str(self.base / "new\nline")):
            with self.subTest(path=path), self.assertRaises(ValueError):
                MODULE.prepare_results(path)
        directory = MODULE.prepare_results(self.base / "results")
        sentinel = directory / "old-failure.xcresult"
        sentinel.mkdir()
        with self.assertRaises(FileExistsError):
            MODULE.prepare_results(directory)
        self.assertTrue(sentinel.is_dir())

    def test_prepare_results_rejects_symlink_parent_or_existing_target(self):
        real = self.base / "real"
        real.mkdir()
        link = self.base / "link"
        link.symlink_to(real, target_is_directory=True)
        for path in (link, link / "results"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                MODULE.prepare_results(path)
        self.assertEqual(list(real.iterdir()), [])

    def test_native_failure_exit_and_raw_bundle_are_preserved(self):
        _, root, _ = self.initialize()
        self.assertEqual(self.native(root, code=65, bundles=("tests",)), 65)
        self.env.update(NATIVE_OUTCOME="failure", JOB_STATUS="failure")
        self.assertEqual(self.finish(root), 0)
        MODULE.check_upload(root)
        receipt = MODULE.read_json(root / "upload" / "verification.json")
        self.assertEqual(receipt["native"]["exit_code"], 65)
        self.assertEqual(receipt["native"]["result_bundles_present"], {"tests": True, "release": False})
        self.assertTrue((root / "results" / "tests.xcresult" / "private.log").exists())
        for path in (root / "upload").iterdir():
            self.assertNotIn("NEVER-UPLOAD-ME", path.read_text())
            self.assertNotIn("private.log", path.read_text())
            self.assertLessEqual(path.stat().st_size, MODULE.MAX_FILE_BYTES)
        with self.assertRaises(ValueError):
            self.native(root)
        self.assertTrue((root / "results" / "tests.xcresult").exists())

    def test_native_command_cannot_replace_result_parent_with_symlink(self):
        _, root, _ = self.initialize()
        outside = self.base / "outside-results"
        outside.mkdir()
        for name in ("tests", "release"):
            (outside / f"{name}.xcresult").mkdir()
        program = ("import os; from pathlib import Path; "
                   f"Path(os.environ['QUICKFILE_RESULT_DIRECTORY']).symlink_to({str(outside)!r}, target_is_directory=True)")
        self.assertEqual(MODULE.run_native(root, [sys.executable, "-c", program]), 1)
        native = MODULE.read_json(root / "native-exit.json")
        self.assertEqual(native["result_bundles_present"], {"tests": False, "release": False})
        self.assertTrue((outside / "tests.xcresult").is_dir())

    def test_native_success_requires_both_requested_result_bundles(self):
        _, root, _ = self.initialize()
        self.assertEqual(self.native(root, bundles=("tests",)), 1)
        self.assertEqual(self.finish(root), 1)
        # Even a result-contract failure creates sanitized, inspectable receipts.
        MODULE.check_upload(root)

    def test_success_receipt_records_scope_and_no_raw_data(self):
        _, root, _ = self.initialize()
        self.assertEqual(self.native(root), 0)
        self.assertEqual(self.finish(root), 0)
        self.assertEqual({p.name for p in (root / "upload").iterdir()}, MODULE.UPLOAD_FILES)
        receipt = MODULE.read_json(root / "upload" / "verification.json")
        self.assertEqual(receipt["xcodegen_version"], "2.46.0")
        self.assertIs(receipt["raw_results_uploaded"], False)
        self.assertNotIn("NEVER-UPLOAD-ME", Path(self.env["GITHUB_STEP_SUMMARY"]).read_text())

    def test_upload_allowlist_rejects_extra_files_directories_and_raw_results(self):
        _, root, _ = self.initialize()
        self.native(root)
        self.finish(root)
        for name in ("raw.xcresult", "trace.json", "log.txt", ".env", "certificate.p12"):
            extra = root / "upload" / name
            extra.write_text("NEVER-UPLOAD-ME")
            with self.subTest(name=name), self.assertRaises(ValueError):
                MODULE.check_upload(root)
            extra.unlink()
        (root / "upload" / "DerivedData").mkdir()
        with self.assertRaises(ValueError):
            MODULE.check_upload(root)

    def test_upload_rejects_symlink_size_unknown_fields_and_arbitrary_text(self):
        _, root, _ = self.initialize()
        self.native(root)
        self.finish(root)
        target = root / "upload" / "verification.json"
        original = target.read_text()
        mutations = ["x" * (MODULE.MAX_FILE_BYTES + 1)]
        payload = json.loads(original)
        for change in ({"private_log": "NEVER-UPLOAD-ME"}, {"xcodegen_version": "PRIVATE-VERSION"},
                       {"raw_results_uploaded": True}, {"native": {"exit_code": 65, "result_bundles_present": {"tests": "NEVER-UPLOAD-ME", "release": False}}}):
            mutations.append(json.dumps(dict(payload, **change)))
        for contents in mutations:
            target.write_text(contents)
            with self.subTest(contents=contents[:70]), self.assertRaises(ValueError):
                MODULE.check_upload(root)
        target.unlink()
        secret = self.base / "secret.txt"
        secret.write_text("NEVER-UPLOAD-ME")
        target.symlink_to(secret)
        with self.assertRaises(ValueError):
            MODULE.check_upload(root)
        self.assertEqual(secret.read_text(), "NEVER-UPLOAD-ME")

    def test_upload_rejects_duplicate_keys_and_hardlinks(self):
        _, root, _ = self.initialize()
        self.native(root)
        self.finish(root)
        target = root / "upload" / "verification.json"
        original = target.read_text()
        target.write_text(original.replace('"schema_version": 1', '"schema_version": "NEVER-UPLOAD-ME", "schema_version": 1'))
        with self.assertRaises(ValueError):
            MODULE.check_upload(root)
        target.write_text(original)
        os.link(target, self.base / "linked-receipt.json")
        with self.assertRaises(ValueError):
            MODULE.check_upload(root)

    def test_receipt_growth_after_fstat_still_uses_a_bounded_read_budget(self):
        target = self.base / "growing.json"
        target.write_text('{"safe": true}')
        original_fstat, original_read = os.fstat, os.read
        returned_bytes = 0
        requests = []

        def grow_after_fstat(descriptor):
            info = original_fstat(descriptor)
            with target.open("ab") as stream:
                stream.write(b" " * (MODULE.MAX_FILE_BYTES * 4))
            return info

        def bounded_read(descriptor, size):
            nonlocal returned_bytes
            requests.append(size)
            # Force short reads too, checking the budget spans every call.
            data = original_read(descriptor, min(size, 97))
            returned_bytes += len(data)
            return data

        with patch.object(MODULE.os, "fstat", side_effect=grow_after_fstat), patch.object(MODULE.os, "read", side_effect=bounded_read):
            with self.assertRaisesRegex(ValueError, "receipt exceeds size limit"):
                MODULE.read_json(target)
        self.assertEqual(returned_bytes, MODULE.MAX_FILE_BYTES + 1)
        self.assertTrue(all(0 < size <= MODULE.MAX_FILE_BYTES + 1 for size in requests))
        self.assertGreater(len(requests), 1)

    def test_descriptor_read_accepts_exact_limit_and_rejects_one_extra_byte(self):
        target = self.base / "boundary.json"
        prefix = b'{"safe": true}'
        target.write_bytes(prefix + b" " * (MODULE.MAX_FILE_BYTES - len(prefix)))
        self.assertEqual(MODULE.read_json(target), {"safe": True})
        with target.open("ab") as stream:
            stream.write(b" ")
        with self.assertRaises(ValueError):
            MODULE.read_json(target)

    def test_descriptor_open_rejects_leaf_swapped_to_symlink_or_fifo(self):
        target = self.base / "swapped.json"
        secret = self.base / "private.json"
        secret.write_text('{"private": "NEVER-UPLOAD-ME"}')
        original_guard = MODULE.no_symlinks

        def swap_after_guard(path, kind):
            original_guard(path)
            path.unlink()
            if kind == "symlink":
                path.symlink_to(secret)
            else:
                os.mkfifo(path)

        for kind in ("symlink", "fifo"):
            if target.exists() or target.is_symlink():
                target.unlink()
            target.write_text('{"safe": true}')
            with self.subTest(kind=kind), patch.object(MODULE, "no_symlinks", side_effect=lambda path: swap_after_guard(path, kind)):
                with self.assertRaises((OSError, ValueError)):
                    MODULE.read_json(target)
        self.assertEqual(secret.read_text(), '{"private": "NEVER-UPLOAD-ME"}')

    def test_identity_rejects_unknown_fields_inconsistent_status_and_sensitive_text(self):
        _, root, _ = self.initialize()
        original = MODULE.read_json(root / "upload" / "identity.json")
        for group, key, value in (("actual", "xcode", "SECRET/PATH"), ("source", "checkout_sha", "SECRET"),
                                   ("expected", "developer_directory", "/Users/private/Xcode.app"),
                                   ("source", "extra", "SECRET"), ("actual", "extra", "SECRET")):
            payload = copy.deepcopy(original)
            payload[group][key] = value
            with self.subTest(group=group, key=key), self.assertRaises(ValueError):
                MODULE.validate_identity(payload)
        with self.assertRaises(ValueError):
            MODULE.validate_identity(dict(original, identity_verified=False))

    def test_cli_failure_does_not_echo_private_inputs(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "prepare-results", "PRIVATE-SECRET"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("PRIVATE-SECRET", result.stdout + result.stderr)

    @unittest.skipUnless(shutil.which("zsh"), "zsh is unavailable")
    def test_verification_script_fails_before_build_on_existing_result_path(self):
        _, root, _ = self.initialize()
        results = root / "results"
        results.mkdir()
        sentinel = results / "tests.xcresult"
        sentinel.mkdir()
        bins = self.base / "bin"
        bins.mkdir()
        for name in ("xcodebuild", "xcodegen"):
            path = bins / name
            path.write_text("#!/bin/sh\necho UNEXPECTED-EXECUTION\nexit 99\n")
            path.chmod(0o755)
        result = subprocess.run(["zsh", str(PROJECT / "Scripts" / "verify-release-readiness.sh")], capture_output=True, text=True,
                                env=dict(os.environ, PATH=str(bins) + os.pathsep + os.environ["PATH"], QUICKFILE_RESULT_DIRECTORY=str(results)))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CI evidence validation failed", result.stderr)
        self.assertNotIn("UNEXPECTED-EXECUTION", result.stdout)
        self.assertTrue(sentinel.is_dir())


class CIWorkflowContractTests(unittest.TestCase):
    def setUp(self):
        self.main = (PROJECT / ".github" / "workflows" / "ci.yml").read_text()
        self.preview = (PROJECT / ".github" / "workflows" / "macos-27-compatibility.yml").read_text()

    def rows(self, text):
        # Fixed, intentionally simple matrix syntax: no runtime YAML dependency.
        pattern = (r"- runner: ([\w-]+)\n\s+macos_major: '([0-9]+)'\n\s+architecture: (\w+)"
                   r"\n\s+xcode_version: '([0-9.]+)'\n\s+developer_directory: (\S+)")
        return re.findall(pattern, text)

    def test_main_matrix_keeps_linux_and_both_15_lanes_and_adds_26(self):
        self.assertIn("runs-on: ubuntu-24.04", self.main)
        self.assertEqual(self.rows(self.main), [
            ("macos-15", "15", "arm64", "26.3", "/Applications/Xcode_26.3.app/Contents/Developer"),
            ("macos-15-intel", "15", "x86_64", "26.3", "/Applications/Xcode_26.3.app/Contents/Developer"),
            ("macos-26", "26", "arm64", "26.3", "/Applications/Xcode_26.3.app/Contents/Developer"),
        ])
        self.assertIn("  pull_request:\n", self.main)
        self.assertIn("    needs: scripts\n", self.main)

    def test_preview_is_independent_main_manual_only_and_not_allowed_to_fail(self):
        self.assertEqual(self.rows(self.preview), [("xcode-27", "27", "arm64", "27.0", "/Applications/Xcode_27.0.app/Contents/Developer")])
        self.assertIn("    branches: [main]", self.preview)
        self.assertIn("  workflow_dispatch:\n", self.preview)
        self.assertNotIn("  pull_request:", self.preview)
        self.assertNotIn("pull_request_target", self.preview)
        self.assertNotIn("needs:", self.preview)
        self.assertNotIn("continue-on-error", self.preview)
        self.assertNotIn("required", self.preview)

    def test_mac_steps_are_identical_and_keep_existing_security_checks(self):
        self.assertEqual(self.main.rsplit("    steps:\n", 1)[1], self.preview.rsplit("    steps:\n", 1)[1])
        for text in (self.main, self.preview):
            self.assertIn("permissions:\n  contents: read\n", text)
            self.assertIn("persist-credentials: false", text)
            self.assertIn("shasum --algorithm 256 --check", text)
            self.assertIn("python3 -m unittest discover -s Scripts/tests -v", text)
            self.assertIn("./Scripts/verify-release-readiness.sh", text)
            self.assertLess(text.index("run: python3 Scripts/ci-evidence.py initialize"), text.index("      - name: Install XcodeGen"))
            self.assertIn("DEVELOPER_DIR: ${{ matrix.developer_directory }}", text)
            self.assertNotIn("secrets.", text)
            self.assertNotIn("self-hosted", text)
            self.assertNotIn("xlarge", text)
            self.assertNotIn("continue-on-error", text)

    def test_upload_is_pinned_explicit_bounded_and_failure_preserving(self):
        for text in (self.main, self.preview):
            self.assertIn("if: always() && steps.identity.outputs.root != ''", text)
            self.assertIn("if: always() && steps.evidence.outcome == 'success'", text)
            self.assertIn("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1", text)
            path_block = text.split("          path: |\n")[1].split("          retention-days:")[0]
            self.assertEqual(path_block.splitlines(), ["            ${{ steps.identity.outputs.root }}/upload/identity.json",
                                                     "            ${{ steps.identity.outputs.root }}/upload/verification.json"])
            self.assertIn("retention-days: 7", text)
            self.assertIn("if-no-files-found: error", text)
            self.assertIn("include-hidden-files: false", text)
            self.assertIn("overwrite: false", text)
            self.assertNotIn("*", path_block)

    def test_native_script_requests_separate_fresh_result_bundles(self):
        text = (PROJECT / "Scripts" / "verify-release-readiness.sh").read_text()
        self.assertIn('-resultBundlePath "${TEST_RESULT_BUNDLE}"', text)
        self.assertIn('-resultBundlePath "${RELEASE_RESULT_BUNDLE}"', text)
        self.assertIn('TEST_RESULT_BUNDLE="${RESULT_DIRECTORY}/tests.xcresult"', text)
        self.assertIn('RELEASE_RESULT_BUNDLE="${RESULT_DIRECTORY}/release.xcresult"', text)
        self.assertIn('/usr/bin/mktemp -d', text)
        self.assertIn('prepare-results "${QUICKFILE_RESULT_DIRECTORY}"', text)
        self.assertNotIn('rm -', text)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', text)
        self.assertIn('verify-build-settings.py', text)
        self.assertIn('ARCHS=\'arm64 x86_64\'', text)


if __name__ == "__main__":
    unittest.main()
