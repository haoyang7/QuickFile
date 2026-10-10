import copy
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "verify-build-settings.py"
SPEC = importlib.util.spec_from_file_location("verify_build_settings", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

TARGETS = (
    "QuickFile", "QuickFileCore", "QuickFileInfrastructure",
    "QuickFileApplication", "FinderExtension", "QuickFileTests",
)


def fixture():
    entries = []
    for target in TARGETS:
        settings = {"MACOSX_DEPLOYMENT_TARGET": "13.0"}
        if target in ("QuickFile", "FinderExtension"):
            settings["ENABLE_HARDENED_RUNTIME"] = "YES"
        if target in ("QuickFileCore", "QuickFileInfrastructure", "QuickFileApplication", "FinderExtension"):
            settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
        if target == "QuickFile":
            settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
        entries.append({"action": "build", "target": target, "buildSettings": settings})
    return entries


class VerifyBuildSettingsTests(unittest.TestCase):
    def run_cli(self, contents, version="13.0"):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--expected-macos-version", version],
            input=contents, text=True, capture_output=True, check=False,
        )

    def test_all_thirteen_checks_pass_without_exposing_other_settings(self):
        payload = fixture()
        for entry in payload:
            entry["buildSettings"]["PRIVATE_VALUE"] = "PRIVATE-BUILD-PATH"
        result = self.run_cli(json.dumps(payload))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "QuickFile Hardened Runtime: YES",
            "FinderExtension Hardened Runtime: YES",
            "QuickFile app icon set: AppIcon",
            *[f"{target} extension-safe APIs: YES" for target in (
                "QuickFileCore", "QuickFileInfrastructure", "QuickFileApplication", "FinderExtension")],
            *[f"{target} minimum macOS version: 13.0" for target in TARGETS],
        ])
        self.assertEqual(result.stderr, "")
        self.assertNotIn("PRIVATE", result.stdout + result.stderr)

    def test_extension_safety_does_not_restrict_app_or_test_host_apis(self):
        payload = fixture()
        for entry in payload:
            if entry["target"] in ("QuickFile", "QuickFileTests"):
                entry["buildSettings"]["APPLICATION_EXTENSION_API_ONLY"] = "NO"
        self.assertEqual(MODULE.verify_settings(payload, "13.0"), MODULE.verify_settings(fixture(), "13.0"))

    def test_shared_library_safety_failure_does_not_disclose_setting_value(self):
        payload = fixture()
        for entry in payload:
            if entry["target"] == "QuickFileInfrastructure":
                entry["buildSettings"]["APPLICATION_EXTENSION_API_ONLY"] = "PRIVATE-BUILD-PATH"
        result = self.run_cli(json.dumps(payload))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("QuickFileInfrastructure extension-safe APIs", result.stderr)
        self.assertNotIn("PRIVATE-BUILD-PATH", result.stderr)

    def test_each_assertion_rejects_missing_empty_wrong_and_non_string_values(self):
        original = fixture()
        missing = object()
        for index, entry in enumerate(original):
            for key in entry["buildSettings"]:
                for value in (missing, None, "", "wrong", True, 13.0, ["13.0"], {}):
                    with self.subTest(target=entry["target"], key=key, value=value):
                        payload = copy.deepcopy(original)
                        if value is missing:
                            del payload[index]["buildSettings"][key]
                        else:
                            payload[index]["buildSettings"][key] = value
                        with self.assertRaises(ValueError):
                            MODULE.verify_settings(payload, "13.0")

    def test_each_required_target_must_be_present(self):
        for target in TARGETS:
            with self.subTest(target=target), self.assertRaises(ValueError):
                MODULE.verify_settings([entry for entry in fixture() * 2 if entry["target"] != target], "13.0")

    def test_repeated_targets_pass_when_every_required_setting_matches(self):
        repeated = fixture()
        for entry in repeated:
            entry["buildSettings"]["UNRELATED_SETTING"] = "different unreported value"
        self.assertEqual(
            MODULE.verify_settings(fixture() + repeated + fixture(), "13.0"),
            MODULE.verify_settings(fixture(), "13.0"),
        )

    def test_invalid_setting_in_first_or_later_repeated_target_cannot_be_hidden(self):
        missing = object()
        for entry in fixture():
            for key in entry["buildSettings"]:
                for value in (missing, None, "", "wrong", True, 13.0, ["13.0"], {}):
                    for first in (True, False):
                        with self.subTest(target=entry["target"], key=key, value=value, first=first):
                            bad = copy.deepcopy(entry)
                            if value is missing:
                                del bad["buildSettings"][key]
                            else:
                                bad["buildSettings"][key] = value
                            payload = [bad] + fixture() if first else fixture() + [bad]
                            with self.assertRaises(ValueError):
                                MODULE.verify_settings(payload, "13.0")

    def test_repeated_unrelated_targets_are_allowed_but_still_require_valid_structure(self):
        extra = [{"target": "OtherTarget", "buildSettings": {}}] * 2
        self.assertEqual(
            MODULE.verify_settings(fixture() + extra, "13.0"),
            MODULE.verify_settings(fixture(), "13.0"),
        )
        with self.assertRaises(ValueError):
            MODULE.verify_settings(fixture() + extra + [{"target": "OtherTarget"}], "13.0")

    def test_repeated_target_mismatch_fails_without_partial_success_or_value_disclosure(self):
        bad = copy.deepcopy(fixture()[0])
        bad["buildSettings"]["ENABLE_HARDENED_RUNTIME"] = "PRIVATE-BUILD-PATH"
        for payload in ([bad] + fixture(), fixture() + [bad]):
            result = self.run_cli(json.dumps(payload))
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            self.assertIn("QuickFile Hardened Runtime", result.stderr)
            self.assertNotIn("PRIVATE-BUILD-PATH", result.stderr)

    def test_malformed_payload_shapes_are_rejected(self):
        for payload in (None, {}, "", [], [None], [[]], [{}],
                        [{"target": "QuickFile"}],
                        [{"target": "", "buildSettings": {}}],
                        [{"target": [], "buildSettings": {}}],
                        [{"target": "QuickFile", "buildSettings": []}]):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                MODULE.verify_settings(payload, "13.0")

    def test_invalid_json_and_extra_output_fail_without_partial_success(self):
        valid = json.dumps(fixture())
        for contents in ("", "PRIVATE-BUILD-PATH", "progress\n" + valid, valid + "\ntrailing", valid[:-1]):
            with self.subTest(contents=contents[:20]):
                result = self.run_cli(contents)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("error:", result.stderr)
                self.assertNotIn("PRIVATE-BUILD-PATH", result.stderr)

    def test_duplicate_json_keys_fail_instead_of_using_last_value(self):
        valid = json.dumps(fixture())
        for original, replacement in (
            ('"target": "QuickFile"', '"target": "wrong", "target": "QuickFile"'),
            ('"ENABLE_HARDENED_RUNTIME": "YES"', '"ENABLE_HARDENED_RUNTIME": "NO", "ENABLE_HARDENED_RUNTIME": "YES"'),
        ):
            with self.subTest(original=original):
                result = self.run_cli(valid.replace(original, replacement, 1))
                self.assertEqual(result.returncode, 1)
                self.assertIn("duplicate key", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_mismatch_fails_without_echoing_arbitrary_value_or_partial_success(self):
        payload = fixture()
        payload[-1]["buildSettings"]["MACOSX_DEPLOYMENT_TARGET"] = "PRIVATE-BUILD-PATH"
        result = self.run_cli(json.dumps(payload))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("QuickFileTests minimum macOS version", result.stderr)
        self.assertNotIn("PRIVATE-BUILD-PATH", result.stderr)

    def test_target_order_and_additional_targets_do_not_change_checks(self):
        payload = list(reversed(fixture())) + [{"target": "OtherTarget", "buildSettings": {}}]
        self.assertEqual(MODULE.verify_settings(payload, "13.0"), MODULE.verify_settings(fixture(), "13.0"))

    def test_expected_macos_version_is_supplied_by_readiness_script(self):
        payload = fixture()
        for entry in payload:
            entry["buildSettings"]["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
        self.assertEqual(self.run_cli(json.dumps(payload), version="14.0").returncode, 0)
        self.assertEqual(self.run_cli(json.dumps(payload)).returncode, 1)


if __name__ == "__main__":
    unittest.main()
