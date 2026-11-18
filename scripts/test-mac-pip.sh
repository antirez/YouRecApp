#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in ""|--hardware) ;; *) echo "Usage: $0 [--hardware]" >&2; exit 2 ;; esac
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
build="${YOUREC_PIP_BUILD_DIR:-$PWD/.benchmarks/mac-pip/build}"
destination="platform=macOS,variant=Mac Catalyst,arch=arm64"
xcodebuild build-for-testing -project YouRec.xcodeproj -scheme YouRec -configuration Debug \
    -derivedDataPath "$build" -destination "$destination" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO
products="$build/Build/Products"
plans=("$products"/YouRec_macosx*-arm64.xctestrun)
[[ -f "${plans[0]}" && "${#plans[@]}" == 1 ]]
# Keep the disposable plan beside the original so Xcode resolves __TESTROOT__.
tmp=$(mktemp "$products/.pip-plan.XXXXXXXX")
plan="$tmp.xctestrun"
trap 'rm -f "$tmp" "$plan"' EXIT
cp "${plans[0]}" "$plan"
# Only attach the recorder preview on failure. Never retain a desktop recording.
plist=/usr/libexec/PlistBuddy
"$plist" -c 'Set :YouRecUITests:SystemAttachmentLifetime keepNever' "$plan"
test=YouRecUITests/DesktopPiPUITests/testDraggingAndResizingRecordedInset
if [[ "${1:-}" == --hardware ]]; then
    app="$products/Debug-maccatalyst/YouRec.app"
    mkdir -p "$app/Contents/Frameworks"
    chart="$app/Contents/Frameworks/DesktopPiPChart.dylib"
    if [[ ! -f "$chart" || Tests/DesktopPiPChart.m -nt "$chart" ]]; then
        xcrun --sdk macosx clang -fobjc-arc -dynamiclib -framework AppKit Tests/DesktopPiPChart.m -o "$chart"
        codesign --force --sign - "$chart"
    fi
    if ! codesign --verify --strict "$app" 2>/dev/null; then
        codesign --force --sign - --preserve-metadata=identifier,entitlements,flags "$app"
    fi
    "$plist" -c 'Add :YouRecUITests:EnvironmentVariables:YOUREC_PIP_HARDWARE string 1' "$plan"
    test=YouRecUITests/DesktopPiPUITests
fi
xcodebuild test-without-building -xctestrun "$plan" -destination "$destination" \
    -parallel-testing-enabled NO "-only-testing:$test"
