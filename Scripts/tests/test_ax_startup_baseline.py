"""The startup precondition cannot absorb growth from measured target cycles."""
import copy
import contextlib
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Investigations"))
import ax_startup_baseline as startup
import test_ax_compatibility as compatibility
PROBE = compatibility.PROBE


SCAN_LABELS = ['baseline', 'registered-10', 'removed-10', 'removed-20', 'removed-30', 'observer-exited']


def registration_scan_classification(scans):
    """Separate a fully classified baseline increase from other strict failures."""
    try:
        baseline, registered = scans[:2]
        if [baseline['label'], registered['label']] != SCAN_LABELS[:2]:
            return 'invalid-scan'
        for row in (baseline, registered):
            if (type(row['exit_code']) is not int or row['exit_code'] not in (0, 1)
                    or row['destroyed_notification_stack_present'] is not False
                    or type(row['unclassified_nodes']) is not int
                    or any(type(row[key]) is not int or row[key] < 0 for key in ('leak_nodes', 'leak_bytes'))
                    or any(type(group['tree_nodes']) is not int or group['tree_nodes'] < 0
                           or type(group['root_instances']) is not int or group['root_instances'] < 1
                           for group in row['groups'])
                    or sum(group['tree_nodes'] for group in row['groups']) != row['leak_nodes']):
                return 'invalid-scan'
            PROBE.validate_product_scan(row)
        try:
            PROBE.validate_product_scan(registered, baseline)
        except RuntimeError:
            return 'classified-growth'
        return 'no-growth'
    except (KeyError, TypeError, ValueError, RuntimeError):
        return 'invalid-scan'


