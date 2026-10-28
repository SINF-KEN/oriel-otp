# Maintaining the fork

The work is split so that everything that could go upstream stays separate from what only makes sense for the
fork.

| Branch | Based on | Contains | Goes to |
| --- | --- | --- | --- |
| `main` | Yubico's `main` | Upstream plus general improvements | Yubico |
| `feature/ente-auth-sync` | `main` | Batch add API and Ente Auth sync, with Yubico branding | Yubico, as a pull request |
| `fork/oriel-otp` | `feature/ente-auth-sync` | Only the rebranding commits | The Oriel OTP app |

## Repositories

| Remote | Repository | Holds |
| --- | --- | --- |
| `origin` | [Yubico/yubioath-ios](https://github.com/Yubico/yubioath-ios) | Upstream |
| `fork` | [SINF-KEN/yubioath-ios](https://github.com/SINF-KEN/yubioath-ios) | `main` and `feature/ente-auth-sync`, for pull requests to Yubico |
| `oriel` | [SINF-KEN/oriel-otp](https://github.com/SINF-KEN/oriel-otp) | `fork/oriel-otp` as `main`, `feature/ente-auth-sync`, and `simulator-demo` |

`simulator-demo` is `main` plus debug-only tooling for the simulator: a simulated YubiKey, a fake Ente server
at `https://demo.ente.test` (any email, password `demo`) and a menu item that acts like scanning a YubiKey's NFC
OTP. It is all inside `#if DEBUG && targetEnvironment(simulator)` and never goes into `main`. Rebase it onto
`main` after updating the app.

Publishing the app branch:

```bash
git push oriel fork/oriel-otp:main
```

The rebranding is a few commits that touch identifiers, assets and a handful of strings, so it rebases with few
conflicts:

```bash
git fetch origin
git rebase origin/main main
git rebase main feature/ente-auth-sync
git rebase --onto feature/ente-auth-sync feature/ente-auth-sync@{1} fork/oriel-otp
```

The last step uses `--onto` with the feature branch's previous position (`@{1}`, from the reflog), so only the
fork's own commits move. A plain `git rebase feature/ente-auth-sync fork/oriel-otp` would also replay the old copies
of the feature commits once they have been rewritten, and conflict with the new ones.

Put new features and fixes on `main` or a feature branch, never on `fork/oriel-otp`, so they stay upstreamable.

## What the rebranding changes

- Name: Oriel OTP, on the home screen, in About and in the version history.
- Identifiers: bundle ids, app group, keychain group and URL scheme under `io.github.sinf-ken`. The Yubico team
  ids are removed, so set your own team in Xcode before running on a device.
- `applinks:my.yubico.com` is removed, since only Yubico's app can claim that domain. Tapping a YubiKey's NFC
  OTP link opens Safari instead of the app.
- App icons: a lock on a shield, in pink or dark, instead of the Yubico logo, and the Yubico wordmark in the navigation bar is
  replaced by the app name.
- Colors: taken from the icon. The accent, `YubiBlue` and `YubiGreen` (names kept to keep the diff small) are
  crimson `#B2001F` in light mode and blush `#FFBFCB` in dark mode. The 16 account avatar colors are soft
  rose-centred pastels in light mode, where the letter is black, and deep jewel tones in dark mode, where it is
  white, all at the same perceived lightness so none stands out. Every pair keeps at least 7.9:1 contrast.
- About: terms, privacy policy, user guide and support point to this repository.

## What stays, and why

- The Apache 2.0 `LICENSE` and the `Copyright (C) Yubico` headers. The license requires keeping them, and
  modified files carry an additional copyright line.
- "YubiKey" and "Yubico OTP" where they name the hardware or its OTP protocol, the drawings of YubiKey models
  and the link to Yubico's smart card documentation. These describe what the app works with; [NOTICE](../NOTICE)
  states there is no affiliation.
- `com.yubico.ylp`, the accessory protocol of Lightning YubiKeys, which the app needs to talk to them.
- Release notes of earlier Yubico versions in `VersionHistory.plist`.

To pick another name, search for `Oriel OTP`, `OrielOTP`, `orielotp` and `sinf-ken`.
