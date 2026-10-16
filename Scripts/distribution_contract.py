"""Shared on-disk and sandbox contract for QuickFile's outside-store builds."""

import plistlib
import re

APP_ID = "com.haoyoung.QuickFile"
EXTENSION_ID = APP_ID + ".FinderExtension"
STORAGE_MODE = "local-shared"
STORAGE_PATH = "/Library/Application Support/QuickFileCommunity/"
STORAGE_ENTITLEMENT = "com.apple.security.temporary-exception.files.home-relative-path.read-write"
MACH_ENTITLEMENT = "com.apple.security.temporary-exception.mach-lookup.global-name"
IDENTITY_ENTITLEMENTS = (
    "com.apple.application-identifier", "application-identifier", "com.apple.developer.team-identifier",
)
_RELEASE_NUMBER = r"(?:0|[1-9][0-9]{0,17})"
MARKETING_VERSION_PATTERN = rf"{_RELEASE_NUMBER}\.{_RELEASE_NUMBER}\.{_RELEASE_NUMBER}"
_RELEASE_TAG = rf"v({MARKETING_VERSION_PATTERN})(?:-beta\.[1-9][0-9]{{0,17}})?"


def release_tag_version(release_tag: str) -> str:
    match = re.fullmatch(_RELEASE_TAG, release_tag) if isinstance(release_tag, str) else None
    if match is None:
        raise ValueError("release tag must be vVERSION or vVERSION-beta.N with canonical numbers of at most 18 digits and positive N")
    return match[1]


def expected_entitlements(label: str, *, updater: bool = False) -> dict:
    if label not in ("app", "finder_extension"):
        raise ValueError("unknown application component")
    values = {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.files.bookmarks.app-scope": True,
        STORAGE_ENTITLEMENT: [STORAGE_PATH],
    }
    if label == "app":
        values["com.apple.security.files.user-selected.read-write"] = True
        values["com.apple.security.network.client"] = True
        if updater:
            values[MACH_ENTITLEMENT] = [APP_ID + "-spks", APP_ID + "-spki"]
    return values


def exact_entitlements(actual: dict, expected: dict) -> bool:
    # Property-list types matter: Python otherwise considers 1 equal to True.
    return plistlib.dumps(actual, sort_keys=True) == plistlib.dumps(expected, sort_keys=True)


def signed_permissions_match(actual: dict, label: str, *, updater: bool, development: bool) -> bool:
    permissions = dict(actual)
    for key in IDENTITY_ENTITLEMENTS:
        permissions.pop(key, None)  # Checked separately against the actual signing identity.
    for key in ("get-task-allow", "com.apple.security.get-task-allow"):
        if key in permissions:
            if not development or type(permissions.pop(key)) is not bool:
                return False
    if isinstance(permissions.get(MACH_ENTITLEMENT), list):
        services = permissions[MACH_ENTITLEMENT]
        if not all(isinstance(item, str) for item in services):
            return False
        permissions[MACH_ENTITLEMENT] = sorted(services)
    expected = expected_entitlements(label, updater=updater)
    if MACH_ENTITLEMENT in expected:
        expected[MACH_ENTITLEMENT].sort()
    return exact_entitlements(permissions, expected)


def configuration_matches(info: dict, channel: str) -> bool:
    return (info.get("QuickFileStorageMode") == STORAGE_MODE
            and info.get("QuickFileDistributionChannel") == channel)