def check_negative_control(test, receipt, records, original, modified, return_code):
    compatibility.LIFECYCLE.receipt_fields(receipt, ('cleanup',))
    if type(receipt['cleanup']) is dict and receipt['cleanup'].get('primary_exception') is True:
        raise ValueError('AX receipt incomplete: runner aborted')
    compatibility.LIFECYCLE.receipt_fields(receipt, ('startup_baseline', 'coverage', 'scans',
        'destroyed_buttons', 'notifications', 'ordinary_compensations', 'mutable_compensations',
        'validation_errors'))
    # Emit only anonymous observations before any acceptance assertion, including
    # on failure. The runner's strict verdict stays failed for an injected leak.
    scans = receipt.get('scans', [])
    classification = registration_scan_classification(scans)
    labels = [row['stage'] for row in receipt.get('validation_errors', [])]
    safe_labels = {*SCAN_LABELS, 'execution', 'cleanup', 'notifications', 'compensation-branches'}
    number = lambda value: value if type(value) is int else None
    evidence = {'protocol': startup.PROTOCOL, 'removed_autoreleases': 2,
        'original_source_sha256': hashlib.sha256(original.encode()).hexdigest(),
        'negative_source_sha256': hashlib.sha256(modified).hexdigest(),
        'runner_return_code': return_code,
        'registration_scan_classification': classification,
        'strict_failure_labels': [label if label in safe_labels else 'other' for label in labels],
        'scans': [{'label': row.get('label') if row.get('label') in SCAN_LABELS else 'other',
                   **{key: number(row.get(key)) for key in ('exit_code', 'leak_nodes', 'leak_bytes', 'unclassified_nodes')},
                   'destroyed_notification_stack_present': row.get('destroyed_notification_stack_present') if type(row.get('destroyed_notification_stack_present')) is bool else None,
                   'root_instances': (sum(group['root_instances'] for group in row['groups'])
                                      if all(type(group.get('root_instances')) is int for group in row.get('groups', [])) and 'groups' in row else None),
                   'unexpected_root_present': any(group.get('root_type') != 'NSXPCConnection' for group in row.get('groups', []))}
                  for row in scans]}
    (records / 'negative-control.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps({'negative_control': evidence}), flush=True)

    test.assertEqual(return_code, 1)
    startup.validate(receipt['startup_baseline'])
    test.assertEqual(receipt['startup_baseline']['status'], 'observed-stable')
    test.assertEqual(receipt['coverage'], 'failed')
    for key, expected in (('destroyed_buttons', 30), ('notifications', 60),
                          ('ordinary_compensations', 30), ('mutable_compensations', 30)):
        test.assertEqual(receipt[key], expected)
    test.assertEqual([row['label'] for row in scans], SCAN_LABELS)
    test.assertIn(classification, ('no-growth', 'classified-growth'))
    test.assertTrue(all(row['exit_code'] in (0, 1) for row in scans))
    test.assertTrue(all(not row['destroyed_notification_stack_present'] for row in scans[:2]))
    test.assertTrue(all(row['destroyed_notification_stack_present'] for row in scans[2:]))
    test.assertTrue(all(row['leak_nodes'] > scans[0]['leak_nodes'] and row['leak_bytes'] > scans[0]['leak_bytes'] for row in scans[2:]))
    expected_labels = SCAN_LABELS[1:] if classification == 'classified-growth' else SCAN_LABELS[2:]
    test.assertEqual(labels, expected_labels)
    test.assertTrue(receipt['cleanup']['processes_exited'])
    test.assertEqual(receipt['cleanup']['errors'], [])
    test.assertTrue(all(receipt['cleanup'][role]['exited'] and not receipt['cleanup'][role]['errors'] for role in ('host', 'reader')))
    inputs = json.loads((records / 'inputs.json').read_text())
    test.assertEqual(inputs['sources']['QuickFileApp/AXCompatibility.m'], evidence['negative_source_sha256'])


def check_negative_control_result(test, result, records, original, modified):
    # Keep bounded raw diagnostics in test failures, outside the anonymous
    # negative-control summary. In particular, retain the runner traceback.
    tail = lambda stream: stream.encode('utf-8', errors='replace')[-8192:].decode('utf-8', errors='ignore')
    diagnostics = (f'AX negative-control runner exit code: {result.returncode}\n'
                   f'stdout:\n{tail(result.stdout)}\nstderr:\n{tail(result.stderr)}')
    test.assertEqual(result.returncode, 1, diagnostics)
    try:
        receipt = json.loads((records / 'result.json').read_text())
        check_negative_control(test, receipt, records, original, modified, result.returncode)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, AssertionError) as error:
        problem = ('AX receipt incomplete: result.json missing'
                   if isinstance(error, FileNotFoundError) and error.filename == str(records / 'result.json')
                   else f'AX receipt validation failed: {error}')
        raise test.failureException(f'{problem}\n{diagnostics}') from error


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires macOS SDK')
class StartupBaselineNativeNegativeControlTests(unittest.TestCase):
    def test_settled_baseline_rejects_real_uncompensated_ax_copies(self):
        temporary = compatibility.ROOT / '.build/Temporary'
        temporary.mkdir(parents=True, exist_ok=True)
        parent = Path(tempfile.gettempdir()).resolve()
        if not parent.is_relative_to(temporary): parent = temporary
        with tempfile.TemporaryDirectory(prefix='ax-startup-negative-', dir=parent) as directory:
            work = Path(directory)
            overlay = work / 'source'
            for name in PROBE.fixture_sources():
                target = overlay / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(compatibility.ROOT / name, target)
            source = overlay / 'QuickFileApp/AXCompatibility.m'
            original = source.read_text()
            self.assertEqual(original.count('[result autorelease];'), 2)
            # Reintroduce the verified ownership defect only in this isolated
            # build. Keep branch counters so a compensation-count assertion
            # cannot substitute for detecting the actual leaked AX copies.
            source.write_text(original.replace('[result autorelease];', '(void)result;'))
            records = compatibility.notification_records(work)
            records = records.with_name(records.name + '-negative-control')
            loader = '''import importlib.util, pathlib, sys
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location('negative_control_runner', pathlib.Path(sys.argv[1]) / 'verify-ax-compatibility.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.ROOT = pathlib.Path(sys.argv[2])
sys.argv = [str(spec.origin), *sys.argv[3:]]
raise SystemExit(runner.main())
'''
            result = subprocess.run([sys.executable, '-B', '-c', loader, str(compatibility.INVESTIGATIONS), str(overlay),
                '--work-directory', str(overlay / '.build/Temporary/fixture'), '--records-directory', str(records),
                '--settle-startup-baseline'], capture_output=True, text=True, timeout=300)
            if result.returncode == 77:
                compatibility.LIFECYCLE.record(records, 'negative-control', result.returncode)
                self.skipTest('AX negative control unavailable: ' + result.stdout.strip())
            check_negative_control_result(self, result, records, original, source.read_bytes())
            compatibility.LIFECYCLE.record(records, 'negative-control', result.returncode)


