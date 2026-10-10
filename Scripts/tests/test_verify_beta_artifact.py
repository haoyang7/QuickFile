import datetime as dt
import importlib.util
import io
import plistlib
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "verify-beta-artifact.py"
SPEC = importlib.util.spec_from_file_location("verify_beta_artifact", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class FakeRunner:
    def __init__(self, certificate="Developer ID Application: Example", profile_days=30, enabled=True, accepted=True, notarized=True, override=None, architectures=None, teams=None, groups=None, profile_groups=None, profile_app_ids=None, signing_app_ids=None, entitlement_overrides=None, all_devices=False, devices=1, device_lists=None, leaf_certificate=b"FAKE-LEAF", profile_certificates=None, certificate_extraction="success", runtime_flags=None):
        self.certificate = certificate
        self.profile_days = profile_days
        self.enabled = enabled
        self.accepted = accepted
        self.notarized = notarized
        self.override = override
        self.architectures = architectures or {"QuickFile": "arm64 x86_64", "FinderExtension": "arm64 x86_64"}
        self.teams = teams or {"QuickFile.app": "TEAM", "FinderExtension.appex": "TEAM"}
        self.groups = groups or {"QuickFile.app": [MODULE.EXPECTED_APP_GROUP], "FinderExtension.appex": [MODULE.EXPECTED_APP_GROUP]}
        self.profile_groups = profile_groups or {"QuickFile.app": [MODULE.EXPECTED_APP_GROUP], "FinderExtension.appex": [MODULE.EXPECTED_APP_GROUP]}
        self.profile_app_ids = profile_app_ids or {
            "QuickFile.app": "TEAM.com.haoyoung.QuickFile",
            "FinderExtension.appex": "TEAM.com.haoyoung.QuickFile.FinderExtension",
        }
        self.signing_app_ids = signing_app_ids if signing_app_ids is not None else {
            "QuickFile.app": f"{self.teams['QuickFile.app']}.{MODULE.EXPECTED_APP_ID}",
            "FinderExtension.appex": f"{self.teams['FinderExtension.appex']}.{MODULE.EXPECTED_EXTENSION_ID}",
        }
        self.entitlement_overrides = entitlement_overrides or {}
        self.all_devices = all_devices
        self.devices = devices
        self.device_lists = device_lists
        self.leaf_certificate = leaf_certificate
        self.profile_certificates = [leaf_certificate] if profile_certificates is None else profile_certificates
        self.certificate_extraction = certificate_extraction
        self.runtime_flags = runtime_flags or {}

    def run(self, arguments):
        path = Path(arguments[-1])
        if arguments[:2] == ["/usr/bin/codesign", "--verify"]:
            return MODULE.CommandResult(0)
        if arguments[:3] == ["/usr/bin/codesign", "-d", "--verbose=4"]:
            identifier = MODULE.EXPECTED_EXTENSION_ID if path.name.endswith(".appex") else MODULE.EXPECTED_APP_ID
            text = f"Identifier={identifier}\nAuthority={self.certificate}\nTeamIdentifier={self.teams[path.name]}\n"
            flags = self.runtime_flags.get(path.name, "0x10000(runtime)")
            if flags is not None:
                text += f"CodeDirectory v=20500 flags={flags}\n"
            text += "Executable Segment flags=0x0\n"
            return MODULE.CommandResult(0, stderr=text.encode())
        if arguments[:3] == ["/usr/bin/codesign", "-d", "--entitlements"]:
            entitlements = {
                "com.apple.security.application-groups": self.groups[path.name],
                "com.apple.security.app-sandbox": True,
                "com.apple.security.files.bookmarks.app-scope": True,
            }
            signing_app_id = self.signing_app_ids.get(path.name)
            if signing_app_id is not None:
                entitlements["com.apple.application-identifier"] = signing_app_id
            if path.name == "QuickFile.app":
                entitlements["com.apple.security.files.user-selected.read-write"] = True
            entitlements.update(self.entitlement_overrides.get(path.name, {}))
            return MODULE.CommandResult(0, stdout=plistlib.dumps(entitlements))
        if arguments[:2] == ["/usr/bin/codesign", "-d"] and arguments[2].startswith("--extract-certificates="):
            if self.certificate_extraction == "error":
                return MODULE.CommandResult(-1, error="unavailable")
            if self.certificate_extraction == "rejected":
                return MODULE.CommandResult(1)
            if self.certificate_extraction == "missing":
                return MODULE.CommandResult(0)
            prefix = arguments[2].partition("=")[2]
            Path(f"{prefix}0").write_bytes(self.leaf_certificate)
            return MODULE.CommandResult(0)
        if arguments[:2] == ["/usr/bin/lipo", "-archs"]:
            return MODULE.CommandResult(0, stdout=self.architectures[path.name].encode())
        if arguments[:3] == ["/usr/bin/security", "cms", "-D"]:
            expiration = NOW + dt.timedelta(days=self.profile_days)
            bundle_name = "FinderExtension.appex" if "PlugIns" in path.parts else "QuickFile.app"
            device_values = self.device_lists[bundle_name] if self.device_lists else [f"device-{index}" for index in range(self.devices)]
            profile = {
                "ExpirationDate": expiration,
                "ProvisionedDevices": device_values,
                "ProvisionsAllDevices": self.all_devices,
                "Entitlements": {
                    "com.apple.security.application-groups": self.profile_groups[bundle_name],
                    "com.apple.application-identifier": self.profile_app_ids[bundle_name],
                },
                "TeamIdentifier": [self.teams[bundle_name]],
                "DeveloperCertificates": self.profile_certificates,
                "UUID": "SECRET-PROFILE-UUID",
            }
            return MODULE.CommandResult(0, stdout=plistlib.dumps(profile))
        if arguments == ["/usr/sbin/spctl", "--status"]:
            word = "enabled" if self.enabled else "disabled"
            return MODULE.CommandResult(0, stdout=f"assessments {word}".encode())
        if arguments[:2] == ["/usr/sbin/spctl", "--assess"]:
            lines = ["accepted" if self.accepted else "rejected"]
            if self.notarized:
                lines.append("source=Notarized Developer ID")
            if self.override:
                lines.append(f"override={self.override}")
            return MODULE.CommandResult(0 if self.accepted else 1, stderr="\n".join(lines).encode())
        raise AssertionError(arguments)


NOW = dt.datetime(2026, 9, 26, 4, 0, tzinfo=dt.timezone.utc)


class ArtifactFixture:
    def __init__(self, profiles=False):
        self.temporary = tempfile.TemporaryDirectory()
        self.app = Path(self.temporary.name) / "QuickFile.app"
        extension = self.app / "Contents/PlugIns/FinderExtension.appex"
        self._bundle(self.app, MODULE.EXPECTED_APP_ID, "QuickFile", profiles)
        self._bundle(extension, MODULE.EXPECTED_EXTENSION_ID, "FinderExtension", profiles)

    def _bundle(self, path, identifier, executable, profile):
        (path / "Contents/MacOS").mkdir(parents=True)
        plist = {
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": executable,
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "LSMinimumSystemVersion": "13.0",
        }
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
        (path / "Contents/MacOS" / executable).touch()
        if profile:
            (path / "Contents/embedded.provisionprofile").touch()

    def close(self):
        self.temporary.cleanup()


class VerifyBetaArtifactTests(unittest.TestCase):
    def inspect(self, runner=None, mode="developer-id", profiles=False):
        fixture = ArtifactFixture(profiles=profiles)
        self.addCleanup(fixture.close)
        return MODULE.inspect_artifact(fixture.app, mode, runner or FakeRunner(), NOW)

    def status(self, report, name):
        return next(check["status"] for check in report["checks"] if check["name"] == name)

    def test_successful_developer_id_fixture(self):
        report = self.inspect(profiles=True)
        self.assertEqual(report["verdict"], "pass")
        self.assertNotIn("Developer ID Application: Example", str(report))

    def test_minimum_system_version_requires_exact_string_in_both_modes(self):
        for mode, certificate in (("developer-id", "Developer ID Application: Example"),
                                  ("registered-devices", "Apple Development: Example")):
            report = self.inspect(FakeRunner(certificate=certificate), mode, profiles=True)
            self.assertEqual(report["verdict"], "pass")
            for label in ("app", "finder_extension"):
                self.assertEqual(self.status(report, f"{label}.minimum_system_version"), "pass")
                self.assertEqual(report["components"][label]["minimum_system_version"], "13.0")

    def test_invalid_minimum_system_versions_fail_each_component_in_both_modes(self):
        # Expected diagnostics preserve safe inputs, including their scalar type.
        # None means the plist key is missing; plistlib does not encode None.
        cases = (
            ("13.0.1", "13.0.1"), ("13.0.999", "13.0.999"),
            ("13.0.0", "13.0.0"), ("13", "13"), ("013.0", "013.0"),
            ("13.00", "13.00"), ("12.0", "12.0"), ("14.0", "14.0"),
            (13, 13), (13.0, 13.0), (True, "invalid"),
            (None, "invalid"), ("", "invalid"), ("13..0", "invalid"),
            ("13.0\n", "invalid"), (" 13.0", "invalid"), ("13.0beta", "invalid"),
            ("/Users/PRIVATE_MINIMUM", "invalid"),
            (["PRIVATE_MINIMUM"], "invalid"), ({"PRIVATE_MINIMUM": "13.0"}, "invalid"),
            (b"PRIVATE_MINIMUM", "invalid"), (float("nan"), "invalid"),
            (float("inf"), "invalid"),
        )
        bundles = (("app", "Contents/Info.plist"),
                   ("finder_extension", "Contents/PlugIns/FinderExtension.appex/Contents/Info.plist"))
        for mode, certificate in (("developer-id", "Developer ID Application: Example"),
                                  ("registered-devices", "Apple Development: Example")):
            for label, relative in bundles:
                other_label = "finder_extension" if label == "app" else "app"
                for minimum, expected in cases:
                    with self.subTest(mode=mode, component=label, minimum=minimum):
                        fixture = ArtifactFixture(profiles=True)
                        try:
                            info_path = fixture.app / relative
                            info = plistlib.loads(info_path.read_bytes())
                            if minimum is None:
                                info.pop("LSMinimumSystemVersion")
                            else:
                                info["LSMinimumSystemVersion"] = minimum
                            info_path.write_bytes(plistlib.dumps(info))
                            report = MODULE.inspect_artifact(
                                fixture.app, mode, FakeRunner(certificate=certificate), NOW,
                            )
                        finally:
                            fixture.close()
                        self.assertEqual(report["verdict"], "fail")
                        self.assertEqual(self.status(report, f"{label}.minimum_system_version"), "fail")
                        self.assertEqual(self.status(report, f"{other_label}.minimum_system_version"), "pass")
                        actual = report["components"][label]["minimum_system_version"]
                        self.assertIs(type(actual), type(expected))
                        self.assertEqual(actual, expected)
                        self.assertEqual(report["components"][other_label]["minimum_system_version"], "13.0")
                        self.assertNotIn("PRIVATE_MINIMUM", str(report))

    def test_app_and_extension_each_require_hardened_runtime_in_both_modes(self):
        components = {"QuickFile.app": "app", "FinderExtension.appex": "finder_extension"}
        for mode, certificate in (("developer-id", "Developer ID Application: Example"),
                                  ("registered-devices", "Apple Development: Example")):
            positive = self.inspect(FakeRunner(certificate=certificate), mode, profiles=True)
            self.assertEqual(positive["verdict"], "pass")
            for disabled in (("QuickFile.app",), ("FinderExtension.appex",), tuple(components)):
                with self.subTest(mode=mode, disabled=disabled):
                    report = self.inspect(FakeRunner(
                        certificate=certificate,
                        runtime_flags={bundle: "0x0(none)" for bundle in disabled},
                    ), mode, profiles=True)
                    self.assertEqual(report["verdict"], "fail")
                    for bundle, label in components.items():
                        self.assertEqual(self.status(positive, f"{label}.hardened_runtime"), "pass")
                        self.assertEqual(self.status(report, f"{label}.hardened_runtime"),
                                         "fail" if bundle in disabled else "pass")

    def test_missing_or_malformed_runtime_flags_fail_closed_for_each_component(self):
        for bundle, label in (("QuickFile.app", "app"), ("FinderExtension.appex", "finder_extension")):
            for flags in (None, "invalid", "0x0(runtime)"):
                with self.subTest(bundle=bundle, flags=flags):
                    report = self.inspect(FakeRunner(runtime_flags={bundle: flags}), profiles=True)
                    self.assertEqual(report["verdict"], "fail")
                    self.assertEqual(self.status(report, f"{label}.hardened_runtime"), "fail")

    def test_unavailable_signature_metadata_cannot_pass_runtime_gate(self):
        for bundle, label in (("QuickFile.app", "app"), ("FinderExtension.appex", "finder_extension")):
            for result in (MODULE.CommandResult(-1, error="unavailable"), MODULE.CommandResult(1)):
                with self.subTest(bundle=bundle, returncode=result.returncode):
                    class Runner(FakeRunner):
                        def run(self, arguments):
                            if arguments[:3] == ["/usr/bin/codesign", "-d", "--verbose=4"] and Path(arguments[-1]).name == bundle:
                                return result
                            return super().run(arguments)

                    report = self.inspect(Runner(), profiles=True)
                    self.assertEqual(report["verdict"], "fail")
                    self.assertEqual(self.status(report, f"{label}.hardened_runtime"), "unknown")

    def test_disabled_assessments_reject_even_if_artifact_says_accepted(self):
        report = self.inspect(FakeRunner(enabled=False, accepted=True), profiles=True)
        self.assertEqual(report["verdict"], "fail")
        self.assertEqual(self.status(report, "gatekeeper.artifact_assessment"), "fail")

    def test_assessment_override_rejects_even_if_notarized_and_accepted(self):
        report = self.inspect(FakeRunner(override="security disabled"), profiles=True)
        self.assertEqual(self.status(report, "gatekeeper.artifact_assessment"), "fail")

    def test_accepted_without_notarized_source_fails(self):
        report = self.inspect(FakeRunner(notarized=False), profiles=True)
        self.assertEqual(self.status(report, "gatekeeper.artifact_assessment"), "fail")

    def test_wrong_certificate_fails(self):
        report = self.inspect(FakeRunner(certificate="Apple Development: Person"), profiles=True)
        self.assertEqual(self.status(report, "distribution.certificate_kind"), "fail")

    def test_registered_profile_expiring_before_eight_days_fails(self):
        report = self.inspect(FakeRunner(certificate="Apple Development: Person", profile_days=7.9), "registered-devices", profiles=True)
        self.assertEqual(report["verdict"], "fail")
        self.assertEqual(self.status(report, "app.profile_validity"), "fail")

    def test_expired_profile_fails(self):
        report = self.inspect(FakeRunner(certificate="Apple Development: Person", profile_days=-1), "registered-devices", profiles=True)
        self.assertEqual(self.status(report, "finder_extension.profile_validity"), "fail")

    def test_registered_devices_are_not_reported_as_universal(self):
        report = self.inspect(FakeRunner(certificate="Apple Development: Person", profile_days=9, devices=1), "registered-devices", profiles=True)
        self.assertEqual(report["verdict"], "pass")
        self.assertEqual(report["device_scope"], "registered devices only")
        self.assertEqual(report["profiles"][0]["device_count"], 1)
        self.assertFalse(report["profiles"][0]["all_devices"])
        serialized = str(report)
        self.assertNotIn("device-0", serialized)
        self.assertNotIn("SECRET-PROFILE-UUID", serialized)

    def test_mismatched_team_fails(self):
        report = self.inspect(FakeRunner(teams={"QuickFile.app": "A", "FinderExtension.appex": "B"}), profiles=True)
        self.assertEqual(self.status(report, "signing.same_team"), "fail")

    def test_mismatched_app_group_fails(self):
        report = self.inspect(FakeRunner(groups={"QuickFile.app": [MODULE.EXPECTED_APP_GROUP], "FinderExtension.appex": ["wrong.group"]}), profiles=True)
        self.assertEqual(self.status(report, "finder_extension.app_group"), "fail")

    def test_profile_must_authorize_signed_app_group(self):
        report = self.inspect(FakeRunner(profile_groups={"QuickFile.app": [MODULE.EXPECTED_APP_GROUP], "FinderExtension.appex": ["wrong.group"]}), profiles=True)
        self.assertEqual(self.status(report, "distribution.profile_app_group"), "fail")

    def test_profile_must_authorize_corresponding_application_identifier(self):
        report = self.inspect(FakeRunner(profile_app_ids={"QuickFile.app": "TEAM.com.other.App", "FinderExtension.appex": "TEAM.com.haoyoung.QuickFile.FinderExtension"}), profiles=True)
        self.assertEqual(self.status(report, "distribution.profile_application_identifier"), "fail")

    def test_signed_application_identifier_must_match_team_and_bundle(self):
        wrong = self.inspect(FakeRunner(signing_app_ids={"QuickFile.app": "TEAM.com.other.App", "FinderExtension.appex": "TEAM.com.haoyoung.QuickFile.FinderExtension"}, profile_app_ids={"QuickFile.app": "TEAM.com.other.App", "FinderExtension.appex": "TEAM.com.haoyoung.QuickFile.FinderExtension"}), profiles=True)
        self.assertEqual(self.status(wrong, "app.signature_application_identifier"), "fail")

        missing = self.inspect(FakeRunner(signing_app_ids={"QuickFile.app": None, "FinderExtension.appex": "TEAM.com.haoyoung.QuickFile.FinderExtension"}), profiles=True)
        self.assertEqual(self.status(missing, "app.signature_application_identifier"), "fail")

        correct = self.inspect(FakeRunner(), profiles=True)
        self.assertEqual(self.status(correct, "app.signature_application_identifier"), "pass")
        self.assertEqual(self.status(correct, "finder_extension.signature_application_identifier"), "pass")

    def test_profile_must_contain_actual_signing_leaf_certificate(self):
        report = self.inspect(FakeRunner(leaf_certificate=b"CURRENT", profile_certificates=[b"OLD-SAME-TEAM"]), profiles=True)
        self.assertEqual(self.status(report, "app.profile_leaf_certificate"), "fail")
        self.assertNotIn("CURRENT", str(report))
        self.assertNotIn("OLD-SAME-TEAM", str(report))

    def test_missing_or_unreadable_extracted_leaf_certificate_fails(self):
        missing = self.inspect(FakeRunner(certificate_extraction="missing"), profiles=True)
        self.assertEqual(self.status(missing, "finder_extension.profile_leaf_certificate"), "fail")
        unavailable = self.inspect(FakeRunner(certificate_extraction="error"), profiles=True)
        self.assertEqual(self.status(unavailable, "app.profile_leaf_certificate"), "unknown")

    def test_matching_leaf_certificate_passes(self):
        report = self.inspect(FakeRunner(leaf_certificate=b"CURRENT", profile_certificates=[b"OTHER", b"CURRENT"]), profiles=True)
        self.assertEqual(self.status(report, "app.profile_leaf_certificate"), "pass")
        self.assertEqual(self.status(report, "finder_extension.profile_leaf_certificate"), "pass")

    def test_legal_terminal_wildcard_application_identifier_passes(self):
        report = self.inspect(FakeRunner(profile_app_ids={"QuickFile.app": "TEAM.com.haoyoung.*", "FinderExtension.appex": "TEAM.com.haoyoung.QuickFile.*"}), profiles=True)
        self.assertEqual(report["verdict"], "pass")

    def test_non_prefixed_app_group_requires_embedded_profiles(self):
        report = self.inspect(FakeRunner())
        self.assertEqual(self.status(report, "distribution.embedded_profiles"), "fail")

    def test_minimum_validity_is_configurable(self):
        fixture = ArtifactFixture(profiles=True)
        self.addCleanup(fixture.close)
        report = MODULE.inspect_artifact(fixture.app, "developer-id", FakeRunner(profile_days=2), NOW, min_valid_days=1)
        self.assertEqual(report["verdict"], "pass")

    def test_rounded_remaining_days_cannot_cross_validity_boundary(self):
        report = self.inspect(FakeRunner(profile_days=7.9996), profiles=True)
        self.assertEqual(self.status(report, "app.profile_validity"), "fail")

    def test_non_finite_minimum_validity_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory, redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                MODULE.main(["QuickFile.app", "--output", str(Path(directory) / "report.json"), "--min-valid-days", "nan"])
        self.assertEqual(raised.exception.code, 2)

    def test_required_sandbox_and_file_entitlements(self):
        report = self.inspect(FakeRunner(entitlement_overrides={"QuickFile.app": {"com.apple.security.app-sandbox": False}}), profiles=True)
        self.assertEqual(self.status(report, "app.entitlement.app-sandbox"), "fail")

        report = self.inspect(FakeRunner(entitlement_overrides={"FinderExtension.appex": {"com.apple.security.files.bookmarks.app-scope": False}}), profiles=True)
        self.assertEqual(self.status(report, "finder_extension.entitlement.files_bookmarks_app-scope"), "fail")

        report = self.inspect(FakeRunner(entitlement_overrides={"QuickFile.app": {"com.apple.security.files.user-selected.read-write": False}}), profiles=True)
        self.assertEqual(self.status(report, "app.entitlement.files_user-selected_read-write"), "fail")

    def test_registered_profiles_need_common_device_without_disclosing_it(self):
        runner = FakeRunner(
            certificate="Apple Development: Person",
            device_lists={"QuickFile.app": ["APP-DEVICE"], "FinderExtension.appex": ["EXTENSION-DEVICE"]},
        )
        report = self.inspect(runner, "registered-devices", profiles=True)
        self.assertEqual(self.status(report, "distribution.registered_device_intersection"), "fail")
        self.assertEqual(report["registered_device_intersection_count"], 0)
        self.assertNotIn("APP-DEVICE", str(report))
        self.assertNotIn("EXTENSION-DEVICE", str(report))

    def test_missing_architecture_fails(self):
        report = self.inspect(FakeRunner(architectures={"QuickFile": "arm64", "FinderExtension": "arm64 x86_64"}), profiles=True)
        self.assertEqual(self.status(report, "app.architectures"), "fail")

    def test_wrong_bundle_id_fails(self):
        fixture = ArtifactFixture(profiles=True)
        self.addCleanup(fixture.close)
        info_path = fixture.app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier"] = "invalid.bundle"
        info_path.write_bytes(plistlib.dumps(info))
        report = MODULE.inspect_artifact(fixture.app, "developer-id", FakeRunner(), NOW)
        self.assertEqual(self.status(report, "app.bundle_id"), "fail")
        self.assertNotIn("invalid.bundle", str(report))

    def test_invalid_architecture_output_is_redacted(self):
        report = self.inspect(FakeRunner(architectures={"QuickFile": "SECRET_ARCH", "FinderExtension": "arm64 x86_64"}), profiles=True)
        self.assertNotIn("SECRET_ARCH", str(report))

    def test_versions_and_builds_must_match(self):
        fixture = ArtifactFixture(profiles=True)
        self.addCleanup(fixture.close)
        path = fixture.app / "Contents/PlugIns/FinderExtension.appex/Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["CFBundleVersion"] = "43"
        path.write_bytes(plistlib.dumps(info))
        report = MODULE.inspect_artifact(fixture.app, "developer-id", FakeRunner(), NOW)
        self.assertEqual(self.status(report, "components.build_match"), "fail")

    def test_executable_name_is_fixed_and_untrusted_value_is_redacted(self):
        fixture = ArtifactFixture(profiles=True)
        self.addCleanup(fixture.close)
        path = fixture.app / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["CFBundleExecutable"] = "../../SECRET_PATH"
        path.write_bytes(plistlib.dumps(info))
        report = MODULE.inspect_artifact(fixture.app, "developer-id", FakeRunner(), NOW)
        self.assertEqual(self.status(report, "app.executable"), "fail")
        self.assertNotIn("SECRET_PATH", str(report))


class SparkleArtifactTests(unittest.TestCase):
    binary_paths = {
        "framework": "Sparkle",
        "installer": "XPCServices/Installer.xpc/Contents/MacOS/Installer",
        "downloader": "XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
        "autoupdate": "Autoupdate",
        "updater": "Updater.app/Contents/MacOS/Updater",
    }

    class Runner(FakeRunner):
        helper_team = "TEAM"
        helper_runtime = True
        helper_certificate = "Developer ID Application: Test"

        def __init__(self):
            super().__init__(entitlement_overrides={"QuickFile.app": {
                "com.apple.security.temporary-exception.mach-lookup.global-name": [
                    MODULE.EXPECTED_APP_ID + "-spks", MODULE.EXPECTED_APP_ID + "-spki"
                ]
            }})
            self.helper_architecture_results = {}

        def run(self, arguments):
            path = Path(arguments[-1])
            if "Sparkle.framework" in path.parts:
                if arguments[:3] == ["/usr/bin/codesign", "-d", "--verbose=4"]:
                    flags = "0x10000(runtime)" if self.helper_runtime else "0x0(none)"
                    text = f"Identifier=org.sparkle.test\nAuthority={self.helper_certificate}\nTeamIdentifier={self.helper_team}\nCodeDirectory v=20500 flags={flags}\nExecutable Segment flags=0x0\n"
                    return MODULE.CommandResult(0, stderr=text.encode())
                if arguments[:2] == ["/usr/bin/lipo", "-archs"]:
                    if not path.is_file():
                        return MODULE.CommandResult(1)
                    return self.helper_architecture_results.get(path.name, MODULE.CommandResult(0, stdout=b"arm64 x86_64"))
            return super().run(arguments)

    def sparkle_fixture(self):
        fixture = ArtifactFixture(profiles=True)
        self.addCleanup(fixture.close)
        framework = fixture.app / "Contents/Frameworks/Sparkle.framework/Versions/B"
        for relative in self.binary_paths.values():
            binary = framework / relative
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.touch()
        return fixture

    def test_enabled_updates_require_embedded_framework(self):
        fixture = ArtifactFixture(profiles=True)
        self.addCleanup(fixture.close)
        info_path = fixture.app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["QuickFileUpdatesEnabled"] = "YES"
        info_path.write_bytes(plistlib.dumps(info))
        report = MODULE.inspect_artifact(fixture.app, "developer-id", FakeRunner(), NOW)
        self.assertEqual(next(item["status"] for item in report["checks"] if item["name"] == "sparkle.framework_required"), "fail")

    def test_helpers_require_same_team_runtime_and_distribution_certificate(self):
        fixture = self.sparkle_fixture()
        runner = self.Runner()
        self.assertEqual(MODULE.inspect_artifact(fixture.app, "developer-id", runner, NOW)["verdict"], "pass")
        for attribute, value, check in [
            ("helper_team", "OTHER_TEAM", "signing_team"),
            ("helper_runtime", False, "hardened_runtime"),
            ("helper_certificate", "Apple Development: Test", "certificate_kind"),
        ]:
            with self.subTest(attribute=attribute):
                previous = getattr(runner, attribute)
                setattr(runner, attribute, value)
                report = MODULE.inspect_artifact(fixture.app, "developer-id", runner, NOW)
                self.assertEqual(next(item["status"] for item in report["checks"] if item["name"] == f"sparkle.installer.{check}"), "fail")
                self.assertEqual(report["verdict"], "fail")
                setattr(runner, attribute, previous)

    def test_every_sparkle_binary_requires_both_architectures(self):
        fixture = self.sparkle_fixture()
        runner = self.Runner()
        report = MODULE.inspect_artifact(fixture.app, "developer-id", runner, NOW)
        self.assertEqual(report["verdict"], "pass")
        for label, relative in self.binary_paths.items():
            check_name = f"sparkle.{label}.architectures"
            self.assertEqual(next(item["status"] for item in report["checks"] if item["name"] == check_name), "pass")
            for architectures in (b"arm64", b"x86_64"):
                with self.subTest(label=label, architectures=architectures):
                    runner.helper_architecture_results = {Path(relative).name: MODULE.CommandResult(0, stdout=architectures)}
                    thin_report = MODULE.inspect_artifact(fixture.app, "developer-id", runner, NOW)
                    self.assertEqual(next(item["status"] for item in thin_report["checks"] if item["name"] == check_name), "fail")
                    self.assertEqual(thin_report["verdict"], "fail")

    def test_helper_architecture_errors_and_missing_binary_fail_closed(self):
        fixture = self.sparkle_fixture()
        runner = self.Runner()
        for result, status in [
            (MODULE.CommandResult(0, stdout=b"SECRET-PATH"), "fail"),
            (MODULE.CommandResult(1), "fail"),
            (MODULE.CommandResult(-1, error="unavailable"), "unknown"),
        ]:
            with self.subTest(status=status, result=result.stdout):
                runner.helper_architecture_results = {"Installer": result}
                report = MODULE.inspect_artifact(fixture.app, "developer-id", runner, NOW)
                self.assertEqual(next(item["status"] for item in report["checks"] if item["name"] == "sparkle.installer.architectures"), status)
                self.assertEqual(report["verdict"], "fail")
                self.assertNotIn("SECRET-PATH", str(report))
        runner.helper_architecture_results = {}
        binary = fixture.app / "Contents/Frameworks/Sparkle.framework/Versions/B" / self.binary_paths["installer"]
        binary.unlink()
        report = MODULE.inspect_artifact(fixture.app, "developer-id", runner, NOW)
        self.assertEqual(next(item["status"] for item in report["checks"] if item["name"] == "sparkle.installer.architectures"), "fail")
        self.assertEqual(report["verdict"], "fail")


class SignatureMetadataTests(unittest.TestCase):
    def test_runtime_uses_code_directory_flags_and_ignores_executable_segment(self):
        class Runner:
            def __init__(self, flags):
                self.flags = flags

            def run(self, arguments):
                return MODULE.CommandResult(0, stderr=(
                    f"CodeDirectory v=20500 size=550 flags={self.flags} hashes=6+7 location=embedded\n"
                    "Executable Segment flags=0x0\n"
                ).encode())

        for flags, expected in (("0x10000(runtime)", "yes"), ("0x10002(adhoc,runtime)", "yes"), ("0x2(adhoc)", "no")):
            with self.subTest(flags=flags):
                metadata, error = MODULE._signature_metadata(Runner(flags), Path("QuickFile.app"))
                self.assertIsNone(error)
                self.assertEqual(metadata["hardened_runtime"], expected)


if __name__ == "__main__":
    unittest.main()
