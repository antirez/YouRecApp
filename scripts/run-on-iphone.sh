#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <device-id> [development-team-id]" >&2
    echo "Find devices with: xcrun devicectl list devices" >&2
    echo "Set your signing team in Xcode, or pass its ID as the second argument." >&2
    exit 1
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
device_id="$1"
build_command=(
    xcodebuild
    -project "$project_root/YouRec.xcodeproj"
    -scheme YouRec
    -configuration Debug
    -destination 'generic/platform=iOS'
    -derivedDataPath "$project_root/build"
    -allowProvisioningUpdates
)
if [[ -n "${2:-}" ]]; then
    build_command+=("DEVELOPMENT_TEAM=$2")
fi

"${build_command[@]}" build

app="$project_root/build/Build/Products/Debug-iphoneos/YouRec.app"
bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist")
xcrun devicectl device install app --device "$device_id" "$app"

xcrun devicectl device process launch \
    --device "$device_id" \
    "$bundle_id"