class NegativeControlReceiptTests(unittest.TestCase):
    def receipt(self):
        baseline, _ = StartupBaselineTests().exercise([288])
        scans = []
        for index, label in enumerate(SCAN_LABELS):
            growth = max(0, index - 1) * 10
            scans.append(compatibility.AXCompatibilityHeapValidationTests.scan(
                288 + growth, 18432 + growth * 64, ax=index >= 2)
                | {'label': label, 'exit_code': 1, 'host': {'private_path': '/private/secret'}})
        return {'startup_baseline': baseline, 'coverage': 'failed', 'scans': scans,
                'destroyed_buttons': 30, 'notifications': 60,
                'ordinary_compensations': 30, 'mutable_compensations': 30,
                'validation_errors': [{'stage': label, 'message': '/private/secret 0x1234'} for label in SCAN_LABELS[2:]],
                'cleanup': {'processes_exited': True, 'errors': [],
                            'host': {'exited': True, 'errors': []}, 'reader': {'exited': True, 'errors': []}}}

    @staticmethod
    def add_registration_growth(receipt, metric='leak_nodes'):
        row = receipt['scans'][1]
        if metric == 'root_instances':
            row['groups'][0]['root_instances'] += 1
        else:
            row[metric] += 1
            if metric == 'leak_nodes': row['groups'][0]['tree_nodes'] += 1
        receipt['validation_errors'].insert(0, {'stage': 'registered-10', 'message': '/private/secret growth'})

    def exercise(self, receipt, *, fails=False, return_code=1, wrong_source=False):
        with tempfile.TemporaryDirectory() as directory:
            records = Path(directory)
            digest = hashlib.sha256(b'negative').hexdigest()
            (records / 'inputs.json').write_text(json.dumps({'sources': {
                'QuickFileApp/AXCompatibility.m': '0' * 64 if wrong_source else digest}}))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                if fails:
                    with self.assertRaises(AssertionError):
                        check_negative_control(self, receipt, records, 'original', b'negative', return_code)
                else:
                    check_negative_control(self, receipt, records, 'original', b'negative', return_code)
            evidence = json.loads((records / 'negative-control.json').read_text())
            self.assertEqual(json.loads(output.getvalue()), {'negative_control': evidence})
            self.assertNotIn('secret', output.getvalue())
            self.assertNotIn('0x1234', output.getvalue())
            return evidence

    def test_accepts_four_required_failures_or_classified_registration_growth(self):
        receipt = self.receipt()
        self.assertEqual(self.exercise(receipt)['registration_scan_classification'], 'no-growth')
        for metric in ('leak_nodes', 'leak_bytes', 'root_instances'):
            with self.subTest(metric=metric):
                receipt = self.receipt()
                self.add_registration_growth(receipt, metric)
                evidence = self.exercise(receipt)
                self.assertEqual(evidence['registration_scan_classification'], 'classified-growth')
                self.assertEqual(evidence['strict_failure_labels'], SCAN_LABELS[1:])
                self.assertEqual(evidence['runner_return_code'], 1)

    def test_unclassified_unknown_and_unavailable_registration_remain_failures(self):
        mutations = [lambda row: row.update(unclassified_nodes=1),
                     lambda row: row['groups'][0].update(root_type='/private/secret'),
                     lambda row: row.update(destroyed_notification_stack_present=True),
                     lambda row: row.update(exit_code=2),
                     lambda row: row.update(leak_nodes=None),
                     lambda row: row['groups'][0].update(tree_nodes=None),
                     lambda row: row['groups'][0].update(root_instances=None),
                     lambda row: row['groups'][0].update(tree_nodes=0)]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                receipt = self.receipt()
                self.add_registration_growth(receipt)
                mutate(receipt['scans'][1])
                self.assertEqual(self.exercise(receipt, fails=True)['registration_scan_classification'], 'invalid-scan')

    def test_failure_labels_must_match_every_required_checkpoint_without_extras(self):
        expected = SCAN_LABELS[1:]
        invalid = [expected[:index] + expected[index + 1:] for index in range(1, 5)]
        invalid += [expected + [extra] for extra in ('cleanup', 'execution', 'baseline', '/private/secret')]
        invalid += [list(reversed(expected)), ['registered-10', *expected]]
        for labels in invalid:
            with self.subTest(labels=labels):
                receipt = self.receipt()
                self.add_registration_growth(receipt)
                receipt['validation_errors'] = [{'stage': label} for label in labels]
                self.exercise(receipt, fails=True)

    def test_registration_failure_and_actual_growth_must_agree(self):
        receipt = self.receipt()
        receipt['validation_errors'].insert(0, {'stage': 'registered-10'})
        self.exercise(receipt, fails=True)
        receipt = self.receipt()
        self.add_registration_growth(receipt)
        receipt['validation_errors'].pop(0)
        self.exercise(receipt, fails=True)

    def test_target_leak_detection_and_activity_checks_remain_required(self):
        for index in range(2, 6):
            for change in ({'destroyed_notification_stack_present': False}, {'leak_nodes': 288}, {'leak_bytes': 18432}):
                with self.subTest(index=index, change=change):
                    receipt = self.receipt()
                    receipt['scans'][index].update(change)
                    self.exercise(receipt, fails=True)
        for key in ('destroyed_buttons', 'notifications', 'ordinary_compensations', 'mutable_compensations'):
            receipt = self.receipt(); receipt[key] = 0
            self.exercise(receipt, fails=True)
        self.exercise(self.receipt(), fails=True, return_code=0)

    def test_cleanup_and_source_checks_remain_required_with_failure_evidence(self):
        mutations = [lambda value: value.update(processes_exited=False),
                     lambda value: value.update(errors=['private cleanup failure']),
                     lambda value: value['host'].update(exited=False),
                     lambda value: value['reader'].update(errors=['private cleanup failure'])]
        for mutate in mutations:
            receipt = self.receipt(); mutate(receipt['cleanup'])
            self.exercise(receipt, fails=True)
        self.exercise(self.receipt(), fails=True, wrong_source=True)


