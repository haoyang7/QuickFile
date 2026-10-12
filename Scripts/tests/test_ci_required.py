import itertools
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


PROJECT = Path(__file__).resolve().parents[2]
WORKFLOW = PROJECT / ".github" / "workflows" / "ci.yml"


def step_script(workflow, name):
    block = workflow.split(f"      - name: {name}\n", 1)[1]
    lines = block.split("        run: |\n", 1)[1].splitlines()
    script = []
    for line in lines:
        if line and not line.startswith("          "):
            break
        script.append(line)
    return textwrap.dedent("\n".join(script))


class CIRequiredTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ci-required-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.workflow = WORKFLOW.read_text()
        self.output = self.root / "output"
        self.summary = self.root / "summary"
        self.env = dict(os.environ, GITHUB_EVENT_NAME="pull_request",
                        GITHUB_OUTPUT=str(self.output), GITHUB_STEP_SUMMARY=str(self.summary))
        self.git("init", "-q")
        for path in ("README.md", "LICENSE", "Shared/example.swift", "Scripts/example.md"):
            self.write(path, "initial\n")
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output([
            "git", "-c", "user.name=CI fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args,
        ], cwd=self.repo, stderr=subprocess.PIPE, text=True).strip()

    def write(self, path, content):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def classify(self, base=None, head=None, event="pull_request"):
        self.output.unlink(missing_ok=True)
        self.summary.unlink(missing_ok=True)
        script = step_script(self.workflow, "Classify changed paths")
        result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], cwd=self.repo,
                                env=dict(self.env, GITHUB_EVENT_NAME=event, PR_BASE_SHA=base or self.base,
                                         PR_HEAD_SHA=head or self.git("rev-parse", "HEAD")),
                                capture_output=True, text=True)
        return result, self.output.read_text() if self.output.exists() else ""

    def test_root_markdown_and_license_only_are_explicitly_not_tested(self):
        self.write("README.md", "updated\n")
        self.write("LICENSE", "updated\n")
        self.write("new documentation.md", "new\n")
        self.commit()
        result, output = self.classify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "run_checks=false\n")
        self.assertIn("skipped, not tested", self.summary.read_text())

    def test_code_config_nested_docs_assets_and_unknown_paths_require_validation(self):
        paths = ("Shared/example.swift", "FinderExtension/file.swift", "QuickFileApp/file.swift",
                 "QuickFileTests/file.swift", "QuickFile.xcodeproj/project.pbxproj", "project.yml",
                 ".github/workflows/example.yml", "Scripts/example.md", "Release/example.md",
                 "docs/example.md", "Screenshots/example.png", "root-script.py", "new-uppercase.MD",
                 "Shared/new\nline.swift")
        for path in paths:
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.write(path, "changed\n")
                self.commit()
                result, output = self.classify()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, "run_checks=true\n")

    def test_deleted_or_renamed_code_cannot_be_hidden_as_root_documentation(self):
        for rename in (False, True):
            with self.subTest(rename=rename):
                self.git("reset", "--hard", self.base)
                source = self.repo / "Shared/example.swift"
                if rename:
                    source.rename(self.repo / "former-code.md")
                else:
                    source.unlink()
                self.commit()
                result, output = self.classify()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, "run_checks=true\n")

    def test_full_diff_includes_code_after_more_than_300_docs(self):
        for index in range(350):
            self.write(f"documentation-{index:03}.md", "new\n")
        self.write("zzz-code.py", "new\n")
        self.commit()
        result, output = self.classify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "run_checks=true\n")

    def test_pr_scope_uses_head_changes_even_when_checkout_is_merge_with_advanced_base(self):
        self.git("branch", "pr", self.base)
        self.write("Shared/example.swift", "base advanced\n")
        base = self.commit()
        self.git("checkout", "-q", "pr")
        self.write("README.md", "pr documentation\n")
        head = self.commit()
        self.git("merge", "--no-ff", "-qm", "synthetic merge", base)
        self.assertNotEqual(self.git("rev-parse", "HEAD"), head)
        result, output = self.classify(base, head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "run_checks=false\n")

    def test_bad_or_unavailable_sha_fails_without_success_output(self):
        for sha in ("invalid", "--output=README.md", "0" * 40):
            with self.subTest(sha=sha):
                result, output = self.classify(head=sha)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, "")

    def test_push_and_manual_events_always_require_full_validation(self):
        for event in ("push", "workflow_dispatch"):
            with self.subTest(event=event):
                result, output = self.classify(head="not-needed", event=event)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, "run_checks=true\n")

    def test_required_gate_fails_closed_for_every_dependency_result_combination(self):
        script = step_script(self.workflow, "Require successful verification or explicit documentation skip")
        results = ("success", "failure", "cancelled", "skipped")
        for scope, changes, scripts, macos in itertools.product(("true", "false", ""), results, results, results):
            with self.subTest(scope=scope, changes=changes, scripts=scripts, macos=macos):
                self.summary.unlink(missing_ok=True)
                result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script],
                                        env=dict(self.env, CHANGES_RESULT=changes, RUN_CHECKS=scope,
                                                 SCRIPTS_RESULT=scripts, MACOS_RESULT=macos),
                                        capture_output=True, text=True)
                expected = changes == "success" and (
                    (scope == "true" and scripts == macos == "success") or
                    (scope == "false" and scripts == macos == "skipped"))
                self.assertEqual(result.returncode == 0, expected, result.stderr)
                summary = self.summary.read_text()
                if expected and scope == "false":
                    self.assertIn("skipped, not tested", summary)
                if expected and scope == "true":
                    self.assertIn("all three macOS", summary)

    def test_workflow_always_creates_gate_for_pr_and_waits_for_all_checks(self):
        pr_trigger = self.workflow.split("  pull_request:\n", 1)[1].split("  workflow_dispatch:", 1)[0]
        self.assertNotIn("paths", pr_trigger)
        required = self.workflow.split("  required:\n", 1)[1]
        self.assertIn("    name: CI required\n", required)
        self.assertIn("    needs: [changes, scripts, macos]\n    if: always()\n", required)
        self.assertIn("    needs: changes\n    if: needs.changes.outputs.run_checks == 'true'\n", self.workflow)
        self.assertIn("    needs: [changes, scripts]\n    if: needs.changes.outputs.run_checks == 'true'\n", self.workflow)
        self.assertIn("          fetch-depth: 0\n", self.workflow)
        self.assertIn("          PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}\n", self.workflow)
        self.assertIn("          PR_BASE_SHA: ${{ github.event.pull_request.base.sha }}\n", self.workflow)
        self.assertIn("      fail-fast: false\n", self.workflow)
        self.assertIn("permissions:\n  contents: read\n", self.workflow)
        self.assertNotIn("pull_request_target", self.workflow)
        self.assertNotIn("continue-on-error", self.workflow)
        self.assertNotIn("secrets.", self.workflow)


if __name__ == "__main__":
    unittest.main()
