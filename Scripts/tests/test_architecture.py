import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/verify-architecture.py"
TEMPORARY = ROOT / ".build/Temporary/architecture-optimization"


class ArchitectureFixture(unittest.TestCase):
    def setUp(self):
        TEMPORARY.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="architecture-test-", dir=TEMPORARY)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        shutil.copytree(ROOT / "Shared", self.root / "Shared")
        self.spec = (ROOT / "project.yml").read_text()
        (self.root / "project.yml").write_text(self.spec)

    def run_guard(self, *, root=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(root or self.root)],
            text=True, capture_output=True, check=False,
        )

    def change_spec(self, old, new):
        self.assertIn(old, self.spec)
        (self.root / "project.yml").write_text(self.spec.replace(old, new, 1))

    def assert_failure(self, text):
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn(text, result.stderr)


class ArchitectureTests(ArchitectureFixture):
    def test_current_workspace_and_copy_pass(self):
        for root in (ROOT, self.root):
            with self.subTest(root="workspace" if root == ROOT else "fixture"):
                result = self.run_guard(root=root)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertEqual(len(result.stdout.splitlines()), 3)

    def test_added_unlisted_shared_file_fails(self):
        (self.root / "Shared/Unlisted.swift").write_text("import Foundation\n")
        self.assert_failure("Shared/Unlisted.swift")

    def test_omitted_source_fails(self):
        self.change_spec("      - path: Shared/FileTemplate.swift\n", "")
        self.assert_failure("missing from library targets: Shared/FileTemplate.swift")

    def test_missing_source_fails(self):
        (self.root / "Shared/FileTemplate.swift").unlink()
        self.assert_failure("source does not exist: Shared/FileTemplate.swift")

    def test_duplicate_source_in_same_or_another_library_fails(self):
        for anchor in ("Shared/TemplateDraft.swift", "Shared/AuthorizedDirectory.swift"):
            with self.subTest(anchor=anchor):
                self.change_spec(
                    f"      - path: {anchor}",
                    f"      - path: {anchor}\n      - path: Shared/FileTemplate.swift",
                )
                self.assert_failure("duplicate Shared source ownership")

    def test_shared_cannot_also_compile_in_app_extension_or_tests(self):
        for anchor in ("QuickFileApp", "FinderExtension", "QuickFileTests"):
            with self.subTest(target=anchor):
                self.change_spec(
                    f"      - path: {anchor}\n",
                    f"      - path: Shared/FileTemplate.swift\n      - path: {anchor}\n",
                )
                self.assert_failure("Shared sources may only compile in the three libraries")

    def test_shared_directory_and_root_source_in_app_fail(self):
        for path in ("Shared",):
            with self.subTest(path=path):
                self.change_spec("      - path: QuickFileApp\n", f"      - path: {path}\n")
                self.assert_failure("Shared sources may only compile in the three libraries")

    def test_source_path_aliases_fail_before_ownership_checks(self):
        for anchor, path in (
            ("QuickFileApp", "."), ("QuickFileApp", "./Shared"),
            ("QuickFileApp", "QuickFileApp/../Shared/FileTemplate.swift"),
            ("Shared/AuthorizedDirectory.swift", "Shared/./FileTemplate.swift"),
            ("Shared/AuthorizedDirectory.swift", "Shared//FileTemplate.swift"),
        ):
            with self.subTest(anchor=anchor, path=path):
                self.change_spec(
                    f"      - path: {anchor}\n",
                    f"      - path: {path}\n      - path: {anchor}\n",
                )
                self.assert_failure("canonical repository-relative paths without aliases")

    def test_column_zero_comment_does_not_hide_app_target(self):
        commented = self.spec.replace("  QuickFile:\n", "# Main app target\n  QuickFile:\n", 1)
        (self.root / "project.yml").write_text(commented)
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.root / "project.yml").write_text(commented.replace(
            "      - path: QuickFileApp\n",
            "      - path: Shared/FileTemplate.swift\n      - path: QuickFileApp\n", 1,
        ))
        self.assert_failure("Shared sources may only compile in the three libraries")

    def test_comments_inside_sources_do_not_hide_later_shared_entry(self):
        for comment in ("# App sources", "    # App sources"):
            with self.subTest(comment=comment):
                self.change_spec(
                    "    sources:\n      - path: QuickFileApp\n",
                    f"    sources:\n{comment}\n      - path: Shared/FileTemplate.swift\n      - path: QuickFileApp\n",
                )
                self.assert_failure("Shared sources may only compile in the three libraries")

    def test_library_requires_explicit_files_without_filters(self):
        self.change_spec("      - path: Shared/FileTemplate.swift", "      - path: Shared")
        self.assert_failure("must list individual Shared Swift files")
        self.change_spec(
            "      - path: Shared/FileTemplate.swift",
            '      - path: Shared/FileTemplate.swift\n        excludes: ["*.swift"]',
        )
        self.assert_failure("Shared libraries allow no source filters")

    def test_reverse_dependencies_fail_in_all_libraries(self):
        for library, dependency in (
            ("QuickFileCore", "QuickFileInfrastructure"),
            ("QuickFileInfrastructure", "QuickFileApplication"),
            ("QuickFileApplication", "QuickFileInfrastructure"),
            ("QuickFileApplication", "QuickFile"),
            ("QuickFileInfrastructure", "FinderExtension"),
        ):
            with self.subTest(library=library, dependency=dependency):
                section = re.search(rf"^  {library}:\n.*?(?=^  [A-Za-z_]|\Z)", self.spec, re.MULTILINE | re.DOTALL)[0]
                if library == "QuickFileCore":
                    changed = section + f"    dependencies:\n      - target: {dependency}\n"
                else:
                    changed = section.replace("- target: QuickFileCore", f"- target: {dependency}")
                self.change_spec(section, changed)
                self.assert_failure(f"forbidden target dependency: {library} -> {dependency}")

    def test_unsupported_dependency_format_fails_explicitly(self):
        self.change_spec("      - target: QuickFileCore", "      - QuickFileCore")
        self.assert_failure("dependencies must use explicit")

    def test_unsupported_target_names_indentation_and_templates_fail(self):
        for header in ('  "ExtraUI":', "   ExtraUI:", "    ExtraUI:"):
            with self.subTest(header=header):
                (self.root / "project.yml").write_text(
                    self.spec + f"\n{header}\n    sources:\n      - path: Shared/FileTemplate.swift\n"
                )
                self.assert_failure("error:")
        (self.root / "project.yml").write_text("include: extra.yml\n" + self.spec)
        self.assert_failure("without includes or target templates")

    def test_top_level_keys_require_current_unquoted_format(self):
        for key in ("include", "targetTemplates", "options"):
            for spelling in (f"{key} :", f'"{key}":', f"'{key}':"):
                with self.subTest(spelling=spelling):
                    (self.root / "project.yml").write_text(f"{spelling} extra.yml\n" + self.spec)
                    self.assert_failure("unsupported top-level key syntax")
        for key in ("include", "targetTemplates"):
            with self.subTest(key=key):
                (self.root / "project.yml").write_text(f"{key}: extra.yml\n" + self.spec)
                self.assert_failure("without includes or target templates")

    def test_deeply_indented_source_path_cannot_be_hidden_as_source_option(self):
        self.change_spec(
            "      - path: QuickFileApp\n",
            "      - path: QuickFileApp\n        - path: Shared/FileTemplate.swift\n",
        )
        self.assert_failure("sources must use explicit")

    def test_reverse_import_variants_fail(self):
        variants = (
            "import QuickFile", "@testable import QuickFile",
            "@preconcurrency import QuickFile", "@_implementationOnly import QuickFile",
            "import struct QuickFile.Model", "import func QuickFile.create",
            "internal import QuickFile", "import\n QuickFile",
            "import /* comment */ QuickFile", "import `QuickFile`",
            "import Foundation; import QuickFile", "#if DEBUG\nimport QuickFile\n#endif",
            "import QuickFileInfrastructure", "import QuickFileApplication",
            "import FinderExtension", "import QuickFileFutureUI", "import SwiftUI", "import Sparkle",
        )
        for source in variants:
            with self.subTest(source=source):
                (self.root / "Shared/FileTemplate.swift").write_text(source + "\n")
                self.assert_failure("forbidden import")

    def test_allowed_core_import_variants_pass_in_application(self):
        for declaration in (
            "@testable import QuickFileCore", "@preconcurrency import QuickFileCore",
            "import struct QuickFileCore.FileTemplate", "import enum QuickFileCore.Kind",
            "import typealias QuickFileCore.ID", "import protocol QuickFileCore.Store",
            "import let QuickFileCore.value", "import var QuickFileCore.value",
            "@preconcurrency\nimport QuickFileCore", "import /* comment */ QuickFileCore",
        ):
            with self.subTest(declaration=declaration):
                (self.root / "Shared/FinderAuthorizationCoordinator.swift").write_text(declaration + "\n")
                result = self.run_guard()
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_comments_and_strings_do_not_create_imports(self):
        (self.root / "Shared/FileTemplate.swift").write_text('''
// import QuickFile
/* import QuickFile /* import SwiftUI */ import Sparkle */
let text = "import QuickFile"
let raw = #"import SwiftUI"#
let escaped = "\\\" import QuickFile"
let multiline = """
import Sparkle
"""
import struct Foundation.Date
import AppKit
''')
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unrecognized_import_format_fails_explicitly(self):
        (self.root / "Shared/FileTemplate.swift").write_text("import 123\n")
        self.assert_failure("unsupported Swift import syntax at line 1")


