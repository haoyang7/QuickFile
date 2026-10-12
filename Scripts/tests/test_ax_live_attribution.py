import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from test_ax_frozen_nodes import Case, NODES, listing


def prepare_live(case, mode="product"):
    scans = [{"label": label, "leak_nodes": len(case.points[label]),
              "leak_bytes": sum(case.points[label].values()), "exit_code": 1}
             for label in NODES.LIVE_LABELS]
    (case.records / "scans.json").write_text(json.dumps(scans))
    (case.records / "result.json").write_text(json.dumps({
        "mode": mode, "scan_mode": "live", "live_attribution": True, "coverage": "failed"}))
    for row in scans:
        (case.records / (row["label"] + "-live.stdout.txt")).write_text(listing(case.points[row["label"]]))
    selected = NODES.first_live_growth(scans)
    captures = [{"label": label, "status": "complete", "exit_code": 0,
                 "after_scan_ms": 3, "duration_ms": 20,
                 "stdout_sha256": hashlib.sha256((case.records / (label + "-live.stdout.txt")).read_bytes()).hexdigest(),
                 "graph_sha256": NODES.graph_hash(case.graphs / (label + ".memgraph"))}
                for label in (("baseline", selected) if selected else ("baseline",))]
    (case.records / "live-captures.json").write_text(json.dumps(captures))


def compare_live(case):
    with mock.patch.object(NODES.Tools, "run", autospec=True, side_effect=case.run):
        value = NODES.compare(case.graphs, case.records, live_pair=True)
    NODES.validate_summary(value)
    return value


class AXLiveAttributionTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin" and os.environ.get("QUICKFILE_AX_LIVE_CAPTURE_SMOKE") == "1",
                         "Explicit native live-capture investigation only")
    def test_native_live_capture_cli(self):
        """Exercise the installed leaks binary, including its actual graph output."""
        root = Path(os.environ.get("QUICKFILE_AX_LIVE_CAPTURE_DIRECTORY",
                    Path(__file__).resolve().parents[2] / ".build/Temporary/ax-live-capture-cli"))
        root.mkdir(parents=True, exist_ok=True)
        try:
            with tempfile.TemporaryDirectory(dir=root, prefix="owned-") as directory:
                work = Path(directory)
                source, executable = work / "owned.c", work / "owned"
                source.write_text('#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n'
                    'int main(void) { void *p = malloc(128); memset(p, 0x55, 128); free(p); '
                    'puts("ready"); fflush(stdout); return getchar() == EOF; }\n')
                entitlements = work / "debug.plist"
                entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
                def run(command):
                    try:
                        return subprocess.run(command, capture_output=True, text=True, timeout=60)
                    except (OSError, subprocess.TimeoutExpired):
                        self.fail("Owned CLI test tool did not complete")
                self.assertEqual(run(["xcrun", "clang", "-O0", "-g", str(source), "-o", str(executable)]).returncode, 0,
                                 "Owned CLI fixture compilation failed")
                self.assertEqual(run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(executable)]).returncode, 0,
                                 "Owned CLI fixture signing failed")
                environment = dict(os.environ)
                for key in ("MallocScribble", "MallocPreScribble", "MallocNanoZone", "MallocGuardEdges", "DYLD_INSERT_LIBRARIES"):
                    environment.pop(key, None)
                environment.update(MallocStackLogging="1", MallocStackLoggingNoCompact="1")
                with (work / "host.stderr.txt").open("w") as errors:
                    process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                               stderr=errors, text=True, env=environment)
                    try:
                        # Wait for the owned fixture without blocking forever on stdout.
                        import select
                        self.assertTrue(select.select([process.stdout], [], [], 5)[0], "Owned CLI fixture did not become ready")
                        self.assertEqual(process.stdout.readline().strip(), "ready", "Owned CLI fixture failed before readiness")
                        original = run(["leaks", "--noContent", "--groupByType", "--nosources", "--fullStacks", str(process.pid)])
                        self.assertIn(original.returncode, (0, 1), NODES.capture_error_signals(original.stdout + original.stderr))
                        (work / "baseline-live.stdout.txt").write_text(original.stdout)
                        captured = NODES.capture_live_point(process.pid, "baseline", work, work, time.monotonic())
                        self.assertEqual(captured["status"], "complete", captured)
                        self.assertGreater((work / "baseline.memgraph").stat().st_size, 0)
                        self.assertEqual(captured["graph_sha256"], NODES.graph_hash(work / "baseline.memgraph"))
                        history = run(["malloc_history", "--allEvents", "--fullStacks", str(work / "baseline.memgraph")])
                        self.assertEqual(history.returncode, 0, "Owned capture history could not be read")
                        self.assertTrue(re.search(r"^ALLOC ", history.stdout, re.M), "Owned capture has no allocation history")
                    finally:
                        try:
                            process.communicate("\n", timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.communicate(timeout=5)
                        self.assertIsNotNone(process.returncode, "Owned CLI fixture did not exit")
        finally:
            if not any(root.iterdir()):
                root.rmdir()

    def test_failed_tool_exports_only_fixed_error_signals_and_accepts_old_receipts(self):
        cases = (
            ("leaks[123]: leaks cannot examine process 456 (owned) for unknown reasons; try sudo.\n"
             "leaks[123]: [fatal] mach port for process 0 not valid", ["task_port"]),
            ("unrecognized option --private; Usage: leaks --fullStackHistory", ["stack_history", "option"]),
            ("Unable to create /private/secret.memgraph: Permission denied", ["permission", "file_io"]),
            ("private path, address 0x1234 and an unrecognized diagnostic", ["unclassified"]),
        )
        for text, expected in cases:
            with self.subTest(expected=expected):
                self.assertEqual(NODES.capture_error_signals(text), expected)
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory), {}, {}, first=2)
            prepare_live(case)
            value = compare_live(case)
            original = copy.deepcopy(value)
            value["live_captures"][0]["error_signals"] = []
            NODES.validate_summary(value)
            NODES.validate_summary(original)
            for signals in (["private failure"], ["task_port"], ["option", "option"], "timeout"):
                value["live_captures"][0]["error_signals"] = signals
                with self.assertRaises(ValueError):
                    NODES.validate_summary(value)

    def test_only_first_original_growth_is_selected_and_compact_identity_stays_unknown(self):
        for mode in ("heap-control", "product"):
            for label in NODES.LIVE_LABELS[1:]:
                with self.subTest(mode=mode, label=label), tempfile.TemporaryDirectory() as directory:
                    case = Case(Path(directory), {0x1000: 48}, {0x1000: 48, 0x2000: 80},
                                first=NODES.HEAP_LABELS.index(label))
                    prepare_live(case, mode)
                    value = compare_live(case)
                    self.assertEqual(value["schema"], 3)
                    self.assertEqual(value["selected_label"], label)
                    self.assertEqual(value["selection"], "live-pair")
                    self.assertEqual(value["status"], "partial")
                    self.assertEqual(value["nodes"][0]["baseline_presence"], "present")
                    self.assertEqual(value["nodes"][0]["history"]["classification"], "unknown")
                    self.assertIn("compact_history", value["reasons"])
                    self.assertEqual([point["label"] for point in value["checked_points"]], ["baseline", label])
                    self.assertEqual([point["label"] for point in value["live_scans"]], list(NODES.LIVE_LABELS))
                    self.assertNotIn("added-10", [call[1] for call in case.calls])
                    self.assertEqual(json.loads(NODES.encode_summary(value)), value)
                    self.assertNotIn("private", NODES.encode_summary(value).decode())

    def test_absent_baseline_allocation_can_be_new_but_retained_resized_address_cannot(self):
        for resized in (False, True):
            with self.subTest(resized=resized), tempfile.TemporaryDirectory() as directory:
                before = {0x1000: 48}
                after = {0x1000: 80} if resized else before | {0x2000: 80}
                case = Case(Path(directory), before, after, first=2)
                case.baseline_heap = before
                address = 0x1000 if resized else 0x2000
                case.heap_diff = {address: 80}
                case.before_events = [("ALLOC", 0x1000, 48)]
                case.after_events = case.before_events + ([("FREE", 0x1000, 48)] if resized else []) + [("ALLOC", address, 80)]
                prepare_live(case)
                value = compare_live(case)
                self.assertEqual(value["nodes"][0]["history"]["classification"], "unknown" if resized else "new_allocation")
                self.assertEqual(value["status"], "partial" if resized else "complete")

    def test_later_graph_mismatch_does_not_overwrite_original_counts_or_select_later_growth(self):
        for point in ("baseline", "registered-10"):
            with self.subTest(point=point), tempfile.TemporaryDirectory() as directory:
                case = Case(Path(directory), {0x1000: 48}, {0x1000: 48, 0x2000: 80}, first=2)
                prepare_live(case)
                original = (case.records / "scans.json").read_bytes()
                case.points[point] = {0x1000: 48, 0x3000: 32}
                case.baseline_heap[0x3000] = 32
                value = compare_live(case)
                self.assertEqual(value["status"], "partial")
                self.assertEqual(value["selected_label"], "registered-10")
                self.assertIn("live_snapshot_mismatch", value["reasons"])
                source = next(row for row in value["live_scans"] if row["label"] == point)
                self.assertEqual(source["leak_bytes"], 48 if point == "baseline" else 128)
                self.assertEqual((case.records / "scans.json").read_bytes(), original)

    def test_no_growth_captures_only_baseline_and_graph_disagreement_remains_partial(self):
        for mismatch in (False, True):
            with self.subTest(mismatch=mismatch), tempfile.TemporaryDirectory() as directory:
                case = Case(Path(directory), {0x1000: 48}, {0x1000: 48})
                prepare_live(case)
                if mismatch:
                    case.points["baseline"] = {}
                value = compare_live(case)
                self.assertEqual(value["selection"], "live-no-growth")
                self.assertEqual(value["status"], "partial" if mismatch else "complete")
                self.assertEqual([(kind, label) for kind, label, _ in case.calls], [("list", "baseline"), ("tree", "baseline")])
                with mock.patch.object(sys, "path", [str(Path(NODES.__file__).parent), *sys.path]):
                    import ax_bridge_evidence as bridge_module
                    bridge = bridge_module.collect(frozen=value, traces={}, baseline_heap=None,
                        before_graph=None, after_graph=None, tools=mock.Mock(summary={"tools": []}), reference_ids={})
                    bridge_module.validate_summary(bridge, value)
                self.assertEqual(bridge["status"], "partial" if mismatch else "not_needed")

    def test_auxiliary_disappearance_and_candidate_limit_are_explicit(self):
        for count in (0, 18):
            with self.subTest(count=count), tempfile.TemporaryDirectory() as directory:
                after = {0x2000 + index * 128: 48 for index in range(max(count, 1))}
                case = Case(Path(directory), {}, after, first=2)
                prepare_live(case)
                if not count:
                    case.points["registered-10"] = {}
                value = compare_live(case)
                self.assertEqual(value["status"], "partial")
                self.assertEqual(value["candidate_count"], count)
                self.assertEqual(value["omitted_candidates"], max(0, count - NODES.CANDIDATES))
                self.assertIn("candidate_limit" if count else "live_snapshot_mismatch", value["reasons"])

    def test_missing_tampered_or_unfinished_capture_never_launches_offline_tools(self):
        for failure in ("stdout", "totals", "graph", "capture", "timeout", "cleanup", "mode"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                case = Case(Path(directory), {}, {0x2000: 48}, first=2)
                prepare_live(case)
                if failure == "stdout":
                    (case.records / "baseline-live.stdout.txt").write_text("missing original totals")
                elif failure == "totals":
                    (case.records / "removed-30-live.stdout.txt").write_text(listing({}))
                elif failure == "graph":
                    (case.graphs / "baseline.memgraph").write_bytes(b"changed")
                elif failure in ("capture", "timeout"):
                    path = case.records / "live-captures.json"
                    rows = json.loads(path.read_text())
                    if failure == "capture":
                        rows[0]["stdout_sha256"] = "0" * 64
                    else:
                        rows[0].update(status="timeout", exit_code=None, graph_sha256=None)
                    path.write_text(json.dumps(rows))
                elif failure == "cleanup":
                    (case.records / "process-cleanup.json").write_text('{"processes_exited":false}')
                else:
                    (case.records / "result.json").write_text('{"mode":"product","scan_mode":"diagnostic"}')
                value = compare_live(case)
                self.assertEqual(value["status"], "unavailable")
                self.assertEqual(case.calls, [])

    def test_public_schema_rejects_unbound_hashes_private_fields_and_generation_overclaim(self):
        with tempfile.TemporaryDirectory() as directory:
            case = Case(Path(directory), {}, {0x2000: 48}, first=2)
            prepare_live(case)
            value = compare_live(case)
        for mutate in (
            lambda v: v["live_captures"][0].update(graph_sha256="0" * 64),
            lambda v: v["live_captures"][0].update(stdout_sha256="0" * 64),
            lambda v: v["live_captures"][0].update(after_scan_ms=-1),
            lambda v: v["live_scans"][1].update(label="removed-30"),
            lambda v: v["live_scans"][0].update(private="secret"),
            lambda v: v["nodes"][0]["history"].update(classification="preexisting"),
            lambda v: v["nodes"][0]["history"].update(classification="new_allocation"),
        ):
            changed = copy.deepcopy(value)
            mutate(changed)
            with self.assertRaises(ValueError):
                NODES.validate_summary(changed)


if __name__ == "__main__":
    unittest.main()
