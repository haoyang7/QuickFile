import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT / "Scripts" / "ci-scope.py"
SPEC = "project.yml"
PBX = "QuickFile.xcodeproj/project.pbxproj"


class CIScopeTests(unittest.TestCase):
    def setUp(self):
        temporary_root = PROJECT / ".build" / "Temporary"
        configured_root = Path(tempfile.gettempdir()).resolve()
        if configured_root.is_relative_to(temporary_root.resolve()):
            temporary_root = configured_root
        temporary_root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="ci-scope-", dir=temporary_root)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.output = self.root / "output"
        self.summary = self.root / "summary"
        self.spec = (PROJECT / SPEC).read_text()
        self.pbx = (PROJECT / PBX).read_text()
        self.version = re.search(r'CURRENT_PROJECT_VERSION: "([0-9]+)"', self.spec)[1]
        self.next_version = str(int(self.version) + 1)
        self.git("init", "-q", "--object-format=sha1", "-b", "main")
        for path in ("README.md", "LICENSE", "Shared/example.swift", "Scripts/example.md"):
            self.write(path, "initial\n")
        self.write(SPEC, self.spec)
        self.write(PBX, self.pbx)
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output([
            "git", "-c", "user.name=CI fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args,
        ], cwd=self.repo, stderr=subprocess.PIPE, text=True).strip()

    def write(self, path, content):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            target.write_bytes(content)
        else:
            target.write_text(content)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def bump(self, version=None):
        version = self.next_version if version is None else version
        self.write(SPEC, self.spec.replace(f'CURRENT_PROJECT_VERSION: "{self.version}"',
                                          f'CURRENT_PROJECT_VERSION: "{version}"'))
        self.write(PBX, self.pbx.replace(f"CURRENT_PROJECT_VERSION = {self.version};",
                                        f"CURRENT_PROJECT_VERSION = {version};"))

    def classify(self, base=None, head=None, event="pull_request"):
        self.output.unlink(missing_ok=True)
        self.summary.unlink(missing_ok=True)
        base = self.base if base is None else base
        head = self.git("rev-parse", "HEAD") if head is None else head
        result = subprocess.run(["python3", str(SCRIPT)], cwd=self.repo,
                                env=dict(os.environ, GITHUB_EVENT_NAME=event, PR_BASE_SHA=base,
                                         PR_HEAD_SHA=head, PUSH_BEFORE_SHA=base, PUSH_HEAD_SHA=head,
                                         GITHUB_OUTPUT=str(self.output), GITHUB_STEP_SUMMARY=str(self.summary)),
                                capture_output=True, text=True)
        output = dict(line.split("=", 1) for line in self.output.read_text().splitlines()) if self.output.exists() else {}
        return result, output

    def assert_scope(self, scope, **kwargs):
        result, output = self.classify(**kwargs)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, {"scope": scope, "run_checks": str(scope == "full").lower()})
        return self.summary.read_text()

    def test_build_increment_with_optional_root_docs_for_pr_and_push(self):
        for documents in (False, True):
            for event in ("pull_request", "push"):
                with self.subTest(documents=documents, event=event):
                    self.git("reset", "--hard", self.base)
                    self.bump()
                    if documents:
                        self.write("README.md", "updated\n")
                        self.write("LICENSE", "updated\n")
                        self.write("release notes.md", "new\n")
                    head = self.commit()
                    summary = self.assert_scope("build-version", event=event)
                    self.assertIn(f"`{self.version}` → `{self.next_version}`", summary)
                    self.assertIn(self.base, summary)
                    self.assertIn(head, summary)
                    self.assertIn("Debug/Release", summary)
                    self.assertIn("skipped, not tested", summary)
                    self.assertIn("signing and DMG validation are not claimed", summary)

    def test_canonical_build_can_increase_by_more_than_one(self):
        self.bump(str(int(self.version) + 12))
        self.commit()
        self.assert_scope("build-version")

    def test_root_markdown_and_license_only_are_explicitly_not_tested(self):
        self.write("README.md", "updated\n")
        self.write("LICENSE", "updated\n")
        self.write("new documentation.md", "new\n")
        self.commit()
        self.assertIn("skipped, not tested", self.assert_scope("documentation"))

    def test_deleted_root_docs_still_use_documentation_scope(self):
        (self.repo / "README.md").unlink()
        self.commit()
        self.assert_scope("documentation")

    def test_other_paths_require_full_validation_even_with_valid_build_increment(self):
        paths = ("Shared/example.swift", "FinderExtension/file.swift", "QuickFileApp/file.swift",
                 "QuickFileTests/file.swift", ".github/workflows/ci.yml", "Scripts/ci-scope.py",
                 "Scripts/example.md", "Release/example.md", "docs/example.md", "Screenshots/example.png",
                 "root-script.py", "new-uppercase.MD", "QuickFile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                 "Shared/new\nline.swift")
        for path in paths:
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.bump()
                self.write(path, "changed\n")
                self.commit()
                self.assert_scope("full")

    def test_deleted_or_renamed_code_cannot_be_hidden_as_root_documentation(self):
        for rename in (False, True):
            with self.subTest(rename=rename):
                self.git("reset", "--hard", self.base)
                self.bump()
                source = self.repo / "Shared/example.swift"
                if rename:
                    source.rename(self.repo / "former-code.md")
                else:
                    source.unlink()
                self.commit()
                self.assert_scope("full")

    def test_full_diff_includes_code_after_more_than_300_docs(self):
        for index in range(350):
            self.write(f"documentation-{index:03}.md", "new\n")
        self.bump()
        self.write("zzz-code.py", "new\n")
        self.commit()
        self.assert_scope("full")

    def test_only_one_version_file_changed_requires_full_validation(self):
        for path in (SPEC, PBX):
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.bump()
                self.git("restore", path)
                self.commit()
                self.assert_scope("full")

    def test_head_versions_must_match_in_spec_debug_and_release(self):
        mutations = (
            (SPEC, lambda content: content.replace(f'"{self.next_version}"', f'"{int(self.next_version) + 1}"')),
            (PBX, lambda content: content.replace(f"CURRENT_PROJECT_VERSION = {self.next_version};",
                                                 f"CURRENT_PROJECT_VERSION = {self.version};", 1)),
        )
        for path, mutation in mutations:
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.bump()
                self.write(path, mutation((self.repo / path).read_text()))
                self.commit()
                self.assert_scope("full")

    def test_base_versions_must_already_match(self):
        self.write(SPEC, self.spec.replace(f'"{self.version}"', f'"{int(self.version) + 2}"'))
        base = self.commit()
        self.bump()
        self.commit()
        self.assert_scope("full", base=base)

    def test_rollback_and_noncanonical_numbers_require_full_validation(self):
        for version in (str(int(self.version) - 1), "0", "01", "+108", "-1", "108.0", " 108", "1e3"):
            with self.subTest(version=version):
                self.git("reset", "--hard", self.base)
                self.bump(version)
                self.commit()
                self.assert_scope("full")

    def test_same_build_with_formatting_edits_does_not_pass_version_validation(self):
        self.write(SPEC, self.spec.replace(f'"{self.version}"', f'"{self.version}" '))
        self.write(PBX, self.pbx.replace(f"CURRENT_PROJECT_VERSION = {self.version};",
                                        f"CURRENT_PROJECT_VERSION = {self.version}; "))
        self.commit()
        self.assert_scope("full")

    def test_other_version_file_bytes_cannot_change(self):
        changes = ((SPEC, 'MARKETING_VERSION: "0.1.0"', 'MARKETING_VERSION: "0.2.0"'),
                   (SPEC, 'ARCHS: "arm64 x86_64"', 'ARCHS: "arm64"'),
                   (SPEC, "exactVersion: 2.10.0", "exactVersion: 2.11.0"),
                   (SPEC, "settings:\n", "# extra comment\nsettings:\n"),
                   (PBX, "CODE_SIGN_ENTITLEMENTS = FinderExtension/FinderExtension.entitlements;",
                    "CODE_SIGN_ENTITLEMENTS = FinderExtension/other.entitlements;"),
                   (PBX, "MARKETING_VERSION = 0.1.0;", "MARKETING_VERSION = 0.2.0;"),
                   (PBX, "/* Begin XCBuildConfiguration section */", "/* changed comment */"))
        for path, before, after in changes:
            with self.subTest(path=path, before=before):
                self.git("reset", "--hard", self.base)
                self.bump()
                content = (self.repo / path).read_text()
                self.assertIn(before, content)
                self.write(path, content.replace(before, after))
                self.commit()
                self.assert_scope("full")

    def test_duplicate_or_misplaced_assignments_in_base_are_ambiguous(self):
        cases = ((SPEC, self.spec + f'\nother:\n    CURRENT_PROJECT_VERSION: "{self.version}"\n'),
                 (SPEC, self.spec + f'\nother:\n    "CURRENT_PROJECT_VERSION": "{self.version}"\n'),
                 (SPEC, self.spec + '\n"settings": {}\n'),
                 (PBX, self.pbx + f"\n/* CURRENT_PROJECT_VERSION = {self.version}; */\n"),
                 (SPEC, self.spec.replace("settings:\n  base:\n", "other:\n  base:\n")),
                 (PBX, self.pbx.replace('\trootObject = ', '\totherObject = ')),
                 (PBX, self.pbx.replace('/* Begin XCBuildConfiguration section */',
                                        '/* Begin XCBuildConfiguration section */\n'
                                        '\t\tC12D89717304E4B3F36437B9 /* Debug */ = {};')),
                 (PBX, self.pbx.replace('Build configuration list for PBXProject "QuickFile"',
                                        'Build configuration list for PBXProject "Other"')))
        for path, content in cases:
            with self.subTest(path=path, content=content[-80:]):
                self.git("reset", "--hard", self.base)
                self.write(path, content)
                base = self.commit()
                for file in (SPEC, PBX):
                    content = (self.repo / file).read_text()
                    content = content.replace(f'CURRENT_PROJECT_VERSION: "{self.version}"',
                                              f'CURRENT_PROJECT_VERSION: "{self.next_version}"')
                    content = content.replace(f"CURRENT_PROJECT_VERSION = {self.version};",
                                              f"CURRENT_PROJECT_VERSION = {self.next_version};")
                    self.write(file, content)
                self.commit()
                self.assert_scope("full", base=base)

    def test_binary_and_non_utf8_version_files_require_full_validation(self):
        for suffix in (b"\0", b"\xff"):
            for path in (SPEC, PBX):
                with self.subTest(suffix=suffix, path=path):
                    self.git("reset", "--hard", self.base)
                    self.bump()
                    self.write(path, (self.repo / path).read_bytes() + suffix)
                    self.commit()
                    self.assert_scope("full")

    def test_commented_or_nested_project_versions_in_base_require_full_validation(self):
        line = f"\t\t\t\tCURRENT_PROJECT_VERSION = {self.version};"
        cases = (
            self.pbx.replace(line, "\t\t\t\t/*\n" + line + "\n\t\t\t\t*/"),
            self.pbx.replace("/* Begin XCBuildConfiguration section */", "/* Begin XCBuildConfiguration section */\n/*")
                    .replace("/* End XCBuildConfiguration section */", "*/\n/* End XCBuildConfiguration section */"),
            self.pbx.replace(line, "\t\t\t\tOTHER = {\n" + line + "\n\t\t\t\t};"),
            self.pbx.replace(line, '\t\t\t\tOTHER = "\n' + line + '\n\t\t\t\t";'),
        )
        for index, content in enumerate(cases):
            with self.subTest(case=index):
                self.git("reset", "--hard", self.base)
                self.write(PBX, content)
                base = self.commit()
                self.write(SPEC, self.spec.replace(f'CURRENT_PROJECT_VERSION: "{self.version}"',
                                                  f'CURRENT_PROJECT_VERSION: "{self.next_version}"'))
                self.write(PBX, content.replace(f"CURRENT_PROJECT_VERSION = {self.version};",
                                                f"CURRENT_PROJECT_VERSION = {self.next_version};"))
                self.commit()
                for event in ("pull_request", "push"):
                    self.assert_scope("full", base=base, event=event)

    def test_duplicate_or_structurally_ambiguous_shared_base_requires_full_validation(self):
        cases = [self.spec.replace("\npackages:\n", f"\n  {key}: {{}}\n\npackages:\n")
                 for key in ("base", '"base"', "'base'", "base ")]
        cases += [
            self.spec.replace("\npackages:\n", "\n# shared settings continue\n  base: {}\n\npackages:\n"),
            self.spec.replace("settings:\n  base:\n", "settings:\n  'base': {}\n  base:\n"),
            self.spec + "\nsettings : {}\n",
            f'settings:\n  base: |\n    CURRENT_PROJECT_VERSION: "{self.version}"\n\npackages:\n',
            f'settings:\n  base:\n    OTHER: {{\n    CURRENT_PROJECT_VERSION: "{self.version}"\n    }}\n\npackages:\n',
        ]
        for index, content in enumerate(cases):
            with self.subTest(case=index):
                self.git("reset", "--hard", self.base)
                self.write(SPEC, content)
                base = self.commit()
                self.write(SPEC, content.replace(f'CURRENT_PROJECT_VERSION: "{self.version}"',
                                                 f'CURRENT_PROJECT_VERSION: "{self.next_version}"'))
                self.write(PBX, self.pbx.replace(f"CURRENT_PROJECT_VERSION = {self.version};",
                                                f"CURRENT_PROJECT_VERSION = {self.next_version};"))
                self.commit()
                for event in ("pull_request", "push"):
                    self.assert_scope("full", base=base, event=event)

    def test_unsupported_or_duplicate_top_level_yaml_in_base_requires_full_validation(self):
        cases = [self.spec + "\n" + suffix + "\n" for suffix in (
            r'"\u0073ettings": {}',
            "? settings\n: {}",
            "name: Other",
            "options:",
            "'other': value",
            "other: !tag value",
            "other: &anchor value",
            "{settings: {}}",
        )]
        cases += [prefix + self.spec for prefix in (
            "---\n",
            "%YAML 1.2\n",
            "%TAG !example! tag:example.invalid,2026:\n",
        )]
        for index, content in enumerate(cases):
            with self.subTest(case=index):
                self.git("reset", "--hard", self.base)
                self.write(SPEC, content)
                base = self.commit()
                self.write(SPEC, content.replace(f'CURRENT_PROJECT_VERSION: "{self.version}"',
                                                 f'CURRENT_PROJECT_VERSION: "{self.next_version}"'))
                self.write(PBX, self.pbx.replace(f"CURRENT_PROJECT_VERSION = {self.version};",
                                                f"CURRENT_PROJECT_VERSION = {self.next_version};"))
                self.commit()
                for event in ("pull_request", "push"):
                    self.assert_scope("full", base=base, event=event)

    def test_top_level_comments_in_base_preserve_version_fast_path(self):
        content = "# spec comment\n\n" + self.spec + "\n# final comment\n"
        self.write(SPEC, content)
        base = self.commit()
        self.write(SPEC, content.replace(f'CURRENT_PROJECT_VERSION: "{self.version}"',
                                         f'CURRENT_PROJECT_VERSION: "{self.next_version}"'))
        self.write(PBX, self.pbx.replace(f"CURRENT_PROJECT_VERSION = {self.version};",
                                        f"CURRENT_PROJECT_VERSION = {self.next_version};"))
        self.commit()
        for event in ("pull_request", "push"):
            self.assert_scope("build-version", base=base, event=event)

    def test_project_root_object_aliases_and_wrong_dictionary_levels_require_full_validation(self):
        debug = next(match for match in re.finditer(
            r"(?m)^\t\t([0-9A-F]{24}) /\* Debug \*/ = \{\n(?:\t{3}.*\n)*\t\t\};\n", self.pbx)
            if "CURRENT_PROJECT_VERSION" in match[0])
        debug_id = debug[1]
        list_id = re.search(r'buildConfigurationList = ([0-9A-F]{24}) /\* Build configuration list for PBXProject', self.pbx)[1]
        root_id = re.search(r"rootObject = ([0-9A-F]{24})", self.pbx)[1]
        empty_debug = " = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };\n"
        object_entries = (
            f'\t\t"{debug_id}"' + empty_debug,
            f'\t{debug_id}' + empty_debug,
            '\t\t"\\U' + f'{ord(debug_id[0]):04X}' + debug_id[1:] + '"' + empty_debug,
        )
        cases = [self.pbx.replace("/* End XCBuildConfiguration section */", entry + "/* End XCBuildConfiguration section */")
                 for entry in object_entries]
        for entry in ('"objects" = {};', f'"rootObject" = {debug_id};',
                      '"obj\\U0065cts" = {};', 'obj\\U0065cts = {};',
                      'objects = {};', f'rootObject = {debug_id};'):
            before, after = self.pbx.rsplit("}", 1)
            cases.append(before + "\t" + entry + "\n}" + after)
        # Identical indentation does not put an object in the objects dictionary.
        for identifier in (debug_id, list_id, root_id):
            block = re.search(r"(?m)^\t\t" + identifier + r" /\*[^\n]*\*/ = \{\n(?:\t{3}.*\n)*\t\t\};\n", self.pbx)[0]
            moved = self.pbx.replace(block, "")
            cases.append(moved.replace("\tclasses = {\n", "\tclasses = {\n" + block))
        # A similarly indented reference inside attributes is not the project's
        # actual buildConfigurationList property.
        other_list = re.search(r"buildConfigurationList = ([0-9A-F]{24}) /\* Build configuration list for PBXNativeTarget", self.pbx)[1]
        reference = f'buildConfigurationList = {list_id} /* Build configuration list for PBXProject "QuickFile" */;'
        redirected = self.pbx.replace(reference, f"buildConfigurationList = {other_list};")
        cases.append(redirected.replace("\t\t\t\tLastUpgradeCheck = 1430;\n",
                                        "\t\t\t\tLastUpgradeCheck = 1430;\n\t\t\t" + reference + "\n"))
        for index, content in enumerate(cases):
            with self.subTest(case=index):
                self.git("reset", "--hard", self.base)
                self.write(PBX, content)
                base = self.commit()
                self.write(SPEC, self.spec.replace(f'CURRENT_PROJECT_VERSION: "{self.version}"',
                                                  f'CURRENT_PROJECT_VERSION: "{self.next_version}"'))
                self.write(PBX, content.replace(f"CURRENT_PROJECT_VERSION = {self.version};",
                                                f"CURRENT_PROJECT_VERSION = {self.next_version};"))
                self.commit()
                for event in ("pull_request", "push"):
                    self.assert_scope("full", base=base, event=event)

    def test_project_structure_ignores_comment_and_string_container_text(self):
        content = self.pbx.replace("\t\t\t\tLastUpgradeCheck = 1430;\n",
                                   '\t\t\t\tLastUpgradeCheck = 1430;\n'
                                   '\t\t\t\tScopeProbe = "\\"objects\\" = {}; ( ) // literal";\n')
        content = content.replace("/* End XCBuildConfiguration section */",
                                  '/* "objects" = {}; "rootObject" = hidden; */\n'
                                  "/* End XCBuildConfiguration section */")
        self.assertNotEqual(content, self.pbx)
        self.write(PBX, content)
        base = self.commit()
        self.write(SPEC, self.spec.replace(f'CURRENT_PROJECT_VERSION: "{self.version}"',
                                          f'CURRENT_PROJECT_VERSION: "{self.next_version}"'))
        self.write(PBX, content.replace(f"CURRENT_PROJECT_VERSION = {self.version};",
                                        f"CURRENT_PROJECT_VERSION = {self.next_version};"))
        self.commit()
        for event in ("pull_request", "push"):
            self.assert_scope("build-version", base=base, event=event)

    def test_version_file_modes_symlinks_and_type_replacements_require_full_validation(self):
        for path in (SPEC, PBX):
            for kind in ("executable", "symlink", "directory"):
                with self.subTest(path=path, kind=kind):
                    self.git("reset", "--hard", self.base)
                    self.bump()
                    target = self.repo / path
                    if kind == "executable":
                        target.chmod(0o755)
                    else:
                        target.unlink()
                        if kind == "symlink":
                            target.symlink_to("README.md")
                        else:
                            self.write(path + "/file.md", "replacement\n")
                    self.commit()
                    self.assert_scope("full")

    def test_version_files_cannot_be_added_deleted_or_renamed(self):
        for kind in ("added", "deleted", "renamed"):
            with self.subTest(kind=kind):
                self.git("reset", "--hard", self.base)
                if kind == "added":
                    for path in (SPEC, PBX):
                        (self.repo / path).unlink()
                    base = self.commit()
                    self.bump()
                else:
                    base = self.base
                    self.bump()
                    for index, path in enumerate((SPEC, PBX)):
                        if kind == "deleted":
                            (self.repo / path).unlink()
                        else:
                            (self.repo / path).rename(self.repo / f"former-version-{index}.md")
                self.commit()
                self.assert_scope("full", base=base)

    def test_original_objects_ignore_dirty_worktree_attributes_and_diff_drivers(self):
        self.bump()
        self.commit()
        self.write(SPEC, "dirty worktree\n")
        self.write("Shared/example.swift", "dirty code\n")
        self.write(".git/info/attributes", f"{SPEC} diff=version\n{PBX} diff=version\n")
        self.git("config", "diff.version.textconv", "false")
        self.git("config", "diff.external", "false")
        self.assert_scope("build-version")

    def test_replace_refs_cannot_hide_code_changes(self):
        self.bump()
        clean = self.commit()
        self.write("Shared/example.swift", "changed code\n")
        head = self.commit()
        self.git("replace", head, clean)
        self.assert_scope("full", head=head)

    def test_pr_scope_uses_merge_base_and_head_even_with_advanced_base_and_merge_checkout(self):
        self.git("branch", "pr", self.base)
        self.write("Shared/example.swift", "base advanced\n")
        base = self.commit()
        self.git("checkout", "-q", "pr")
        self.bump()
        head = self.commit()
        self.git("merge", "--no-ff", "-qm", "synthetic merge", base)
        self.assertNotEqual(self.git("rev-parse", "HEAD"), head)
        summary = self.assert_scope("build-version", base=base, head=head)
        self.assertIn(self.base, summary)
        self.assertNotIn(base, summary)

    def test_push_uses_exact_before_and_head_instead_of_checkout(self):
        self.bump()
        head = self.commit()
        self.write("Shared/example.swift", "later checkout\n")
        self.commit()
        self.assert_scope("build-version", head=head, event="push")

    def test_bad_unavailable_or_noncommit_endpoints_fail_without_outputs(self):
        for event in ("pull_request", "push"):
            for field in ("base", "head"):
                for sha in ("", "invalid", "--output=README.md", "f" * 40, self.git("rev-parse", "HEAD^{tree}")):
                    with self.subTest(event=event, field=field, sha=sha):
                        result, output = self.classify(event=event, **{field: sha})
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(output, {})

    def test_new_branch_push_and_manual_events_require_full_validation(self):
        self.assert_scope("full", event="push", base="0" * 40)
        for event in ("workflow_dispatch", "unknown"):
            self.assert_scope("full", event=event, base="invalid", head="not-needed")

    def test_empty_diff_requires_full_validation(self):
        self.assert_scope("full")

    def test_multiple_merge_bases_fail_without_outputs(self):
        self.write("a.md", "a\n")
        a = self.commit()
        self.git("reset", "--hard", self.base)
        self.write("b.md", "b\n")
        b = self.commit()
        tree = self.git("rev-parse", "HEAD^{tree}")
        first = self.git("commit-tree", tree, "-p", a, "-p", b, "-m", "first merge")
        second = self.git("commit-tree", tree, "-p", b, "-p", a, "-m", "second merge")
        result, output = self.classify(base=first, head=second)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, {})

    def test_unrelated_pr_histories_fail_without_outputs(self):
        tree = self.git("rev-parse", "HEAD^{tree}")
        unrelated = self.git("commit-tree", tree, "-m", "unrelated root")
        result, output = self.classify(head=unrelated)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, {})


if __name__ == "__main__":
    unittest.main()