class GeneratedProjectSyncTests(ArchitectureFixture):
    # Execute the unchanged XcodeGen stage in bash, including real Git diffs.
    # This exercises the shell gate on Linux without installing zsh or Xcode.
    def setUp(self):
        super().setUp()
        scripts = self.root / "Scripts"
        scripts.mkdir()
        shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
        self.managed = [
            "QuickFile.xcodeproj/project.pbxproj",
            "QuickFile.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
            "QuickFile.xcodeproj/xcshareddata/xcschemes/QuickFile.xcscheme",
            "QuickFileApp/Info.plist", "QuickFileApp/QuickFile.entitlements",
            "FinderExtension/Info.plist", "FinderExtension/FinderExtension.entitlements",
        ]
        self.unmanaged = "QuickFile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        for path in [*self.managed, self.unmanaged, "README.md"]:
            file = self.root / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("committed fixture\n")
        self.git("init", "-q")
        self.git("add", ".")
        tree = self.git("write-tree").stdout.strip()
        # Synthetic HEAD is fixture-local; no commit operation touches ROOT.
        commit = self.git("commit-tree", tree, input="Synthetic test fixture\n").stdout.strip()
        self.git("update-ref", "HEAD", commit)
        generator = self.root / "xcodegen-fixture"
        generator.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
