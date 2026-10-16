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
        self.workflow = WORKFLOW.read_text()
        self.summary = self.root / "summary"
        self.env = dict(os.environ, GITHUB_STEP_SUMMARY=str(self.summary))

    def test_required_gate_fails_closed_for_every_dependency_result_combination(self):
        script = step_script(self.workflow, "Require successful verification or explicit verified scope")
        results = ("success", "failure", "cancelled", "skipped")
        for scope, run_checks, changes, scripts, macos in itertools.product(
                ("full", "documentation", "build-version", "", "unknown"), ("true", "false", ""),
                results, results, results):
            with self.subTest(scope=scope, run_checks=run_checks, changes=changes, scripts=scripts, macos=macos):
                self.summary.unlink(missing_ok=True)
                result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script],
                                        env=dict(self.env, CHANGES_RESULT=changes, RUN_CHECKS=run_checks, SCOPE=scope,
                                                 SCRIPTS_RESULT=scripts, MACOS_RESULT=macos),
                                        capture_output=True, text=True)
                expected = changes == "success" and (
                    (scope == "full" and run_checks == "true" and scripts == macos == "success") or
                    (scope in ("documentation", "build-version") and run_checks == "false" and
                     scripts == macos == "skipped"))
                self.assertEqual(result.returncode == 0, expected, result.stderr)
                summary = self.summary.read_text()
                if expected and scope in ("documentation", "build-version"):
                    self.assertIn("skipped, not tested", summary)
                if expected and scope == "build-version":
                    self.assertIn("project consistency verified", summary)
                if expected and scope == "full":
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
        self.assertIn("          PUSH_BEFORE_SHA: ${{ github.event.before }}\n", self.workflow)
        self.assertIn("          PUSH_HEAD_SHA: ${{ github.sha }}\n", self.workflow)
        self.assertIn("        run: python3 Scripts/ci-scope.py\n", self.workflow)
        self.assertIn("      scope: ${{ steps.scope.outputs.scope }}\n", self.workflow)
        self.assertIn("          SCOPE: ${{ needs.changes.outputs.scope }}\n", required)
        self.assertIn("      fail-fast: false\n", self.workflow)
        self.assertIn("permissions:\n  contents: read\n", self.workflow)
        self.assertNotIn("pull_request_target", self.workflow)
        self.assertNotIn("continue-on-error", self.workflow)
        self.assertNotIn("secrets.", self.workflow)

    def test_required_matrix_includes_a_non_optional_ax_coverage_baseline(self):
        block = self.workflow.split('      - name: Require actual AX coverage on the macOS 26 baseline\n', 1)[1]
        block = block.split('      - name:', 1)[0]
        self.assertIn("        if: matrix.macos_major == '26'\n", block)
        self.assertIn('python3 Scripts/ci-evidence.py require-ax-coverage "$CI_EVIDENCE_ROOT"', block)
        self.assertNotIn('continue-on-error', block)
        self.assertIn("macos_major: '26'", self.workflow)


if __name__ == "__main__":
    unittest.main()
