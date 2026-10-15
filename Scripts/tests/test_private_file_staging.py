"""Real staging syscalls and isolated resource/namespace faults on owned directories."""
import errno
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

if __package__:
    from .native_test_support import compile_fixture_localizations
else:
    from native_test_support import compile_fixture_localizations

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "Staging regression requires macOS")
class PrivateFileStagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = ROOT / ".build/Temporary"
        parent.mkdir(parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix="staging-failure-tests-", dir=parent)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.output = Path(cls.temporary.name)
        compile_fixture_localizations(cls.output)
        cls.executable = cls.output / "StagingFailureCases"
        result = subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(cls.output / "module-cache"),
            str(ROOT / "Shared/QuickFileLocalization.swift"),
            str(ROOT / "Shared/PrivateFileStagingDirectory.swift"),
            str(ROOT / "Scripts/tests/fixtures/StagingFailureCases.swift"),
            "-o", str(cls.executable),
        ], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def run_case(self, scenario):
        with tempfile.TemporaryDirectory(prefix="owned-", dir=self.output) as directory:
            result = subprocess.run([str(self.executable), scenario, directory],
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertTrue(report['parent_open'])
            return report

    def test_cross_device_replacement_is_rejected_and_reclaimed(self):
        report = self.run_case('cross-device')
        self.assertEqual(report['errors'][-1], {'domain': 'NSPOSIXErrorDomain', 'code': errno.EXDEV})
        self.assertEqual(report['entries'], {})

    def test_normal_probe_removes_its_directory(self):
        report = self.run_case('normal')
        self.assertEqual(report['errors'], [])
        self.assertEqual(report['entries'], {})

    def test_descriptor_exhaustion_after_mkdir_does_not_leave_empty_directory(self):
        report = self.run_case('fd-exhausted')
        self.assertEqual(report['errors'][-1], {'domain': 'NSPOSIXErrorDomain', 'code': errno.EMFILE})
        self.assertEqual(report['entries'], {})

    def test_unavailable_identity_preserves_unconfirmed_directory(self):
        report = self.run_case('identity-unavailable')
        self.assertEqual(report['errors'][-1], {'domain': 'NSPOSIXErrorDomain', 'code': errno.EIO})
        self.assertEqual(report['entries'], {'staging': []})

    def test_failed_initialization_never_removes_replacement_entries(self):
        for scenario, expected in [('replacement-file', 'sentinel'), ('replacement-empty', []),
                                   ('replacement-nonempty', ['keep.txt'])]:
            with self.subTest(scenario=scenario):
                report = self.run_case(scenario)
                self.assertTrue(report['cleanup_failed'])
                self.assertEqual(report['errors'][-1], {'domain': 'NSPOSIXErrorDomain', 'code': errno.EIO})
                self.assertEqual(report['entries'], {'moved': [], 'staging': expected})
                self.assertTrue(report['sentinel_intact'])

    def test_failed_initialization_keeps_unexpected_contents_and_reports_cleanup(self):
        report = self.run_case('nonempty')
        self.assertTrue(report['cleanup_failed'])
        self.assertEqual(report['errors'][-1], {'domain': 'NSPOSIXErrorDomain', 'code': errno.EIO})
        self.assertEqual(report['entries'], {'staging': ['keep.txt']})
        self.assertTrue(report['sentinel_intact'])

    def test_opened_directory_must_match_the_created_identity(self):
        report = self.run_case('replacement-opened')
        self.assertTrue(report['cleanup_failed'])
        self.assertEqual(report['errors'][-1], {'domain': 'NSPOSIXErrorDomain', 'code': errno.ESTALE})
        self.assertEqual(report['entries'], {'moved': [], 'staging': []})
