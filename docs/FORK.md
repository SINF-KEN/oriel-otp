# The fork

Oriel OTP started as a fork of Yubico's [yubioath-ios](https://github.com/Yubico/yubioath-ios). It's now developed
on its own: [SINF-KEN/oriel-otp](https://github.com/SINF-KEN/oriel-otp) is the only remote, changes go to `main`
through pull requests, and nothing is rebased onto Yubico's `main` or sent upstream any more. Earlier, the work was
split into an upstreamable `main`, a `feature/ente-auth-sync` branch and a `fork/oriel-otp` branch with only the
rebranding; that split was dropped once the app had diverged too far for it to be useful.

The debug-only tooling for the simulator lives on `main`: a simulated YubiKey, a fake Ente server at
`https://demo.ente.test` (any email, password `demo`), a menu item that acts like scanning a YubiKey's NFC OTP,
and a clock that can be frozen. It is all inside `#if DEBUG && (targetEnvironment(simulator) || os(macOS))`, and on
the Mac only switched on with the `-SimulatedYubiKey YES` launch argument. It is used to take the README screenshots
(see [screenshots.md](screenshots.md)).

## What the rebranding changes

- Name: Oriel OTP, on the home screen, in About and in the version history.
- Identifiers: bundle ids, app group, keychain group and URL scheme under `io.github.sinf-ken`. The Yubico team
  ids are removed, so set your own team in Xcode before running on a device.
- `applinks:my.yubico.com` is removed, since only Yubico's app can claim that domain. Tapping a YubiKey's NFC
  OTP link opens Safari instead of the app.
- Lightning: the `com.yubico.ylp` accessory protocol is removed. Apple only accepts it from apps on Yubico's MFi
  product plan, so iPhones with a Lightning port reach the YubiKey over NFC instead.
- App icons: a lock on a shield, in pink or dark, instead of the Yubico logo, and the Yubico wordmark in the navigation bar is
  replaced by the app name.
- Colors: taken from the icon. The accent, `YubiBlue` and `YubiGreen` (names kept to keep the diff small) are
  crimson `#B2001F` in light mode and blush `#FFBFCB` in dark mode. The 16 account avatar colors are soft
  rose-centred pastels in light mode, where the letter is black, and deep jewel tones in dark mode, where it is
  white, all at the same perceived lightness so none stands out. Every pair keeps at least 7.9:1 contrast.
- About: terms, privacy policy, user guide and support point to this repository.
- Artwork: the YubiKey photos and drawings, the tutorial images and the key symbol are replaced by the app's own
  drawings. Yubico's release notes are removed and the version starts at 1.0.

## What stays, and why

- The Apache 2.0 `LICENSE` and the `Copyright (C) Yubico` headers. The license requires keeping them, and
  modified files carry an additional copyright line.
- "YubiKey" and "Yubico OTP" where they name the hardware or its OTP protocol, and the link to Yubico's smart
  card documentation. These describe what the app works with; [NOTICE](../NOTICE)
  states there is no affiliation.

To pick another name, search for `Oriel OTP`, `OrielOTP`, `orielotp` and `sinf-ken`.
