#!/bin/bash
#
# Regenerates the README screenshots in docs/screenshots.
#
# Runs the Screenshots scheme's UI test on a new, empty simulator that is deleted afterwards. The app uses its
# debug-only simulated YubiKey and fake Ente server, with the clock frozen, so the screenshots only change when
# the UI does.
#
# Usage: tools/screenshots.sh
#   DEVICE_TYPE  simulator device type, e.g. "iPhone 17 Pro" (default: the newest iPhone Pro)
#   SOURCE_PACKAGES_DIR  already resolved Swift packages to build with, e.g. from CI's cache (default: resolve anew)

set -euo pipefail
cd "$(dirname "$0")/.."

output=docs/screenshots
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The newest iOS runtime that has the device type. Runtimes list their device types newest first.
read -r runtime device_type_id DEVICE_TYPE < <(xcrun simctl list runtimes -j | jq -r --arg name "${DEVICE_TYPE:-}" '
    [.runtimes[] | select(.platform == "iOS" and .isAvailable) | . as $runtime
     | [.supportedDeviceTypes[] | select(if $name == "" then .name | test("^iPhone [0-9]+ Pro$") else .name == $name end)][0]
     | select(. != null) | [$runtime.version, $runtime.identifier, .identifier, .name]]
    | sort_by(.[0] | split(".") | map(tonumber)) | last | select(. != null) | .[1:] | join(" ")')
if [[ -z "${runtime:-}" ]]; then
    echo "No iOS runtime has the simulator ${DEVICE_TYPE:-iPhone Pro}" >&2
    exit 1
fi

udid=$(xcrun simctl create "Oriel OTP screenshots" "$device_type_id" "$runtime")
trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true; xcrun simctl delete "$udid" || true; rm -rf "$work"' EXIT
echo "Taking screenshots on $DEVICE_TYPE ($runtime)"

xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" >/dev/null
xcrun simctl ui "$udid" appearance light
xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100

mkdir -p "$work/screenshots"
formatter=(cat)
if command -v xcbeautify >/dev/null; then
    formatter=(xcbeautify ${GITHUB_ACTIONS:+--renderer github-actions})
fi
packages=()
if [[ -n "${SOURCE_PACKAGES_DIR:-}" ]]; then
    packages=(-clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" -disableAutomaticPackageResolution
        -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates)
fi
# xcodebuild passes TEST_RUNNER_ variables to the test without the prefix.
TEST_RUNNER_SCREENSHOT_DIR="$work/screenshots" xcodebuild test \
    -project OrielOTP.xcodeproj -scheme Screenshots -destination "id=$udid" \
    -derivedDataPath "$work/DerivedData" ${packages[@]+"${packages[@]}"} | "${formatter[@]}"

mkdir -p "$output"
for new in "$work"/screenshots/*.png; do
    old="$output/$(basename "$new")"
    if cmp -s "$new" "$old"; then
        continue
    fi
    cp "$new" "$old"
    echo "Updated $old"
done
