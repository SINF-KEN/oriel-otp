# Maintaining the fork

The work is split so that everything that could go upstream stays separate from what only makes sense for the
fork.

| Branch | Based on | Contains | Goes to |
| --- | --- | --- | --- |
| `main` | Yubico's `main` | Upstream plus general improvements | Yubico |
| `feature/ente-auth-sync` | `main` | Batch add API and Ente Auth sync, with Yubico branding | Yubico, as a pull request |
| `fork/keyotp` | `feature/ente-auth-sync` | Only the rebranding commits | The KeyOTP app |

The rebranding is a few commits that touch identifiers, assets and a handful of strings, so it rebases with few
conflicts:

```bash
git fetch origin
git rebase origin/main main
git rebase main feature/ente-auth-sync
git rebase --onto feature/ente-auth-sync feature/ente-auth-sync@{1} fork/keyotp
```

The last step uses `--onto` with the feature branch's previous position (`@{1}`, from the reflog), so only the
fork's own commits move. A plain `git rebase feature/ente-auth-sync fork/keyotp` would also replay the old copies
of the feature commits once they have been rewritten, and conflict with the new ones.

Put new features and fixes on `main` or a feature branch, never on `fork/keyotp`, so they stay upstreamable.

## What the rebranding changes

- Name: KeyOTP, on the home screen, in About and in the version history.
- Identifiers: bundle ids, app group, keychain group and URL scheme under `io.github.sinf-ken`. The Yubico team
  ids are removed, so set your own team in Xcode before running on a device.
- `applinks:my.yubico.com` is removed, since only Yubico's app can claim that domain. Tapping a YubiKey's NFC
  OTP link opens Safari instead of the app.
- App icons: a key on indigo instead of the Yubico logo, and the Yubico wordmark in the navigation bar is
  replaced by the app name. The brand colors `YubiBlue` and `YubiGreen` keep their names, to keep the diff
  small, but are indigo.
- About: terms, privacy policy, user guide and support point to this repository.

## What stays, and why

- The Apache 2.0 `LICENSE` and the `Copyright (C) Yubico` headers. The license requires keeping them, and
  modified files carry an additional copyright line.
- "YubiKey" and "Yubico OTP" where they name the hardware or its OTP protocol, the drawings of YubiKey models
  and the link to Yubico's smart card documentation. These describe what the app works with; [NOTICE](../NOTICE)
  states there is no affiliation.
- `com.yubico.ylp`, the accessory protocol of Lightning YubiKeys, which the app needs to talk to them.
- Release notes of earlier Yubico versions in `VersionHistory.plist`.

To pick another name, search for `KeyOTP` and `sinf-ken`.
