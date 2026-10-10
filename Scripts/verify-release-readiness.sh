#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
TEST_DERIVED_DATA="${PROJECT_DIRECTORY}/.build/VerificationTests"
RELEASE_DERIVED_DATA="${PROJECT_DIRECTORY}/.build/VerificationRelease"
PACKAGE_DIRECTORY="${PROJECT_DIRECTORY}/.build/VerificationSourcePackages"
PACKAGE_LOCK="${PROJECT_DIRECTORY}/QuickFile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
TEST_ARCH=$(/usr/bin/uname -m)
EXPECTED_APP_BUNDLE_ID="com.haoyoung.QuickFile"
EXPECTED_EXTENSION_BUNDLE_ID="com.haoyoung.QuickFile.FinderExtension"
EXPECTED_APP_GROUP="group.com.haoyoung.QuickFile"
EXPECTED_APP_CATEGORY="public.app-category.utilities"
EXPECTED_MACOS_VERSION="13.0"
APP_ICON_DIRECTORY="${PROJECT_DIRECTORY}/QuickFileApp/Assets.xcassets/AppIcon.appiconset"

XCODEGEN_COMMAND=$(command -v xcodegen || true)
XCODEBUILD_COMMAND=$(command -v xcodebuild || true)

if [[ -z "${XCODEGEN_COMMAND}" ]]; then
    print -u2 -- "error: xcodegen is not available in PATH"
    exit 1
fi

if [[ -z "${XCODEBUILD_COMMAND}" ]]; then
    print -u2 -- "error: xcodebuild is not available in PATH"
    exit 1
fi

cd -- "${PROJECT_DIRECTORY}"

# Give each invocation new, explicit result bundle paths. Never erase a previous
# failure. CI keeps raw bundles runner-local; only synthetic receipts are uploaded.
if [[ -n "${QUICKFILE_RESULT_DIRECTORY:-}" ]]; then
    RESULT_DIRECTORY=$(python3 "${SCRIPT_DIRECTORY}/ci-evidence.py" \
        prepare-results "${QUICKFILE_RESULT_DIRECTORY}")
else
    mkdir -p -- "${PROJECT_DIRECTORY}/.build"
    RESULT_DIRECTORY=$(/usr/bin/mktemp -d "${PROJECT_DIRECTORY}/.build/VerificationResults.XXXXXX")
fi
TEST_RESULT_BUNDLE="${RESULT_DIRECTORY}/tests.xcresult"
RELEASE_RESULT_BUNDLE="${RESULT_DIRECTORY}/release.xcresult"

if [[ ! -f "${PACKAGE_LOCK}" ]]; then
    print -u2 -- "error: committed Package.resolved is missing"
    exit 1
fi
PACKAGE_LOCK_HASH=$(/usr/bin/shasum -a 256 "${PACKAGE_LOCK}" | /usr/bin/awk '{ print $1 }')
print -- "Package.resolved SHA-256: ${PACKAGE_LOCK_HASH}"

# Reuse only pinned dependency sources/artifacts within this verification run.
# Debug and Release build products remain in separate DerivedData directories.
mkdir -p -- "${PACKAGE_DIRECTORY}"

print -- "Checking XcodeGen"
python3 "${SCRIPT_DIRECTORY}/verify-architecture.py"
"${XCODEGEN_COMMAND}" version
"${XCODEGEN_COMMAND}" dump --spec project.yml --type summary

# XcodeGen owns these tracked outputs, but not the SwiftPM resolution lock.
# CI must verify the committed project, not a project repaired by generate.
# Local development commonly starts with intentional uncommitted changes.
XCODEGEN_MANAGED_FILES=(
    "QuickFile.xcodeproj/project.pbxproj"
    "QuickFile.xcodeproj/project.xcworkspace/contents.xcworkspacedata"
    ":(glob)QuickFile.xcodeproj/xcshareddata/xcschemes/*.xcscheme"
    "QuickFileApp/Info.plist"
    "QuickFileApp/QuickFile.entitlements"
    "FinderExtension/Info.plist"
    "FinderExtension/FinderExtension.entitlements"
)
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    if ! git diff --quiet HEAD -- "${XCODEGEN_MANAGED_FILES[@]}"; then
        print -u2 -- "error: XcodeGen-managed files must be clean before CI generation"
        git diff --name-only HEAD -- "${XCODEGEN_MANAGED_FILES[@]}"
        exit 1
    fi
fi
"${XCODEGEN_COMMAND}" generate
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    if ! git diff --quiet HEAD -- "${XCODEGEN_MANAGED_FILES[@]}"; then
        print -u2 -- "error: committed XcodeGen outputs are out of sync with project.yml"
        git diff --name-only HEAD -- "${XCODEGEN_MANAGED_FILES[@]}"
        exit 1
    fi
fi

verify_plist_value() {
    local plist_path=$1
    local key_path=$2
    local expected_value=$3
    local label=$4
    local actual_value

    actual_value=$(/usr/libexec/PlistBuddy -c "Print ${key_path}" "${plist_path}")
    print -- "${label}: ${actual_value}"

    if [[ "${actual_value}" != "${expected_value}" ]]; then
        print -u2 -- "error: ${label} expected ${expected_value}, got ${actual_value}"
        exit 1
    fi
}