class NegativeControlRunnerResultTests(unittest.TestCase):
    def exercise(self, content, problem, *, return_code=1, stdout='runner stdout', stderr='runner traceback'):
        with tempfile.TemporaryDirectory() as directory:
            records = Path(directory)
            if content is not None:
                (records / 'result.json').write_text(content)
            result = subprocess.CompletedProcess([], return_code, stdout, stderr)
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(AssertionError) as failure:
                check_negative_control_result(self, result, records, 'original', b'negative')
            message = str(failure.exception)
            self.assertIn(problem, message)
            self.assertIn('stdout:\n', message)
            self.assertIn(stdout[-100:], message)
            self.assertIn('stderr:\n', message)
            self.assertIn(stderr[-100:], message)
            return message

    def test_missing_receipt_preserves_both_runner_streams(self):
        self.exercise(None, 'AX receipt incomplete: result.json missing')

    def test_aborted_receipt_is_reported_before_missing_activity(self):
        self.exercise(json.dumps({'coverage': 'failed', 'cleanup': {'primary_exception': True},
                                  'validation_errors': [{'stage': 'execution'}]}),
                      'AX receipt incomplete: runner aborted')

    def test_missing_activity_and_malformed_receipts_fail_with_diagnostics(self):
        receipt = NegativeControlReceiptTests().receipt()
        del receipt['destroyed_buttons']
        self.exercise(json.dumps(receipt), 'AX receipt incomplete: missing fields destroyed_buttons')
        for content in ('{', '[]', 'null', json.dumps({'cleanup': None}),
                        json.dumps(NegativeControlReceiptTests().receipt() | {'scans': None})):
            with self.subTest(content=content):
                self.exercise(content, 'AX receipt validation failed:')

    def test_execution_failure_is_not_replaced_by_missing_receipt(self):
        message = self.exercise(None, 'AX negative-control runner exit code: 2', return_code=2)
        self.assertNotIn('result.json missing', message)

    def test_runner_diagnostics_are_bounded_and_retain_traceback_tail(self):
        message = self.exercise(None, 'AX receipt incomplete: result.json missing',
            stdout='omitted stdout' + 'a' * 9000 + 'stdout tail',
            stderr='omitted stderr' + 'b' * 9000 + 'traceback tail')
        self.assertNotIn('omitted stdout', message)
        self.assertNotIn('omitted stderr', message)
        self.assertLess(len(message), 17 * 1024)
        message = self.exercise(None, 'AX receipt incomplete: result.json missing', stdout='界' * 9000, stderr='错' * 9000)
        self.assertLess(len(message.encode('utf-8')), 17 * 1024)

    def test_complete_negative_control_still_emits_only_anonymous_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            records = Path(directory)
            (records / 'result.json').write_text(json.dumps(NegativeControlReceiptTests().receipt()))
            (records / 'inputs.json').write_text(json.dumps({'sources': {
                'QuickFileApp/AXCompatibility.m': hashlib.sha256(b'negative').hexdigest()}}))
            output = io.StringIO()
            result = subprocess.CompletedProcess([], 1, 'private stdout', 'private stderr')
            with contextlib.redirect_stdout(output):
                check_negative_control_result(self, result, records, 'original', b'negative')
            evidence = json.loads((records / 'negative-control.json').read_text())
            self.assertEqual(json.loads(output.getvalue()), {'negative_control': evidence})
            self.assertNotIn('private', output.getvalue())
            self.assertNotIn('secret', output.getvalue())


