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


NATIVE_DIAGNOSTIC_WORDS = {word.lower(): word for word in (
    "fullStackHistory", "MallocStackLogging", "MallocStackLoggingNoCompact", "MallocStackLoggingLite", "MSL",
    "compact", "noncompact", "non-compact", "lite", "mode", "supported", "support", "supports", "unsupported",
    "not", "no", "never", "only", "enable", "enabled", "enabling", "disable", "disabled", "stack", "logging", "history",
    "requires", "require", "required", "with", "when", "without", "using", "used", "must", "cannot", "available",
    "unavailable", "allowed", "is", "are", "be", "to", "for", "and", "or", "because", "in", "a", "the", "this",
    "current", "full", "malloc", "allocation", "allocations", "freed", "record", "records", "recording", "process", "error", "fatal",
    "option", "options", "use", "instead", "can", "could", "unable", "failed", "version", "set", "setting", "settings",
    "environment", "variable", "variables", "legacy", "normal", "uncompacted", "all", "free",
    "does", "doesn't", "don't", "isn't", "aren't", "can't", "won't", "couldn't", "wasn't", "weren't", "didn't")}


def native_diagnostic_clues(output):
    """Ordered whitelist words only; these lexical hints do not establish cause."""
    words = []
    payload = output.encode("utf-8") if isinstance(output, str) else output
    truncated = len(payload) > 65536
    bounded = payload[:65536]
    if truncated and bounded and not bounded[-1:].isspace():
        # A clipped unknown word must not become a complete whitelist word.
        prefix = bounded.rsplit(None, 1)
        bounded = prefix[0] if len(prefix) == 2 else b""
    for raw in bounded.split():
        try:
            word = raw.decode("utf-8")
        except UnicodeDecodeError:
            # Dropping invalid bytes could turn an unknown token into a clue.
            continue
        word = word.replace("’", "'").strip(".,:;!?()[]{}'\"`").removeprefix("--")
        # Reject paths, addresses, process IDs, and unknown attached text. Only
        # the named malloc settings may carry the literal =0 / =1 suffix.
        setting = re.fullmatch(r"(MallocStackLogging(?:NoCompact|Lite)?)(?:=[01])?", word, re.I)
        if setting:
            word = setting[1]
        if word.lower() not in NATIVE_DIAGNOSTIC_WORDS:
            continue
        if len(words) == 64:
            truncated = True
            break
        words.append(NATIVE_DIAGNOSTIC_WORDS[word.lower()])
    return {"status": "recognized" if words else "unknown", "words": words, "truncated": truncated}


def native_full_history_failure(stdout, stderr, pid):
    """Classify complete private output before applying lossy display filters."""
    if stdout and stderr:
        return "unknown"
    # Both static forms are present in leaks. Match the complete diagnostic,
    # with this owned target PID and no extra line, word, or second channel.
    message = (f"[fatal] Cannot save a memgraph with '--fullStackHistory' for pid {pid} "
               "because it ran with MallocStackLogging lite mode. "
               "Please run the process with full MallocStackLogging.")
    pattern = r"(?:leaks\[[1-9][0-9]*\]: )?" + re.escape(message) + r"\n?"
    return "unsupported_lite_mode" if re.fullmatch(pattern, stdout or stderr) else "unknown"


def native_capture_comparison(pid, work):
    """One owned process, unchanged malloc settings, full history first."""
    cases = []
    for full in (True, False):
        failure_kind = "unknown"
        graph = work / ("full-history.memgraph" if full else "baseline.memgraph")
        if not full:
            # Exercise the live auxiliary contract itself, independently of
            # the preceding full-history capability observation.
            captured = NODES.capture_live_point(pid, "baseline", work, work, time.monotonic())
            status, code = captured["status"], captured["exit_code"]
            log = work / "baseline-capture.txt"
            diagnostic = ""
            if log.is_file():
                with log.open("rb") as stream:
                    diagnostic = stream.read(65537)
        else:
            try:
                captured = subprocess.run(["leaks", "--noContent", "--fullStacks", "--fullStackHistory",
                                          f"--outputGraph={graph}", str(pid)],
                                          capture_output=True, text=True, timeout=60)
                code = captured.returncode
                status = "complete" if code in (0, 1) and graph.is_file() else "failed"
                diagnostic = captured.stdout + "\n" + captured.stderr
                failure_kind = native_full_history_failure(captured.stdout, captured.stderr, pid)
            except subprocess.TimeoutExpired:
                status, code, diagnostic = "timeout", None, ""
            except OSError:
                status, code, diagnostic = "failed", None, ""
        row = {"case": "full_stack_history" if full else "current_stack_history", "capture_status": status,
               "capture_exit_code": code, "graph_created": graph.is_file(),
               "capture_failure_kind": failure_kind if status != "complete" else None,
               "capture_clues": native_diagnostic_clues(diagnostic) if status != "complete" else None,
               "history_status": "not_attempted", "history_exit_code": None, "history_clues": None}
        if status == "complete":
            try:
                history = subprocess.run(["malloc_history", "--allEvents", "--fullStacks", str(graph)],
                                         capture_output=True, text=True, timeout=60)
                row["history_exit_code"] = history.returncode
                row["history_status"] = ("readable" if re.search(r"^ALLOC ", history.stdout, re.M) else "no_allocations") if history.returncode == 0 else "failed"
                if row["history_status"] == "failed":
                    row["history_clues"] = native_diagnostic_clues(history.stdout + "\n" + history.stderr)
            except subprocess.TimeoutExpired:
                row["history_status"] = "timeout"
            except OSError:
                row["history_status"] = "io_error"
        cases.append(row)
    return {"schema": 2, "scope": "owned-native-capture-comparison", "same_process": True,
            "malloc_settings": {"MallocStackLogging": "1", "MallocStackLoggingNoCompact": "1"},
            "cases": cases}


