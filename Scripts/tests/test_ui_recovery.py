"""Harness coverage only; no test launches the GUI, reads AX, or measures leaks.

The macOS smoke also runs one small creation probe in its own temporary directory
with deterministic owned-fixture bookmarks and injected scope start/stop. It never
invokes live bookmark APIs, Finder, or production App Group data.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]


def load_script(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts/Investigations" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BUILD = load_script("build_ui_recovery", "build-ui-recovery.py")
RUN = load_script("run_ui_recovery", "run-ui-recovery.py")
ROW_MEMORY = load_script("run_ax_row_memory", "run-ax-row-memory.py")


class UIRecoveryBuildCommandTests(unittest.TestCase):
    def build_commands(self, *arguments):
        with tempfile.TemporaryDirectory(prefix="quickfile-ui-command-test-") as temporary:
            output = Path(temporary)
            with patch.object(sys, "argv", ["build-ui-recovery.py", "--output", temporary, *arguments]), \
                    patch.object(BUILD.subprocess, "run") as run, \
                    patch.object(BUILD.subprocess, "check_output", return_value="fixture-sha\n"), \
                    contextlib.redirect_stdout(io.StringIO()):
                BUILD.main()
            calls = [call.args[0] for call in run.call_args_list]
            manifest = json.loads((output / "source-manifest.json").read_text())
            bundles = list(output.glob("*.app/Contents/Info.plist"))
            info = plistlib.loads(bundles[0].read_bytes()) if bundles else None
            return calls, manifest, info

    def test_recovery_compiles_current_container_and_all_dependencies(self):
        calls, manifest, info = self.build_commands("--optimization", "release")
        self.assertEqual(len(calls), 5)  # Three modules, one executable, ad-hoc signing.
        executable = calls[3]
        for name in ("AppTabsView", "DiagnosticsView", "DiagnosticsViewModel", "FinderMenuSettingsViewModel", "FinderAuthorizationRequestPump", "AppModalPresentationGate", "TemplatePreviewController"):
            source = f"QuickFileApp/{name}.swift"
            self.assertIn(str(ROOT / source), executable)
            self.assertEqual(manifest["sources"][source], hashlib.sha256((ROOT / source).read_bytes()).hexdigest())
        self.assertIn(str(ROOT / "Scripts/Investigations/UIRecovery.swift"), executable)
        self.assertNotIn(str(ROOT / "QuickFileApp/QuickFileApp.swift"), executable)
        self.assertNotIn(str(ROOT / "QuickFileApp/ContentView.swift"), executable)
        self.assertTrue(all("-O" in command for command in calls[:4]))
        self.assertEqual(calls[-1][:4], ["codesign", "--force", "--sign", "-"])
        self.assertEqual(info["CFBundleIdentifier"], "local.quickfile.investigation.ui-recovery")

    def test_existing_tab_switch_build_is_preserved(self):
        calls, manifest, info = self.build_commands("--probe", "tab-switch")
        self.assertIn(str(ROOT / "Scripts/Investigations/TabSwitch.swift"), calls[3])
        self.assertNotIn(str(ROOT / "Scripts/Investigations/UIRecovery.swift"), calls[3])
        self.assertEqual(info["CFBundleExecutable"], "TabSwitch")
        self.assertEqual(manifest["optimization"], "debug")

    def test_modules_only_does_not_build_or_sign_any_app(self):
        calls, manifest, info = self.build_commands("--modules-only")
        self.assertEqual(len(calls), 3)
        self.assertIsNone(info)
        self.assertTrue(all(path.startswith("Shared/") for path in manifest["sources"]))
        self.assertTrue(all(command[:2] == ["xcrun", "swiftc"] for command in calls))


class UIRecoveryMemoryScanTests(unittest.TestCase):
    def test_leak_scan_accepts_zero_and_one_and_records_heap(self):
        for exit_code, nodes, size in ((0, 0, 0), (1, 2, 64)):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory(prefix="quickfile-memory-test-") as temporary:
                output = Path(temporary)
                raw = f"Process 1234: {nodes} leaks for {size} total leaked bytes.\n"
                if nodes:
                    raw += "  2 (64 bytes) ROOT LEAK: NSArray 0xabc\n"
                heap = "  3 96 32.0 NSArray\n"
                results = [subprocess.CompletedProcess([], exit_code, raw, "leaks diagnostic\n"),
                           subprocess.CompletedProcess([], 0, heap, "")]
                with patch.object(RUN.subprocess, "run", side_effect=results) as commands:
                    result = RUN.scan(1234, output, "baseline")
                self.assertEqual([call.args[0][0] for call in commands.call_args_list], ["leaks", "heap"])
                self.assertEqual(result["leaks"], nodes)
                self.assertEqual(result["leakedBytes"], size)
                self.assertEqual(result["rootGroups"], [{"nodesInGroup": 2, "root": "NSArray <address>"}] if nodes else [])
                self.assertEqual(result["selectedHeapClasses"], {"NSArray": {"instances": 3, "bytes": 96}})
                self.assertEqual(json.loads((output / "memory-baseline.json").read_text()), result)
                self.assertEqual((output / "private-baseline-leaks.txt").read_text(), raw + "leaks diagnostic\n")
                self.assertEqual((output / "private-baseline-heap.txt").read_text(), heap)

    def test_unavailable_leak_scan_keeps_raw_without_heap_or_memory_receipt(self):
        summary = "Process 1234: 0 leaks for 0 total leaked bytes.\n"
        for exit_code, stdout in ((2, summary), (-9, summary), (0, ""), (1, "")):
            with self.subTest(exit_code=exit_code, stdout=stdout), tempfile.TemporaryDirectory(prefix="quickfile-memory-test-") as temporary:
                output = Path(temporary)
                failed = subprocess.CompletedProcess([], exit_code, stdout, "error: process unavailable\n")
                with patch.object(RUN.subprocess, "run", return_value=failed) as commands:
                    with self.assertRaisesRegex(RuntimeError, f"Leak scan could not inspect owned process; exit {exit_code}"):
                        RUN.scan(1234, output, "baseline")
                commands.assert_called_once()
                self.assertEqual(commands.call_args.args[0][0], "leaks")
                self.assertEqual((output / "private-baseline-leaks.txt").read_text(), stdout + failed.stderr)
                self.assertFalse((output / "memory-baseline.json").exists())
                self.assertFalse((output / "private-baseline-heap.txt").exists())

    def test_allocation_roots_accepts_zero_and_one_and_keeps_raw(self):
        for exit_code, nodes in ((0, 0), (1, 2)):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory(prefix="quickfile-address-test-") as temporary:
                output = Path(temporary)
                raw = f"Process 1234: {nodes} leaks for {nodes * 32} total leaked bytes.\n"
                if nodes:
                    raw += "  2 (64 bytes) ROOT LEAK: 0xabc NSArray\n"
                completed = subprocess.CompletedProcess([], exit_code, raw, "leaks diagnostic\n")
                with patch.object(ROW_MEMORY.subprocess, "run", return_value=completed) as commands:
                    roots = ROW_MEMORY.allocation_roots(1234, output, "baseline")
                commands.assert_called_once()
                self.assertEqual(roots, {"0xabc"} if nodes else set())
                self.assertEqual((output / "private-baseline-addresses.txt").read_text(), raw + completed.stderr)

    def test_unavailable_allocation_scan_keeps_raw_and_rejects_even_valid_summary(self):
        summary = "Process 1234: 0 leaks for 0 total leaked bytes.\n"
        for exit_code, stdout in ((2, summary), (-9, summary), (0, ""), (1, "")):
            with self.subTest(exit_code=exit_code, stdout=stdout), tempfile.TemporaryDirectory(prefix="quickfile-address-test-") as temporary:
                output = Path(temporary)
                failed = subprocess.CompletedProcess([], exit_code, stdout, "error: process unavailable\n")
                with patch.object(ROW_MEMORY.subprocess, "run", return_value=failed) as commands:
                    with self.assertRaisesRegex(RuntimeError, f"Cannot collect per-address leak evidence; exit {exit_code}"):
                        ROW_MEMORY.allocation_roots(1234, output, "baseline")
                commands.assert_called_once()
                self.assertEqual((output / "private-baseline-addresses.txt").read_text(), stdout + failed.stderr)
                self.assertEqual(list(output.glob("*.json")), [])

    def test_allocation_failure_aborts_case_before_history_release_or_success_receipts(self):
        with tempfile.TemporaryDirectory(prefix="quickfile-address-protocol-test-") as temporary:
            output = Path(temporary) / "case"

            class FixtureProcess:
                returncode = None

                def __init__(self, command, **kwargs):
                    self.pid = 1235 if command[0] == "reader" else 1234
                    if self.pid == 1234:
                        (output / "ready.json").write_text(json.dumps({"checkpoint": "baseline", "modelOperationsIdle": True}))
                        (output / "ax-baseline.json").write_text(json.dumps({"pid": self.pid, "readCount": 1}))

                def poll(self):
                    return self.returncode

                def wait(self, timeout):
                    self.returncode = 0
                    return 0

                def terminate(self):
                    self.returncode = -15

            failed = subprocess.CompletedProcess([], 2, "Process 1234: 0 leaks for 0 total leaked bytes.\n", "error: unavailable\n")
            with patch.object(ROW_MEMORY.UI, "CHECKPOINTS", ("baseline",)), \
                    patch.object(ROW_MEMORY.subprocess, "Popen", side_effect=FixtureProcess), \
                    patch.object(ROW_MEMORY.subprocess, "run", return_value=failed) as commands, \
                    patch.object(ROW_MEMORY, "scan", return_value={"leaks": 0, "rssBytes": 0, "physicalFootprintBytes": 0}) as scans, \
                    patch.object(ROW_MEMORY.time, "sleep"), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, "Cannot collect per-address leak evidence; exit 2"):
                    ROW_MEMORY.run_case(Path("fixture"), Path("reader"), output, observed=True)
            scans.assert_called_once()
            commands.assert_called_once()
            self.assertEqual(commands.call_args.args[0][0], "leaks")
            self.assertEqual((output / "private-before-reader-exit-addresses.txt").read_text(), failed.stdout + failed.stderr)
            for receipt in ("summary.json", "address-persistence.json", "release-reader", "continue-baseline",
                            "private-root-before-exit.txt", "private-root-after-exit.txt"):
                self.assertFalse((output / receipt).exists(), receipt)
            self.assertTrue((output / "abort").exists())


class UIRecoveryProtocolTests(unittest.TestCase):
    def test_legacy_cases_are_unchanged_and_production_cases_are_separate(self):
        expected = {
            "both-unobserved": ("both", "superset", "reload", False),
            "picker-unobserved": ("picker", "superset", "reload", False),
            "list-unobserved": ("list", "superset", "reload", False),
            "both-disjoint-unobserved": ("both", "disjoint", "reload", False),
            "both-preflight-unobserved": ("both", "superset", "create-preflight", False),
            "both-observed": ("both", "superset", "reload", True),
            "picker-observed": ("picker", "superset", "reload", True),
            "list-observed": ("list", "superset", "reload", True),
        }
        for label, configuration in expected.items():
            self.assertEqual(RUN.CASES[label], configuration)
        self.assertEqual(RUN.CASES["production-tabs-unobserved"], ("production-tabs", "superset", "reload", False))
        self.assertEqual(RUN.CASES["production-tabs-observed"], ("production-tabs", "superset", "reload", True))
        self.assertEqual(RUN.CASES["production-tabs-disjoint-unobserved"], ("production-tabs", "disjoint", "reload", False))
        self.assertEqual(RUN.CASES["production-tabs-preflight-unobserved"], ("production-tabs", "superset", "create-preflight", False))

    def test_current_container_injects_dependencies_and_preserves_read_only_protocol(self):
        source = (ROOT / "Scripts/Investigations/UIRecovery.swift").read_text()
        self.assertIn("AppTabsView(", source)
        self.assertIn("finderMenuSettings: driver.menuSettings!, diagnosticsViewModel: driver.diagnostics!", source)
        self.assertIn("selectedTab: $productionTab", source)
        self.assertIn('TabView(selection: $page)', source)
        self.assertIn('extensionEnabledProvider: { false }', source)
        self.assertIn('defaults: defaults, failureHistoryFileURL: directory.appendingPathComponent("failures.json")', source)
        self.assertIn('authorizedDirectoryStore: grants', source)
        self.assertIn('storageURL: directory.appendingPathComponent("finder-menu-settings.json")', source)
        self.assertIn('changeNotificationName: suite + ".menu-settings"', source)
        self.assertIn('load: { try settings.load() }, save: { try settings.save($0) }', source)
        self.assertIn('diagnostics = nil', source)
        self.assertIn('menuSettings = nil', source)
        for forbidden in ("DiagnosticsViewModel()", "FinderMenuSettingsViewModel()", "UserDefaults.standard",
                          "forSecurityApplicationGroupIdentifier:", "FinderExtensionRuntimeInspector.snapshot",
                          "NSOpenPanel()", "NSPasteboard.general", "AXUIElementPerformAction", "CGEvent("):
            self.assertNotIn(forbidden, source)
        self.assertIn("read-only AX; do not activate production controls", source)
        self.assertIn("this executable is not a sandbox for manual actions", source)

    def exercise_runner(self, label, *, invalid_ax=False, exit_code=0, symlink_root=False):
        with tempfile.TemporaryDirectory(prefix="quickfile-ui-protocol-test-") as temporary:
            argument_root = Path(temporary)
            if symlink_root:
                physical_root = argument_root / "physical"
                physical_root.mkdir()
                argument_root = argument_root / "alias"
                argument_root.symlink_to(physical_root, target_is_directory=True)
            output_argument = argument_root / "run"
            executable_argument = argument_root / "owned-fixture"
            # Match the runner's canonical paths, including macOS /var ->
            # /private/var. Keep aliased argv values to exercise normalization.
            output = output_argument.resolve()
            executable = executable_argument.resolve()
            pid = 41234
            observed = RUN.CASES[label][3]
            case_output = output / label

            class FixtureProcess:
                returncode = None

                def __init__(self):
                    self.pid = pid

                def poll(self):
                    return self.returncode

                def wait(self, timeout):
                    self.returncode = exit_code
                    (case_output / "timeline.json").write_text(json.dumps({
                        "events": [{"stage": "completed"}], "noFileCreation": True,
                    }))
                    return exit_code

            process = FixtureProcess()

            def start(command, **kwargs):
                self.assertEqual(command, [str(executable), "--output", str(case_output),
                    "--variant", "production-tabs", "--identities", RUN.CASES[label][1],
                    "--restore", RUN.CASES[label][2]])
                self.assertEqual(kwargs["env"]["MallocStackLogging"], "1")
                (case_output / "ready.json").write_text(json.dumps({"checkpoint": RUN.CHECKPOINTS[0]}))
                if observed:
                    for checkpoint in RUN.CHECKPOINTS:
                        (case_output / f"ax-{checkpoint}.json").write_text(json.dumps({
                            "pid": pid + (1 if invalid_ax else 0), "readCount": 1,
                        }))
                return process

            def scan(owned_pid, path, checkpoint):
                self.assertEqual(owned_pid, pid)
                self.assertEqual(path, case_output)
                index = RUN.CHECKPOINTS.index(checkpoint)
                if index + 1 < len(RUN.CHECKPOINTS):
                    (case_output / "ready.json").write_text(json.dumps({"checkpoint": RUN.CHECKPOINTS[index + 1]}))
                return {"checkpoint": checkpoint, "leaks": 0, "leakedBytes": 0}

            def ready(predicate, owned_process, **kwargs):
                self.assertIs(owned_process, process)
                self.assertTrue(predicate())

            with patch.object(sys, "argv", ["run-ui-recovery.py", "--output", str(output_argument),
                                           "--executable", str(executable_argument), "--cases", label]), \
                    patch.object(RUN.subprocess, "Popen", side_effect=start) as launched, \
                    patch.object(RUN.subprocess, "run", side_effect=AssertionError("unexpected external command")), \
                    patch.object(RUN, "scan", side_effect=scan) as scanned, \
                    patch.object(RUN, "wait_for", side_effect=ready), \
                    patch.object(RUN.time, "sleep"), contextlib.redirect_stdout(io.StringIO()) as messages:
                if invalid_ax:
                    with self.assertRaisesRegex(RuntimeError, "AX acknowledgement"):
                        RUN.main()
                    scanned.assert_not_called()
                    self.assertTrue((case_output / "abort").exists())
                    return
                if exit_code != 0:
                    with self.assertRaisesRegex(RuntimeError, f"UI fixture failed after checkpoints \\({exit_code}\\)"):
                        RUN.main()
                    self.assertEqual(scanned.call_count, 5)
                    self.assertEqual(json.loads((case_output / "timeline.json").read_text())["events"][-1]["stage"], "completed")
                    self.assertFalse((output / "summary.json").exists())
                    return
                RUN.main()
            launched.assert_called_once()
            self.assertEqual(scanned.call_count, 5)
            summary = json.loads((output / "summary.json").read_text())[0]
            self.assertEqual(summary["variant"], "production-tabs")
            self.assertEqual(summary["AXObserved"], observed)
            self.assertTrue(summary["noFileCreation"])
            self.assertEqual(len(list(case_output.glob("continue-*"))), 5)
            if observed:
                self.assertEqual(messages.getvalue().count("read-only AX; do not activate production controls"), 5)

    def test_runner_uses_current_container_with_five_read_only_ax_handshakes(self):
        self.exercise_runner("production-tabs-observed")

    def test_runner_resolves_symlinked_fixture_roots_before_launch_and_scan(self):
        self.exercise_runner("production-tabs-observed", symlink_root=True)

    def test_runner_supports_current_container_preflight_without_ax(self):
        self.exercise_runner("production-tabs-preflight-unobserved")

    def test_runner_rejects_ax_receipt_from_another_process_before_scanning(self):
        self.exercise_runner("production-tabs-observed", invalid_ax=True)

    def test_runner_rejects_nonzero_exit_even_after_completed_timeline(self):
        self.exercise_runner("production-tabs-unobserved", exit_code=7)


def fixture_from_source(source, transition, count, *, identities="superset", revision=0):
    """Interpret only the known fixture's literal/format contract, not Swift/UI.

    This deliberately narrow source-backed model fails if its recognized Swift
    expressions change. It cannot establish compiler lifetimes or AX behavior.
    """
    fixture = source.split("private static func fixture(", 1)[1].split(
        "private func verifyModel(", 1)[0]
    base = re.search(r'let base = count == (\d+) && identities == "disjoint" \? ([\d_]+) : 0', fixture)
    identifier = re.search(r'UUID\(uuidString: String\(format: "([^"]+)", base \+ index \+ 1\)\)!', fixture)
    name = re.search(r'name: String\(format: "([^"]+)", index\)', fixture)
    extension = re.search(r'fileExtension: "([^"]+)",\s*content: marker', fixture)
    body = re.search(r'content: marker \+ String\(repeating: "([^"]+)", count: (\d+)\)\)\s*\n\s*}', fixture)
    markers = {
        key: marker for keys, marker in re.findall(
            r'case ([^:]+):\s*(?://[^\n]*\n\s*)*marker = "([^"]+)"', fixture
        ) for key in re.findall(r'\.(\w+)', keys)
    }
    if None in (base, identifier, name, extension, body) or transition not in markers:
        raise ValueError("Fixture source contract changed; review the source-backed model")

    def expand(value, index):
        for key, replacement in (("count", count), ("index", index), ("bodyRevision", revision)):
            value = value.replace("\\(" + key + ")", str(replacement))
        if "\\(" in value:
            raise ValueError("Unrecognized fixture interpolation")
        return value

    offset = int(base[2].replace("_", "")) if count == int(base[1]) and identities == "disjoint" else 0
    return [{
        "id": identifier[1] % (offset + index + 1),
        "name": name[1] % index,
        "fileExtension": extension[1],
        "isEnabled": True,  # FileTemplate default; the call shape above forbids overrides.
        "content": expand(markers[transition], index) + expand(body[1], index) * int(body[2]),
    } for index in range(count)]


class UIRecoveryFixtureTransitionTests(unittest.TestCase):
    """Source/fixture-contract checks only; no Swift, AppKit, AX, or leaks run."""

    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / "Scripts/Investigations/UIRecovery.swift").read_text()

    def fixture(self, transition, count, **kwargs):
        return fixture_from_source(self.source, transition, count, **kwargs)

    def test_four_explicit_modes_keep_legacy_default_and_checkpoint_contract(self):
        for case, label in (("legacyCountTagged", "legacy-count-tagged"),
                            ("identicalReload", "identical-reload"),
                            ("bodyUpdate", "body-update"), ("membershipOnly", "membership-only")):
            self.assertIn(f'case {case} = "{label}"', self.source)
        self.assertIn('options["--transition"] ?? "legacy-count-tagged"', self.source)
        self.assertIn('case .legacyCountTagged, .membershipOnly: return 300', self.source)
        self.assertIn('case .identicalReload, .bodyUpdate: return 8', self.source)
        self.assertIn('case .legacyCountTagged, .membershipOnly: return "large300"', self.source)
        self.assertIn('case .identicalReload: return "reloaded8"', self.source)
        self.assertIn('case .bodyUpdate: return "updated8"', self.source)
        self.assertEqual(RUN.CHECKPOINTS, ("baseline8", "large300-1", "restored8-1", "large300-2", "restored8-2"))
        self.assertIn('transition == .legacyCountTagged ? "model300-\\(cycle)"', self.source)

    def test_legacy_fixture_still_changes_surviving_bodies_and_supports_disjoint_ids(self):
        small = self.fixture("legacyCountTagged", 8)
        large = self.fixture("legacyCountTagged", 300)
        disjoint = self.fixture("legacyCountTagged", 300, identities="disjoint")
        self.assertEqual(small[0]["content"], "UIRECOVERY-BODY-8-0-" + "body-0 " * 2048)
        self.assertEqual(large[0]["content"], "UIRECOVERY-BODY-300-0-" + "body-0 " * 2048)
        self.assertEqual([v["id"] for v in small], [v["id"] for v in large[:8]])
        self.assertTrue(all(a["content"] != b["content"] for a, b in zip(small, large)))
        self.assertTrue(set(v["id"] for v in small).isdisjoint(v["id"] for v in disjoint))
        self.assertEqual(small, self.fixture("legacyCountTagged", 8))

    def test_identical_reload_keeps_ids_count_bodies_and_reuses_exact_disk_bytes(self):
        initial = self.fixture("identicalReload", 8)
        for _ in range(4):
            self.assertEqual(initial, self.fixture("identicalReload", 8))
        disk = self.source.split('if transition == .identicalReload {', 1)[1].split('        let diskBytesIdentical', 1)[0]
        identical_branch, encoded_branch = disk.split('        } else {', 1)
        self.assertIn('JSONDecoder().decode([FileTemplate].self, from: previousBytes) == target', identical_branch)
        self.assertIn('data = previousBytes', identical_branch)
        self.assertNotIn('JSONEncoder()', identical_branch)
        self.assertIn('data = try JSONEncoder().encode(target)', encoded_branch)
        self.assertIn('let diskBytesIdentical = previousBytes == data', self.source)
        self.assertIn('changedSurvivingOtherFields == 0, diskBytesIdentical else', self.source)

    def test_body_update_keeps_every_nonbody_field_and_restores_all_original_bytes(self):
        baseline = self.fixture("bodyUpdate", 8)
        for _ in range(2):
            changed = self.fixture("bodyUpdate", 8, revision=1)
            self.assertEqual(len(changed), len(baseline))
            for original, updated in zip(baseline, changed):
                self.assertEqual({k: v for k, v in original.items() if k != "content"},
                                 {k: v for k, v in updated.items() if k != "content"})
                self.assertNotEqual(original["content"].encode(), updated["content"].encode())
            self.assertEqual(baseline, self.fixture("bodyUpdate", 8))
        self.assertIn('let changedRevision = transition == .bodyUpdate ? 1 : 0', self.source)
        self.assertIn('guard identityOrderUnchanged, changedSurvivingBodies == count,', self.source)

    def test_membership_only_preserves_all_eight_survivors_exactly_for_two_cycles(self):
        baseline = self.fixture("membershipOnly", 8)
        for _ in range(2):
            large = self.fixture("membershipOnly", 300)
            restored = self.fixture("membershipOnly", 8)
            self.assertEqual(large[:8], baseline)
            self.assertEqual(restored, baseline)
            self.assertEqual(len({value["id"] for value in large}), 300)
            self.assertEqual(len({value["id"] for value in large} - {value["id"] for value in restored}), 292)
        self.assertIn('!old.content.utf8.elementsEqual(value.content.utf8)', self.source)
        self.assertIn('guard oldIDs != newIDs, changedSurvivingBodies == 0, changedSurvivingOtherFields == 0,', self.source)
        self.assertIn('survivingIdentityOrderUnchanged,\n                  oldIDs.isSubset', self.source)

    def test_source_backed_model_detects_count_tagged_membership_regression(self):
        changed = self.source.replace('marker = "UIRECOVERY-BODY-STABLE-\\(index)-"',
                                      'marker = "UIRECOVERY-BODY-STABLE-\\(count)-\\(index)-"')
        self.assertNotEqual(changed, self.source)
        self.assertNotEqual(fixture_from_source(changed, "membershipOnly", 8),
                            fixture_from_source(changed, "membershipOnly", 300)[:8])

    def test_source_backed_model_detects_noop_body_revision_regression(self):
        changed = self.source.replace('marker = "UIRECOVERY-BODY-REV\\(bodyRevision)-\\(index)-"',
                                      'marker = "UIRECOVERY-BODY-REV0-\\(index)-"')
        self.assertNotEqual(changed, self.source)
        self.assertEqual(fixture_from_source(changed, "bodyUpdate", 8),
                         fixture_from_source(changed, "bodyUpdate", 8, revision=1))

    def test_unknown_fixture_formula_requires_review_instead_of_silent_model_pass(self):
        for original, replacement in (
            ('base + index + 1', 'count + index + 1'),
            ('count: 2048))', 'count: 2048), isEnabled: false)'),
        ):
            with self.subTest(replacement=replacement):
                changed = self.source.replace(original, replacement)
                self.assertNotEqual(changed, self.source)
                with self.assertRaisesRegex(ValueError, "Fixture source contract changed"):
                    fixture_from_source(changed, "membershipOnly", 8)

    def test_incompatible_and_malformed_options_are_rejected_before_writes(self):
        validation = self.source.split('    init() throws {', 1)[1].split(
            'try FileManager.default.createDirectory(at: directory,', 1)[0]
        for guard in ('arguments.count >= 2, flags.contains(arguments[0])',
                      '!arguments[1].hasPrefix("--"), options[arguments[0]] == nil',
                      'guard let selectedTransition = FixtureTransition(rawValue:',
                      'guard transition == .legacyCountTagged || identityMode == "superset" else',
                      'guard restoreEntry != "create-preflight" || transition.changedCount > 8 else'):
            self.assertIn(guard, validation)
        self.assertIn('throw FixtureError.invalidArguments', validation)
        self.assertIn('exit(EXIT_FAILURE)', self.source)
        self.assertNotIn('try! RecoveryDriver()', self.source)

    def test_preflight_proves_selected_id_will_be_removed_before_calling_create(self):
        selection = self.source.split('private func selectRemovedIdentityForPreflight() throws {', 1)[1].split(
            '    func run() async {', 1)[0]
        self.assertIn('model.templates.last(where: { !restoredIDs.contains($0.id) })?.id', selection)
        self.assertIn('model.selectedTemplateID = removedID', selection)
        self.assertIn('guard model.selectedTemplate != nil, !restoredIDs.contains(removedID) else', selection)
        self.assertIn('"selectedIDRemovedOnRestore": true', selection)
        run = self.source.split('    func run() async {', 1)[1].split('private struct RenderWitness', 1)[0]
        self.assertLess(run.index('try selectRemovedIdentityForPreflight()'), run.index('try changeDisk(to: 8'))
        self.assertLess(run.index('try changeDisk(to: 8'), run.index('await model.createFile()'))
        self.assertIn('guard model.createdFileURL == nil', run)
        self.assertIn('try verifyModel(count: 8)', run)

    def test_driver_retains_only_scalar_transition_evidence_across_awaits(self):
        stored_properties = self.source.split('private final class RecoveryDriver:', 1)[1].split('    init() throws {', 1)[0]
        run = self.source.split('    func run() async {', 1)[1].split('private struct RenderWitness', 1)[0]
        self.assertNotIn('[FileTemplate]', stored_properties)
        self.assertNotIn('Self.fixture(', run)
        self.assertNotIn('model.templates.map', run)
        self.assertIn('private func changeDisk(to count: Int, bodyRevision: Int = 0, label: String) throws', self.source)
        self.assertIn('private func verifyModel(count: Int, bodyRevision: Int = 0) throws', self.source)
        evidence = self.source.split('try event(label, extra:', 1)[1].split('    private func selectRemovedIdentity', 1)[0]
        for forbidden in ('"templates":', '"target":', '"content":', '"previousBytes":', '"oldByID":'):
            self.assertNotIn(forbidden, evidence)
        for field in ('"fixtureProtocolVersion": 2', '"transition": transition.rawValue',
                      '"fixtureCountSequence":', '"checkpointSequence":', '"bodyPolicy": transition.bodyPolicy',
                      '"changedSurvivingBodies":', '"changedSurvivingOtherFields":',
                      '"diskBytesIdentical": diskBytesIdentical'):
            self.assertIn(field, self.source)


@unittest.skipUnless(sys.platform == "darwin", "UI recovery compile smoke requires macOS; no GUI is launched")
class UIRecoveryNativeBuildTests(unittest.TestCase):
    def test_fixtures_compile_and_owned_probe_verifies_real_phase_evidence(self):
        # Exactly one full compilation per macOS test run. This accepts only the
        # build/link and owned CLI evidence contract, never GUI, AX, leak,
        # end-to-end latency, or installed-app gates.
        with tempfile.TemporaryDirectory(prefix="quickfile-ui-build-test-") as temporary:
            completed = subprocess.run([
                sys.executable, str(ROOT / "Scripts/Investigations/build-ui-recovery.py"),
                "--output", temporary,
            ], capture_output=True, text=True, timeout=240, cwd=ROOT)
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertTrue((Path(temporary) / "UIRecovery.app/Contents/MacOS/UIRecovery").is_file())
            manifest = json.loads((Path(temporary) / "source-manifest.json").read_text())
            for source in ("QuickFileApp/FinderMenuSettingsSection.swift", "QuickFileApp/TemplateContentPreview.swift",
                           "QuickFileApp/AppTabsView.swift", "QuickFileApp/DiagnosticsView.swift",
                           "QuickFileApp/DiagnosticsViewModel.swift", "Scripts/Investigations/UIRecovery.swift"):
                self.assertIn(source, manifest["sources"])

            # Reuse the same three libraries: do not pay for a second module build.
            # The probe itself is a CLI, using only directories it creates here.
            # Unsigned CI may lack an app-scope key. Deterministic bookmarks are
            # explicit fixture inputs, never evidence of live bookmark behavior.
            probe = Path(temporary) / "CreationTimingProbe"
            compiled = subprocess.run([
                "xcrun", "swiftc", "-swift-version", "5", "-g", "-Onone", "-parse-as-library",
                "-I", temporary, "-L", temporary,
                "-lQuickFileCore", "-lQuickFileInfrastructure", "-lQuickFileApplication",
                "-Xlinker", "-rpath", "-Xlinker", temporary,
                str(ROOT / "Scripts/Investigations/CreationTimingProbe.swift"),
                str(ROOT / "Scripts/Investigations/CreationTimingProbeSample.swift"),
                "-o", str(probe),
            ], capture_output=True, text=True, timeout=90, cwd=ROOT)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            owned = Path(temporary) / "owned-probe-run"
            traces = Path(temporary) / "owned-traces"
            measured = subprocess.run([
                str(probe), "--output", str(owned), "--scope", "fixture", "--bookmarks", "owned-fixture",
                "--grants", "1", "--samples", "1",
            ], env=dict(os.environ, QUICKFILE_CREATION_TIMING_DIR=str(traces)),
                capture_output=True, text=True, timeout=30, cwd=ROOT)
            self.assertEqual(measured.returncode, 0, measured.stdout + measured.stderr)
            report = json.loads((owned / "measurements.json").read_text())
            self.assertEqual(report["scopeMode"], "fixture")
            self.assertEqual(report["bookmarkMode"], "owned-fixture")
            self.assertFalse(report["realBookmarkAPIs"])
            self.assertTrue(report["scopeStartInjected"])
            self.assertFalse(report["mainAppOrAppGroupAccess"])
            self.assertTrue(report["tracingEnabled"])
            self.assertEqual(report["traceEvidenceStatus"], "verified")
            self.assertNotIn("failedSample", report)
            self.assertNotIn("failedEvidenceSample", report)
            self.assertEqual(len(report["measurements"]), 1)
            sample = report["measurements"][0]
            self.assertEqual(sample["sample"], 0)
            self.assertTrue(sample["success"])
            self.assertGreater(sample["durationNS"], 0)
            self.assertEqual(sample["traceEvidence"], {
                "status": "verified", "expected": True, "valid": True, "droppedEvents": 0,
            })
            trace = json.loads((traces / f'{sample["traceID"]}.json').read_text())
            self.assertEqual(trace["id"], sample["traceID"])
            self.assertEqual(trace["kind"], "owned-fixture")
            self.assertEqual(trace["outcome"], "fixture-created-no-finder")
            self.assertEqual(trace["droppedEvents"], 0)
            phases = [event["phase"] for event in trace["events"]]
            self.assertEqual(phases[0], "begin")
            self.assertEqual(phases[-1], "end")
            self.assertIn("file.published", phases)
            self.assertIn("writer.end", phases)
            self.assertIn("authorization.scope.stopped", phases)
            self.assertEqual(len(list(traces.glob("*.json"))), 4)  # Three warmups plus one measured sample.
            self.assertEqual(list((owned / "owned-grant-0/Target").iterdir()), [])

            # A real output failure must not be reported as verified timing or as
            # a file-creation failure. Reuse the executable; no further compilation.
            blocked_trace = Path(temporary) / "trace-path-is-a-regular-file"
            blocked_trace.write_bytes(b"owned sentinel")
            failed_owned = Path(temporary) / "owned-probe-missing-evidence"
            failed = subprocess.run([
                str(probe), "--output", str(failed_owned), "--scope", "fixture", "--bookmarks", "owned-fixture",
                "--grants", "1", "--samples", "1",
            ], env=dict(os.environ, QUICKFILE_CREATION_TIMING_DIR=str(blocked_trace)),
                capture_output=True, text=True, timeout=30, cwd=ROOT)
            self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
            failure_report = json.loads((failed_owned / "measurements.json").read_text())
            self.assertEqual(failure_report["scopeMode"], "fixture")
            self.assertEqual(failure_report["bookmarkMode"], "owned-fixture")
            self.assertFalse(failure_report["realBookmarkAPIs"])
            self.assertTrue(failure_report["scopeStartInjected"])
            self.assertEqual(failure_report["traceEvidenceStatus"], "unavailable")
            self.assertNotIn("failedSample", failure_report)
            self.assertEqual(failure_report["measurements"], [])
            failure = failure_report["failedEvidenceSample"]
            self.assertEqual(failure["sample"], -3)
            self.assertTrue(failure["success"])
            self.assertFalse(failure["traceEvidence"]["valid"])
            self.assertEqual(blocked_trace.read_bytes(), b"owned sentinel")
            self.assertEqual(list((failed_owned / "owned-grant-0/Target").iterdir()), [])

            # Reject incompatible or unknown modes before creating any fixture
            # data, rather than silently falling back to live bookmark APIs.
            for index, (bookmark_mode, scope_mode) in enumerate([
                ("owned-fixture", "live"), ("unknown-mode", "fixture"),
            ]):
                with self.subTest(bookmark_mode=bookmark_mode, scope_mode=scope_mode):
                    invalid_owned = Path(temporary) / f"invalid-mode-{index}"
                    invalid_traces = Path(temporary) / f"invalid-traces-{index}"
                    rejected = subprocess.run([
                        str(probe), "--output", str(invalid_owned), "--scope", scope_mode,
                        "--bookmarks", bookmark_mode, "--grants", "1", "--samples", "1",
                    ], env=dict(os.environ, QUICKFILE_CREATION_TIMING_DIR=str(invalid_traces)),
                        capture_output=True, text=True, timeout=30, cwd=ROOT)
                    self.assertNotEqual(rejected.returncode, 0, rejected.stdout + rejected.stderr)
                    self.assertFalse(invalid_owned.exists())
                    self.assertFalse(invalid_traces.exists())


if __name__ == "__main__":
    unittest.main()
