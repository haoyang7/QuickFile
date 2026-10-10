#!/bin/bash

set -euo pipefail

# Xcode's Code Sign on Copy only signs the outer framework during normal builds.
# Sign the embedded helpers first, then reseal the framework before Xcode signs the app.
# https://sparkle-project.org/documentation/sandboxing/#code-signing
if [[ "${CODE_SIGNING_ALLOWED:-NO}" != "YES" ]]; then
    exit 0
fi

SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:?Missing expanded signing identity}"
SPARKLE_FRAMEWORK="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/Sparkle.framework"
TIMESTAMP_OPTION="--timestamp"
if [[ "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" == "Apple Development:"* || "${SIGNING_IDENTITY}" == "-" ]]; then
    TIMESTAMP_OPTION="--timestamp=none"
fi

sign_component() {
    /usr/bin/codesign --force --sign "${SIGNING_IDENTITY}" --options runtime \
        "${TIMESTAMP_OPTION}" "$@"
}

sign_component "${SPARKLE_FRAMEWORK}/Versions/B/XPCServices/Installer.xpc"
sign_component --preserve-metadata=entitlements "${SPARKLE_FRAMEWORK}/Versions/B/XPCServices/Downloader.xpc"
sign_component "${SPARKLE_FRAMEWORK}/Versions/B/Autoupdate"
sign_component "${SPARKLE_FRAMEWORK}/Versions/B/Updater.app"
sign_component "${SPARKLE_FRAMEWORK}"
