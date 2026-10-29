#!/bin/bash
#
# Regenerates the Mac screenshots in docs/screenshots (mac-*.png).
#
# Runs the Screenshots scheme's Mac UI test. The app uses its debug-only simulated YubiKey and fake Ente server, with
# the clock frozen, light appearance and a 1280 × 800 point window, so the screenshots are 2560 × 1600 pixels on a
# Retina display, a Mac App Store size, and only change when the UI does.
#
# The build is signed ad hoc, without the keychain access group that would need a provisioning profile; the
# screenshots don't use the keychain. The first run may ask to allow UI automation.
#
# Usage: tools/screenshots-macos.sh
#   SOURCE_PACKAGES_DIR  already resolved Swift packages to build with, e.g. from CI's cache (default: resolve anew)

set -euo pipefail
cd "$(dirname "$0")/.."

output=docs/screenshots
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

entitlements="$work/Authenticator-macOS.entitlements"
cp Authenticator/Authenticator-macOS.entitlements "$entitlements"
/usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$entitlements"

packages=()
if [[ -n "${SOURCE_PACKAGES_DIR:-}" ]]; then
    packages=(-clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" -disableAutomaticPackageResolution
        -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates)
fi
formatter=(cat)
if command -v xcbeautify >/dev/null; then
    formatter=(xcbeautify ${GITHUB_ACTIONS:+--renderer github-actions})
fi
xcodebuild test \
    -project Authenticator.xcodeproj -scheme Screenshots -destination 'platform=macOS' \
    -only-testing:AuthenticatorUITests/MacScreenshotTests/testScreenshots \
    -derivedDataPath "$work/DerivedData" -resultBundlePath "$work/Screenshots.xcresult" ${packages[@]+"${packages[@]}"} \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS="$entitlements" \
    | "${formatter[@]}"

# The test attaches the screenshots to its result, named "<name>_0_<UUID>.png".
xcrun xcresulttool export attachments --path "$work/Screenshots.xcresult" --output-path "$work/attachments" >/dev/null
mkdir -p "$output"
jq -r '.[].attachments[] | select(.suggestedHumanReadableName | startswith("mac-")) | "\(.exportedFileName) \(.suggestedHumanReadableName)"' \
    "$work/attachments/manifest.json" |
while read -r file name; do
    new="$work/attachments/$file"
    old="$output/${name%%_0_*}.png"
    if cmp -s "$new" "$old"; then
        continue
    fi
    cp "$new" "$old"
    echo "Updated $old"
done
