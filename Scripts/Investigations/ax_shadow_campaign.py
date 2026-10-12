#!/usr/bin/env python3
"""Bounded, timing-perturbed AX shadow campaign; original strict failures survive.

Only summary.json is publishable. Auxiliary graphs compare reported current-stack
composition, with no allocation-generation or original-baseline identity claim.
"""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time

import ax_composition as composition
import ax_frozen_nodes as frozen
from ax_external_receipt import fixture_sources, load_prepared_build, validate_external_receipt, validate_empty_control_build
from ax_probe_report import leak_groups, validation_failure_counts
from ax_process import run_owned
from ax_reference_campaign import validate_process

ROOT = Path(__file__).resolve().parents[2]
PUBLIC_LIMIT = 512 * 1024
RAW_LIMIT = 16 * 1024 * 1024
GRAPH_LIMIT = 256 * 1024 * 1024
CASES = ('patched-product', 'patched-empty', 'pure-appkit-empty', 'pure-appkit-idle')
LABELS = frozen.LIVE_LABELS
CAPTURES = ('auxiliary-original-baseline', 'auxiliary-candidate', 'auxiliary-late')
POLICY = {'max_probes': 6, 'min_interval_seconds': 2, 'deadline_seconds': 15,
          'tool_timeout_seconds': 5, 'consecutive_equal': 2,
          'comparison': 'counts-bytes-root-kind-type-instances-tree-nodes', 'size_histogram_compared': False}
ENVIRONMENT = {'host': {'MallocStackLogging': '1', 'MallocStackLoggingNoCompact': '1', 'MallocScribble': 'unset'},
               'reader': dict.fromkeys(('MallocStackLogging', 'MallocStackLoggingNoCompact', 'MallocScribble'), 'unset')}
TIME_KEYS = ('baseline_finished', 'settling_started', 'first_measurement_cycle', 'last_original_scan_finished')
ERRORS = ('graph_directory_failed', 'receipt_write_failed', 'environment_unavailable', 'capture_failed',
          'settling_failed', 'not_settled', 'stdout_write_failed')
FAILURES = ('heap_baseline', 'control_activity', 'notifications', 'compensation_branches', 'allocator_environment', 'other')
ACTIVITY = ('destroyed_buttons', 'notifications', 'ordinary_compensations', 'mutable_compensations')
HOST_KEYS = ('buttons', 'allocatedButtons', 'destroyedButtons', 'compensations', 'mutableCompensations')
READER_KEYS = ('notifications', 'all_notifications', 'unmatched_notifications', 'tracked_buttons', 'buttons', 'registrations')


def require(condition):
    if not condition:
        raise ValueError('Invalid bounded AX shadow evidence')


def integer(value, maximum=1_000_000_000):
    return type(value) is int and 0 <= value <= maximum


def digest(value):
    return type(value) is str and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def fields(value, names):
    require(type(value) is dict and set(value) == set(names))


def read_bytes(path, limit):
    # Parent directories must not redirect either public validation or graph tools.
    require(not any(parent.is_symlink() for parent in (path, *path.parents)))
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and 0 < info.st_size <= limit)
    data = path.read_bytes()
    require(len(data) == info.st_size)
    return data


def unique_pairs(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value)
        value[key] = item
    return value


def read_json(path, limit=PUBLIC_LIMIT):
    return json.loads(read_bytes(path, limit), object_pairs_hook=unique_pairs,
                      parse_constant=lambda _: require(False))


def canonical(value):
    return (json.dumps(value, indent=2, allow_nan=False) + '\n').encode()


def file_hash(path, limit):
    return hashlib.sha256(read_bytes(path, limit)).hexdigest()


def groups_projection(groups):
    require(type(groups) is list and len(groups) <= 128)
    counts = Counter()
    for group in groups:
        require(type(group) is dict and group.get('root_kind') in ('LEAK', 'CYCLE', None))
        require(type(group.get('root_type')) is str and len(group['root_type']) <= 256)
        require(integer(group.get('root_instances')) and group['root_instances'] > 0)
        require(group.get('tree_nodes') is None or integer(group['tree_nodes']))
        kind = group['root_kind'].lower() if group['root_kind'] else 'unknown'
        name = group['root_type'] if group['root_type'] in frozen.REFERENCE_TYPES else 'unknown'
        # Preserve group multiplicity and tree size rather than merging distinct roots.
        counts[(kind, name, group['root_instances'], group['tree_nodes'])] += 1
    return [{'root_kind': kind, 'root_type': name, 'root_instances': instances,
             'tree_nodes': nodes, 'groups': count}
            for (kind, name, instances, nodes), count in sorted(counts.items(), key=lambda row: canonical(list(row[0])))]


def signature(row):
    return row['leak_nodes'], row['leak_bytes'], row['groups']


def classification_passed(row):
    return (row['unclassified_nodes'] == 0 and not row['destroyed_notification_stack_present']
            and all(group['root_type'] == 'NSXPCConnection' for group in row['groups']))


def root_count(row):
    return sum(group['root_instances'] * group['groups'] for group in row['groups'])


def fits(row, baseline):
    return classification_passed(row) and all(row[key] <= baseline[key] for key in ('leak_nodes', 'leak_bytes')) and root_count(row) <= root_count(baseline)