class AXLiveAttributionTests(unittest.TestCase):
    def assert_native_capture_contract(self, comparison):
        full, current = comparison["cases"]
        self.assertEqual(current["case"], "current_stack_history")
        self.assertEqual(full["case"], "full_stack_history")
        for row in (current, full) if full["capture_status"] == "complete" else (current,):
            self.assertEqual(row["capture_status"], "complete", row)
            self.assertIn(row["capture_exit_code"], (0, 1), row)
            self.assertTrue(row["graph_created"], row)
            self.assertEqual((row["history_status"], row["history_exit_code"]), ("readable", 0), row)
        if full["capture_status"] != "complete":
            # Only classification of the complete private diagnostic can
            # permit this capability failure. Display clues are not evidence.
            self.assertEqual((full["capture_status"], full["capture_exit_code"], full["graph_created"],
                              full["history_status"], full["history_exit_code"]),
                             ("failed", 255, False, "not_attempted", None), full)
            self.assertEqual(full["capture_failure_kind"], "unsupported_lite_mode", full)

    def test_native_diagnostic_clues_are_ordered_bounded_whitelist_words(self):
        self.assertEqual(native_diagnostic_clues(
            "leaks[123]: ERROR: --fullStackHistory is only supported with MallocStackLoggingNoCompact=1.\n"
            "/private/compact C:\\Users\\lite 0x1234 123 private-fullStackHistory --history=/private/path"),
            {"status": "recognized", "words": ["error", "fullStackHistory", "is", "only", "supported", "with",
                                                   "MallocStackLoggingNoCompact"], "truncated": False})
        self.assertEqual(native_diagnostic_clues("unknown-private-message /private/history 0x1234 9876"),
                         {"status": "unknown", "words": [], "truncated": False})
        self.assertEqual(native_diagnostic_clues("lite mode doesn’t support `--fullStackHistory`.")["words"],
                         ["lite", "mode", "doesn't", "support", "fullStackHistory"])
        limited = native_diagnostic_clues("not " * 65)
        self.assertEqual(limited, {"status": "recognized", "words": ["not"] * 64, "truncated": True})
        self.assertEqual(native_diagnostic_clues("x" * 65536 + " fullStackHistory"),
                         {"status": "unknown", "words": [], "truncated": True})

    def test_native_diagnostic_clues_preserve_negation(self):
        for diagnostic, expected in (
            ("No stack history available", ["no", "stack", "history", "available"]),
            ("fullStackHistory is never supported", ["fullStackHistory", "is", "never", "supported"]),
        ):
            with self.subTest(diagnostic=diagnostic):
                self.assertEqual(native_diagnostic_clues(diagnostic),
                                 {"status": "recognized", "words": expected, "truncated": False})

    def test_native_diagnostic_clues_limit_bytes_and_discard_incomplete_tokens(self):
        unicode_output = "no " + "é" * 33000 + " stack history"
        self.assertEqual(len(unicode_output.encode("utf-8")), 66017)
        self.assertEqual(native_diagnostic_clues(unicode_output),
                         {"status": "recognized", "words": ["no"], "truncated": True})
        for output in (
            b"x " * 32766 + b"only_suffix",
            b"x" * 65531 + b" not\xe2\x80\x99suffix",
        ):
            with self.subTest(length=len(output)):
                self.assertEqual(native_diagnostic_clues(output),
                                 {"status": "unknown", "words": [], "truncated": True})
        self.assertEqual(native_diagnostic_clues(b"not\xff never"),
                         {"status": "recognized", "words": ["never"], "truncated": False})
        self.assertEqual(native_diagnostic_clues(b"x" * 65533 + b" no"),
                         {"status": "recognized", "words": ["no"], "truncated": False})

    def test_native_full_history_classification_requires_complete_single_channel_message(self):
        message = ("[fatal] Cannot save a memgraph with '--fullStackHistory' for pid 9876 "
                   "because it ran with MallocStackLogging lite mode. "
                   "Please run the process with full MallocStackLogging.")
        for prefix in ("", "leaks[123]: "):
            for suffix in ("", "\n"):
                output = prefix + message + suffix
                for stdout, stderr in ((output, ""), ("", output)):
                    with self.subTest(prefix=prefix, suffix=suffix, stdout=bool(stdout)):
                        self.assertEqual(native_full_history_failure(stdout, stderr, 9876), "unsupported_lite_mode")
        for stdout, stderr in (
            ("", message + "\nPermission denied"),
            ("", message + "\nUnexpected backend diagnostic 0x1234"),
            ("", message + " unknownword"),
            ("", message.replace("ran with", "ran unexpectedly with")),
            ("", message.replace("9876", "9877")),
            ("", message.replace("lite mode", "not enabled")),
            ("", "different[123]: " + message),
            ("", "leaks[unknown]: " + message),
            ("", message + "\n\n"),
            ("", "\n" + message),
            ("unexpected", message),
            (message, "\n"),
            (message, message),
            ("", ""),
        ):
            with self.subTest(stdout=stdout, stderr=stderr):
                self.assertEqual(native_full_history_failure(stdout, stderr, 9876), "unknown")

    def test_native_current_contract_preserves_full_history_capability_and_rejects_unknown_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            pid = 9876
            (work / "baseline-live.stdout.txt").write_text("owned ordinary scan")
            full_error = ("leaks[123]: [fatal] Cannot save a memgraph with '--fullStackHistory' for pid 9876 "
                          "because it ran with MallocStackLogging lite mode. "
                          "Please run the process with full MallocStackLogging.\n")
            commands = []
            def run(command, **kwargs):
                commands.append(command)
                if command[0] == "leaks":
                    if "--fullStackHistory" in command:
                        self.assertEqual(command, ["leaks", "--noContent", "--fullStacks", "--fullStackHistory",
                                                   f"--outputGraph={work / 'full-history.memgraph'}", str(pid)])
                        return subprocess.CompletedProcess(command, 255, "", full_error)
                    self.assertEqual(command, ["leaks", "--noContent", "--fullStacks",
                                               f"--outputGraph={work / 'baseline.memgraph'}", str(pid)])
                    (work / "baseline.memgraph").write_bytes(b"owned graph")
                    return subprocess.CompletedProcess(command, 0, "", "")
                self.assertEqual(command, ["malloc_history", "--allEvents", "--fullStacks", str(work / "baseline.memgraph")])
                return subprocess.CompletedProcess(command, 0, "ALLOC 0x1234 private stack\n", "")
            with mock.patch.object(subprocess, "run", side_effect=run):
                result = native_capture_comparison(pid, work)
            self.assert_native_capture_contract(result)
            full, control = result["cases"]
            self.assertEqual((full["capture_status"], full["capture_exit_code"], full["graph_created"], full["history_status"]),
                             ("failed", 255, False, "not_attempted"))
            self.assertEqual((control["capture_status"], control["capture_exit_code"], control["history_status"]),
                             ("complete", 0, "readable"))
            self.assertEqual(len(commands), 3)
            self.assertTrue(result["same_process"])
            encoded = json.dumps(result)
            for private in ("/private", "0x1234", "9876", directory):
                self.assertNotIn(private, encoded)
            for case, field, value in (
                (0, "capture_status", "timeout"), (0, "capture_exit_code", 2), (0, "graph_created", True),
                (0, "capture_failure_kind", "unknown"),
                (1, "capture_status", "failed"), (1, "capture_exit_code", 255), (1, "graph_created", False),
                (1, "history_status", "no_allocations"), (1, "history_exit_code", 1),
            ):
                with self.subTest(case=case, field=field, value=value):
                    invalid = copy.deepcopy(result)
                    invalid["cases"][case][field] = value
                    with self.assertRaises(AssertionError):
                        self.assert_native_capture_contract(invalid)
            original_error = full_error
            for extra in ("Permission denied\n", "Unexpected backend diagnostic 0x1234\n"):
                full_error = original_error + extra
                with self.subTest(extra=extra), mock.patch.object(subprocess, "run", side_effect=run):
                    rejected = native_capture_comparison(pid, work)
                # These additions disappear from the display whitelist but
                # must survive classification and reject the actual contract.
                self.assertEqual(rejected["cases"][0]["capture_clues"], full["capture_clues"])
                self.assertEqual(rejected["cases"][0]["capture_failure_kind"], "unknown")
                with self.assertRaises(AssertionError):
                    self.assert_native_capture_contract(rejected)
            supported = copy.deepcopy(result)
            supported["cases"][0] = control | {"case": "full_stack_history"}
            self.assert_native_capture_contract(supported)
            supported["cases"][0]["history_status"] = "no_allocations"
            with self.assertRaises(AssertionError):
                self.assert_native_capture_contract(supported)

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
                        raise self.failureException("Owned CLI test tool did not complete") from None
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
                        comparison = native_capture_comparison(process.pid, work)
                    finally:
                        try:
                            process.communicate("\n", timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.communicate(timeout=5)
                        self.assertIsNotNone(process.returncode, "Owned CLI fixture did not exit")
                    print(json.dumps(comparison, separators=(",", ":")), flush=True)
                    # Current-stack capture is the live contract. Full-history
                    # support remains a separate, bounded capability check.
                    self.assert_native_capture_contract(comparison)
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
