"""Production coordinator failure spans, isolated from Finder and App Group data."""
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


@unittest.skipUnless(sys.platform == "darwin", "Coordinator trace regression requires macOS")
class CreationPreflightTimingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="quickfile-preflight-timing-")
        cls.addClassCleanup(cls.temporary.cleanup)
        output = Path(cls.temporary.name)
        modules = shared_native_modules()
        cls.executable = output / "CreationPreflightTimingCases"
        compiled = subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-I", str(modules), "-L", str(modules), "-lQuickFileCore", "-lQuickFileInfrastructure", "-lQuickFileApplication",
            "-Xlinker", "-rpath", "-Xlinker", str(modules),
            str(ROOT / "Scripts/Investigations/CreationTimingProbeSample.swift"),
            str(ROOT / "Scripts/tests/fixtures/CreationPreflightTimingCases.swift"),
            "-o", str(cls.executable),
        ], capture_output=True, text=True, timeout=60)
        if compiled.returncode:
            raise RuntimeError(compiled.stdout + compiled.stderr)

    def check_case(self, scenario, outcome, loads, creates):
        with tempfile.TemporaryDirectory(prefix="owned-preflight-trace-") as directory:
            env = {k: v for k, v in os.environ.items() if not k.startswith("QUICKFILE_CREATION_TIMING")}
            env["QUICKFILE_CREATION_TIMING_DIR"] = directory
            result = subprocess.run([str(self.executable), scenario], env=env,
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(len(list(Path(directory).glob("*.json"))), 1)
        self.assertEqual(report["outcome"], outcome)
        self.assertEqual(report["traceOutcome"], outcome)
        self.assertTrue(report["preflightComplete"], report["phases"])
        self.assertEqual(report["missingPhaseMutantsAccepted"], 0)
        self.assertTrue(report["monotonic"])
        self.assertEqual(report["droppedEvents"], 0)
        self.assertEqual(report["counts"], {"loads": loads, "accesses": creates, "creates": creates})
        return report

    def test_invalid_destinations_close_span_without_loading_or_accessing(self):
        for scenario, outcome in [("missing-prepared", "destination-unavailable"),
                                  ("unresolved-selection", "destination-unavailable"),
                                  ("identity-changed", "identity-changed"),
                                  ("directory-removed", "directory-read-failed")]:
            with self.subTest(scenario=scenario):
                self.check_case(scenario, outcome, 0, 0)

    def test_template_failures_close_span_without_access_or_creation(self):
        for scenario, outcome in [("template-read-failure", "template-read-failed"),
                                  ("template-removed", "template-unavailable"),
                                  ("template-disabled", "template-unavailable")]:
            with self.subTest(scenario=scenario):
                self.check_case(scenario, outcome, 1, 0)

    def test_success_closes_both_preflight_stages_and_creates_once(self):
        self.check_case("success", "created", 1, 1)


if __name__ == "__main__":
    unittest.main()
