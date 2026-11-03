#!/bin/bash
#
# Regenerates the README screenshots in docs/screenshots, or runs the iPhone UI tests and accessibility audits.
#
# Runs the Screenshots scheme's UI tests on a new, empty simulator that is deleted afterwards. The app uses its
# debug-only simulated YubiKey and fake Ente server, with the clock frozen, so the screenshots only change when
# the UI does.
#
#   screenshots  only the screenshots, in about half a minute after the build
#   audits       the tap to copy tests and the accessibility audits: in light mode, at the largest text size, right to
#                left, in dark mode and with Increase Contrast. They take about 13 minutes.
#
# Usage: tools/screenshots.sh [screenshots] [audits]   (default: screenshots)
#   DEVICE_TYPE  simulator device type, e.g. "iPhone 17 Pro" (default: the newest iPhone Pro)
#   SOURCE_PACKAGES_DIR  already resolved Swift packages to build with, e.g. from CI's cache (default: resolve anew)
#   RESULT_BUNDLE_PATH  where to keep the tests' result bundles, e.g. to look at a failure (default: not kept). Each
#                       run of the tests adds its name: Screenshots.xcresult becomes Screenshots-<name>.xcresult.

set -euo pipefail
cd "$(dirname "$0")/.."

groups=("$@")
if [[ ${#groups[@]} -eq 0 ]]; then
    groups=(screenshots)
fi
for group in "${groups[@]}"; do
    case "$group" in
        screenshots|audits) ;;
        *) echo "Unknown group $group, expected screenshots or audits" >&2; exit 1 ;;
    esac
done

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
echo "Testing ${groups[*]} on $DEVICE_TYPE ($runtime)"

# A new simulator's first boot takes minutes on a CI runner, so it boots while the app builds.
xcrun simctl boot "$udid"

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
# The app is optimized: signing in to the fake Ente server runs 4096-bit SRP, which the unoptimized build took long
# enough over on CI for the test to give up.
xcodebuild build-for-testing \
    -project OrielOTP.xcodeproj -scheme Screenshots -destination "id=$udid" \
    -derivedDataPath "$work/DerivedData" ${packages[@]+"${packages[@]}"} \
    SWIFT_OPTIMIZATION_LEVEL=-O | "${formatter[@]}"

xcrun simctl bootstatus "$udid" >/dev/null
xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100

# Runs tests with the simulator in light or dark mode, with Increase Contrast enabled or disabled. The audits that
# need dark mode or Increase Contrast skip themselves unless they're told it's on.
run() {
    local name=$1 appearance=$2 increase_contrast=$3
    shift 3
    local only=()
    for test in "$@"; do
        only+=(-only-testing:"OrielOTPUITests/$test")
    done
    xcrun simctl ui "$udid" appearance "$appearance"
    xcrun simctl ui "$udid" increase_contrast "$increase_contrast"
    # xcodebuild passes TEST_RUNNER_ variables to the test without the prefix. A test that fails runs once more: on a
    # busy CI runner the simulator has taken minutes to answer a UI query; a real failure, like an accessibility issue,
    # fails both times.
    TEST_RUNNER_SCREENSHOT_DIR="$work/screenshots" TEST_RUNNER_APPEARANCE="$appearance" \
    TEST_RUNNER_INCREASE_CONTRAST="$increase_contrast" xcodebuild test-without-building \
        -project OrielOTP.xcodeproj -scheme Screenshots -destination "id=$udid" \
        -derivedDataPath "$work/DerivedData" ${packages[@]+"${packages[@]}"} "${only[@]}" \
        -retry-tests-on-failure -test-iterations 2 \
        ${RESULT_BUNDLE_PATH:+-resultBundlePath "${RESULT_BUNDLE_PATH%.xcresult}-$name.xcresult"} \
        | "${formatter[@]}"
}

for group in "${groups[@]}"; do
    case "$group" in
        screenshots)
            run screenshots light disabled ScreenshotTests
            mkdir -p "$output"
            for new in "$work"/screenshots/*.png; do
                old="$output/$(basename "$new")"
                if cmp -s "$new" "$old"; then
                    continue
                fi
                cp "$new" "$old"
                echo "Updated $old"
            done
            ;;
        audits)
            # The dark mode and Increase Contrast audits skip themselves here.
            run audits light disabled TapToCopyTests AccessibilityAuditTests
            run dark dark disabled AccessibilityAuditTests/testDarkAppearance
            run increased-contrast-light light enabled AccessibilityAuditTests/testIncreasedContrast
            run increased-contrast-dark dark enabled AccessibilityAuditTests/testIncreasedContrast
            ;;
    esac
done