if sys.argv[1] == "generate":
    Path("generated.marker").write_text("generated")
    path = os.environ.get("GENERATED_CHANGE")
    if path:
        Path(path).write_text("regenerated fixture\\n")
''')
        generator.chmod(0o755)
        self.generator = generator
        source = (ROOT / "Scripts/verify-release-readiness.sh").read_text()
        start = source.index('print -- "Checking XcodeGen"')
        end = source.index("\nverify_plist_value() {", start)
        self.stage = source[start:end]

    def git(self, *arguments, input=None):
        env = os.environ.copy()
        env.update({"GIT_AUTHOR_NAME": "Fixture", "GIT_COMMITTER_NAME": "Fixture",
                    "GIT_AUTHOR_EMAIL": "fixture@example.invalid", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"})
        return subprocess.run(
            ["git", *arguments], cwd=self.root, env=env, input=input,
            text=True, capture_output=True, check=True,
        )

    def run_stage(self, *, ci=True, change=None):
        env = os.environ.copy()
        env.update({"GITHUB_ACTIONS": "true" if ci else "false",
                    "SCRIPT_DIRECTORY": str(self.root / "Scripts"),
                    "XCODEGEN_COMMAND": str(self.generator), "GENERATED_CHANGE": change or ""})
        # bash equivalent of zsh's print used by this stage only.
        prelude = '''set -euo pipefail
print() {
    if [[ "${1:-}" == "-u2" ]]; then
        shift
        [[ "${1:-}" != "--" ]] || shift
        printf '%s\\n' "$*" >&2
    else
        [[ "${1:-}" != "--" ]] || shift
        printf '%s\\n' "$*"
    fi
}
'''
        return subprocess.run(
            ["bash", "-c", prelude + self.stage], cwd=self.root, env=env,
            text=True, capture_output=True, check=False,
        )

    def test_ci_clean_generated_outputs_pass(self):
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "generated.marker").exists())

    def test_ci_each_managed_output_drift_fails_after_generation(self):
        for path in self.managed:
            with self.subTest(path=path):
                result = self.run_stage(change=path)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("out of sync", result.stderr)
                self.assertIn(path, result.stdout)
                (self.root / path).write_text("committed fixture\n")

    def test_ci_dirty_tracked_output_fails_before_generation(self):
        (self.root / self.managed[0]).write_text("already dirty\n")
        self.git("add", self.managed[0])
        result = self.run_stage()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("must be clean before", result.stderr)
        self.assertFalse((self.root / "generated.marker").exists())

    def test_local_dirty_workspace_passes_even_if_generator_updates_outputs(self):
        (self.root / self.managed[0]).write_text("already dirty\n")
        result = self.run_stage(ci=False, change=self.managed[0])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "generated.marker").exists())

    def test_ci_unrelated_files_lock_and_untracked_outputs_are_excluded(self):
        (self.root / "README.md").write_text("unrelated change\n")
        (self.root / "QuickFile.xcodeproj/xcshareddata/xcschemes/Untracked.xcscheme").write_text("untracked\n")
        result = self.run_stage(change=self.unmanaged)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
