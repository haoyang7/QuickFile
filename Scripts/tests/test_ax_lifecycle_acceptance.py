import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import test_ax_compatibility as compatibility
import test_ax_startup_baseline as startup_tests

policy = compatibility.LIFECYCLE


def ordinary(growth=True):
    baseline, _ = startup_tests.StartupBaselineTests().exercise([288])
    scans = []
    for index, label in enumerate(policy.LABELS):
        nodes = 384 if growth and index else 288
        scans.append(compatibility.AXCompatibilityHeapValidationTests.scan(nodes, nodes * 64)
                     | {"label": label, "exit_code": 1})
    return {"startup_baseline": baseline, "coverage": "failed" if growth else "passed", "scans": scans,
            "destroyed_buttons": 30, "notifications": 60, "ordinary_compensations": 30, "mutable_compensations": 30,
            "notification_receipt": {"notifications": 60, "all_notifications": 60, "unmatched_notifications": 0,
                                     "tracked_buttons": 30, "target_notification_counts": [[1, 1] for _ in range(30)]},
            "validation_errors": [{"stage": label, "message": "/private/secret"} for label in policy.LABELS[1:]] if growth else [],
            "cleanup": {"primary_exception": False, "processes_exited": True, "errors": [],
                        **{role: {"started": True, "exited": True, "return_code": 0, "errors": []}
                           for role in ("host", "reader")}}}


def fixture(kind):
    receipt = ordinary()
    if kind == "negative-control":
        for row in receipt['scans'][2:]:
            row['destroyed_notification_stack_present'] = True
    elif kind == "copy-lifetime":
        receipt.update(coverage='passed', validation_errors=[], mode=kind, instrumented=True,
                       copy_lifetime=compatibility.AXCompatibilityCopyLifetimeTests.receipt(30)['copyLifetime'])
        receipt.pop('scans')
    return receipt


def public_unsupported(checkout="a" * 40):
    value = policy.empty(checkout)
    value['status'] = 'unsupported'
    value['components'] = {kind: {'policy': policy.POLICY, 'kind': kind, 'status': 'unsupported',
        'unsupported_reason': 'unsupported-images', 'runner_return_code': 77, 'original_verdict': 'unsupported',
        'scans': [], 'inputs_sha256': 'b' * 64, 'sources_sha256': 'c' * 64, 'result_sha256': None} for kind in policy.KINDS}
    return value


