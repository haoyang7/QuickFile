"""Synthetic shadow receipts and bounded subprocess tests; no native AX sampling."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
INVESTIGATIONS = ROOT / 'Scripts/Investigations'
SPEC = importlib.util.spec_from_file_location('ax_shadow_campaign_target', INVESTIGATIONS / 'ax_shadow_campaign.py')
C = importlib.util.module_from_spec(SPEC)
with mock.patch.object(sys, 'path', [str(INVESTIGATIONS), *sys.path]): SPEC.loader.exec_module(C)
TEMPORARY = ROOT / '.build/Temporary/ax-shadow-campaign-unit'


def process(code=1, complete=True, status='completed'):
    return {'return_code': code, 'command_return_code': code if status == 'completed' else None, 'status': status,
        'cleanup': {'group_signal': 'sent', 'group_members_exited': complete, 'group_inspection': 'exited' if complete else 'running', 'leader_reaped': True, 'complete': complete}}


def report(nodes=2, size=96, kind='NSXPCConnection'):
    return f'{nodes} leaks for {size} total leaked bytes\nSTACK OF {nodes} INSTANCES OF \'ROOT LEAK: {kind}\':\n {nodes} ({size} bytes) ROOT LEAK:\n'


def raw_scan(label, text, **extras):
    nodes, size = map(int, C.re.search(r'(\d+) leaks for (\d+) total leaked bytes', text).groups())
    groups = C.leak_groups(text)
    return {'label': label, 'leak_nodes': nodes, 'leak_bytes': size, 'unclassified_nodes': nodes - sum(g['tree_nodes'] or 0 for g in groups),
        'destroyed_notification_stack_present': False, 'exit_code': 1, 'stdout_sha256': hashlib.sha256(text.encode()).hexdigest(), 'groups': groups, **extras}


def host(): return dict.fromkeys(C.HOST_KEYS, 0)
def reader(): return dict.fromkeys(C.READER_KEYS, 0) | {'target_notification_counts': []}


def manifest(mode):
    value = {'schema': 1 if mode == 'ordinary' else 2, 'build_mode': mode,
        'sources': dict.fromkeys(C.fixture_sources(mode), 'a' * 64), 'executables': {'host': 'b' * 64, 'reader': 'c' * 64}}
    if mode == 'pure-appkit':
        value['build_evidence'] = {'link_inputs': {'host': ['Scripts/tests/fixtures/AXCompatibilityNotifications.m'], 'reader': ['Scripts/tests/fixtures/AXCompatibilityReader.swift']},
                                  'production_ax_symbol_counts': {'host': 0, 'reader': 0}}
    return value


def initial():
    return {'schema': 3, 'identity': {'checkout_sha': 'a' * 40, 'macos': '26.0.1', 'os_build': '25A354', 'architecture': 'arm64',
        'xcode': '26.3', 'scan_mode': 'settled-baseline-shadow', 'history_mode': 'current-stacks'}, 'builds': {}, 'cases': [],
        'completed': False, 'strict_checks_passed': False, 'evidence_checks_passed': False, 'temporary_cleanup': 'not-run'}


def snapshot(nodes=3, size=48, kind='NSXPCConnection'):
    histogram = C.composition.histogram_nodes([{'type': kind, 'size': size} for _ in range(nodes)])
    return {'schema': 1, 'status': histogram['status'], 'leak_nodes': nodes, 'leak_bytes': nodes * size, 'root_count': nodes,
            'histogram': histogram, 'reasons': list(histogram['reasons'])}


class TemporaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): TEMPORARY.mkdir(parents=True, exist_ok=True)
    @classmethod
    def tearDownClass(cls): TEMPORARY.rmdir()
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=TEMPORARY)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.records = self.root / 'records'
        self.records.mkdir()
        self.hashes = manifest('ordinary')['executables']
    def save(self, name, value): (self.records / name).write_bytes(C.canonical(value))
    def fixture(self, *, failed=True, case='patched-product', capture_failure=False):
        rows = []
        for index, label in enumerate(C.LABELS):
            text = report(2 if index == 0 or not failed else 3, 96 if index == 0 or not failed else 144)
            row = raw_scan(label, text, host=host())
            rows.append(row)
            (self.records / (label + '-original.stdout.txt')).write_text(text)
        self.save('scans.json', rows)
        result = {'coverage': 'failed' if failed else 'passed', 'validation_errors': [{'stage': 'registered-10', 'message': 'private address 0xabc'}] if failed else [],
            'scans': [{k: v for k, v in row.items() if k != 'host'} for row in rows], 'settled_baseline_shadow': True, 'scan_mode': 'live',
            'mode': 'product' if case == 'patched-product' else 'heap-control', 'reader_mode': 'initial-query-only' if case == C.CASES[-1] else 'subscribed',
            **dict.fromkeys(C.ACTIVITY, 0)}
        self.save('result.json', result)
        self.save('process-cleanup.json', {'processes_exited': True})
        external = {'receipt_mode': 'external-startup', 'requested': 'off', 'executables': self.hashes, 'binary_reuse_verified': True}
        for role in ('host', 'reader'):
            external[role] = {'malloc_scribble': 'unset', 'path_matches': True, 'startup_executable_matches': True, 'alive_during_check': True, 'executable_sha256': self.hashes[role]}
        self.save('external-startup.json', external)
        probes = []
        for index in range(2):
            label, text = 'shadow-probe-' + str(index), report(3 if failed else 2, 144 if failed else 96)
            (self.records / (label + '.stdout.txt')).write_text(text)
            probes.append(raw_scan(label, text, index=index, host=host(), reader_warm=reader(), host_activity_zero=True,
                                  start_monotonic=101.0 + 2.1 * index, end_monotonic=101.1 + 2.1 * index))
        captures = []
        graphs = self.records / 'shadow'
        graphs.mkdir()
        for label, source, start, end in ((C.CAPTURES[0], rows[0], 100.01, 100.05), (C.CAPTURES[1], probes[1], 103.3, 103.5), (C.CAPTURES[2], rows[-1], 120., 121.)):
            data = label.encode()
            (graphs / (label + '.memgraph')).write_bytes(data)
            captures.append({'label': label, 'status': 'complete', 'graph_sha256': hashlib.sha256(data).hexdigest(), 'exit_code': 0,
                'graph_file': label + '.memgraph', 'graph_bytes': len(data), 'source_label': source['label'], 'source_stdout_sha256': source['stdout_sha256'],
                'leak_nodes': source['leak_nodes'], 'leak_bytes': source['leak_bytes'], 'groups': source['groups'], 'host_activity_zero': label != C.CAPTURES[2],
                'start_monotonic': start, 'end_monotonic': end})
        if capture_failure:
            captures[1].update(status='failed', graph_sha256=None)
        raw = {'schema': 2, 'settling_policy': C.POLICY, 'status': 'observed-stable', 'chosen_index': 1,
            'baseline_finished_monotonic': 100., 'settling_started_monotonic': 100.1, 'first_measurement_cycle_monotonic': 104., 'last_original_scan_finished_monotonic': 119.,
            'probes': probes, 'captures': captures, 'errors': ['capture_failed'] if capture_failure else [], 'environments': copy.deepcopy(C.ENVIRONMENT),
            'observer_query_policy': 'initial-query-only' if case == C.CASES[-1] else 'ordinary', 'timing_perturbed': True, 'original_parity': False,
            'logging_mode': 'compact', 'history_mode': 'current-stacks', 'original_strict_verdict': 'failed' if failed else 'passed',
            'candidate_hypothetical_verdict': 'unavailable' if capture_failure else 'passed'}
        self.save('settled-baseline-shadow.json', raw)
        return rows, result, raw
    def project(self, failed=True):
        measurement, _ = C.project_measurement(self.records, process(1 if failed else 0))
        shadow = C.project_shadow(self.records, measurement, process(1 if failed else 0), self.hashes, C.CASES[0])
        return measurement, shadow


class ProjectionTests(TemporaryTests):
    def test_candidate_never_overwrites_strict_and_two_roots_are_legal(self):
        self.fixture()
        measurement, shadow = self.project()
        self.assertEqual(shadow['original_strict_verdict'], 'failed')
        self.assertEqual(shadow['candidate_hypothetical_verdict'], 'passed')
        self.assertEqual(C.root_count(measurement['original_scans'][0]), 2)
        self.assertTrue(shadow['timing_evidence'])
        C.validate_shadow(shadow, measurement, process(), C.CASES[0])
    def test_source_binding_counts_environment_and_time_rejected(self):
        rows, result, raw = self.fixture()
        mutations = [lambda r: r['probes'][0].update(stdout_sha256='a' * 64),
            lambda r: r['probes'][0].update(leak_nodes=44), lambda r: r['captures'][0].update(source_stdout_sha256='a' * 64),
            lambda r: r['environments']['reader'].update(MallocStackLogging='1'),
            lambda r: r['environments']['host'].update(MallocStackLoggingNoCompact='unset'),
            lambda r: r['probes'][1].update(start_monotonic=102.),
            lambda r: r['probes'][1]['host'].update(buttons=1), lambda r: r['probes'][0]['reader_warm'].update(registrations=1),
            lambda r: r.update(chosen_index=0),
            lambda r: r.update(first_measurement_cycle_monotonic=102.)]
        for mutation in mutations:
            changed = copy.deepcopy(raw); mutation(changed)
            self.save('settled-baseline-shadow.json', changed)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): self.project()
        self.save('settled-baseline-shadow.json', raw)
        (self.records / 'baseline-original.stdout.txt').write_text(report(99, 999))
        with self.assertRaises(ValueError): self.project()
    def test_missing_capture_retains_original_six_and_hypothesis_unavailable(self):
        self.fixture(capture_failure=True)
        measurement, shadow = self.project()
        self.assertEqual(len(measurement['original_scans']), 6)
        self.assertEqual(shadow['candidate_hypothetical_verdict'], 'unavailable')
        self.assertEqual(shadow['original_strict_verdict'], 'failed')
    def test_baseline_classification_is_a_hard_failure(self):
        self.fixture()
        measurement, shadow = self.project()
        measurement['original_scans'][0]['groups'][0]['root_type'] = 'unknown'
        self.assertEqual(C.hypothetical(measurement, shadow), 'failed')
        measurement['original_scans'][0]['groups'][0]['root_type'] = 'NSXPCConnection'
        measurement['failure_counts']['notifications'] = 1
        self.assertEqual(C.hypothetical(measurement, shadow), 'failed')
    def test_private_names_map_to_fixed_unknown(self):
        text = report(kind='PrivateHostSecret')
        row = raw_scan('baseline', text)
        (self.records / 'baseline-original.stdout.txt').write_text(text)
        public = C.project_scan(row, self.records)
        self.assertEqual(public['groups'][0]['root_type'], 'unknown')
        self.assertNotIn('PrivateHostSecret', C.canonical(public).decode())
    def test_early_late_cannot_be_endpoint(self):
        self.fixture()
        measurement, shadow = self.project()
        late = shadow['captures'][-1]
        late.update(source_label='removed-30', source_stdout_sha256=measurement['original_scans'][-2]['stdout_sha256'], endpoint='earlier-scan')
        shadow['timing_evidence'] = False
        C.validate_shadow(shadow, measurement, process(), C.CASES[0])
        self.assertFalse(C.timing_complete(shadow))
    def test_null_markers_are_explicit_partial(self):
        _, _, raw = self.fixture()
        raw['last_original_scan_finished_monotonic'] = None
        self.save('settled-baseline-shadow.json', raw)
        _, shadow = self.project()
        self.assertFalse(shadow['timing_evidence'])
    def test_actual_process_return_is_bound(self):
        self.fixture(failed=False)
        measurement, shadow = self.project(failed=False)
        self.assertEqual(shadow['original_strict_verdict'], 'passed')
        with self.assertRaises(ValueError): C.validate_shadow(shadow, measurement, process(1), C.CASES[0])


    def test_classification_failed_poll_survives_without_candidate(self):
        _, _, raw = self.fixture()
        text = report(3, 144, 'PrivateUnknownRoot')
        label = 'shadow-probe-0'
        (self.records / (label + '.stdout.txt')).write_text(text)
        raw['probes'] = [raw_scan(label, text, index=0, host=host(), reader_warm=reader(), host_activity_zero=True,
                                  start_monotonic=101., end_monotonic=101.1)]
        raw.update(status='not_settled', chosen_index=None, errors=['settling_failed', 'not_settled'], candidate_hypothetical_verdict='unavailable')
        raw['captures'] = [row for row in raw['captures'] if row['label'] != C.CAPTURES[1]]
        self.save('settled-baseline-shadow.json', raw)
        measurement, shadow = self.project()
        self.assertEqual(len(measurement['original_scans']), 6)
        self.assertEqual(len(shadow['probes']), 1)
        self.assertEqual(shadow['probes'][0]['scan']['groups'][0]['root_type'], 'unknown')
        self.assertIsNone(shadow['chosen_index'])
        self.assertEqual(shadow['candidate_hypothetical_verdict'], 'unavailable')


    def test_candidate_timeout_after_probe_deadline_keeps_independent_window(self):
        _, _, raw = self.fixture()
        raw['captures'][0].update(start_monotonic=85., end_monotonic=100., status='failed', capture_status='timeout', graph_sha256=None)
        raw['baseline_finished_monotonic'] = 84.9
        raw['probes'][0].update(start_monotonic=108., end_monotonic=111.)
        raw['probes'][1].update(start_monotonic=113., end_monotonic=114.95)
        raw['captures'][1].update(start_monotonic=114.96, end_monotonic=115.11, status='failed', capture_status='timeout', graph_sha256=None)
        raw.update(errors=['capture_failed', 'capture_failed'], candidate_hypothetical_verdict='unavailable', first_measurement_cycle_monotonic=116.)
        self.save('settled-baseline-shadow.json', raw)
        measurement, shadow = self.project()
        self.assertEqual(len(measurement['original_scans']), 6)
        self.assertEqual(shadow['chosen_index'], 1)
        self.assertTrue(shadow['timing_evidence'])
        self.assertEqual(shadow['captures'][1]['capture_status'], 'timeout')
        self.assertGreater(shadow['captures'][1]['end_elapsed_ms'] - shadow['timing_markers']['settling_started'], 15000)
        C.validate_shadow(shadow, measurement, process(), C.CASES[0])

    def test_last_poll_after_deadline_does_not_become_stable_candidate(self):
        _, _, raw = self.fixture()
        raw['probes'][0].update(start_monotonic=108., end_monotonic=111.)
        raw['probes'][1].update(start_monotonic=113., end_monotonic=115.11)
        raw.update(status='not_settled', chosen_index=None, errors=['not_settled'], candidate_hypothetical_verdict='unavailable', first_measurement_cycle_monotonic=116.)
        raw['captures'] = [row for row in raw['captures'] if row['label'] != C.CAPTURES[1]]
        self.save('settled-baseline-shadow.json', raw)
        measurement, shadow = self.project()
        self.assertIsNone(shadow['chosen_index'])
        self.assertFalse(shadow['timing_evidence'])
        self.assertEqual(len(shadow['probes']), 2)
        self.assertEqual(len(measurement['original_scans']), 6)
        self.assertEqual(shadow['candidate_hypothetical_verdict'], 'unavailable')

    def test_failed_early_capture_keeps_unknown_host_activity(self):
        _, _, raw = self.fixture()
        raw['captures'][0].update(status='failed', capture_status='failed', graph_sha256=None, host_activity_zero=None)
        raw.update(errors=['capture_failed'], candidate_hypothetical_verdict='unavailable')
        self.save('settled-baseline-shadow.json', raw)
        _, shadow = self.project()
        self.assertIsNone(shadow['captures'][0]['host_activity_zero'])
        self.assertFalse(shadow['timing_evidence'])

    def test_successful_export_with_failed_graph_verification_preserves_status(self):
        _, _, raw = self.fixture()
        raw['captures'][1].update(status='failed', capture_status='complete', graph_sha256=None)
        raw.update(errors=['capture_failed'], candidate_hypothetical_verdict='unavailable')
        self.save('settled-baseline-shadow.json', raw)
        _, shadow = self.project()
        self.assertEqual(shadow['captures'][1]['status'], 'failed')
        self.assertEqual(shadow['captures'][1]['capture_status'], 'complete')
        self.assertFalse(shadow['captures'][1]['graph_binding_verified'])

    def test_fixed_projection_stage_reports_binding_environment_policy(self):
        _, _, raw = self.fixture()
        mutations = [('environment', lambda r: r['environments']['host'].update(MallocStackLogging='other')),
                     ('binding', lambda r: r['captures'][0].update(source_stdout_sha256='a' * 64)),
                     ('policy', lambda r: r.update(logging_mode='private-string'))]
        for reason, mutation in mutations:
            changed = copy.deepcopy(raw); mutation(changed)
            self.save('settled-baseline-shadow.json', changed)
            with self.assertRaises(C.ShadowProjectionError) as failure: self.project()
            self.assertEqual(failure.exception.reason, reason)
            self.assertNotIn('private-string', str(failure.exception))


    def test_probe_before_deadline_by_submillisecond_keeps_true_candidate(self):
        _, _, raw = self.fixture()
        raw['probes'][0].update(start_monotonic=108., end_monotonic=111.)
        raw['probes'][1].update(start_monotonic=113., end_monotonic=115.0996)
        raw['captures'][1].update(start_monotonic=115.0997, end_monotonic=115.1005, status='failed', capture_status='timeout', graph_sha256=None)
        raw.update(errors=['capture_failed'], candidate_hypothetical_verdict='unavailable', first_measurement_cycle_monotonic=116.)
        self.save('settled-baseline-shadow.json', raw)
        measurement, shadow = self.project()
        last = shadow['probes'][-1]
        self.assertEqual(last['end_elapsed_ms'] - shadow['timing_markers']['settling_started'], 15000)
        self.assertTrue(last['within_settling_deadline'])
        self.assertEqual(shadow['chosen_index'], 1)
        self.assertFalse(shadow['timing_evidence'])
        self.assertEqual(shadow['elapsed_time_resolution_ms'], 1)
        C.validate_shadow(shadow, measurement, process(), C.CASES[0])

    def test_probe_after_deadline_by_submillisecond_keeps_no_candidate(self):
        _, _, raw = self.fixture()
        raw['probes'][0].update(start_monotonic=108., end_monotonic=111.)
        raw['probes'][1].update(start_monotonic=113., end_monotonic=115.1004)
        raw['captures'] = [row for row in raw['captures'] if row['label'] != C.CAPTURES[1]]
        raw.update(status='not_settled', chosen_index=None, errors=['not_settled'], candidate_hypothetical_verdict='unavailable', first_measurement_cycle_monotonic=116.)
        self.save('settled-baseline-shadow.json', raw)
        measurement, shadow = self.project()
        last = shadow['probes'][-1]
        self.assertEqual(last['end_elapsed_ms'] - shadow['timing_markers']['settling_started'], 15000)
        self.assertFalse(last['within_settling_deadline'])
        self.assertIsNone(shadow['chosen_index'])
        self.assertFalse(shadow['timing_evidence'])
        C.validate_shadow(shadow, measurement, process(), C.CASES[0])

    def test_exact_deadline_bit_rejects_clear_public_time_conflicts(self):
        self.fixture()
        measurement, shadow = self.project()
        changed = copy.deepcopy(shadow)
        changed['probes'][0]['within_settling_deadline'] = False
        changed['timing_evidence'] = False
        with self.assertRaises(ValueError): C.validate_shadow(changed, measurement, process(), C.CASES[0])
        changed = copy.deepcopy(shadow)
        changed['probes'][-1]['end_elapsed_ms'] = changed['timing_markers']['settling_started'] + 15002
        changed['captures'][1]['start_elapsed_ms'] = changed['probes'][-1]['end_elapsed_ms']
        changed['captures'][1]['end_elapsed_ms'] = changed['captures'][1]['start_elapsed_ms']
        changed['timing_markers']['first_measurement_cycle'] = changed['captures'][1]['end_elapsed_ms']
        changed['timing_evidence'] = False
        with self.assertRaises(ValueError): C.validate_shadow(changed, measurement, process(), C.CASES[0])


    def test_independent_graph_windows_leave_probe_budget_unchanged(self):
        _, _, raw = self.fixture()
        raw['captures'][0].update(start_monotonic=100.01, end_monotonic=114.9)
        raw['settling_started_monotonic'] = 115.
        raw['probes'][0].update(start_monotonic=116., end_monotonic=119.)
        raw['probes'][1].update(start_monotonic=121., end_monotonic=123.8)
        raw['captures'][1].update(start_monotonic=124., end_monotonic=139.1)
        raw.update(first_measurement_cycle_monotonic=140., last_original_scan_finished_monotonic=150.)
        raw['captures'][2].update(start_monotonic=151., end_monotonic=166.1)
        self.save('settled-baseline-shadow.json', raw)
        measurement, shadow = self.project()
        self.assertEqual(shadow['schema'], 2)
        self.assertEqual(shadow['settling_policy']['graph_capture_timeout_seconds'], 15)
        self.assertEqual(shadow['settling_policy']['deadline_seconds'], 15)
        self.assertEqual(shadow['settling_policy']['tool_timeout_seconds'], 5)
        self.assertTrue(shadow['timing_evidence'])
        self.assertEqual(shadow['chosen_index'], 1)
        self.assertGreater(shadow['captures'][1]['end_elapsed_ms'] - shadow['timing_markers']['settling_started'], 15000)
        # Graph metadata/hash work is included in the window; it is not a tool-runtime receipt.
        self.assertGreater(shadow['captures'][1]['end_elapsed_ms'] - shadow['captures'][1]['start_elapsed_ms'], 15000)
        self.assertEqual(shadow['original_strict_verdict'], 'failed')
        self.assertEqual(shadow['candidate_hypothetical_verdict'], 'passed')
        C.validate_shadow(shadow, measurement, process(), C.CASES[0])

    def test_independent_graph_timeout_remains_failed_evidence(self):
        _, _, raw = self.fixture()
        raw['captures'][1].update(start_monotonic=103.3, end_monotonic=118.4, status='failed', capture_status='timeout', graph_sha256=None)
        raw.update(first_measurement_cycle_monotonic=119., last_original_scan_finished_monotonic=120., errors=['capture_failed'], candidate_hypothetical_verdict='unavailable')
        raw['captures'][2].update(start_monotonic=121., end_monotonic=136.1)
        self.save('settled-baseline-shadow.json', raw)
        measurement, shadow = self.project()
        self.assertTrue(shadow['timing_evidence'])
        self.assertEqual(shadow['captures'][1]['capture_status'], 'timeout')
        self.assertFalse(C.evidence_passed({'shadow': shadow, 'offline': None, 'offline_process_run': process(0)}))
        self.assertEqual(len(measurement['original_scans']), 6)
        self.assertEqual(shadow['original_strict_verdict'], 'failed')


class HistogramTests(TemporaryTests):
    def test_signed_replacements_do_not_disappear_at_zero_net(self):
        before = snapshot(2, 48, 'NSXPCConnection')
        after = snapshot(2, 48, 'NSXPCInterface')
        delta = C.histogram_diff(before, after)
        self.assertEqual((delta['net_nodes'], delta['net_bytes']), (0, 0))
        self.assertEqual([row['count_delta'] for row in delta['changes']], [-2, 2])
        self.assertEqual(delta['generation'], 'unknown')
    def test_unknown_buckets_comparable_and_quota_partial_unavailable(self):
        unknown = snapshot(2, 48, 'private-name')
        self.assertEqual(unknown['histogram']['buckets'][0]['type'], 'unknown')
        delta = C.histogram_diff(snapshot(2), unknown)
        self.assertEqual(delta['status'], 'complete')
        self.assertEqual(delta['type_coverage'], 'includes-unknown')
        self.assertEqual(delta['net_nodes'], 0)
        self.assertEqual([r['count_delta'] for r in delta['changes']], [-2, 2])
        self.assertEqual(C.histogram_diff(snapshot(), snapshot(513))['status'], 'unavailable')
        self.assertEqual(C.histogram_diff(None, snapshot())['status'], 'unavailable')
    def test_worker_maximum_six_tools_45_second_deadline(self):
        self.fixture()
        deadlines = []
        class Tools:
            def __init__(self, directory, summary, deadline): self.summary = summary; deadlines.append(deadline)
            def run(self, kind, label, command, allowed):
                self.summary['tools'].append({'tool': kind, 'label': label, 'status': 'complete', 'return_code': 0, 'cleanup_confirmed': True})
                return label
        def parse(listing, tree): return snapshot(2 if listing == C.CAPTURES[0] else 3)
        with mock.patch.object(C.frozen, 'Tools', Tools), mock.patch.object(C.composition, 'histogram_snapshot', side_effect=parse), mock.patch.object(C.time, 'monotonic', return_value=100):
            self.assertEqual(C.offline_worker(self.records, self.root / 'worker'), 0)
        value = C.read_json(self.records / 'shadow-offline.json')
        measurement, shadow = self.project()
        C.validate_offline(value, shadow, measurement)
        self.assertEqual(len(value['tools']), 6)
        self.assertEqual(deadlines, [145])
        self.assertEqual(value['diffs']['candidate_to_late']['net_nodes'], 0)
        value['diffs']['initial_to_late']['net_nodes'] = 0
        with self.assertRaises(ValueError): C.validate_offline(value, shadow, measurement)
    def test_worker_timeout_stops_when_exit_unconfirmed(self):
        self.fixture()
        def fail(*args): raise C.frozen.ExitUnconfirmed()
        with mock.patch.object(C.frozen.Tools, 'run', side_effect=fail) as tools:
            self.assertEqual(C.offline_worker(self.records, self.root / 'worker'), 1)
        self.assertEqual(tools.call_count, 1)
        self.assertFalse(C.read_json(self.records / 'shadow-offline.json')['process_cleanup_confirmed'])
    def test_graph_hash_change_rejects_snapshot_and_keeps_prior(self):
        self.fixture()
        def tools(kind, label, command, allowed):
            if label == C.CAPTURES[1]: Path(command[-1]).write_bytes(b'changed')
            return label
        with mock.patch.object(C.frozen.Tools, 'run', side_effect=tools), mock.patch.object(C.composition, 'histogram_snapshot', side_effect=lambda a, b: snapshot(2 if a == C.CAPTURES[0] else 3)):
            self.assertEqual(C.offline_worker(self.records, self.root / 'worker'), 0)
        value = C.read_json(self.records / 'shadow-offline.json')
        self.assertEqual([row['label'] for row in value['snapshots']], [C.CAPTURES[0], C.CAPTURES[2]])
        self.assertEqual(value['diffs']['candidate_to_late']['status'], 'unavailable')


class PublicTests(TemporaryTests):
    def test_strict_false_with_successful_evidence_remains_false(self):
        self.fixture()
        measurement, shadow = self.project()
        value = initial()
        for name in C.CASES:
            sh = copy.deepcopy(shadow)
            sh['observer_query_policy'] = 'initial-query-only' if name == C.CASES[-1] else 'ordinary'
            offline = C.offline_initial()
            for label in C.CAPTURES:
                offline['snapshots'].append({'label': label, 'graph_sha256': next(r['graph_sha256'] for r in sh['captures'] if r['label'] == label),
                    'snapshot': snapshot(2 if label == C.CAPTURES[0] else 3), 'counts_binding': 'totals-match'})
                for tool in ('list', 'tree'): offline['tools'].append({'tool': tool, 'label': label, 'status': 'complete', 'return_code': 0, 'cleanup_confirmed': True})
            offline['diffs'] = {'initial_to_late': C.histogram_diff(snapshot(2), snapshot(3)), 'candidate_to_late': C.histogram_diff(snapshot(3), snapshot(3))}
            value['cases'].append({'name': name, 'process_run': process(), 'measurement': copy.deepcopy(measurement), 'shadow': sh, 'shadow_projection_reason': 'none',
                'offline_process_run': process(0), 'offline': offline, 'offline_cleanup': {key: offline[key] for key in ('tools', 'process_cleanup_confirmed')}, 'fixture_cleanup_confirmed': True, 'strict_checks_passed': False, 'evidence_checks_passed': True, 'cleanup_confirmed': True})
        value.update(completed=True, evidence_checks_passed=True)
        C.validate_summary(value)
        self.assertFalse(value['strict_checks_passed'])
        changed = copy.deepcopy(value); changed['strict_checks_passed'] = True
        with self.assertRaises(ValueError): C.validate_summary(changed)
        changed = copy.deepcopy(value); changed['cases'][0]['offline']['diffs']['initial_to_late']['changes'][0]['count_delta'] = 9
        with self.assertRaises(ValueError): C.validate_summary(changed)
        encoded = C.encode_summary(value)
        for token in ('0xabc', 'PrivateHostSecret', 'start_monotonic', '/Users/', 'message', 'graph_file', 'pid'):
            self.assertNotIn(token.encode(), encoded)
        self.assertLess(len(encoded), C.PUBLIC_LIMIT)
    def test_independent_canonical_validator_and_oversize_duplicates_links(self):
        public = self.root / 'summary.json'
        C.save_summary(public, initial())
        self.assertEqual(C.main(['--validate-public', '--work-directory', str(self.root)]), 0)
        public.write_bytes(json.dumps(initial()).encode())
        with self.assertRaises(ValueError): C.main(['--validate-public', '--work-directory', str(self.root)])
        public.write_text('{"schema":1,"schema":1}')
        with self.assertRaises(ValueError): C.read_json(public)
        public.write_bytes(b' ' * (C.PUBLIC_LIMIT + 1))
        with self.assertRaises(ValueError): C.read_json(public)
        public.unlink(); original = self.root / 'real.json'; original.write_bytes(C.canonical(initial()))
        public.symlink_to(original)
        with self.assertRaises(ValueError): C.main(['--validate-public', '--work-directory', str(self.root)])
        public.unlink(); os.link(original, public)
        with self.assertRaises(ValueError): C.read_json(public)
    def test_previous_campaign_schema_is_rejected(self):
        for schema in (1, 2):
            value = initial(); value['schema'] = schema
            with self.subTest(schema=schema), self.assertRaises(ValueError): C.validate_summary(value)

    def test_unknown_fields_wrong_numbers_and_privacy_strings_rejected(self):
        for mutate in (lambda v: v.update(message='private'), lambda v: v.update(schema=True), lambda v: v['identity'].update(checkout_sha='secret'), lambda v: v['identity'].update(history_mode='full-no-compact')):
            value = initial(); mutate(value)
            with self.assertRaises(ValueError): C.validate_summary(value)
    def test_workflow_only_uploads_canonical_summary_after_independent_gate(self):
        text = (ROOT / '.github/workflows/ax-settled-baseline-shadow.yml').read_text()
        self.assertIn('permissions:\n  contents: read', text)
        self.assertIn('timeout-minutes: 40', text)
        self.assertIn('--validate-public', text)
        self.assertIn("if: always() && steps.public-evidence.outputs.safe == 'true'", text)
        self.assertIn('path: .build/Temporary/ax-settled-baseline-shadow/campaign/summary.json', text)
        self.assertEqual(text.count('uses: actions/upload-artifact'), 1)
        self.assertNotIn('path: .build/Temporary/ax-settled-baseline-shadow/campaign\n', text)
        self.assertIn('persist-credentials: false', text)


    def test_router_and_mutually_exclusive_workflow_guard(self):
        text = (ROOT / '.github/workflows/ax-settled-baseline-shadow.yml').read_text()
        start = text.index("          import json, os", text.index('Reject mixed investigation requests'))
        stop = text.index('          PY', start)
        source = '\n'.join(line[10:] for line in text[start:stop].splitlines())
        flags = ('ax_causal_probe', 'heap_diagnostics', 'malloc_scribble', 'terminal_origin',
                 'live_attribution', 'install_gate_control', 'pure_appkit_control', 'frozen_control', 'reference_validation', 'reader_exit_control', 'scan_timing_control')
        defaults = dict.fromkeys(flags, False) | {'settled_baseline_shadow': True, 'scan_mode': 'diagnostic', 'receipt_mode': 'internal'}
        for inputs in ({}, defaults):
            with mock.patch.dict(os.environ, {'AX_SHADOW_INPUTS': json.dumps(inputs)}): exec(compile(source, '<workflow-guard>', 'exec'), {})
        invalid = [defaults | {key: True} for key in flags]
        invalid += [defaults | {key: wrong} for key in (*flags, 'settled_baseline_shadow') for wrong in (0, 1, None, 'false')]
        invalid += [defaults | {'scan_mode': 'live'}, defaults | {'receipt_mode': 'external-startup'}, defaults | {'private': True}, []]
        for inputs in invalid:
            with self.subTest(inputs=inputs), mock.patch.dict(os.environ, {'AX_SHADOW_INPUTS': json.dumps(inputs)}), self.assertRaises(AssertionError):
                exec(compile(source, '<workflow-guard>', 'exec'), {})
        router = (ROOT / '.github/workflows/ax-system-baseline.yml').read_text()
        for job in ('ax-system-probe:', 'ax-heap-diagnostics:'):
            condition = router.split(job, 1)[1].splitlines()[1]
            self.assertIn('!inputs.settled_baseline_shadow', condition)
        shadow_job = router.split('  ax-settled-baseline-shadow:', 1)[1]
        self.assertIn('if: ${{ inputs.settled_baseline_shadow }}', shadow_job)
        self.assertIn('uses: ./.github/workflows/ax-settled-baseline-shadow.yml', shadow_job)
        self.assertIn('dispatch_inputs: ${{ toJSON(inputs) }}', shadow_job)

    def test_graph_failure_keeps_probes_and_original_measurements(self):
        self.fixture()
        (self.records / 'shadow' / (C.CAPTURES[1] + '.memgraph')).unlink()
        measurement, shadow = self.project()
        self.assertEqual(len(measurement['original_scans']), 6)
        self.assertEqual(len(shadow['probes']), 2)
        self.assertFalse(shadow['captures'][1]['graph_binding_verified'])

    def test_graph_and_raw_report_limits(self):
        large = self.root / 'oversize'
        with large.open('wb') as stream: stream.truncate(C.GRAPH_LIMIT + 1)
        with self.assertRaises(ValueError): C.file_hash(large, C.GRAPH_LIMIT)
        with large.open('wb') as stream: stream.truncate(C.RAW_LIMIT + 1)
        with self.assertRaises(ValueError): C.read_bytes(large, C.RAW_LIMIT)

    def test_partial_histogram_is_retained_without_diff(self):
        self.fixture()
        measurement, shadow = self.project()
        offline = C.offline_initial()
        partial = snapshot(513)
        source = shadow['probes'][1]['scan']
        source.update(leak_nodes=513, leak_bytes=513 * 48)
        source['groups'][0].update(tree_nodes=513, root_instances=513)
        shadow['probes'][0]['scan'] = copy.deepcopy(source)
        shadow['probes'][0]['scan']['label'] = 'shadow-probe-0'

        offline['snapshots'] = [{'label': C.CAPTURES[1], 'graph_sha256': shadow['captures'][1]['graph_sha256'], 'snapshot': partial, 'counts_binding': 'totals-match'}]
        offline['tools'] = [{'tool': tool, 'label': C.CAPTURES[1], 'status': 'complete', 'return_code': 0, 'cleanup_confirmed': True} for tool in ('list', 'tree')]
        C.validate_offline(offline, shadow, measurement)
        self.assertEqual(offline['snapshots'][0]['snapshot']['status'], 'partial')
        self.assertEqual(offline['diffs']['candidate_to_late']['status'], 'unavailable')


class CampaignTests(TemporaryTests):
    def test_publication_failure_retains_private_evidence_and_prior_summary(self):
        original_encode, original_save = C.encode_summary, C.save_summary
        parent = self.root
        for failure in ('case-budget', 'final-budget', 'write'):
            with self.subTest(failure=failure):
                self.root = parent / failure
                def encode(value):
                    if ((failure == 'case-budget' and len(value['cases']) == 4)
                            or (failure == 'final-budget' and value['temporary_cleanup'] == 'complete')):
                        with mock.patch.object(C, 'PUBLIC_LIMIT', 1):
                            return original_encode(value)
                    return original_encode(value)
                def save(path, value):
                    if failure == 'write' and value['completed']:
                        raise OSError('synthetic private publication failure')
                    return original_save(path, value)
                code = None
                with mock.patch.object(C, 'encode_summary', side_effect=encode), \
                        mock.patch.object(C, 'save_summary', side_effect=save), \
                        contextlib.redirect_stderr(io.StringIO()):
                    try:
                        code, _, _ = self.run_campaign()
                    except (ValueError, OSError):
                        pass
                private = self.root / 'campaign/private'
                self.assertTrue(private.is_dir())
                self.assertTrue(any(private.rglob('process-cleanup.json')))
                self.assertEqual(code, 1)
                value = C.read_json(self.root / 'campaign/summary.json')
                self.assertNotEqual(value['temporary_cleanup'], 'complete')
                self.assertFalse(value['strict_checks_passed'])
                self.assertEqual(len(value['cases']), 3 if failure == 'case-budget' else 4)

    def run_campaign(self, *, cleanup=True, missing_capture=False, tool_cleanup=True, corrupt_evidence=False, strict_failed=True, cleanup_failure=False, shadow_failure=False):
        calls = []
        def owned(command, log, env, timeout):
            calls.append((command, timeout))
            if '--prepare-external-fixture' in command: return process(0)
            if '--offline' in command:
                records = Path(command[command.index('--records') + 1])
                measurement = C.read_json(records / 'projected-measurement.json')
                shadow = C.read_json(records / 'projected-shadow.json')
                value = C.offline_initial(); value['process_cleanup_confirmed'] = tool_cleanup
                for cap in ([] if shadow_failure else shadow['captures']):
                    if cap['status'] != 'complete': continue
                    label = cap['label']; source = next(r for r in measurement['original_scans'] + [p['scan'] for p in shadow['probes']] if r['label'] == cap['source_label'])
                    value['snapshots'].append({'label': label, 'graph_sha256': cap['graph_sha256'], 'snapshot': snapshot(source['leak_nodes']), 'counts_binding': 'totals-match'})
                    for tool in ('list', 'tree'): value['tools'].append({'tool': tool, 'label': label, 'status': 'complete', 'return_code': 0, 'cleanup_confirmed': True})
                points = {r['label']: r['snapshot'] for r in value['snapshots']}
                value['diffs'] = {'initial_to_late': C.histogram_diff(points.get(C.CAPTURES[0]), points.get(C.CAPTURES[2])), 'candidate_to_late': C.histogram_diff(points.get(C.CAPTURES[1]), points.get(C.CAPTURES[2]))}
                if corrupt_evidence: value['diffs']['initial_to_late']['net_nodes'] = 999
                (records / 'shadow-offline.json').write_bytes(C.canonical(value))
                return process(0)
            records = Path(command[command.index('--records-directory') + 1]); records.mkdir(parents=True)
            old = self.records; self.records = records
            name = records.parent.name
            self.fixture(case=name, capture_failure=missing_capture, failed=strict_failed)
            measurement, _ = C.project_measurement(records, process(1 if strict_failed else 0))
            shadow = C.project_shadow(records, measurement, process(1 if strict_failed else 0), self.hashes, name)
            self.save('projected-measurement.json', measurement); self.save('projected-shadow.json', shadow)
            if shadow_failure:
                raw = C.read_json(records / 'settled-baseline-shadow.json')
                raw['environments']['host']['MallocStackLogging'] = 'other'
                self.save('settled-baseline-shadow.json', raw)
            self.records = old
            return process(1 if strict_failed else 0, complete=cleanup)
        with mock.patch.object(C, 'identity', return_value=initial()['identity']), mock.patch.object(C, 'run_owned', side_effect=owned), \
                mock.patch.object(C, 'load_prepared_build', side_effect=lambda directory, sources, mode: manifest(mode)), contextlib.redirect_stdout(io.StringIO()), contextlib.ExitStack() as stack:
            if cleanup_failure: stack.enter_context(mock.patch.object(C.shutil, 'rmtree', side_effect=OSError('controlled cleanup failure')))
            code = C.main(['--work-directory', str(self.root / 'campaign')])
        return code, C.read_json(self.root / 'campaign/summary.json'), calls
    def test_four_cases_reuse_two_builds_red_strict_cleanup_complete(self):
        code, value, calls = self.run_campaign()
        self.assertEqual(code, 1)
        self.assertTrue(value['completed'] and value['evidence_checks_passed'])
        self.assertFalse(value['strict_checks_passed'])
        self.assertEqual([r['name'] for r in value['cases']], list(C.CASES))
        self.assertEqual(sum('--prepare-external-fixture' in command for command, _ in calls), 2)
        self.assertEqual([timeout for command, timeout in calls if '--settled-baseline-shadow' in command], [330] * 4)
        self.assertEqual([timeout for command, timeout in calls if '--offline' in command], [60] * 4)
        self.assertEqual(value['temporary_cleanup'], 'complete')
        self.assertFalse((self.root / 'campaign/private').exists())
    def test_owned_exit_unconfirmed_stops_and_retains_private(self):
        code, value, calls = self.run_campaign(cleanup=False)
        self.assertEqual(len(value['cases']), 1)
        self.assertFalse(any('--offline' in command for command, _ in calls))
        self.assertEqual(value['temporary_cleanup'], 'retained-unconfirmed')
        self.assertTrue((self.root / 'campaign/private').is_dir())
    def test_tool_exit_unconfirmed_stops_later_cases(self):
        _, value, _ = self.run_campaign(tool_cleanup=False)
        self.assertEqual(len(value['cases']), 1)
        self.assertEqual(value['temporary_cleanup'], 'retained-unconfirmed')
    def test_capture_failure_does_not_drop_originals_or_abort_exited_cases(self):
        _, value, _ = self.run_campaign(missing_capture=True)
        self.assertTrue(value['completed'])
        self.assertFalse(value['evidence_checks_passed'])
        self.assertTrue(all(len(case['measurement']['original_scans']) == 6 for case in value['cases']))
        self.assertTrue(all(len(case['offline']['snapshots']) == 2 for case in value['cases']))


    def test_bad_evidence_preserves_confirmed_cleanup_and_continues(self):
        code, value, _ = self.run_campaign(corrupt_evidence=True)
        self.assertEqual(code, 1)
        self.assertTrue(value['completed'])
        self.assertEqual(value['temporary_cleanup'], 'complete')
        for case in value['cases']:
            self.assertTrue(case['cleanup_confirmed'])
            self.assertIsNotNone(case['offline_cleanup'])
            self.assertIsNone(case['offline'])
            self.assertFalse(case['evidence_checks_passed'])
            self.assertEqual(len(case['measurement']['original_scans']), 6)

    def test_missing_shadow_with_empty_offline_keeps_measurement_and_continues(self):
        code, value, calls = self.run_campaign(shadow_failure=True)
        self.assertEqual(code, 1)
        self.assertTrue(value['completed'])
        self.assertEqual(value['temporary_cleanup'], 'complete')
        self.assertEqual(sum('--offline' in command for command, _ in calls), 4)
        for case in value['cases']:
            self.assertIsNone(case['shadow'])
            self.assertEqual(case['shadow_projection_reason'], 'environment')
            self.assertIsNone(case['offline'])
            self.assertEqual(case['offline_cleanup'], {'process_cleanup_confirmed': True, 'tools': []})
            self.assertEqual(len(case['measurement']['original_scans']), 6)
            self.assertTrue(case['cleanup_confirmed'])
            self.assertFalse(case['evidence_checks_passed'])
        C.validate_summary(value)

    def test_final_cleanup_failure_returns_nonzero_with_verdicts_preserved(self):
        code, value, _ = self.run_campaign(strict_failed=False, cleanup_failure=True)
        self.assertEqual(code, 1)
        self.assertTrue(value['strict_checks_passed'] and value['evidence_checks_passed'])
        self.assertEqual(value['temporary_cleanup'], 'failed')
        self.assertTrue((self.root / 'campaign/private').exists())

    def test_worker_cleanup_receipt_is_an_independent_fixed_allowlist(self):
        value = {'process_cleanup_confirmed': True, 'tools': []}
        C.validate_worker_cleanup(value)
        for changed in (value | {'raw': 'private'}, value | {'process_cleanup_confirmed': 1},
                        value | {'tools': [{'tool': 'list', 'label': 'secret', 'status': 'complete', 'return_code': 0, 'cleanup_confirmed': True}]}):
            with self.assertRaises(ValueError): C.validate_worker_cleanup(changed)


if __name__ == '__main__': unittest.main()
