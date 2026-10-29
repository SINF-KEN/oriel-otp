#!/bin/bash
#
# Regenerates the Apple Watch screenshots in docs/screenshots.
#
# Builds the watch app, runs it on a new, empty watch simulator that is deleted afterwards, and takes a screenshot
# of each state. The debug build shows made-up demo accounts with the clock frozen (OrielOTPWatch/DemoMode.swift),
# so the screenshots only change when the UI does.
#
# Usage: tools/watch-screenshots.sh
#   DEVICE_TYPE  simulator device type, e.g. "Apple Watch Ultra 3 (49mm)" (default: the newest 46mm Apple Watch Series)
#   OUTPUT       where to write the screenshots (default: docs/screenshots)
#
# For App Store Connect, which takes one watch size and scales it for the others:
#   DEVICE_TYPE="Apple Watch Ultra 3 (49mm)" OUTPUT=build/app-store/watch tools/watch-screenshots.sh

set -euo pipefail
cd "$(dirname "$0")/.."

output=${OUTPUT:-docs/screenshots}
bundle_id=io.github.sinf-ken.OrielOTP.watchkitapp
# 2027-01-01 00:00:12 UTC, the same moment as the iPhone screenshots.
demo_date=1798761612
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The newest watchOS runtime that has the device type. Runtimes list their device types newest first.
read -r runtime device_type_id DEVICE_TYPE < <(xcrun simctl list runtimes -j | jq -r --arg name "${DEVICE_TYPE:-}" '
    [.runtimes[] | select(.platform == "watchOS" and .isAvailable) | . as $runtime
     | [.supportedDeviceTypes[] | select(if $name == "" then .name | test("^Apple Watch Series [0-9]+ \\(46mm\\)$") else .name == $name end)][0]
     | select(. != null) | [$runtime.version, $runtime.identifier, .identifier, .name]]
    | sort_by(.[0] | split(".") | map(tonumber)) | last | select(. != null) | .[1:] | join(" ")')
if [[ -z "${runtime:-}" ]]; then
    echo "No watchOS runtime has the simulator ${DEVICE_TYPE:-Apple Watch Series (46mm)}. Install one with: xcodebuild -downloadPlatform watchOS" >&2
    exit 1
fi

udid=$(xcrun simctl create "Oriel OTP watch screenshots" "$device_type_id" "$runtime")
trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true; xcrun simctl delete "$udid" || true; rm -rf "$work"' EXIT
echo "Taking screenshots on $DEVICE_TYPE ($runtime)"

xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" >/dev/null

xcodebuild build -project Authenticator.xcodeproj -scheme OrielOTPWatch -destination "id=$udid" \
    -derivedDataPath "$work/DerivedData" -quiet
xcrun simctl install "$udid" "$work/DerivedData/Build/Products/Debug-watchsimulator/OrielOTPWatch.app"

mkdir -p "$work/screenshots"
# Launches the app with the given arguments and saves a screenshot once it has drawn.
shoot() {
    local name=$1
    shift
    xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$bundle_id" -DemoDate "$demo_date" "$@" >/dev/null
    sleep 4
    xcrun simctl io "$udid" screenshot --type=png "$work/screenshots/$name.png" >/dev/null
}
shoot watch-accounts -DemoAccounts YES
shoot watch-wrist-down -DemoAccounts YES -DemoLuminanceReduced YES
shoot watch-empty -DemoAccounts NO

mkdir -p "$output"
for new in "$work"/screenshots/*.png; do
    old="$output/$(basename "$new")"
    if cmp -s "$new" "$old"; then
        continue
    fi
    cp "$new" "$old"
    echo "Updated $old"
done