verify_plist_value \
    "QuickFileApp/QuickFile.entitlements" \
    ":com.apple.security.application-groups:0" \
    "${EXPECTED_APP_GROUP}" \
    "QuickFile App Group entitlement"
verify_plist_value \
    "FinderExtension/FinderExtension.entitlements" \
    ":com.apple.security.application-groups:0" \
    "${EXPECTED_APP_GROUP}" \
    "FinderExtension App Group entitlement"
verify_plist_value \
    "QuickFileApp/QuickFile.entitlements" \
    ":com.apple.security.files.bookmarks.app-scope" \
    "true" \
    "QuickFile app-scoped bookmark entitlement"
verify_plist_value \
    "FinderExtension/FinderExtension.entitlements" \
    ":com.apple.security.files.bookmarks.app-scope" \
    "true" \
    "FinderExtension app-scoped bookmark entitlement"

# Explicitly resolve pinned packages before any settings, test or build command.
# SwiftPM retains responsibility for binary artifact downloads and checksums.
python3 "${SCRIPT_DIRECTORY}/resolve-packages.py" \
    --xcodebuild "${XCODEBUILD_COMMAND}" \
    --project QuickFile.xcodeproj \
    --package-directory "${PACKAGE_DIRECTORY}" \
    --package-lock "${PACKAGE_LOCK}" \
    --expected-lock-hash "${PACKAGE_LOCK_HASH}"

# Query the project once for all thirteen assertions. pipefail keeps Xcode failures
# fatal even if it emitted valid JSON before exiting; the verifier prints only
# the checked settings, never the full build-settings payload.
"${XCODEBUILD_COMMAND}" \
    -project QuickFile.xcodeproj \
    -clonedSourcePackagesDirPath "${PACKAGE_DIRECTORY}" \
    -disableAutomaticPackageResolution \
    -alltargets \
    -configuration Release \
    -showBuildSettings \
    -json \
    CODE_SIGNING_ALLOWED=NO \
    | python3 "${SCRIPT_DIRECTORY}/verify-build-settings.py" \
        --expected-macos-version "${EXPECTED_MACOS_VERSION}"

verify_icon_image() {
    local filename=$1
    local expected_size=$2
    local image_path="${APP_ICON_DIRECTORY}/${filename}"
    local actual_width
    local actual_height

    if [[ ! -f "${image_path}" ]]; then
        print -u2 -- "error: missing app icon image ${filename}"
        exit 1
    fi

    actual_width=$(/usr/bin/sips -g pixelWidth "${image_path}" | /usr/bin/awk '/pixelWidth/ { print $2 }')
    actual_height=$(/usr/bin/sips -g pixelHeight "${image_path}" | /usr/bin/awk '/pixelHeight/ { print $2 }')
    print -- "App icon ${filename}: ${actual_width}x${actual_height}"

    if [[ "${actual_width}" != "${expected_size}" || "${actual_height}" != "${expected_size}" ]]; then
        print -u2 -- "error: ${filename} expected ${expected_size}x${expected_size}, got ${actual_width}x${actual_height}"
        exit 1
    fi
}

verify_icon_image "icon_16x16.png" "16"
verify_icon_image "icon_16x16@2x.png" "32"
verify_icon_image "icon_32x32.png" "32"
verify_icon_image "icon_32x32@2x.png" "64"
verify_icon_image "icon_128x128.png" "128"
verify_icon_image "icon_128x128@2x.png" "256"
verify_icon_image "icon_256x256.png" "256"
verify_icon_image "icon_256x256@2x.png" "512"
verify_icon_image "icon_512x512.png" "512"
verify_icon_image "icon_512x512@2x.png" "1024"

# This macOS hosted XCTest run does not consume IDE indexing data.
# Keep testability, diagnostics, debug info and all test/build validations intact.
print -- "Running ${TEST_ARCH} unit tests"
"${XCODEBUILD_COMMAND}" \
    -project QuickFile.xcodeproj \
    -clonedSourcePackagesDirPath "${PACKAGE_DIRECTORY}" \
    -disableAutomaticPackageResolution \
    -scheme QuickFile \
    -showBuildTimingSummary \
    -hideShellScriptEnvironment \
    -configuration Debug \
    -destination "platform=macOS,arch=${TEST_ARCH}" \
    -derivedDataPath "${TEST_DERIVED_DATA}" \
    -resultBundlePath "${TEST_RESULT_BUNDLE}" \
    CODE_SIGNING_ALLOWED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    ONLY_ACTIVE_ARCH=YES \
    test

print -- "Building unsigned universal Release"
"${XCODEBUILD_COMMAND}" \
    -project QuickFile.xcodeproj \
    -clonedSourcePackagesDirPath "${PACKAGE_DIRECTORY}" \
    -disableAutomaticPackageResolution \
    -scheme QuickFile \
    -showBuildTimingSummary \
    -hideShellScriptEnvironment \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${RELEASE_DERIVED_DATA}" \
    -resultBundlePath "${RELEASE_RESULT_BUNDLE}" \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS='arm64 x86_64' \
    build

