"""Process lifetime and failure cleanup for shared native test modules."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

PROGRAM = r'''
import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch
from Scripts.tests import native_test_support as support

support.ROOT = Path(sys.argv[1])
fail_first = sys.argv[2] == "fail-first"
builds = []

def build(command, **kwargs):
    output = Path(command[command.index("--output") + 1])
    builds.append(str(output))
    (output / "module.dylib").write_text("fixture")
    if fail_first and len(builds) == 1:
        raise subprocess.CalledProcessError(7, command)

with patch.object(support.subprocess, "run", side_effect=build):
    failed_cleanly = False
    if fail_first:
        try:
            support.shared_native_modules()
        except subprocess.CalledProcessError as error:
            failed_cleanly = error.returncode == 7 and not Path(builds[0]).exists()
    first = support.shared_native_modules()
    second = support.shared_native_modules()
    print(json.dumps({"builds": builds, "shared": first == second,
                      "alive": (first / "module.dylib").is_file(),
                      "failed_cleanly": failed_cleanly}))
'''


class NativeTestSupportTests(unittest.TestCase):
    def run_process(self, root, mode="success"):
        result = subprocess.run([sys.executable, "-c", PROGRAM, str(root), mode],
                                cwd=ROOT, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["shared"])
        self.assertTrue(report["alive"])
        for path in report["builds"]:
            self.assertFalse(Path(path).exists(), "Module directory survived process exit")
        return report

    def test_build_is_shared_only_within_process_and_removed_at_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            first = self.run_process(temporary)
            second = self.run_process(temporary)
        self.assertEqual(len(first["builds"]), 1)
        self.assertEqual(len(second["builds"]), 1)
        self.assertNotEqual(first["builds"], second["builds"])

    def test_failed_build_propagates_cleans_partial_output_and_is_not_cached(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = self.run_process(temporary, "fail-first")
        self.assertTrue(report["failed_cleanly"])
        self.assertEqual(len(report["builds"]), 2)
        self.assertNotEqual(*report["builds"])


if __name__ == "__main__":
    unittest.main()