class LifecycleAcceptanceTests(unittest.TestCase):
    def test_native_caller_accepts_lifecycle_but_manual_strict_trial_still_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            records = Path(directory)
            receipt = ordinary(); receipt['ax_leak_nodes'] = None
            (records / 'result.json').write_text(json.dumps(receipt))
            result = SimpleNamespace(returncode=1, stdout='strict heap failure', stderr='')
            case = compatibility.AXCompatibilityCopyTests()
            with patch.object(compatibility, 'notification_records', return_value=records), \
                    patch.object(compatibility.subprocess, 'run', return_value=result), \
                    patch.object(policy, 'record') as record, contextlib.redirect_stdout(io.StringIO()):
                case.run_notifications_fixture()
                record.assert_called_once_with(records, 'ordinary', 1)
                record.reset_mock()
                with self.assertRaises(AssertionError): case.run_notifications_fixture(require_strict_heap=True)
                record.assert_not_called()

    def test_classified_growth_is_separate_from_unchanged_strict_failure(self):
        for growth in (False, True):
            receipt = ordinary(growth)
            original = copy.deepcopy(receipt)
            result = policy.evaluate('ordinary', receipt, int(growth))
            self.assertEqual(policy.growth_labels(result), policy.LABELS[1:] if growth else [])
            self.assertEqual(receipt, original)
            if growth:
                with self.assertRaises(RuntimeError):
                    compatibility.PROBE.validate_product_scan(receipt['scans'][1], receipt['scans'][0])

    def test_no_node_byte_or_root_growth_tolerance_is_introduced(self):
        for metric in ('leak_nodes', 'leak_bytes', 'root_instances'):
            receipt = ordinary(False)
            row = receipt['scans'][3]
            if metric == 'root_instances':
                row['groups'][0][metric] += 1
            else:
                row[metric] += 1
                if metric == 'leak_nodes': row['groups'][0]['tree_nodes'] += 1
            receipt.update(coverage='failed', validation_errors=[{'stage': row['label']}])
            values = policy.evaluate('ordinary', receipt, 1)
            self.assertEqual(policy.growth_labels(values), [row['label']])

    def test_known_leak_is_rejected_as_product_and_accepted_only_as_negative_control(self):
        receipt = fixture('negative-control')
        with self.assertRaises(ValueError): policy.evaluate('ordinary', receipt, 1)
        policy.evaluate('negative-control', receipt, 1)
        for index in range(2, 6):
            for field, value in (('destroyed_notification_stack_present', False), ('leak_nodes', 288), ('leak_bytes', 18432)):
                bad = copy.deepcopy(receipt); bad['scans'][index][field] = value
                with self.assertRaises((ValueError, RuntimeError)):
                    policy.evaluate('negative-control', bad, 1)

    def test_every_scan_rejects_target_unknown_unclassified_and_invalid_evidence(self):
        for index in range(6):
            for mutate in (
                lambda r: r.update(destroyed_notification_stack_present=True),
                lambda r: r.update(unclassified_nodes=1),
                lambda r: r['groups'][0].update(root_type='Unknown'),
                lambda r: r['groups'][0].update(tree_nodes=0),
                lambda r: r.update(exit_code=2), lambda r: r.update(leak_nodes=None),
                lambda r: r.update(leak_bytes=True),
            ):
                bad = ordinary(); mutate(bad['scans'][index])
                with self.subTest(index=index), self.assertRaises((ValueError, RuntimeError)):
                    policy.evaluate('ordinary', bad, 1)

    def test_non_growth_failures_bad_counts_cleanup_and_exit_are_not_waived(self):
        mutations = [lambda r: r['validation_errors'].append({'stage': 'execution'}),
                     lambda r: r['validation_errors'].append({'stage': 'registered-10'}),
                     lambda r: r['validation_errors'].pop(), lambda r: r['scans'].pop(),
                     lambda r: r.update(coverage='passed'), lambda r: r.update(destroyed_buttons=29),
                     lambda r: r.update(ordinary_compensations=0), lambda r: r.update(mutable_compensations=0),
                     lambda r: r['cleanup'].update(primary_exception=True),
                     lambda r: r['cleanup'].update(errors=['failed']),
                     lambda r: r['cleanup']['reader'].update(exited=False),
                     lambda r: r['cleanup']['host'].update(errors=['failed']),
                     lambda r: r['notification_receipt']['target_notification_counts'].__setitem__(0, [0, 2])]
        for mutate in mutations:
            bad = ordinary(); mutate(bad)
            with self.assertRaises((ValueError, RuntimeError)): policy.evaluate('ordinary', bad, 1)
        for code in (0, 77, 124, True):
            with self.assertRaises(ValueError): policy.evaluate('ordinary', ordinary(), code)


class LifecycleEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.records = Path(self.temporary.name).resolve() / 'records'

    def prepare(self, unsupported=False):
        for kind in policy.KINDS:
            directory = self.records if kind == 'ordinary' else self.records.with_name('records-' + kind)
            directory.mkdir()
            inputs = {'sources': policy.source_manifest(policy.ROOT, kind),
                      'baseline_protocol': compatibility.PROBE.ax_startup_baseline.PROTOCOL,
                      'capabilities': {'status': 'unsupported-images' if unsupported else 'enabled', 'enabled': not unsupported},
                      'reader_capabilities': {'trusted': True}}
            (directory / 'inputs.json').write_text(json.dumps(inputs))
            if not unsupported:
                receipt = fixture(kind)
                (directory / 'result.json').write_text(json.dumps(receipt))
                if kind == 'copy-lifetime':
                    hosts = [compatibility.AXCompatibilityCopyLifetimeTests.receipt(30 if i == 9 else 0) | {'sequence': i}
                             for i in range(10)]
                    (directory / 'copy-lifetime-hosts.json').write_text(json.dumps(hosts))
            code = 77 if unsupported else 0 if kind == 'copy-lifetime' else 1
            with contextlib.redirect_stdout(io.StringIO()): policy.record(directory, kind, code)
        row = json.loads((self.records / 'lifecycle-acceptance.json').read_text())
        self.original = {'inputs_sha256': row['inputs_sha256'], 'original_verdict': row['original_verdict'],
                         'status': 'unsupported' if unsupported else 'complete', 'unsupported_reason': row['unsupported_reason'],
                         'original_scans': [dict(scan, unclassified_nodes=0, destroyed_notification_stack_present=False,
                                                 unexpected_roots=False) for scan in row['scans']],
                         'strict_failure_labels': [] if unsupported else policy.LABELS[1:]}
        return self.collect()

    def collect(self):
        return policy.collect(self.records, 'a' * 40, self.original)

    def test_all_three_components_bind_source_and_preserve_dual_verdicts(self):
        value = self.prepare()
        self.assertEqual(value['status'], 'passed')
        self.assertEqual(value['growth_attribution'], 'unresolved')
        self.assertEqual(value['components']['ordinary']['original_verdict'], 'failed')
        self.assertNotIn('/private/secret', json.dumps(value))
        self.assertLess(len(json.dumps(value)), policy.LIMIT)
        for kind, row in value['components'].items():
            self.assertEqual(row['sources_sha256'], policy.manifest_hash(policy.source_manifest(policy.ROOT, kind)))

    def test_unsupported_is_explicit_for_all_three_components(self):
        value = self.prepare(unsupported=True)
        self.assertEqual(value['status'], 'unsupported')
        self.assertEqual(value['growth_attribution'], 'not-evaluated')
        self.assertTrue(all(row['status'] == 'unsupported' for row in value['components'].values()))

    def test_missing_or_changed_components_and_inputs_cannot_pass(self):
        self.prepare()
        for kind in policy.KINDS:
            directory = self.records if kind == 'ordinary' else self.records.with_name('records-' + kind)
            for name in ('lifecycle-acceptance.json', 'inputs.json', 'result.json'):
                target = directory / name
                raw = target.read_bytes(); target.unlink()
                with self.assertRaises(OSError): self.collect()
                target.write_bytes(raw)
                data = json.loads(raw)
                if name == 'inputs.json': data['sources']['QuickFileApp/AXCompatibility.m'] = '0' * 64
                elif name == 'result.json': data['notifications'] = 0
                else: data['runner_return_code'] = 124
                target.write_text(json.dumps(data))
                with self.assertRaises((ValueError, RuntimeError)): self.collect()
                target.write_bytes(raw)

    def test_copy_intermediate_weak_failure_blocks_even_if_final_is_clean(self):
        self.prepare()
        target = self.records.with_name('records-copy-lifetime') / 'copy-lifetime-hosts.json'
        hosts = json.loads(target.read_text()); hosts[3]['copyLifetime']['liveOrdinary'] = 1
        target.write_text(json.dumps(hosts))
        with self.assertRaises(RuntimeError): self.collect()

    def test_ordinary_public_evidence_must_agree_with_acceptance(self):
        self.prepare()
        for key, value in (('inputs_sha256', 'd' * 64), ('original_verdict', 'passed'),
                           ('status', 'partial'), ('strict_failure_labels', []), ('original_scans', [])):
            original = self.original; self.original = dict(original, **{key: value})
            with self.assertRaises(ValueError): self.collect()
            self.original = original

    def test_public_upload_gate_rejects_extra_fields_and_inconsistent_outcomes(self):
        value = self.prepare()
        for change in ({'extra': '/private/secret'}, {'policy': 'unknown'}, {'checkout_sha': 'short'},
                       {'status': 'unsupported'}, {'growth_attribution': 'safe'}):
            with self.assertRaises(ValueError): policy.validate_public(value | change)
        bad = copy.deepcopy(value); bad['components']['ordinary']['scans'][1]['extra'] = '/private/secret'
        with self.assertRaises(ValueError): policy.validate_public(bad)
        bad = copy.deepcopy(value); bad['components']['ordinary']['runner_return_code'] = 0
        with self.assertRaises(ValueError): policy.validate_public(bad)
        bad = copy.deepcopy(value); bad['components']['ordinary']['original_verdict'] = 'passed'
        with self.assertRaises(ValueError): policy.validate_public(bad)


if __name__ == '__main__':
    unittest.main()
