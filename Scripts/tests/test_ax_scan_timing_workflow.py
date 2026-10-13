"""Scan timing routing and public upload boundary, without native sampling."""
import json
import os
from pathlib import Path
import re
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
FLAGS = ('reader_exit_control', 'ax_causal_probe', 'heap_diagnostics', 'malloc_scribble', 'terminal_origin',
         'live_attribution', 'install_gate_control', 'pure_appkit_control', 'frozen_control',
         'reference_validation', 'settled_baseline_shadow')


class ScanTimingWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (ROOT / '.github/workflows/ax-scan-timing.yml').read_text()
        cls.router = (ROOT / '.github/workflows/ax-system-baseline.yml').read_text()
        script = cls.workflow.split("          python3 - <<'PY'\n", 1)[1].split('          PY\n', 1)[0]
        cls.guard = compile('\n'.join(line[10:] for line in script.splitlines()), '<scan-timing-guard>', 'exec')

    def guard_inputs(self, value):
        with mock.patch.dict(os.environ, {'AX_SCAN_TIMING_INPUTS': json.dumps(value)}):
            exec(self.guard, {})

    def condition(self, job, value):
        block = self.router.split('\n  ' + job + ':\n', 1)[1]
        expression = block.split('    if: ${{ ', 1)[1].split(' }}', 1)[0]
        expression = re.sub(r'inputs\.([a-z_]+)', lambda match: repr(value[match[1]]), expression)
        expression = re.sub(r'!(?!=)', 'not ', expression).replace('&&', 'and').replace('||', 'or')
        return eval(expression, {'__builtins__': {}}, {})

    def test_default_and_independent_requests_are_accepted(self):
        defaults = dict.fromkeys(FLAGS, False) | {'scan_timing_control': True, 'scan_mode': 'diagnostic', 'receipt_mode': 'internal'}
        for value in ({}, {'scan_timing_control': True}, defaults):
            with self.subTest(value=value):
                self.guard_inputs(value)

    def test_mixed_or_ill_typed_requests_are_rejected(self):
        values = [{flag: True} for flag in FLAGS]
        values += [{key: value} for key in (*FLAGS, 'scan_timing_control') for value in (0, 1, None, 'false')]
        values += [{'scan_timing_control': False}, {'scan_mode': 'live'}, {'receipt_mode': 'external-startup'}, {'unknown': False}, [], None]
        for value in values:
            with self.subTest(value=value), self.assertRaises(AssertionError):
                self.guard_inputs(value)

    def test_timing_experiment_excludes_legacy_jobs(self):
        defaults = dict.fromkeys((*FLAGS, 'scan_timing_control'), False) | {'scan_mode': 'diagnostic', 'receipt_mode': 'internal'}
        self.assertTrue(self.condition('ax-system-probe', defaults))
        self.assertTrue(self.condition('ax-heap-diagnostics', defaults | {'heap_diagnostics': True}))
        requests = [defaults] + [defaults | {flag: True} for flag in FLAGS]
        for request in requests:
            for job in ('ax-system-probe', 'ax-heap-diagnostics'):
                with self.subTest(job=job, request=request):
                    self.assertFalse(self.condition(job, request | {'scan_timing_control': True}))
        self.assertFalse(self.condition('ax-scan-timing', defaults))
        self.assertTrue(self.condition('ax-scan-timing', defaults | {'scan_timing_control': True}))
        reader = self.router.split('\n  ax-scan-timing:\n', 1)[1]
        self.assertIn('uses: ./.github/workflows/ax-scan-timing.yml', reader)
        self.assertIn('dispatch_inputs: ${{ toJSON(inputs) }}', reader)

    def test_upload_only_follows_independent_public_validation(self):
        self.assertIn('permissions:\n  contents: read', self.workflow)
        self.assertIn('persist-credentials: false', self.workflow)
        self.assertIn('runs-on: macos-26', self.workflow)
        self.assertIn('timeout-minutes: 35', self.workflow)
        self.assertIn('--validate-public', self.workflow)
        self.assertIn("if: always() && steps.public-evidence.outputs.safe == 'true'", self.workflow)
        self.assertEqual(self.workflow.count('uses: actions/upload-artifact'), 1)
        self.assertIn('path: .build/Temporary/ax-scan-timing-controls/campaign/summary.json', self.workflow)
        self.assertIn('retention-days: 7', self.workflow)
        self.assertNotIn('continue-on-error', self.workflow)
        self.assertNotIn('path: .build/Temporary/ax-scan-timing-controls/campaign\n', self.workflow)


if __name__ == '__main__':
    unittest.main()
