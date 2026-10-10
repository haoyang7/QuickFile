#!/bin/bash
# Build a local, unnotarized community candidate without Apple credentials.
set -euo pipefail

PROJECT_DIRECTORY=$(cd -- "$(dirname -- "$0")/.." && pwd)
if [[ $# -ne 2 || "$1" != "--output" ]]; then
    echo "usage: Scripts/build-community.sh --output NEW_DIRECTORY" >&2
    exit 2
fi
OUTPUT_DIRECTORY=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).absolute())' "$2")
if [[ -e "$OUTPUT_DIRECTORY" || -L "$OUTPUT_DIRECTORY" ]]; then
    echo "error: output already exists; choose a new directory" >&2
    exit 1
fi
command -v xcodegen >/dev/null
command -v xcodebuild >/dev/null
cd -- "$PROJECT_DIRECTORY"
mkdir -p .build/Temporary
TASK_DIRECTORY=$(mktemp -d "$PROJECT_DIRECTORY/.build/Temporary/community-build.XXXXXX")
mkdir "$TASK_DIRECTORY/records"
cleanup() {
    local result=$?
    local cleanup_result=0
    # Retain private build records; only reclaim this invocation's build products.
    python3 - "$TASK_DIRECTORY" "$result" <<'PY' || cleanup_result=$?
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys
root = pathlib.Path(sys.argv[1])
errors = []
registrations = []
register = "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

def run(arguments):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=30)
        registrations.append({"command": arguments, "exit_code": result.returncode,
                              "output": result.stdout + result.stderr})
        if result.returncode:
            errors.append("registration cleanup failed")
    except (OSError, subprocess.SubprocessError) as error:
        errors.append(str(error))

log = root / "records" / "build.log"
registered = log.exists() and "RegisterWithLaunchServices " in log.read_text(errors="replace")
if registered:
    app = root / "DerivedData/Build/Products/Release/QuickFile.app"
    # Xcode registers the host and nested apps. Unregister by owned path; never
    # remove a shared Finder bundle identifier through pluginkit -r.
    nested_apps = (path for path in app.rglob("*.app") if not path.is_symlink())
    for nested in sorted(nested_apps, key=lambda path: len(path.parts), reverse=True):
        run([register, "-u", str(nested)])
    run([register, "-u", str(app)])

    installed = pathlib.Path("/Applications/QuickFile.app")
    extension = installed / "Contents/PlugIns/FinderExtension.appex"
    try:
        if installed.exists():
            info = plistlib.loads((installed / "Contents/Info.plist").read_bytes())
            if info.get("CFBundleIdentifier") == "com.haoyoung.QuickFile":
                run([register, "-f", str(installed)])
                if extension.exists():
                    extension_info = plistlib.loads((extension / "Contents/Info.plist").read_bytes())
                    if extension_info.get("CFBundleIdentifier") == "com.haoyoung.QuickFile.FinderExtension":
                        run(["/usr/bin/pluginkit", "-a", str(extension)])
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        errors.append(str(error))

products = [root / name for name in ("DerivedData", "SourcePackages", "Release.xcresult")]
if not errors:
    for path in products:
        try:
            if path.is_symlink():
                path.unlink()
            elif path.exists():
                shutil.rmtree(path)
        except OSError as error:
            errors.append(str(error))
(root / "records" / "cleanup.json").write_text(json.dumps({
    "build_exit_code": int(sys.argv[2]), "build_products_removed": all(not path.exists() for path in products),
    "registration_actions": registrations, "cleanup_errors": errors,
    "installed": False, "published": False,
}, indent=2) + "\n")
sys.exit(bool(errors))
PY
    echo "Build records: $TASK_DIRECTORY/records"
    if [[ "$result" -eq 0 ]]; then result=$cleanup_result; fi
    exit "$result"
}
trap cleanup EXIT

python3 Scripts/verify-architecture.py
xcodegen generate > "$TASK_DIRECTORY/records/xcodegen.log" 2>&1
PACKAGE_LOCK=QuickFile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
LOCK_HASH=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$PACKAGE_LOCK")
python3 Scripts/resolve-packages.py \
    --xcodebuild "$(command -v xcodebuild)" --project QuickFile.xcodeproj \
    --package-directory "$TASK_DIRECTORY/SourcePackages" \
    --package-lock "$PACKAGE_LOCK" --expected-lock-hash "$LOCK_HASH" \
    > "$TASK_DIRECTORY/records/resolve.log" 2>&1
xcodebuild -project QuickFile.xcodeproj -scheme QuickFile \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$TASK_DIRECTORY/DerivedData" \
    -clonedSourcePackagesDirPath "$TASK_DIRECTORY/SourcePackages" \
    -disableAutomaticPackageResolution \
    -resultBundlePath "$TASK_DIRECTORY/Release.xcresult" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) QUICKFILE_COMMUNITY' \
    OTHER_LDFLAGS='$(inherited) -Wl,-dead_strip_dylibs' \
    QUICKFILE_UPDATES_ENABLED=NO QUICKFILE_UPDATE_FEED_URL= QUICKFILE_UPDATE_PUBLIC_KEY= \
    build > "$TASK_DIRECTORY/records/build.log" 2>&1
python3 - "$PACKAGE_LOCK" "$LOCK_HASH" <<'PY'
import hashlib
import sys
if hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest() != sys.argv[2]:
    raise SystemExit("error: Package.resolved changed during the build")
PY
python3 Scripts/package-community.py \
    --app "$TASK_DIRECTORY/DerivedData/Build/Products/Release/QuickFile.app" \
    --output "$OUTPUT_DIRECTORY"
