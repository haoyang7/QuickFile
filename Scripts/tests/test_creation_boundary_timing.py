"""Actual cache/writer trace boundaries on owned fixtures; not Finder latency."""
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


@unittest.skipUnless(sys.platform == "darwin", "Production trace regression requires macOS")
class CreationBoundaryTimingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="quickfile-boundary-timing-")
        cls.addClassCleanup(cls.temporary.cleanup)
        output = Path(cls.temporary.name)
        modules = shared_native_modules()
        cls.executable = output / "CreationBoundaryTimingCases"
        compiled = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        "-I", str(modules), "-L", str(modules), "-lQuickFileCore",
                        "-Xlinker", "-rpath", "-Xlinker", str(modules),
                        str(ROOT / "Scripts/Investigations/CreationTimingProbeSample.swift"),
                        str(ROOT / "Scripts/tests/fixtures/CreationBoundaryTimingCases.swift"),
                        "-o", str(cls.executable)], capture_output=True, text=True, timeout=60)
        if compiled.returncode:
            raise RuntimeError(compiled.stdout + compiled.stderr)

    def run_case(self, scenario):
        with tempfile.TemporaryDirectory(prefix="owned-boundary-trace-") as directory:
            env = {k: v for k, v in os.environ.items() if not k.startswith("QUICKFILE_CREATION_TIMING")}
            env["QUICKFILE_CREATION_TIMING_DIR"] = directory
            result = subprocess.run([str(self.executable), scenario], env=env,
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            for key in ("trace", "firstMenu", "secondMenu", "preparation", "reopenedMenu", "refreshPreparation"):
                if key not in report:
                    continue
                trace = report[key]
                anchor = trace["clockAnchor"]
                self.assertGreater(anchor["numerator"], 0)
                self.assertGreater(anchor["denominator"], 0)
                native_ns = anchor["machTimeTicks"] * anchor["numerator"] // anchor["denominator"]
                self.assertLessEqual(anchor["uptimeBeforeNS"], native_ns)
                self.assertLessEqual(native_ns, anchor["uptimeAfterNS"])
                self.assertLessEqual(anchor["uptimeAfterNS"], trace["events"][0]["uptimeNS"])
            return report

    def test_writer_preflight_rejections_close_once_without_staging(self):
        for scenario, result in [("non-file", "not-file-url"), ("missing", "missing"),
                                 ("not-directory", "not-directory"), ("identity-changed", "identity-changed")]:
            with self.subTest(scenario=scenario):
                self.check_writer(scenario, result, "failed")

    def test_later_write_failure_does_not_reclassify_preflight(self):
        self.check_writer("late-failure", "write-failed", "validated")

    def test_writer_success_has_preflight_result_and_published_file(self):
        self.check_writer("success", "created", "validated")

    def check_writer(self, scenario, result, preflight):
        report = self.run_case("writer-" + scenario)
        self.assertEqual(report["result"], result)
        self.assertEqual(report["trace"]["outcome"], result)
        self.assertEqual(report["trace"]["droppedEvents"], 0)
        phases = [event["phase"] for event in report["trace"]["events"]]
        self.assertEqual([phase for phase in phases if phase.startswith("writer.preflight.")],
                         ["writer.preflight.begin", "writer.preflight." + preflight, "writer.preflight.end"])
        self.assertEqual(phases[-2:], ["writer.end", "end"])
        self.assertTrue(report["preflightComplete"])
        self.assertEqual(report["missingPhaseMutantsAccepted"], 0)
        self.assertEqual(report["targetFiles"], ["未命名.txt"] if result == "created" else [])
        if preflight == "failed":
            self.assertNotIn("staging.begin", phases)

    @staticmethod
    def linked_ids(report):
        return [event["relatedID"] for event in report["events"]
                if event["phase"] == "menu.destination.preparation.link"]

    def check_preparation(self, scenario, outcome):
        report = self.run_case(scenario)
        trace = report["preparation"]
        self.assertEqual(trace["outcome"], outcome)
        self.assertEqual(trace["parentID"], report["firstMenu"]["id"])
        self.assertEqual(self.linked_ids(report["firstMenu"]), [trace["id"]])
        self.assertEqual(self.linked_ids(report["secondMenu"]), [] if scenario == "busy" else [trace["id"]])
        phases = [event["phase"] for event in trace["events"]]
        self.assertEqual(phases[:3], ["begin", "preparation.submitted", "preparation.entered"])
        self.assertEqual(phases[3], "preparation.unavailable" if scenario == "unavailable" else "preparation.ready")
        self.assertEqual(phases[-1], "end")
        self.assertEqual(trace["droppedEvents"], 0)
        ticks = [event["uptimeNS"] for event in trace["events"]]
        self.assertEqual(ticks, sorted(ticks))
        return report

    def test_duplicate_cold_menus_share_the_active_preparation(self):
        self.check_preparation("cold", "ready")

    def test_warm_menu_links_to_cached_proof_not_pending_refresh(self):
        report = self.check_preparation("refresh", "ready")
        self.assertEqual(self.linked_ids(report["reopenedMenu"]), [report["preparation"]["id"]])
        self.assertNotEqual(report["refreshPreparation"]["id"], report["preparation"]["id"])
        self.assertEqual(report["refreshPreparation"]["parentID"], report["reopenedMenu"]["id"])
        self.assertEqual(report["refreshPreparation"]["outcome"], "ready")

    def test_failed_and_discarded_preparations_finish(self):
        for scenario in ("unavailable", "invalidated", "owner-ended"):
            with self.subTest(scenario=scenario):
                report = self.check_preparation(scenario, "discarded" if scenario == "invalidated" else scenario)
                if scenario == "invalidated":
                    self.assertEqual(report["preparation"]["events"][-3]["phase"], "preparation.cache.discarded")
                if scenario == "owner-ended":
                    self.assertTrue(report["ownerReleased"])

    def test_busy_menu_does_not_claim_other_targets_preparation(self):
        report = self.check_preparation("busy", "ready")
        self.assertTrue(report["secondWasBusy"])

    def test_concurrent_marks_are_ordered_and_release_the_recorder(self):
        self.check_concurrent_timing("timing-parallel", complete=True)

    def test_finish_racing_marks_closes_once_and_ignores_later_events(self):
        self.check_concurrent_timing("timing-finish-race", complete=False)

    def check_concurrent_timing(self, scenario, complete):
        report = self.run_case(scenario)
        self.assertTrue(report["ownersReleased"])
        self.assertEqual(report["reportCount"], 16)
        self.assertEqual(len({trace["id"] for trace in report["traces"]}), 16)
        for trace in report["traces"]:
            phases = [event["phase"] for event in trace["events"]]
            ticks = [event["uptimeNS"] for event in trace["events"]]
            self.assertEqual(trace["outcome"], "finished")
            self.assertEqual(trace["droppedEvents"], 0)
            self.assertEqual(phases[0], "begin")
            self.assertEqual(phases[-1], "end")
            self.assertEqual(phases.count("end"), 1)
            self.assertNotIn("after-finish", phases)
            self.assertEqual(ticks, sorted(ticks))
            self.assertEqual(phases[1:-1], ["parallel"] * (len(phases) - 2))
            self.assertLessEqual(len(phases), 386)
            if complete:
                self.assertEqual(len(phases), 386)


if __name__ == "__main__":
    unittest.main()
