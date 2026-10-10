import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("creation_timeline", Path(__file__).resolve().parents[1] / "Investigations/creation-timeline.py")
TIMELINE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TIMELINE)


class CreationTimelineTests(unittest.TestCase):
    def setUp(self):
        phases = ["begin", "action.callback", "action.menu.link", "background.submit", "background.entered",
                  "destination.validation.end", "templates.load.end", "authorization.begin",
                  "authorization.admitted", "writer.preflight.begin", "writer.preflight.validated",
                  "writer.preflight.end", "file.published", "writer.result.ready", "writer.end",
                  "authorization.end", "background.work.finished", "main.completion.enqueued",
                  "main.completion.entered", "finder.reveal.request", "finder.reveal.return", "end"]
        self.trace = {"id": "owned-creation", "kind": "creation", "pid": 123,
                      "outcome": "reveal-returned", "droppedEvents": 0,
                      "clockAnchor": {"machTimeTicks": 300_000, "numerator": 125, "denominator": 3,
                                      "uptimeBeforeNS": 12_499_990, "uptimeAfterNS": 12_500_010},
                      "events": [{"phase": phase, "uptimeNS": 13_000_000 + index * 1_000_000}
                                 for index, phase in enumerate(phases)]}
        self.trace["events"][2]["relatedID"] = "owned-menu"
        # Keep the existing measured endpoints, adding the actual nested stage
        # grammar at equal ticks. Equal ticks never relax event-index causality.
        additions = {
            "destination.validation.end": ["destination.validation.begin", "destination.validation.validated"],
            "templates.load.end": ["templates.load.begin", "templates.load.loaded"],
            "authorization.admitted": ["authorization.table.begin", "authorization.table.loaded", "authorization.table.end",
                                       "authorization.bookmark.begin", "authorization.bookmark.resolved", "authorization.bookmark.end",
                                       "authorization.revision.before-scope.begin", "authorization.revision.before-scope.current",
                                       "authorization.revision.before-scope.end", "authorization.scope.begin", "authorization.scope.started",
                                       "authorization.revision.after-scope.begin", "authorization.revision.after-scope.current",
                                       "authorization.revision.after-scope.end"],
            "authorization.end": ["authorization.scope.stopped"],
        }
        self.trace["events"] = [extra for event in self.trace["events"] for extra in [
            *[{"phase": phase, "uptimeNS": event["uptimeNS"]} for phase in additions.get(event["phase"], [])], event]]
        self.observation = {"traceID": "owned-creation", "pid": 123, "machTimebase": [125, 3],
                            "inputMachTicks": 300_000, "selectedMachTicksUpper": 1_200_000,
                            "endpoint": "recorded-visible-selection"}
        phases = ["begin", "menu.destination.preparation.link", "menu.destination.ready", "menu.prepared", "end"]
        self.menu = {"id": "owned-menu", "pid": 123, "kind": "menu", "outcome": "menu-returned", "droppedEvents": 0,
                     "events": [{"phase": phase, "uptimeNS": 8_000_000 + index * 1_000_000}
                                for index, phase in enumerate(phases)]}
        self.menu["events"][1]["relatedID"] = "owned-proof"
        phases = ["preparation.submitted", "preparation.entered", "preparation.ready",
                  "preparation.cache.publish.begin", "preparation.cache.accepted", "preparation.cache.publish.end"]
        self.preparation = {"id": "owned-proof", "pid": 123, "parentID": "owned-cold-menu",
                            "kind": "destination-preparation", "outcome": "ready", "droppedEvents": 0,
                            "events": [{"phase": phase, "uptimeNS": index * 1_000_000}
                                       for index, phase in enumerate(["begin"] + phases + ["end"])]}
        self.session_id = "1D9C5AEC-D308-4F06-9E57-2253F533C38F"
        for sequence, report in enumerate((self.trace, self.menu, self.preparation), 1):
            report["delivery"] = {"sessionID": self.session_id, "sequence": sequence}
        self.receipts = [{"schemaVersion": 1, "sessionID": self.session_id, "pid": 123, "closed": True,
                          "acceptedReports": 3, "writtenReports": 3, "droppedReports": 0, "failedReports": 0}]

    def assemble(self, trace=None, observation=None, menu=None, preparation=None, receipts=None, source="json"):
        return TIMELINE.assemble(trace or self.trace, observation or self.observation,
                                 menu or self.menu, preparation or self.preparation,
                                 receipts=self.receipts if receipts is None else receipts, source=source)

    def test_single_input_timeline_retains_clock_uncertainty_and_selection_upper_bound(self):
        result = self.assemble()
        self.assertEqual(result["inputToCallbackMS"], [1.49999, 1.50001])
        self.assertEqual(result["callbackToPublicationMS"], 11)
        self.assertEqual(result["inputToPublicationMS"], [12.49999, 12.50001])
        self.assertEqual(result["inputToSelectedUpperMS"], 37.5)
        self.assertEqual(result["clockAnchorUncertaintyNS"], 20)
        self.assertEqual(result["authorizationAdmissionMS"], 1)
        self.assertEqual(result["postPublicationWriterMS"], 2)
        self.assertEqual(result["menuTraceID"], "owned-menu")
        self.assertFalse(result["percentileAcceptance"])
        self.assertEqual(result["preparationTraceID"], "owned-proof")
        self.assertEqual(result["preparationTriggerMenuTraceID"], "owned-cold-menu")
        self.assertEqual(result["preparationQueueMS"], 1)
        self.assertEqual(result["deliveryCompleteness"], "closed-json-sessions")

    def test_slow_post_callback_work_does_not_change_input_dispatch_span(self):
        trace = copy.deepcopy(self.trace)
        for event in trace["events"]:
            if event["phase"] not in ("begin", "action.callback"):
                event["uptimeNS"] += 10_000_000
        result = self.assemble(trace=trace)
        self.assertEqual(result["inputToCallbackMS"], [1.49999, 1.50001])
        self.assertEqual(result["callbackToPublicationMS"], 21)
        self.assertEqual(result["inputToPublicationMS"], [22.49999, 22.50001])

    def test_equal_ticks_cannot_hide_reversed_event_causality(self):
        pairs = [("trace", "background.submit", "background.entered"),
                 ("preparation", "preparation.submitted", "preparation.entered"),
                 ("preparation", "preparation.cache.publish.begin", "preparation.cache.accepted"),
                 ("menu", "menu.destination.preparation.link", "menu.destination.ready"),
                 ("menu", "menu.destination.ready", "menu.prepared")]
        for field, first, second in pairs:
            report = copy.deepcopy(getattr(self, field))
            events = report["events"]
            a, b = [next(index for index, event in enumerate(events) if event["phase"] == phase)
                    for phase in (first, second)]
            events[b]["uptimeNS"] = events[a]["uptimeNS"]
            with self.subTest(field=field, order="equal-valid"):
                self.assemble(**{field: report})
            events[a], events[b] = events[b], events[a]
            with self.subTest(field=field, phase=first), self.assertRaises(ValueError):
                self.assemble(**{field: report})

    def test_mutually_exclusive_and_unknown_stage_results_are_rejected(self):
        for field, phase in [("trace", "writer.preflight.failed"), ("trace", "writer.preflight.unknown"),
                             ("preparation", "preparation.unavailable"), ("preparation", "preparation.cache.discarded"),
                             ("menu", "menu.destination.loading"), ("menu", "menu.destination.unavailable")]:
            report = copy.deepcopy(getattr(self, field))
            report["events"].insert(-1, {"phase": phase, "uptimeNS": report["events"][-2]["uptimeNS"]})
            with self.subTest(phase=phase), self.assertRaises(ValueError):
                self.assemble(**{field: report})

    def test_rejected_authorization_attempt_can_precede_successful_fallback(self):
        def span(prefix, result):
            return [prefix + ".begin", prefix + "." + result, prefix + ".end"]

        resolved = span("authorization.bookmark", "resolved")
        before = span("authorization.revision.before-scope", "current")
        attempts = {
            "before-changed": span("authorization.revision.before-scope", "changed"),
            "scope-rejected": before + ["authorization.scope.begin", "authorization.scope.rejected"],
            "after-changed": before + ["authorization.scope.begin", "authorization.scope.started"]
                             + span("authorization.revision.after-scope", "changed") + ["authorization.scope.stopped"],
        }
        # Exact-grant rejection can discover a later parent, or use a parent
        # already resolved before attempting the exact grant.
        for name, rejected in attempts.items():
            for resolved_first in (False, True):
                report = copy.deepcopy(self.trace)
                index = next(index for index, event in enumerate(report["events"])
                             if event["phase"] == "authorization.revision.before-scope.begin")
                fallback = resolved + rejected if resolved_first else rejected + resolved
                report["events"][index:index] = [{"phase": phase, "uptimeNS": report["events"][index]["uptimeNS"]}
                                                for phase in fallback]
                with self.subTest(attempt=name, resolved_first=resolved_first):
                    self.assemble(trace=report)
        report = copy.deepcopy(self.trace)
        index = next(index for index, event in enumerate(report["events"]) if event["phase"] == "authorization.bookmark.begin")
        report["events"][index:index] = [{"phase": phase, "uptimeNS": report["events"][index]["uptimeNS"]}
                                        for phase in span("authorization.bookmark", "failed")]
        self.assemble(trace=report)

    def test_terminal_failures_cannot_accompany_successful_creation(self):
        cases = [("destination.validation.failed", "destination.validation.end"),
                 ("templates.load.failed", "templates.load.end"),
                 *[(phase, "authorization.admitted") for phase in (
                     "authorization.table.failed", "authorization.no-match", "authorization.unresolved",
                     "authorization.changed", "authorization.scope-unavailable",
                     "authorization.revision.before-scope.failed", "authorization.revision.after-scope.failed")]]
        for phase, next_phase in cases:
            report = copy.deepcopy(self.trace)
            index = next(index for index, event in enumerate(report["events"]) if event["phase"] == next_phase)
            report["events"].insert(index, {"phase": phase, "uptimeNS": report["events"][index]["uptimeNS"]})
            with self.subTest(phase=phase), self.assertRaises(ValueError):
                self.assemble(trace=report)

    def test_complete_failure_spans_cannot_replace_required_success_spans(self):
        for phase in ("destination.validation.validated", "templates.load.loaded", "authorization.table.loaded",
                      "authorization.revision.before-scope.current", "authorization.revision.after-scope.current"):
            report = copy.deepcopy(self.trace)
            event = next(event for event in report["events"] if event["phase"] == phase)
            event["phase"] = phase.rsplit(".", 1)[0] + ".failed"
            with self.subTest(phase=phase), self.assertRaises(ValueError):
                self.assemble(trace=report)

    def test_writer_must_finish_before_successful_authorization_scope_stops(self):
        for next_phase in ("writer.preflight.begin", "writer.end"):
            report = copy.deepcopy(self.trace)
            stop = next(event for event in report["events"] if event["phase"] == "authorization.scope.stopped")
            report["events"].remove(stop)
            index = next(index for index, event in enumerate(report["events"]) if event["phase"] == next_phase)
            stop["uptimeNS"] = report["events"][index]["uptimeNS"]
            report["events"].insert(index, stop)
            with self.subTest(next_phase=next_phase), self.assertRaises(ValueError):
                self.assemble(trace=report)

    def test_authorization_rejects_unknown_duplicate_and_reordered_attempt_markers(self):
        for phase in ("authorization.unknown", "authorization.scope.stopped", "authorization.scope.started",
                      "authorization.bookmark.resolved", "authorization.revision.before-scope.end"):
            report = copy.deepcopy(self.trace)
            index = next(index for index, event in enumerate(report["events"]) if event["phase"] == "authorization.admitted")
            report["events"].insert(index, {"phase": phase, "uptimeNS": report["events"][index]["uptimeNS"]})
            with self.subTest(phase=phase), self.assertRaises(ValueError):
                self.assemble(trace=report)
        report = copy.deepcopy(self.trace)
        start = next(index for index, event in enumerate(report["events"]) if event["phase"] == "authorization.scope.begin")
        report["events"][start], report["events"][start + 1] = report["events"][start + 1], report["events"][start]
        with self.assertRaises(ValueError):
            self.assemble(trace=report)

    def test_native_input_and_returned_menu_must_precede_creation_begin(self):
        for ticks in (312_000, 312_001):
            with self.subTest(ticks=ticks), self.assertRaises(ValueError):
                self.assemble(observation=dict(self.observation, inputMachTicks=ticks))
        self.assemble(observation=dict(self.observation, inputMachTicks=311_999))
        menu = copy.deepcopy(self.menu)
        menu["events"][-1]["uptimeNS"] = 13_000_000
        self.assemble(menu=menu)
        menu["events"][-1]["uptimeNS"] += 1
        with self.assertRaises(ValueError):
            self.assemble(menu=menu)

    def test_json_requires_matching_lossless_closed_receipts(self):
        for key, value in [("closed", False), ("closed", 1), ("schemaVersion", 2), ("pid", 124),
                           ("writtenReports", 2), ("droppedReports", 1), ("failedReports", 1),
                           ("acceptedReports", -1), ("droppedReports", False)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.assemble(receipts=[dict(self.receipts[0], **{key: value})])
        for receipts in ([], self.receipts * 2):
            with self.assertRaises(ValueError):
                self.assemble(receipts=receipts)
        for delivery in (None, {"sessionID": self.session_id, "sequence": 0},
                         {"sessionID": self.session_id, "sequence": 4},
                         {"sessionID": self.session_id, "sequence": True},
                         {"sessionID": self.session_id, "sequence": 2},
                         {"sessionID": "../other", "sequence": 1}):
            trace = copy.deepcopy(self.trace)
            if delivery is None:
                del trace["delivery"]
            else:
                trace["delivery"] = delivery
            with self.subTest(delivery=delivery), self.assertRaises(ValueError):
                self.assemble(trace=trace)

    def test_pid_counter_and_timebase_types_match_native_integer_schema(self):
        for pid, receipt_pid in ((True, 1), (123.0, 123), (-5, -5), (0, 0), (2**31, 2**31)):
            with self.subTest(pid=pid), self.assertRaises(ValueError):
                self.assemble(trace=dict(self.trace, pid=pid), menu=dict(self.menu, pid=pid),
                              preparation=dict(self.preparation, pid=pid), observation=dict(self.observation, pid=pid),
                              receipts=[dict(self.receipts[0], pid=receipt_pid)])
        with self.assertRaises(ValueError):
            self.assemble(observation=dict(self.observation, pid=123.0))
        with self.assertRaises(ValueError):
            self.assemble(receipts=[dict(self.receipts[0], acceptedReports=2**64, writtenReports=2**64)])
        for timebase in ([125.0, 3.0], [True, 3], [0, 3], [2**32, 3]):
            with self.subTest(timebase=timebase), self.assertRaises(ValueError):
                self.assemble(observation=dict(self.observation, machTimebase=timebase))
        for key in ("inputMachTicks", "selectedMachTicksUpper"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.assemble(observation=dict(self.observation, **{key: 2**64}))

    def test_signpost_exports_require_explicit_source_and_do_not_claim_json_delivery(self):
        reports = [copy.deepcopy(report) for report in (self.trace, self.menu, self.preparation)]
        for report in reports:
            del report["delivery"]
        with self.assertRaises(ValueError):
            TIMELINE.assemble(reports[0], self.observation, reports[1], reports[2])
        result = TIMELINE.assemble(reports[0], self.observation, reports[1], reports[2], source="signpost-export")
        self.assertEqual(result["deliveryCompleteness"], "external-signpost-validation-required")
        self.assertEqual(result["jsonSessionIDs"], [])
        with self.assertRaises(ValueError):
            self.assemble(source="signpost-export")

    def run_cli(self, *, source="json", include_receipt=True, include_delivery=True):
        with tempfile.TemporaryDirectory(prefix="owned-timeline-cli-") as directory:
            root = Path(directory)
            args = [sys.executable, str(Path(TIMELINE.__file__))]
            for name in ("trace", "observation", "menu", "preparation"):
                value = copy.deepcopy(getattr(self, name))
                if not include_delivery:
                    value.pop("delivery", None)
                path = root / (name + ".json")
                path.write_text(json.dumps(value))
                args.extend(["--" + name, str(path)])
            if include_receipt:
                (root / "receipts").mkdir()
                (root / "receipts" / (self.session_id + ".json")).write_text(json.dumps(self.receipts[0]))
            output = root / "timeline.json"
            args.extend(["--source", source, "--output", str(output)])
            result = subprocess.run(args, capture_output=True, text=True, timeout=10)
            return result, json.loads(output.read_text()) if output.exists() else None

    def test_cli_loads_receipts_from_dedicated_subdirectory(self):
        result, output = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["jsonSessionIDs"], [self.session_id])

    def test_cli_missing_receipt_or_legacy_json_fails_before_creating_output(self):
        for kwargs in ({"include_receipt": False}, {"include_delivery": False}):
            result, output = self.run_cli(**kwargs)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(output)
            self.assertTrue("receipt" in result.stderr or "delivery metadata" in result.stderr)

    def test_cli_explicit_signpost_mode_preserves_external_evidence_path(self):
        result, output = self.run_cli(source="signpost-export", include_receipt=False, include_delivery=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["deliveryCompleteness"], "external-signpost-validation-required")

    def test_missing_each_required_phase_is_rejected(self):
        for event in self.trace["events"]:
            trace = copy.deepcopy(self.trace)
            trace["events"] = [e for e in trace["events"] if e["phase"] != event["phase"]]
            with self.subTest(phase=event["phase"]), self.assertRaises(ValueError):
                self.assemble(trace=trace)

    def test_other_process_other_trace_api_return_and_incompatible_clocks_are_rejected(self):
        for key, value in [("pid", 124), ("traceID", "other"), ("endpoint", "reveal-returned"),
                           ("machTimebase", [1, 1]), ("inputMachTicks", 900_000), ("selectedMachTicksUpper", 100_000)]:
            observation = dict(self.observation, **{key: value})
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.assemble(observation=observation)

    def test_reordered_duplicate_overflowed_and_failed_traces_are_rejected(self):
        mutants = []
        reordered = copy.deepcopy(self.trace)
        reordered["events"][7]["phase"], reordered["events"][8]["phase"] = reordered["events"][8]["phase"], reordered["events"][7]["phase"]
        mutants.append(reordered)
        duplicate = copy.deepcopy(self.trace)
        duplicate["events"].insert(2, dict(duplicate["events"][1]))
        mutants += [duplicate, dict(self.trace, droppedEvents=1), dict(self.trace, outcome="failed")]
        for trace in mutants:
            with self.assertRaises(ValueError):
                self.assemble(trace=trace)

    def test_unrelated_menu_other_process_and_discarded_proof_are_rejected(self):
        for menu in [dict(self.menu, id="other"), dict(self.menu, pid=124)]:
            with self.assertRaises(ValueError):
                self.assemble(menu=menu)
        for preparation in [dict(self.preparation, id="other"), dict(self.preparation, pid=124),
                            dict(self.preparation, outcome="discarded"), dict(self.preparation, droppedEvents=1)]:
            with self.assertRaises(ValueError):
                self.assemble(preparation=preparation)

    def test_missing_menu_or_preparation_phase_and_future_proof_are_rejected(self):
        for field in ("menu", "preparation"):
            report = getattr(self, field)
            for event in report["events"]:
                mutant = copy.deepcopy(report)
                mutant["events"] = [e for e in mutant["events"] if e["phase"] != event["phase"]]
                with self.subTest(field=field, phase=event["phase"]), self.assertRaises(ValueError):
                    self.assemble(**{field: mutant})
        preparation = copy.deepcopy(self.preparation)
        for event in preparation["events"]:
            event["uptimeNS"] += 30_000_000
        with self.assertRaises(ValueError):
            self.assemble(preparation=preparation)

    def test_publication_and_menu_return_must_precede_the_action(self):
        preparation = copy.deepcopy(self.preparation)
        for event in preparation["events"]:
            if event["phase"].startswith("preparation.cache.") or event["phase"] == "end":
                event["uptimeNS"] += 50_000_000
        with self.assertRaises(ValueError):
            self.assemble(preparation=preparation)
        menu = copy.deepcopy(self.menu)
        menu["events"][-1]["uptimeNS"] += 50_000_000
        with self.assertRaises(ValueError):
            self.assemble(menu=menu)

    def test_menu_may_read_published_snapshot_before_acceptance_is_logged(self):
        preparation = copy.deepcopy(self.preparation)
        for event in preparation["events"]:
            if event["phase"] in ("preparation.cache.accepted", "preparation.cache.publish.end", "end"):
                event["uptimeNS"] += 20_000_000
        self.assertEqual(self.assemble(preparation=preparation)["preparationTraceID"], "owned-proof")

    def test_empty_related_reports_and_invalid_clock_values_are_rejected(self):
        for field in ("menu", "preparation"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.assemble(**{field: dict(getattr(self, field), events=[])})
        for value in (-1, 1.5, True):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.assemble(observation=dict(self.observation, inputMachTicks=value))
        trace = copy.deepcopy(self.trace)
        trace["clockAnchor"]["uptimeAfterNS"] = trace["events"][0]["uptimeNS"] + 1
        with self.assertRaises(ValueError):
            self.assemble(trace=trace)


if __name__ == "__main__":
    unittest.main()