class StartupBaselineTests(unittest.TestCase):
    def exercise(self, values, *, duration=1, error=None):
        clock = [0.0]
        receipt = startup.empty()
        saved = []
        def measure(index, deadline):
            self.assertLess(clock[0], deadline)
            clock[0] += duration
            if index == error:
                raise RuntimeError("invalid scan or nonzero target activity")
            nodes = values[min(index, len(values) - 1)]
            signature = hashlib.sha256(str(nodes).encode()).hexdigest()
            return {"leak_nodes": nodes, "leak_bytes": nodes * 64,
                    "groups": [{"root_instances": 3}], "startup_signature": signature,
                    "stdout_sha256": hashlib.sha256(str(index).encode()).hexdigest()}
        def sleep(seconds):
            clock[0] += seconds
        with mock.patch.object(startup.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(startup.time, "sleep", side_effect=sleep):
            try:
                chosen = startup.settle(measure, lambda value: saved.append(copy.deepcopy(value)), receipt)
            except RuntimeError:
                chosen = None
        startup.validate(receipt)
        self.assertEqual(receipt, saved[-1])
        return receipt, chosen

    def test_zero_target_ramp_is_preserved_before_stable_baseline(self):
        receipt, chosen = self.exercise([279, 286, 286])
        self.assertEqual(receipt["status"], "observed-stable")
        self.assertEqual(receipt["probes"][0]["leak_nodes"], 279)
        self.assertGreaterEqual(receipt["probes"][-1]["elapsed_ms"], 20000)
        self.assertEqual(chosen["leak_nodes"], 286)
        self.assertEqual(chosen["stdout_sha256"], receipt["probes"][-1]["stdout_sha256"])

    def test_stable_pair_does_not_finish_before_observation_window(self):
        receipt, chosen = self.exercise([192, 192, 192, 192, 192, 288, 288, 288])
        self.assertEqual(chosen["leak_nodes"], 288)
        self.assertEqual(receipt["selected_index"], 7)

    def test_never_uses_largest_startup_value_as_baseline(self):
        receipt, chosen = self.exercise([288, 286])
        self.assertEqual(chosen["leak_nodes"], 286)
        self.assertEqual(receipt["probes"][0]["leak_nodes"], 288)

    def test_continuing_growth_exhausts_probe_budget_without_baseline(self):
        receipt, chosen = self.exercise(list(range(12)))
        self.assertIsNone(chosen)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(len(receipt["probes"]), 12)

    def test_equal_scan_completing_after_deadline_is_not_accepted(self):
        receipt, chosen = self.exercise([286], duration=14)
        self.assertIsNone(chosen)
        self.assertEqual(receipt["status"], "failed")

    def test_bad_probe_aborts_without_retry_or_discarding_previous_probes(self):
        receipt, chosen = self.exercise([286], error=2)
        self.assertIsNone(chosen)
        self.assertEqual(len(receipt["probes"]), 2)
        self.assertEqual(receipt["status"], "failed")

    def test_formal_one_node_one_byte_or_one_root_growth_still_fails(self):
        scan = compatibility.AXCompatibilityHeapValidationTests.scan
        base = scan(286, 18624)
        for later in (scan(287, 18624), scan(286, 18625),
                      base | {"groups": [{"root_type": "NSXPCConnection", "root_instances": 2}]}):
            with self.subTest(later=later), self.assertRaises(RuntimeError):
                PROBE.validate_product_scan(later, base)

    def test_receipt_rejects_false_stability_or_private_fields(self):
        valid, _ = self.exercise([286])
        mutations = [lambda v: v.update(selected_index=0),
                     lambda v: v["probes"][-2].update(signature_sha256="a" * 64),
                     lambda v: v["probes"][-1].update(elapsed_ms=40000),
                     lambda v: v["probes"][0].update(path="private"),
                     lambda v: v["policy"].update(consecutive_equal=True)]
        for change in mutations:
            value = copy.deepcopy(valid)
            change(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                startup.validate(value)

    def test_fingerprint_requires_complete_counts_and_detects_composition_change(self):
        from ax_composition import empty_grouped, grouped_composition
        empty = {"leak_nodes": 0, "leak_bytes": 0, "groups": []}
        composition = grouped_composition("Process 1: 0 leaks for 0 total leaked bytes.\n")
        first = startup.fingerprint(empty, composition)
        changed = copy.deepcopy(composition)
        changed["type_counts"] = [{"type": "NSArray", "count": 1}]
        self.assertNotEqual(first, startup.fingerprint(empty, changed))
        with self.assertRaises(RuntimeError):
            startup.fingerprint(empty, empty_grouped('node_budget', (513, 32832)))

    def test_failed_fingerprint_reports_bounded_anonymous_parser_diagnostics(self):
        from ax_composition import encoded, grouped_composition, PUBLIC_LIMIT, validate_grouped_composition
        reports = [
            'Process 1: 513 leaks for 32832 total leaked bytes.\n',
            "Process 1: 1 leaks for 64 total leaked bytes.\n\n"
            "STACK OF 1 INSTANCE OF 'ROOT CYCLE: NSXPCConnection':\n"
            "0 private-image 0x1234 private_symbol + 0\n====\n"
            "    1 (64 bytes) ROOT CYCLE: NSXPCConnection\n"
            "       /private/secret-account 0x1234 unsupported-row\n",
        ]
        for report in reports:
            composition = grouped_composition(report)
            with self.subTest(reason=composition['reasons']), self.assertRaises(RuntimeError) as caught:
                startup.fingerprint({}, composition)
            published = str(caught.exception).split(': ', 1)[1]
            value = json.loads(published)
            validate_grouped_composition(value)
            self.assertEqual(value, composition)
            self.assertLessEqual(len(encoded(value)), PUBLIC_LIMIT)
            for secret in ('secret-account', 'private-image', 'private_symbol', '0x1234'):
                self.assertNotIn(secret, published)
            with self.assertRaises(ValueError):
                startup.fingerprint({}, composition | {'private_path': '/private/secret-account'})

    def test_new_protocol_refuses_other_investigation_modes_before_launch(self):
        import contextlib
        import io
        flags = ["--copy-lifetime", "--heap-control", "--system-baseline", "--settled-baseline-shadow",
                 "--heap-diagnostics", "--reference-validation", "--live-attribution", "--read-only"]
        base = ["probe", "--work-directory", "/unused", "--records-directory", "/unused-records",
                "--settle-startup-baseline"]
        for flag in flags:
            with self.subTest(flag=flag), mock.patch.object(sys, "argv", base + [flag]), \
                    mock.patch.object(PROBE.subprocess, "Popen") as launched, \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
                PROBE.main()
            self.assertEqual(failure.exception.code, 2)
            launched.assert_not_called()
