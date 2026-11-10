# CI

The workflows are in `.github/workflows`:

| Workflow | Runs | Does |
| --- | --- | --- |
| `OrielOTPTests` (`swift.yml`) | Pull requests, pushes to `main`, tag pushes | Builds, lints and tests; its `build` job is the required check |
| `TestFlight` (`testflight.yml`) | After `OrielOTPTests` passes for a push to `main`, or by hand | Uploads the iPhone and Mac builds, see [testflight.md](testflight.md) |
| `Screenshots` (`screenshots.yml`) | Pushes to `main` that change the app, or by hand | Regenerates the README screenshots, see [screenshots.md](screenshots.md) |
| `Accessibility` (`accessibility.yml`) | By hand | Accessibility audits on an iPhone and an iPad, see [accessibility.md](accessibility.md) |

Every action is pinned to a commit SHA, with its version in a comment, and Dependabot (`.github/dependabot.yml`)
updates the actions and the Swift packages weekly. The macOS jobs run on GitHub-hosted `xcode-27` runners.

## Branch protection

`main` requires a pull request (with no required approvals), the `build` status check, and the branch to be up to
date with `main` before merging. It isn't enforced for administrators (`enforce_admins` is off), so the owner can
still push or merge past it.

## OrielOTPTests

A newer push to a pull request cancels its run in progress; runs for `main` and tags always finish. Release builds are
tagged, so the workflow tests the tag push and doesn't also run for the `release` event.

- **`changes`** lists a pull request's files. If they're all documentation (`docs/`, top-level `*.md`, `LICENSE`,
  `NOTICE`) or `.github/dependabot.yml`, the macOS jobs are skipped. Pushes always build.
- **`dependency-review`** runs on pull requests and fails on a vulnerability of moderate severity or higher in a
  changed dependency.
- **`test`** (iOS):
  1. Lints a few files with `swift-format --strict`. The older files don't follow the configuration, so the lint is
     limited to the files listed in the workflow rather than reformatting the whole repository.
  2. Validates the project file, plists, entitlements, privacy manifests and schemes, checks that every
     `Package.resolved` pin has a 40-character revision, and that the 10 targets' configurations keep complete strict
     concurrency checking and warnings as errors.
  3. Checks the translations' format specifiers with `tools/check-format-specifiers.py`: every translation, plural
     form and substitution must read its key's arguments with the same types, and no others.
  4. Picks the `iPhone 17` simulator with the newest iOS runtime and resolves the Swift packages (below).
  5. Builds the app, its extensions, the embedded watch app and the tests with `xcodebuild build-for-testing`, with
     code coverage, while the simulator is still shut down.
  6. Boots the simulator, runs the tests with `xcodebuild test-without-building`, and shuts the simulator down.
  7. Prints a summary of the result bundle and fails if `EnteLoginFlow.swift` drops below 50% line coverage or
     `TokenResponseStore.swift` below 90%.
  8. Uploads the result bundle, the logs and the summary for 7 days, also when a step failed.

  The simulator boots only after the build. Its first boot on a fresh runner takes most of the machine for minutes:
  when it started before the build, `xcodebuild` took 3 to 8 minutes to start and the build 7 to 11 minutes, against
  under 4 for the macOS job's build. Both builds print `-showBuildTimingSummary`, which lists where the build time
  went.
- **`test-macos`**, on a second runner at the same time: builds the watch app on its own for the watchOS simulator,
  so a watchOS-only failure shows as such, then runs the unit tests on macOS. There's no provisioning profile, so the
  Mac build is signed ad hoc with a copy of the Mac entitlements without the keychain access group, the app group
  and AutoFill; the keychain tests skip themselves without the access group. See [macos.md](macos.md).
- **`build`** always runs and is the required check. It passes only if `changes` passed, dependency review passed
  (on pull requests), and both test jobs passed, or both were skipped for a documentation-only change.

Both test builds pass `SWIFT_OPTIMIZATION_LEVEL=-O`. The Ente sign-in tests run 4096-bit SRP with BigInt against the
in-process fake server, and an unoptimized BigInt takes long enough for their requests to time out. `DEBUG` and
testability stay on. The optimized Mac app has no debug dylib, so its hardened runtime would refuse the ad hoc test
bundle; the Mac test build turns the hardened runtime off.

### Running the tests locally

Pass the same setting to a local run, or those tests fail with "The request timed out":

```sh
xcodebuild test -project OrielOTP.xcodeproj -scheme OrielOTP \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OrielOTPTests SWIFT_OPTIMIZATION_LEVEL=-O
```

The project can't set this for Debug: Xcode builds Swift packages with their own default settings, so the project's
and the schemes' settings don't reach BigInt (a Debug build with the project set to `-O` still compiles BigInt with
`-Onone`); only a setting on the `xcodebuild` command line does. Testing from Xcode (⌘U) has the same timeouts.

Run the Mac tests only in CI or with the ad hoc signing above: the Mac Debug build has its own bundle ID, but a build
signed with the team still shares the installed app's keychain items and app group (see [macos.md](macos.md)).

## Swift packages

`.github/actions/swift-packages` resolves the packages pinned in `Package.resolved` into `$RUNNER_TEMP/SourcePackages`,
with automatic resolution and updates turned off, for every workflow that builds.

- **Cache.** Only the checkouts, `artifacts` and `workspace-state.json` (about 45 MB) are cached, keyed by the runner
  OS, the Xcode build version and the SHA-256 of `Package.resolved` (computed with `shasum` rather than `hashFiles()`,
  which has timed out on a busy runner). SwiftPM's mirrors aren't cached: yubikit-swift's alone is about 580 MB, which
  took longer to restore than to clone. DerivedData isn't cached. The TestFlight upload doesn't use the cache at all.
- **Verification.** A cache can hold whatever a run saved under its key, so after resolving, the action checks the
  files that will be built, whether they came from the cache or not:
  - `workspace-state.json` must list the pinned revisions, the checkouts folder must hold exactly the pinned
    packages, and no package may have downloaded an artifact.
  - Each checkout's files are hashed into a Git tree and compared with the tree of the pinned commit. Only that
    commit object is fetched from the package's repository (`git fetch --depth=1 --filter=tree:0`), and Git checks
    that it hashes to the pinned revision. Any changed, added or removed file fails the step.
  - swift-sodium ships libsodium prebuilt, as `Clibsodium.xcframework` in its repository. Its SHA-256 (of the
    `shasum -a 256` list of its files, sorted by path) is recorded in the action as `CLIBSODIUM_SHA256`, so a
    swift-sodium update fails until the new binary has been looked at and the value updated.

BigInt is pinned to a commit rather than a release: `96fb3b17` ("Bump minimum watchOS to 9", attaswift/BigInt#140)
fixes a deployment target warning in the watch build, which the warnings-as-errors setting turns into an error, and
it's newer than the latest release, 6.0.1. Move the pin to a release tag once one includes it.

## TestFlight, Screenshots and Accessibility

- **TestFlight** runs in the `testflight` environment and clones the packages instead of restoring the cache. The
  signing keychain and App Store Connect key are only on the runner for the steps that need them. See
  [testflight.md](testflight.md).
- **Screenshots** runs the iPhone (`tools/screenshots.sh`) and Mac (`tools/screenshots-macos.sh`) screenshot tests
  on two runners, and pushes changed screenshots to the `bot/screenshots` branch for a pull request.
- **Accessibility** runs the accessibility audits and tap to copy tests (`tools/screenshots.sh audits`) on an iPhone
  and an iPad, in several appearances and text sizes.