def validate_scan(row, label):
    fields(row, ('label', 'leak_nodes', 'leak_bytes', 'unclassified_nodes', 'destroyed_notification_stack_present',
                 'exit_code', 'stdout_sha256', 'groups'))
    require(row['label'] == label and all(integer(row[key]) for key in ('leak_nodes', 'leak_bytes', 'unclassified_nodes')))
    require(type(row['exit_code']) is int and row['exit_code'] in (0, 1) and digest(row['stdout_sha256']))
    require(type(row['destroyed_notification_stack_present']) is bool)
    require(type(row['groups']) is list and len(row['groups']) <= 128)
    keys = []
    for group in row['groups']:
        fields(group, ('root_kind', 'root_type', 'root_instances', 'tree_nodes', 'groups'))
        require(group['root_kind'] in ('leak', 'cycle', 'unknown') and group['root_type'] in frozen.REFERENCE_TYPES)
        require(integer(group['root_instances']) and group['root_instances'] > 0 and integer(group['groups'], 128) and group['groups'] > 0)
        require(group['tree_nodes'] is None or integer(group['tree_nodes']))
        keys.append((group['root_kind'], group['root_type'], group['root_instances'], group['tree_nodes']))
    require(len(set(keys)) == len(keys) and row['groups'] == sorted(row['groups'], key=lambda g: canonical([g[k] for k in ('root_kind', 'root_type', 'root_instances', 'tree_nodes')])))
    require(sum((g['tree_nodes'] or 0) * g['groups'] for g in row['groups']) + row['unclassified_nodes'] == row['leak_nodes'])


def project_scan(row, records):
    label = row.get('label')
    require(label in LABELS or type(label) is str and re.fullmatch(r'shadow-probe-[0-5]', label))
    suffix = '.stdout.txt' if label.startswith('shadow-probe-') else '-original.stdout.txt'
    data = read_bytes(records / (label + suffix), RAW_LIMIT)
    require(hashlib.sha256(data).hexdigest() == row.get('stdout_sha256'))
    text = data.decode('utf-8')
    totals = re.findall(r'(\d+) leaks for (\d+) total leaked bytes', text)
    require(len(totals) == 1 and tuple(map(int, totals[0])) == (row.get('leak_nodes'), row.get('leak_bytes')))
    actual = leak_groups(text)
    require(actual == row.get('groups'))
    require(row.get('destroyed_notification_stack_present') == ('_NSAccessibilityRemoveAllObserversAndSendDestroyedNotification' in text))
    projected = {key: row[key] for key in ('label', 'leak_nodes', 'leak_bytes', 'unclassified_nodes', 'destroyed_notification_stack_present', 'exit_code', 'stdout_sha256')}
    projected['groups'] = groups_projection(actual)
    validate_scan(projected, label)
    return projected


def strict_verdict(measurement, process):
    if measurement is None or process['status'] != 'completed' or process['command_return_code'] is None:
        return 'unavailable'
    scans = measurement['original_scans']
    failed = (process['command_return_code'] != 0 or any(measurement['failure_counts'].values())
              or len(scans) != 6 or not scans or not classification_passed(scans[0])
              or any(not fits(row, scans[0]) for row in scans[1:]))
    return 'failed' if failed else 'passed'


def hypothetical(measurement, shadow):
    if measurement is None or shadow['chosen_index'] is None or shadow['errors'] or len(measurement['original_scans']) != 6:
        return 'unavailable'
    scans = measurement['original_scans']
    candidate = shadow['probes'][shadow['chosen_index']]['scan']
    fail = any(count for key, count in measurement['failure_counts'].items() if key != 'heap_baseline')
    return 'failed' if fail or not classification_passed(scans[0]) or any(not fits(row, candidate) for row in scans[1:]) else 'passed'


def project_measurement(records, process):
    result = read_json(records / 'result.json')
    rows = read_json(records / 'scans.json')
    require(type(rows) is list and len(rows) <= 6)
    scans = [project_scan(row, records) for row in rows]
    require([row['label'] for row in scans] == list(LABELS[:len(scans)]))
    if result.get('scans') is not None:
        require(len(result['scans']) == len(rows))
        for row, summary in zip(rows, result['scans']):
            require(all(summary.get(key) == value for key, value in row.items() if key != 'host'))
    counts = {key: result.get(key, 0) for key in ACTIVITY}
    require(all(integer(value, 100000) for value in counts.values()))
    measurement = {'original_scans': scans, 'failure_counts': validation_failure_counts(result), 'activity_counts': counts}
    return measurement, result


