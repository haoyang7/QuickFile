"""Unhandled campaign failures preserve diagnostics and the last valid receipt."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts/Investigations'))
import ax_reference_campaign as reference
import ax_shadow_campaign as shadow


class CampaignExceptionRetentionTests(unittest.TestCase):
    def exercise(self, campaign, error, *, write_failure=False, persistent=False):
        temporary = ROOT / '.build/Temporary'
        temporary.mkdir(parents=True, exist_ok=True)
        parent = Path(tempfile.gettempdir()).resolve()
        if not parent.is_relative_to(temporary): parent = temporary
        with tempfile.TemporaryDirectory(prefix='ax-campaign-crash-', dir=parent) as directory:
            work = Path(directory) / 'campaign'
            public = work / 'summary.json'
            published = []
            calls = []
            original_save = campaign.save_summary
            process = {'return_code': 0, 'command_return_code': 0, 'status': 'completed',
                'cleanup': {'group_signal': 'absent', 'group_members_exited': True,
                    'group_inspection': 'exited', 'leader_reaped': True, 'complete': True}}
            native_outputs = {('xcodebuild', '-version'): 'Xcode 26.3\nBuild version 17C529',
                ('git', 'rev-parse', 'HEAD'): 'a' * 40, ('sw_vers', '-productVersion'): '26.6.2',
                ('sw_vers', '-buildVersion'): '25G83', ('uname', '-m'): 'arm64'}

            def run(command, log, *args, **kwargs):
                self.assertIn('--prepare-external-fixture', command)
                log.write_bytes(b'private build diagnostics\n')
                return copy.deepcopy(process)

            def save(path, value):
                calls.append(value['temporary_cleanup'])
                if write_failure and (len(calls) == 2 or persistent and len(calls) > 2):
                    raise error
                original_save(path, value)
                published.append(path.read_bytes())

            with mock.patch.object(campaign, 'run_owned', side_effect=run) as runner, \
                    mock.patch.object(campaign, 'load_prepared_build', side_effect=error) as build, \
                    mock.patch.object(campaign, 'save_summary', side_effect=save), \
                    mock.patch.object(campaign.subprocess, 'check_output',
                        side_effect=lambda command, **kwargs: native_outputs[tuple(command)]), \
                    mock.patch.object(campaign.shutil, 'rmtree') as remove:
                with self.assertRaises(type(error)) as caught:
                    campaign.main(['--work-directory', str(work)])
                self.assertIs(caught.exception, error)
                remove.assert_not_called()
                self.assertEqual(runner.call_count, 1)
                self.assertEqual(build.call_count, 0 if write_failure else 1)
            self.assertEqual(len(calls), 2)
            self.assertEqual(public.read_bytes(), published[-1])
            self.assertEqual((work / 'private/ordinary.log').read_bytes(), b'private build diagnostics\n')
            value = json.loads(public.read_bytes())
            self.assertEqual(value['temporary_cleanup'], 'not-run')
            self.assertFalse(value['completed'])
            self.assertFalse(value['strict_checks_passed'])
            self.assertEqual(campaign.main(['--work-directory', str(work), '--validate-public']), 0)

    def test_build_exception_and_interrupt_keep_diagnostics_and_original_exception(self):
        for campaign in (reference, shadow):
            for error in (RuntimeError('prepared build mismatch'), KeyboardInterrupt()):
                with self.subTest(campaign=campaign.__name__, error=type(error).__name__):
                    self.exercise(campaign, error)

    def test_single_and_persistent_write_failures_keep_prior_receipt_and_original_exception(self):
        for campaign in (reference, shadow):
            for persistent in (False, True):
                with self.subTest(campaign=campaign.__name__, persistent=persistent):
                    self.exercise(campaign, OSError('summary write failure'),
                        write_failure=True, persistent=persistent)


if __name__ == '__main__':
    unittest.main()