APP_BUNDLE="${RELEASE_DERIVED_DATA}/Build/Products/Release/QuickFile.app"
EXTENSION_BUNDLE="${APP_BUNDLE}/Contents/PlugIns/FinderExtension.appex"
APP_BINARY="${APP_BUNDLE}/Contents/MacOS/QuickFile"
EXTENSION_BINARY="${EXTENSION_BUNDLE}/Contents/MacOS/FinderExtension"

verify_plist_value \
    "${APP_BUNDLE}/Contents/Info.plist" \
    ":CFBundleIdentifier" \
    "${EXPECTED_APP_BUNDLE_ID}" \
    "QuickFile Bundle ID"
verify_plist_value \
    "${EXTENSION_BUNDLE}/Contents/Info.plist" \
    ":CFBundleIdentifier" \
    "${EXPECTED_EXTENSION_BUNDLE_ID}" \
    "FinderExtension Bundle ID"
verify_plist_value \
    "${APP_BUNDLE}/Contents/Info.plist" \
    ":LSMinimumSystemVersion" \
    "${EXPECTED_MACOS_VERSION}" \
    "QuickFile minimum macOS version"
verify_plist_value \
    "${EXTENSION_BUNDLE}/Contents/Info.plist" \
    ":LSMinimumSystemVersion" \
    "${EXPECTED_MACOS_VERSION}" \
    "FinderExtension minimum macOS version"
verify_plist_value \
    "${APP_BUNDLE}/Contents/Info.plist" \
    ":CFBundleIconName" \
    "AppIcon" \
    "QuickFile compiled app icon"
verify_plist_value \
    "${APP_BUNDLE}/Contents/Info.plist" \
    ":LSApplicationCategoryType" \
    "${EXPECTED_APP_CATEGORY}" \
    "QuickFile application category"

if [[ ! -f "${APP_BUNDLE}/Contents/Resources/AppIcon.icns" ]]; then
    print -u2 -- "error: compiled AppIcon.icns is missing from QuickFile.app"
    exit 1
fi
print -- "QuickFile compiled icon resource: AppIcon.icns"

verify_architectures() {
    local binary_path=$1
    local product_name=$2
    local architectures

    architectures=$(/usr/bin/lipo -archs "${binary_path}")
    print -- "${product_name} architectures: ${architectures}"

    if [[ " ${architectures} " != *" arm64 "* || " ${architectures} " != *" x86_64 "* ]]; then
        print -u2 -- "error: ${product_name} is not a universal arm64/x86_64 binary"
        exit 1
    fi
}

verify_architectures "${APP_BINARY}" "QuickFile"
verify_architectures "${EXTENSION_BINARY}" "FinderExtension"

SPARKLE_FRAMEWORK="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
verify_architectures "${SPARKLE_FRAMEWORK}/Versions/B/Sparkle" "Sparkle"
for helper in \
    "Autoupdate" \
    "Updater.app/Contents/MacOS/Updater" \
    "XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "XPCServices/Downloader.xpc/Contents/MacOS/Downloader"; do
    verify_architectures "${SPARKLE_FRAMEWORK}/Versions/B/${helper}" "Sparkle ${helper}"
done
verify_plist_value "${APP_BUNDLE}/Contents/Info.plist" ":QuickFileUpdatesEnabled" "NO" "Default offline update configuration"
verify_plist_value "${APP_BUNDLE}/Contents/Info.plist" ":SUEnableInstallerLauncherService" "true" "Sparkle installer service"
verify_plist_value "${APP_BUNDLE}/Contents/Info.plist" ":SUEnableDownloaderService" "true" "Sparkle downloader service"
verify_plist_value "${APP_BUNDLE}/Contents/Info.plist" ":SUEnableAutomaticChecks" "false" "Automatic update checks default"
verify_plist_value "${APP_BUNDLE}/Contents/Info.plist" ":SUAllowsAutomaticUpdates" "false" "User-confirmed update installation"
verify_plist_value "${APP_BUNDLE}/Contents/Info.plist" ":SUSendProfileInfo" "false" "System profiling disabled"
APP_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_BUNDLE}/Contents/Info.plist")
verify_plist_value "${EXTENSION_BUNDLE}/Contents/Info.plist" ":CFBundleVersion" "${APP_BUILD}" "Matching extension build"

FINAL_PACKAGE_LOCK_HASH=$(/usr/bin/shasum -a 256 "${PACKAGE_LOCK}" | /usr/bin/awk '{ print $1 }')
if [[ "${FINAL_PACKAGE_LOCK_HASH}" != "${PACKAGE_LOCK_HASH}" ]]; then
    print -u2 -- "error: Package.resolved changed during verification"
    exit 1
fi
print -- "Package.resolved unchanged"
print -- "Unsigned release readiness verification passed"