def finite_time(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def project_shadow(records, measurement, process, expected, case):
    raw = read_json(records / 'settled-baseline-shadow.json')
    require(type(raw.get('schema')) is int and raw['schema'] == 1 and raw.get('settling_policy') == POLICY and canonical(raw['settling_policy']) == canonical(POLICY))
    require(raw.get('timing_perturbed') is True and raw.get('original_parity') is False)
    require(raw.get('logging_mode') == 'compact' and raw.get('history_mode') == 'current-stacks')
    validate_external_receipt(read_json(records / 'external-startup.json', 16384), 'off', expected)
    require(raw.get('environments') == ENVIRONMENT)
    observer = 'initial-query-only' if case == 'pure-appkit-idle' else 'ordinary'
    require(raw.get('observer_query_policy') == observer)
    require(type(raw.get('errors')) is list and len(raw['errors']) <= 32 and all(error in ERRORS for error in raw['errors']))
    probes, captures = raw.get('probes'), raw.get('captures')
    require(type(probes) is list and len(probes) <= 6 and type(captures) is list and len(captures) <= 3)
    markers = {key: raw.get(key + '_monotonic') for key in TIME_KEYS}
    require(all(value is None or finite_time(value) for value in markers.values()))
    times = [row.get('start_monotonic') for row in probes + captures] + [value for value in markers.values() if value is not None]
    require(all(finite_time(value) for value in times))
    origin = min(times) if times else 0
    def window(row):
        start, end = row.get('start_monotonic'), row.get('end_monotonic')
        require(finite_time(start) and finite_time(end) and start <= end)
        return {'start_elapsed_ms': round((start - origin) * 1000), 'end_elapsed_ms': round((end - origin) * 1000)}
    public_probes = []
    for index, row in enumerate(probes):
        require(type(row.get('index')) is int and row['index'] == index and row.get('label') == 'shadow-probe-' + str(index))
        require(row.get('host_activity_zero') is True)
        require(type(row.get('host')) is dict and all(type(row['host'].get(key)) is int and row['host'][key] == 0 for key in HOST_KEYS))
        require(type(row.get('reader_warm')) is dict and all(type(row['reader_warm'].get(key)) is int and row['reader_warm'][key] == 0 for key in READER_KEYS) and row['reader_warm'].get('target_notification_counts') == [])
        raw_signature = (row['leak_nodes'], row['leak_bytes'], sorted((g['root_kind'], g['root_type'], g['root_instances'], g['tree_nodes']) for g in row['groups']))
        public_probes.append({'index': index, 'scan': project_scan(row, records), 'host_activity_zero': True,
                              'reader_warm_zero': True, 'signature_sha256': hashlib.sha256(canonical(raw_signature)).hexdigest(), **window(row)})
        require(row['end_monotonic'] - row['start_monotonic'] <= 5)
        if index:
            require(row['start_monotonic'] - probes[index - 1]['end_monotonic'] >= 2)
    chosen = next((index for index in range(1, len(public_probes)) if classification_passed(public_probes[index]['scan']) and classification_passed(public_probes[index - 1]['scan']) and signature(public_probes[index]['scan']) == signature(public_probes[index - 1]['scan']) and public_probes[index]['signature_sha256'] == public_probes[index - 1]['signature_sha256']), None)
    require(raw.get('chosen_index') == chosen and (raw.get('chosen_index') is None or type(raw['chosen_index']) is int))
    require(raw.get('status') == ('observed-stable' if chosen is not None else 'not_settled'))
    if probes:
        require(markers['settling_started'] is not None and probes[-1]['end_monotonic'] - markers['settling_started'] < 15)
    sources = {row['label']: row for row in measurement['original_scans']}
    sources.update({row['scan']['label']: row['scan'] for row in public_probes})
    public_captures = []
    for row in captures:
        label = row.get('label')
        require(label in CAPTURES and label not in [item['label'] for item in public_captures])
        source_label = row.get('source_label')
        require(source_label in sources)
        source = sources[source_label]
        require(row.get('source_stdout_sha256') == source['stdout_sha256'] and all(row.get(key) == source[key] for key in ('leak_nodes', 'leak_bytes')))
        require(groups_projection(row.get('groups')) == source['groups'])
        if label == CAPTURES[0]: require(source_label == 'baseline')
        if label == CAPTURES[1]:
            require(chosen is not None and source_label == 'shadow-probe-' + str(chosen))
            require(markers['settling_started'] is not None and row['end_monotonic'] - markers['settling_started'] < 15)
        if label != CAPTURES[2]: require(row.get('host_activity_zero') is True)
        require(row.get('status') in ('complete', 'failed'))
        require(row.get('exit_code') is None or type(row['exit_code']) is int and -127 <= row['exit_code'] <= 255)
        graph_verified = False
        if row['status'] == 'complete':
            require(row.get('graph_file') == label + '.memgraph' and digest(row.get('graph_sha256')) and integer(row.get('graph_bytes'), GRAPH_LIMIT) and row['graph_bytes'] > 0)
            try:
                graph_verified = file_hash(records / 'shadow' / (label + '.memgraph'), GRAPH_LIMIT) == row['graph_sha256']
            except (OSError, ValueError):
                pass
        public_captures.append({'label': label, 'status': row['status'], 'graph_sha256': row.get('graph_sha256'), 'graph_binding_verified': graph_verified,
                                'source_label': source_label, 'source_stdout_sha256': source['stdout_sha256'],
                                'exit_code': row['exit_code'], 'host_activity_zero': label != CAPTURES[2],
                                'endpoint': 'observer-exited' if label == CAPTURES[2] and source_label == 'observer-exited' else 'earlier-scan' if label == CAPTURES[2] else 'zero-target-idle',
                                **window(row)})
    result = read_json(records / 'result.json')
    require(result.get('settled_baseline_shadow') is True and result.get('scan_mode') == 'live'
            and result.get('mode') == ('product' if case == CASES[0] else 'heap-control')
            and result.get('reader_mode') == ('initial-query-only' if case == CASES[-1] else 'subscribed'))
    shadow = {'schema': 1, 'timing_markers': {key: None if value is None else round((value - origin) * 1000) for key, value in markers.items()}, 'timing_evidence': False, 'settling_policy': POLICY, 'status': raw['status'], 'chosen_index': chosen,
              'probes': public_probes, 'captures': public_captures, 'errors': raw['errors'],
              'environments': raw['environments'], 'observer_query_policy': observer,
              'timing_perturbed': True, 'original_parity': False, 'logging_mode': 'compact', 'history_mode': 'current-stacks',
              'original_strict_verdict': strict_verdict(measurement, process), 'candidate_hypothetical_verdict': 'unavailable'}
    shadow['timing_evidence'] = timing_complete(shadow)
    shadow['candidate_hypothetical_verdict'] = hypothetical(measurement, shadow)
    require(raw.get('original_strict_verdict') == shadow['original_strict_verdict'] and raw.get('candidate_hypothetical_verdict') == shadow['candidate_hypothetical_verdict'])
    validate_shadow(shadow, measurement, process, case)
    return shadow


def timing_complete(value):
    markers = value['timing_markers']
    if any(markers[key] is None for key in TIME_KEYS): return False
    captures = {row['label']: row for row in value['captures']}
    if CAPTURES[0] not in captures or CAPTURES[2] not in captures: return False
    baseline, settling, first, last = (markers[key] for key in TIME_KEYS)
    if not baseline <= settling <= captures[CAPTURES[0]]['start_elapsed_ms']: return False
    if not first <= last <= captures[CAPTURES[2]]['start_elapsed_ms']: return False
    if captures[CAPTURES[2]]['endpoint'] != 'observer-exited': return False
    return all(row['end_elapsed_ms'] <= first for label, row in captures.items() if label != CAPTURES[2])


def validate_shadow(value, measurement, process, case):
    fields(value, ('schema', 'timing_markers', 'timing_evidence', 'settling_policy', 'status', 'chosen_index', 'probes', 'captures', 'errors', 'environments', 'observer_query_policy',
                   'timing_perturbed', 'original_parity', 'logging_mode', 'history_mode', 'original_strict_verdict', 'candidate_hypothetical_verdict'))
    require(type(value['schema']) is int and value['schema'] == 1)
    require(value['settling_policy'] == POLICY and canonical(value['settling_policy']) == canonical(POLICY))
    require(value['timing_perturbed'] is True and value['original_parity'] is False and value['logging_mode'] == 'compact' and value['history_mode'] == 'current-stacks')
    require(value['environments'] == ENVIRONMENT and value['observer_query_policy'] == ('initial-query-only' if case == CASES[-1] else 'ordinary'))
    require(type(value['errors']) is list and len(value['errors']) <= 32 and all(error in ERRORS for error in value['errors']))
    fields(value['timing_markers'], TIME_KEYS)
    require(all(item is None or integer(item, 330000) for item in value['timing_markers'].values()))
    require(type(value['timing_evidence']) is bool and value['timing_evidence'] == timing_complete(value))
    markers = value['timing_markers']
    for before, after in zip(TIME_KEYS, TIME_KEYS[1:]):
        if markers[before] is not None and markers[after] is not None: require(markers[before] <= markers[after])
    probes = value['probes']
    require(type(probes) is list and len(probes) <= 6)
    def window(row, maximum=45000):
        require(all(integer(row[key], maximum) for key in ('start_elapsed_ms', 'end_elapsed_ms')) and row['start_elapsed_ms'] <= row['end_elapsed_ms'])
    for index, row in enumerate(probes):
        fields(row, ('index', 'scan', 'host_activity_zero', 'reader_warm_zero', 'signature_sha256', 'start_elapsed_ms', 'end_elapsed_ms'))
        require(type(row['index']) is int and row['index'] == index and row['host_activity_zero'] is True and row['reader_warm_zero'] is True and digest(row['signature_sha256']))
        validate_scan(row['scan'], 'shadow-probe-' + str(index))
        if not classification_passed(row['scan']):
            require(index == len(probes) - 1 and value['chosen_index'] is None and 'settling_failed' in value['errors'])
        window(row, 330000)
        require(value['timing_markers']['settling_started'] is not None and row['end_elapsed_ms'] - value['timing_markers']['settling_started'] <= 15000)
        require(row['end_elapsed_ms'] - row['start_elapsed_ms'] <= 5000)
        if index: require(row['start_elapsed_ms'] - probes[index - 1]['end_elapsed_ms'] >= 2000)
    chosen = next((i for i in range(1, len(probes)) if classification_passed(probes[i]['scan']) and classification_passed(probes[i - 1]['scan']) and signature(probes[i]['scan']) == signature(probes[i - 1]['scan']) and probes[i]['signature_sha256'] == probes[i - 1]['signature_sha256']), None)
    require((value['chosen_index'] is None or type(value['chosen_index']) is int) and value['chosen_index'] == chosen)
    require(value['status'] == ('not_settled' if chosen is None else 'observed-stable'))
    if chosen is not None: require(chosen == len(probes) - 1)
    require(type(value['captures']) is list and len(value['captures']) <= 3)
    sources = {row['label']: row for row in measurement['original_scans']}
    sources.update({row['scan']['label']: row['scan'] for row in probes})
    seen = []
    for row in value['captures']:
        fields(row, ('label', 'status', 'graph_sha256', 'graph_binding_verified', 'source_label', 'source_stdout_sha256', 'exit_code', 'host_activity_zero', 'endpoint', 'start_elapsed_ms', 'end_elapsed_ms'))
        label = row['label']
        require(label in CAPTURES and label not in seen and [CAPTURES.index(x) for x in seen] == sorted(CAPTURES.index(x) for x in seen))
        seen.append(label)
        require(row['source_label'] in sources and row['source_stdout_sha256'] == sources[row['source_label']]['stdout_sha256'])
        require(row['status'] in ('complete', 'failed') and (row['graph_sha256'] is None or digest(row['graph_sha256'])))
        require(row['status'] != 'complete' or digest(row['graph_sha256']))
        require(type(row['graph_binding_verified']) is bool and (not row['graph_binding_verified'] or row['status'] == 'complete'))
        require(row['exit_code'] is None or type(row['exit_code']) is int and -127 <= row['exit_code'] <= 255)
        window(row, 330000)
        require(row['host_activity_zero'] is (label != CAPTURES[2]))
        require(row['endpoint'] == ('observer-exited' if label == CAPTURES[2] and row['source_label'] == 'observer-exited' else 'earlier-scan' if label == CAPTURES[2] else 'zero-target-idle'))
        if label != CAPTURES[2] and markers['first_measurement_cycle'] is not None: require(row['end_elapsed_ms'] <= markers['first_measurement_cycle'])
        if label == CAPTURES[2] and markers['last_original_scan_finished'] is not None: require(markers['last_original_scan_finished'] <= row['start_elapsed_ms'])
        if label == CAPTURES[0]:
            if markers['baseline_finished'] is not None and markers['settling_started'] is not None: require(markers['baseline_finished'] <= markers['settling_started'] <= row['start_elapsed_ms'])
            require(row['source_label'] == 'baseline' and (not probes or row['end_elapsed_ms'] <= probes[0]['start_elapsed_ms']))
        if label == CAPTURES[1]:
            require(chosen is not None and row['source_label'] == 'shadow-probe-' + str(chosen) and row['start_elapsed_ms'] >= probes[chosen]['end_elapsed_ms'] and row['end_elapsed_ms'] - value['timing_markers']['settling_started'] <= 15000)
    require(value['original_strict_verdict'] == strict_verdict(measurement, process))
    require(value['candidate_hypothetical_verdict'] == hypothetical(measurement, value))


def numeric_histogram_complete(point):
    if point is None or point['status'] == 'unavailable': return False
    histogram = point['histogram']
    return (not any(histogram[key] for key in ('omitted_nodes', 'omitted_bytes', 'omitted_buckets'))
            and set(histogram['reasons']) <= {'unknown_type'}
            and sum(row['count'] for row in histogram['buckets']) == point['leak_nodes']
            and sum(row['size'] * row['count'] for row in histogram['buckets']) == point['leak_bytes'])


def histogram_diff(before, after):
    value = {'status': 'unavailable', 'semantics': 'auxiliary-current-stack-type-size-net-count', 'generation': 'unknown', 'type_coverage': 'unavailable',
             'net_nodes': None, 'net_bytes': None, 'changes': []}
    if not numeric_histogram_complete(before) or not numeric_histogram_complete(after): return value
    old, new = ({(r['type'], r['size']): r['count'] for r in point['histogram']['buckets']} for point in (before, after))
    value.update(status='complete', type_coverage='includes-unknown' if any(point['histogram']['unknown_type_nodes'] for point in (before, after)) else 'named', net_nodes=after['leak_nodes'] - before['leak_nodes'], net_bytes=after['leak_bytes'] - before['leak_bytes'],
        changes=[{'type': kind, 'size': size, 'count_delta': new.get((kind, size), 0) - old.get((kind, size), 0)}
                 for kind, size in sorted(old.keys() | new.keys()) if new.get((kind, size), 0) != old.get((kind, size), 0)])
    return value


def offline_initial():
    return {'schema': 1, 'snapshots': [], 'diffs': {'initial_to_late': histogram_diff(None, None), 'candidate_to_late': histogram_diff(None, None)},
            'tools': [], 'process_cleanup_confirmed': True}


def validate_offline(value, shadow, measurement):
    fields(value, ('schema', 'snapshots', 'diffs', 'tools', 'process_cleanup_confirmed'))
    require(type(value['schema']) is int and value['schema'] == 1 and type(value['process_cleanup_confirmed']) is bool)
    require(type(value['snapshots']) is list and len(value['snapshots']) <= 3)
    captures = {row['label']: row for row in shadow['captures']} if shadow else {}
    sources = {row['label']: row for row in measurement['original_scans']} if measurement else {}
    if shadow: sources.update({row['scan']['label']: row['scan'] for row in shadow['probes']})
    snapshots = {}
    for row in value['snapshots']:
        fields(row, ('label', 'graph_sha256', 'snapshot', 'counts_binding'))
        label = row['label']
        require(label in captures and label not in snapshots and captures[label]['status'] == 'complete' and captures[label]['graph_binding_verified'] and row['graph_sha256'] == captures[label]['graph_sha256'])
        composition.validate_snapshot(row['snapshot'])
        source = sources[captures[label]['source_label']]
        match = all(row['snapshot'][key] == source[key] for key in ('leak_nodes', 'leak_bytes')) and row['snapshot']['root_count'] == root_count(source)
        require(row['counts_binding'] == ('totals-match' if match else 'unavailable'))
        snapshots[label] = row['snapshot'] if match else None
    fields(value['diffs'], ('initial_to_late', 'candidate_to_late'))
    # Earlier aborted captures cannot masquerade as the six-checkpoint endpoint.
    late = snapshots.get(CAPTURES[2]) if captures.get(CAPTURES[2], {}).get('endpoint') == 'observer-exited' else None
    require(value['diffs'] == {'initial_to_late': histogram_diff(snapshots.get(CAPTURES[0]), late),
                               'candidate_to_late': histogram_diff(snapshots.get(CAPTURES[1]), late)})
    validate_worker_cleanup({key: value[key] for key in ('process_cleanup_confirmed', 'tools')})
    for label in snapshots:
        require(all(any(t['label'] == label and t['tool'] == tool and t['status'] == 'complete' and t['cleanup_confirmed'] for t in value['tools']) for tool in ('list', 'tree')))


def validate_worker_cleanup(value):
    fields(value, ('process_cleanup_confirmed', 'tools'))
    require(type(value['process_cleanup_confirmed']) is bool)
    require(type(value['tools']) is list and len(value['tools']) <= 6)
    seen = set()
    for row in value['tools']:
        fields(row, ('tool', 'label', 'status', 'return_code', 'cleanup_confirmed'))
        require(row['tool'] in ('list', 'tree') and row['label'] in CAPTURES and (row['tool'], row['label']) not in seen)
        seen.add((row['tool'], row['label']))
        require(row['status'] in frozen.TOOL_STATES and type(row['cleanup_confirmed']) is bool)
        require(row['return_code'] is None or type(row['return_code']) is int and -127 <= row['return_code'] <= 255)
        if not row['cleanup_confirmed']: require(value['process_cleanup_confirmed'] is False)


def offline_worker(records, private):
    result = offline_initial()
    private.mkdir(exist_ok=False, mode=0o700)
    raw = read_json(records / 'settled-baseline-shadow.json')
    require(read_json(records / 'process-cleanup.json').get('processes_exited') is True)
    captures = raw.get('captures')
    require(type(captures) is list and len(captures) <= 3)
    deadline = time.monotonic() + 45
    tools = frozen.Tools(private / 'tools', result, deadline)
    seen = set()
    try:
        for capture in captures:
            if time.monotonic() >= deadline: break
            label = capture.get('label')
            require(label in CAPTURES and label not in seen)
            seen.add(label)
            if capture.get('status') != 'complete': continue
            graph = records / 'shadow' / (label + '.memgraph')
            try:
                expected = capture.get('graph_sha256')
                require(digest(expected) and file_hash(graph, GRAPH_LIMIT) == expected)
                listing = tools.run('list', label, ['/usr/bin/leaks', '--noContent', '--list', '--nosources', str(graph)], (0, 1))
                require(file_hash(graph, GRAPH_LIMIT) == expected)
                tree = tools.run('tree', label, ['/usr/bin/leaks', '--noContent', '--nosources', str(graph)], (0, 1))
                require(file_hash(graph, GRAPH_LIMIT) == expected)
                snapshot = composition.histogram_snapshot(listing, tree)
                match = (snapshot['leak_nodes'] == capture.get('leak_nodes') and snapshot['leak_bytes'] == capture.get('leak_bytes')
                         and snapshot['root_count'] == sum(g['root_instances'] for g in capture.get('groups', [])))
                result['snapshots'].append({'label': label, 'graph_sha256': expected, 'snapshot': snapshot, 'counts_binding': 'totals-match' if match else 'unavailable'})
            except frozen.ExitUnconfirmed:
                raise
            except (frozen.EvidenceError, ValueError, OSError, TypeError, KeyError):
                continue
    except frozen.ExitUnconfirmed:
        result['process_cleanup_confirmed'] = False
    finally:
        snapshots = {r['label']: r['snapshot'] for r in result['snapshots'] if r['counts_binding'] == 'totals-match'}
        late = snapshots.get(CAPTURES[2]) if any(c.get('label') == CAPTURES[2] and c.get('source_label') == 'observer-exited' for c in captures) else None
        result['diffs'] = {'initial_to_late': histogram_diff(snapshots.get(CAPTURES[0]), late), 'candidate_to_late': histogram_diff(snapshots.get(CAPTURES[1]), late)}
        (records / 'shadow-offline.json').write_bytes(canonical(result))
    return 0 if result['process_cleanup_confirmed'] else 1


def validate_measurement(value):
    fields(value, ('original_scans', 'failure_counts', 'activity_counts'))
    require(type(value['original_scans']) is list and len(value['original_scans']) <= 6)
    for label, row in zip(LABELS, value['original_scans']): validate_scan(row, label)
    fields(value['failure_counts'], FAILURES)
    require(all(integer(count, 64) for count in value['failure_counts'].values()))
    fields(value['activity_counts'], ACTIVITY)
    require(all(integer(count, 100000) for count in value['activity_counts'].values()))


def evidence_passed(case):
    shadow, offline, run = case['shadow'], case['offline'], case['offline_process_run']
    return (shadow is not None and shadow['timing_evidence'] and shadow['status'] == 'observed-stable' and not shadow['errors']
            and offline is not None and run is not None and run['status'] == 'completed' and run['return_code'] == 0
            and case['cleanup_confirmed'] and len(offline['snapshots']) == 3
            and len(shadow['captures']) == 3 and all(row['graph_binding_verified'] for row in shadow['captures'])
            and all(numeric_histogram_complete(row['snapshot']) and row['counts_binding'] == 'totals-match' for row in offline['snapshots'])
            and all(delta['status'] == 'complete' for delta in offline['diffs'].values()))


def validate_summary(value):
    fields(value, ('schema', 'identity', 'builds', 'cases', 'completed', 'strict_checks_passed', 'evidence_checks_passed', 'temporary_cleanup'))
    require(type(value['schema']) is int and value['schema'] == 1)
    identity = value['identity']
    fields(identity, ('checkout_sha', 'macos', 'os_build', 'architecture', 'xcode', 'scan_mode', 'history_mode'))
    require(type(identity['checkout_sha']) is str and re.fullmatch(r'[0-9a-f]{40}', identity['checkout_sha']) is not None)
    require(type(identity['macos']) is str and re.fullmatch(r'26\.\d+(?:\.\d+)?', identity['macos']) is not None)
    require(type(identity['os_build']) is str and re.fullmatch(r'25[A-Z][0-9]{1,6}[a-z]?', identity['os_build']) is not None)
    require(identity['architecture'] == 'arm64' and identity['xcode'] == '26.3' and identity['scan_mode'] == 'settled-baseline-shadow' and identity['history_mode'] == 'current-stacks')
    require(all(type(value[key]) is bool for key in ('completed', 'strict_checks_passed', 'evidence_checks_passed')))
    require(value['temporary_cleanup'] in ('not-run', 'complete', 'retained-unconfirmed', 'failed'))
    require(type(value['builds']) is dict and set(value['builds']) <= {'ordinary', 'pure-appkit'})
    for mode, row in value['builds'].items():
        fields(row, ('process_run', 'manifest'))
        validate_process(row['process_run'])
        manifest = row['manifest']
        if manifest is None: continue
        fields(manifest, ('schema', 'build_mode', 'sources', 'executables', *(['build_evidence'] if mode == 'pure-appkit' else [])))
        require(type(manifest['schema']) is int and manifest['schema'] == (1 if mode == 'ordinary' else 2) and manifest['build_mode'] == mode)
        fields(manifest['sources'], fixture_sources(mode))
        fields(manifest['executables'], ('host', 'reader'))
        require(all(digest(item) for item in list(manifest['sources'].values()) + list(manifest['executables'].values())))
        if mode == 'pure-appkit': validate_empty_control_build(manifest['build_evidence'], mode)
    cases = value['cases']
    require(type(cases) is list and len(cases) <= 4)
    for index, case in enumerate(cases):
        fields(case, ('name', 'process_run', 'measurement', 'shadow', 'offline_process_run', 'offline', 'offline_cleanup', 'fixture_cleanup_confirmed',
                      'strict_checks_passed', 'evidence_checks_passed', 'cleanup_confirmed'))
        require(case['name'] == CASES[index])
        require(all(type(case[key]) is bool for key in ('fixture_cleanup_confirmed', 'strict_checks_passed', 'evidence_checks_passed', 'cleanup_confirmed')))
        validate_process(case['process_run'])
        if case['measurement'] is not None: validate_measurement(case['measurement'])
        if case['shadow'] is not None:
            require(case['measurement'] is not None)
            validate_shadow(case['shadow'], case['measurement'], case['process_run'], case['name'])
        if case['offline_process_run'] is not None: validate_process(case['offline_process_run'])
        if case['offline_cleanup'] is not None:
            require(case['offline_process_run'] is not None)
            validate_worker_cleanup(case['offline_cleanup'])
        if case['offline'] is not None:
            require(case['offline_process_run'] is not None and case['shadow'] is not None)
            validate_offline(case['offline'], case['shadow'], case['measurement'])
            require(case['offline_cleanup'] == {key: case['offline'][key] for key in ('process_cleanup_confirmed', 'tools')})
        confirmed = case['process_run']['cleanup']['complete'] and case['fixture_cleanup_confirmed']
        if case['offline_process_run'] is not None:
            confirmed = confirmed and case['offline_process_run']['cleanup']['complete'] and case['offline_cleanup'] is not None and case['offline_cleanup']['process_cleanup_confirmed'] and all(t['cleanup_confirmed'] for t in case['offline_cleanup']['tools'])
        require(case['cleanup_confirmed'] == confirmed)
        require(case['strict_checks_passed'] == (strict_verdict(case['measurement'], case['process_run']) == 'passed' and case['cleanup_confirmed']))
        require(case['evidence_checks_passed'] == bool(evidence_passed(case)))
        if index < len(cases) - 1: require(case['cleanup_confirmed'])
    require(not value['completed'] or len(cases) == 4)
    for key in ('strict_checks_passed', 'evidence_checks_passed'):
        require(value[key] == (value['completed'] and all(case[key] for case in cases)))
    require(len(canonical(value)) <= PUBLIC_LIMIT)


def encode_summary(value):
    validate_summary(value)
    return canonical(value)


def save_summary(path, value):
    payload = encode_summary(value)
    temporary = path.with_suffix('.tmp')
    require(not temporary.is_symlink() and not path.is_symlink())
    temporary.write_bytes(payload)
    temporary.replace(path)


def identity():
    def output(*command): return subprocess.check_output(command, text=True, timeout=15, cwd=ROOT).strip()
    require(output('xcodebuild', '-version').splitlines()[0] == 'Xcode 26.3')
    return {'checkout_sha': output('git', 'rev-parse', 'HEAD'), 'macos': output('sw_vers', '-productVersion'),
            'os_build': output('sw_vers', '-buildVersion'), 'architecture': output('uname', '-m'),
            'xcode': '26.3', 'scan_mode': 'settled-baseline-shadow', 'history_mode': 'current-stacks'}


def campaign(root):
    observed_identity = identity()
    root.mkdir(exist_ok=False, parents=True, mode=0o700)
    private = root / 'private'
    private.mkdir(mode=0o700)
    public = root / 'summary.json'
    summary = {'schema': 1, 'identity': observed_identity, 'builds': {}, 'cases': [], 'completed': False,
               'strict_checks_passed': False, 'evidence_checks_passed': False, 'temporary_cleanup': 'not-run'}
    save_summary(public, summary)
    environment = dict(os.environ)
    for key in ('MallocScribble', 'MallocStackLogging', 'MallocStackLoggingNoCompact'): environment.pop(key, None)
    cleanup_confirmed = True
    prepared = {}
    runner = ROOT / 'Scripts/Investigations/verify-ax-compatibility.py'
    try:
        for mode in ('ordinary', 'pure-appkit'):
            directory = private / mode
            process = run_owned([sys.executable, str(runner), '--prepare-external-fixture', '--work-directory', str(directory),
                '--records-directory', str(private / (mode + '-records')), *(['--empty-control-mode', mode] if mode != 'ordinary' else [])],
                private / (mode + '.log'), environment, timeout=180)
            summary['builds'][mode] = {'process_run': process, 'manifest': None}
            cleanup_confirmed = process['cleanup']['complete']
            save_summary(public, summary)
            if process['return_code'] != 0 or not cleanup_confirmed: return 1
            hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in fixture_sources(mode)}
            manifest = load_prepared_build(directory, hashes, mode)
            summary['builds'][mode]['manifest'] = manifest
            prepared[mode] = directory, manifest['executables']
            save_summary(public, summary)
        for name in CASES:
            mode = 'ordinary' if name.startswith('patched-') else 'pure-appkit'
            directory, hashes = prepared[mode]
            case_root = private / name
            case_root.mkdir()
            records = case_root / 'records'
            process = run_owned([sys.executable, str(runner), '--settled-baseline-shadow', '--external-startup-receipt', '--malloc-scribble', 'off',
                '--prepared-fixture-directory', str(directory), '--work-directory', str(case_root / 'fixture'), '--records-directory', str(records),
                *(['--heap-control'] if name != CASES[0] else []), *(['--empty-control-mode', mode] if mode == 'pure-appkit' else []),
                *(['--reference-idle'] if name == CASES[-1] else [])], case_root / 'measurement.log', environment, timeout=330)
            case = {'name': name, 'process_run': process, 'measurement': None, 'shadow': None, 'offline_process_run': None,
                    'offline': None, 'offline_cleanup': None, 'fixture_cleanup_confirmed': False, 'strict_checks_passed': False, 'evidence_checks_passed': False,
                    'cleanup_confirmed': False}
            summary['cases'].append(case)
            cleanup_confirmed = process['cleanup']['complete']
            try:
                cleanup = read_json(records / 'process-cleanup.json')
                case['fixture_cleanup_confirmed'] = cleanup.get('processes_exited') is True
                cleanup_confirmed = cleanup_confirmed and case['fixture_cleanup_confirmed']
            except (ValueError, OSError, TypeError): cleanup_confirmed = False
            try:
                case['measurement'], result = project_measurement(records, process)
            except (ValueError, OSError, TypeError, KeyError, RuntimeError, UnicodeError): pass
            if case['measurement'] is not None:
                try:
                    case['shadow'] = project_shadow(records, case['measurement'], process, hashes, name)
                except (ValueError, OSError, TypeError, KeyError, RuntimeError, UnicodeError): pass
            # A failed diagnostic projection is not evidence of a live process.
            # Every fully exited case gets its independent bounded offline worker.
            if cleanup_confirmed:
                offline = run_owned([sys.executable, '-B', str(Path(__file__).resolve()), '--offline', '--records', str(records),
                    '--private', str(case_root / 'offline')], case_root / 'offline.log', environment, timeout=60)
                case['offline_process_run'] = offline
                cleanup_confirmed = cleanup_confirmed and offline['cleanup']['complete']
                try:
                    value = read_json(records / 'shadow-offline.json')
                    cleanup_receipt = {key: value[key] for key in ('process_cleanup_confirmed', 'tools')}
                    validate_worker_cleanup(cleanup_receipt)
                    case['offline_cleanup'] = cleanup_receipt
                    cleanup_confirmed = cleanup_confirmed and cleanup_receipt['process_cleanup_confirmed'] and all(t['cleanup_confirmed'] for t in cleanup_receipt['tools'])
                except (ValueError, OSError, TypeError, KeyError):
                    cleanup_confirmed = False
                    value = None
                if value is not None and case['shadow'] is not None and case['measurement'] is not None:
                    try:
                        validate_offline(value, case['shadow'], case['measurement'])
                        case['offline'] = value
                    except (ValueError, OSError, TypeError, KeyError):
                        pass
            case['cleanup_confirmed'] = bool(cleanup_confirmed)
            case['strict_checks_passed'] = strict_verdict(case['measurement'], process) == 'passed' and case['cleanup_confirmed']
            case['evidence_checks_passed'] = bool(evidence_passed(case))
            save_summary(public, summary)
            print(json.dumps({'case': name, 'strict_checks_passed': case['strict_checks_passed'],
                'evidence_checks_passed': case['evidence_checks_passed'], 'cleanup_confirmed': case['cleanup_confirmed']}), flush=True)
            if not cleanup_confirmed: return 1
        summary['completed'] = True
        for key in ('strict_checks_passed', 'evidence_checks_passed'): summary[key] = all(case[key] for case in summary['cases'])
        return_code = 0 if summary['strict_checks_passed'] and summary['evidence_checks_passed'] else 1
    finally:
        if cleanup_confirmed:
            try:
                shutil.rmtree(private)
                summary['temporary_cleanup'] = 'complete'
            except OSError:
                summary['temporary_cleanup'] = 'failed'
        else: summary['temporary_cleanup'] = 'retained-unconfirmed'
        save_summary(public, summary)
    return return_code if summary['temporary_cleanup'] == 'complete' else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-directory', type=Path)
    parser.add_argument('--validate-public', action='store_true')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--records', type=Path)
    parser.add_argument('--private', type=Path)
    args = parser.parse_args(argv)
    if args.offline:
        require(args.records is not None and args.private is not None and args.work_directory is None and not args.validate_public)
        for path in (args.records, args.private):
            require(not any(parent.is_symlink() for parent in (path, *path.parents)))
            path.resolve().relative_to(ROOT / '.build/Temporary')
        return offline_worker(args.records, args.private)
    require(args.work_directory is not None and args.records is None and args.private is None)
    require(not any(parent.is_symlink() for parent in (args.work_directory, *args.work_directory.parents)))
    root = args.work_directory.resolve()
    root.relative_to(ROOT / '.build/Temporary')
    if args.validate_public:
        public = root / 'summary.json'
        value = read_json(public)
        require(read_bytes(public, PUBLIC_LIMIT) == encode_summary(value))
        return 0
    return campaign(root)


if __name__ == '__main__':
    raise SystemExit(main())
