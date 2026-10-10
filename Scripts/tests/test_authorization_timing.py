"""Real store branches with isolated storage and fake bookmarks; no Finder or App Group."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

if __package__:
    from .native_test_support import shared_native_modules
else:
    from native_test_support import shared_native_modules

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "Authorization trace regression requires macOS")
class AuthorizationTimingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="quickfile-authorization-timing-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.output = Path(cls.temporary.name)
        modules = shared_native_modules()
        cls.executable = cls.output / "AuthorizationTimingCases"
        compiled = subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-I", str(modules), "-L", str(modules), "-lQuickFileCore", "-lQuickFileInfrastructure",
            "-Xlinker", "-rpath", "-Xlinker", str(modules),
            str(ROOT / "Scripts/Investigations/CreationTimingProbeSample.swift"),
            str(ROOT / "Scripts/tests/fixtures/AuthorizationTimingCases.swift"),
            "-o", str(cls.executable),
        ], capture_output=True, text=True, timeout=60)
        if compiled.returncode:
            raise RuntimeError(compiled.stdout + compiled.stderr)

    def check_case(self, scenario, outcome, starts, operations, mutation=False):
        with tempfile.TemporaryDirectory(prefix="owned-authorization-trace-") as directory:
            env = {k: v for k, v in os.environ.items() if not k.startswith("QUICKFILE_CREATION_TIMING")}
            env["QUICKFILE_CREATION_TIMING_DIR"] = directory
            result = subprocess.run([str(self.executable), scenario], env=env,
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(len(list(Path(directory).glob("*.json"))), 1)
        self.assertEqual(report["outcome"], outcome)
        self.assertEqual(report["traceOutcome"], outcome)
        self.assertTrue(report["traceComplete"], report["phases"])
        self.assertEqual(report["missingEndMutantsAccepted"], 0)
        self.assertTrue(report["monotonic"])
        self.assertEqual(report["droppedEvents"], 0)
        self.assertEqual(report["scopeStarts"], starts)
        self.assertEqual(report["scopeStops"], starts)
        self.assertEqual(report["operations"], operations)
        self.assertEqual(report["mutationPerformed"], mutation)
        return report

    def test_success_and_unresolvable_bookmark_fallback_are_complete(self):
        self.check_case("valid", "admitted", 1, 1)
        report = self.check_case("broken-bookmark-fallback", "admitted", 1, 1)
        self.assertIn("authorization.bookmark.failed", report["phases"])
        self.assertEqual(report["bookmarkResolutions"], 2)

    def test_exact_hint_skips_earlier_unresolvable_bookmark(self):
        report = self.check_case("exact-hint-skips-earlier-unrelated", "admitted", 1, 1)
        self.assertEqual(report["bookmarkResolutions"], 1)
        self.assertNotIn("authorization.bookmark.failed", report["phases"])

    def test_unresolved_no_match_and_table_failure_are_complete(self):
        for scenario, outcome in [("unresolved", "unresolved"), ("no-match", "no-match"),
                                  ("table-failure", "table-failure")]:
            with self.subTest(scenario=scenario):
                self.check_case(scenario, outcome, 0, 0)

    def test_scope_rejection_and_parent_fallback_are_complete(self):
        self.check_case("scope-unavailable", "scope-unavailable", 0, 0)
        report = self.check_case("scope-fallback", "admitted", 1, 1)
        self.assertIn("authorization.scope.rejected", report["phases"])

    def test_revocation_before_and_after_scope_are_closed_and_never_admitted(self):
        self.check_case("revoke-before", "changed", 0, 0, True)
        self.check_case("revoke-after", "changed", 1, 0, True)

    def test_revocation_can_fall_back_to_unchanged_parent_with_closed_attempts(self):
        self.check_case("revoke-before-fallback", "admitted", 1, 1, True)
        self.check_case("revoke-after-fallback", "admitted", 2, 1, True)

    def test_revision_read_errors_close_spans_and_balance_started_scope(self):
        self.check_case("before-check-failure", "storage-error", 0, 0, True)
        self.check_case("after-check-failure", "storage-error", 1, 0, True)

    def test_operation_failure_is_not_retried_and_stops_scope(self):
        self.check_case("operation-failure", "operation-failed", 1, 1)

    def test_exact_grant_skips_later_unrelated_bookmark(self):
        report = self.check_case("exact-first-unrelated", "admitted", 1, 1)
        self.assertEqual(report["bookmarkResolutions"], 1)

    def test_rejected_exact_grant_can_discover_parent_after_admission_attempt(self):
        report = self.check_case("scope-fallback-parent-later", "admitted", 1, 1)
        self.assertEqual(report["bookmarkResolutions"], 2)
        self.assertLess(report["phases"].index("authorization.scope.rejected"),
                        len(report["phases"]) - 1 - report["phases"][::-1].index("authorization.bookmark.begin"))

    def test_revoked_exact_grant_can_discover_later_parent(self):
        for scenario, starts in [("revoke-before-fallback-parent-later", 1),
                                  ("revoke-after-fallback-parent-later", 2)]:
            with self.subTest(scenario=scenario):
                report = self.check_case(scenario, "admitted", starts, 1, True)
                self.assertEqual(report["bookmarkResolutions"], 2)

    def test_exact_operation_failure_does_not_resolve_later_parent(self):
        report = self.check_case("operation-failure-parent-later", "operation-failed", 1, 1)
        self.assertEqual(report["bookmarkResolutions"], 1)


if __name__ == "__main__":
    unittest.main()
