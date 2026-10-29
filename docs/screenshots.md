# README screenshots

The screenshots in the README are taken from the app itself, by a UI test that runs in the iOS Simulator. Nobody
has to capture them by hand, and they show the real UI.

## What is in them

The test runs the debug build, which in the simulator connects to a simulated YubiKey
(`Authenticator/Model/Debug/SimulatedYubiKey.swift`) and to a fake Ente server
(`Authenticator/EnteAuth/FakeEnteServer.swift`). All accounts, emails and secrets are made up. No real YubiKey,
Ente account or network connection is used.

Both are wrapped in `#if DEBUG && targetEnvironment(simulator)`, as is the `-DemoDate` launch argument that
freezes the clock (`Authenticator/Model/AppClock.swift`). None of it is compiled into release builds or builds
for a device.

To make the screenshots the same on every run:

- the clock is frozen at 2027-01-01 00:00:12 UTC, so the codes and countdown rings don't change,
- the simulated YubiKey's accounts, salt and serial number are fixed,
- the test runs on a new, empty simulator, in light mode, with the status bar showing 9:41 and full signal and battery.

## Running it locally

```bash
tools/screenshots.sh
```

This needs Xcode and `jq`. The script creates a simulator for the newest iPhone Pro (set `DEVICE_TYPE`, e.g.
`DEVICE_TYPE="iPhone 17 Pro"`, to pick another one), runs `AuthenticatorUITests` with the `Screenshots` scheme and
deletes the simulator again. Screenshots whose bytes changed are copied to `docs/screenshots/`; the others are left
alone.

The test is `AuthenticatorUITests/ScreenshotTests.swift`. To add a screenshot, navigate to the screen there and
call `save("name")`, then add `docs/screenshots/name.png` to the README.

## Apple Watch

The watch screenshots (`watch-*.png`) are taken by `tools/watch-screenshots.sh`, which needs a watchOS simulator
runtime (`xcodebuild -downloadPlatform watchOS`) and `jq`. It builds the watch app, installs it on a new, empty
watch simulator (the newest 46mm Apple Watch Series, or `DEVICE_TYPE`), takes a screenshot of each state with
`simctl io` and deletes the simulator again.

The debug build in the simulator reads launch arguments from `OrielOTPWatch/DemoMode.swift`: `-DemoAccounts YES`
shows made-up accounts instead of the keychain and doesn't talk to the iPhone, `-DemoDate` freezes the clock at the
same moment as the iPhone screenshots, and `-DemoLuminanceReduced YES` shows the wrist down look, which the
simulator can't produce on demand. None of it is compiled into release builds.

The watch simulator doesn't support status bar overrides, so the time in the corner is the time the script ran.
CI doesn't run this script yet.

## In CI

`.github/workflows/screenshots.yml` runs the script when the app, the test or the script changes:

- On pull requests, the screenshots are uploaded as the `screenshots` artifact of the run, so UI changes can be
  looked at before merging.
- On `main`, changed screenshots are committed as "Update the README screenshots" and force-pushed to the
  `bot/screenshots` branch, and the run's summary links to a new pull request from it. `main` only takes pull
  requests and Actions isn't allowed to open them here, so a maintainer opens it, which also runs the required
  `build` check. When nothing changed, nothing is pushed. The workflow can also be started by hand from the
  Actions tab.

Different simulator models and iOS versions render slightly differently, so CI's screenshots are the reference. A
screenshot committed from a different simulator may be replaced by CI's once.
