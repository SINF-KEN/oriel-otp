# Oriel OTP

Oriel OTP is an iOS and iPadOS authenticator that keeps your one-time password accounts on a YubiKey instead of
on your phone. It can also **import your accounts from [Ente Auth](https://ente.io/auth)**, so moving them onto a
hardware key takes a few taps instead of re-scanning every QR code.

<p align="center">
  <img src="docs/screenshots/accounts.png" width="250" alt="The account list with codes from a YubiKey">
  &nbsp;
  <img src="docs/screenshots/account-details.png" width="250" alt="The details of one account">
  &nbsp;
  <img src="docs/screenshots/ente-accounts.png" width="250" alt="Choosing which Ente Auth accounts to add to the YubiKey">
</p>

The screenshots are taken from the app in the simulator, with made-up demo accounts. See
[docs/screenshots.md](docs/screenshots.md).

## Features

- **OATH codes on a YubiKey.** Time-based (TOTP) and counter-based (HOTP) codes, as used by most online services.
  The secrets are stored on the YubiKey and the codes are calculated there; the app doesn't keep a copy.
- **Ente Auth import.** Sign in to Ente Auth, pick accounts and add them to the YubiKey. Accounts already on the
  key are skipped, and accounts the key can't store are listed with the reason.
- **Adding accounts.** Scan a QR code or enter the details by hand. Accounts can require a touch of the YubiKey
  before a code is shown.
- **Everyday use.** Search, pin favorites, copy codes, rename and delete accounts, Steam codes, and an optional
  password for the YubiKey's OATH application.
- **CryptoTokenKit.** Certificates in the YubiKey's PIV (smart card) application can be used to sign in to apps
  and websites through iOS, in the same way as other smart cards.

## Compatibility

| | |
| --- | --- |
| System | iOS and iPadOS 17 or later, on iPhone and iPad |
| YubiKey | A YubiKey with the OATH application, such as the YubiKey 5 Series. The Security Key Series and YubiKey Bio don't have it. |
| NFC | On iPhone, by holding an NFC YubiKey (e.g. YubiKey 5 NFC) to the top of the phone |
| USB-C | On iPhones and iPads with a USB-C port, e.g. with a YubiKey 5C NFC |
| Lightning | On iPhones and iPads with a Lightning port, with a YubiKey 5Ci |

## Importing from Ente Auth

Open the menu in the account list and choose **Sync from Ente Auth**, or tap the same button shown when the list is
empty. Pick the accounts and tap **Add**. A YubiKey holds a fixed number of accounts, so the sheet shows how much
room is left, only selects as many accounts as fit, and warns when the selection is too big.

The import works in one direction only: accounts are read from Ente Auth and copied onto the YubiKey. Nothing is
created, changed or deleted in your Ente vault, and accounts you later remove from Ente stay on the YubiKey until you
delete them there.

Everything is decrypted on the device. Your Ente password never leaves it, and by default nothing is stored once
the sheet is closed. Self-hosted Ente servers are supported. [docs/ente-auth.md](docs/ente-auth.md) describes how
the sign in and decryption work.

## Security and privacy

- The app has no analytics or advertising and doesn't send your data to the developer.
- OATH secrets live on the YubiKey. The app only writes them to the key when you add an account.
- A YubiKey password is only saved in the keychain if you choose to. Staying signed in to Ente Auth is optional,
  and the saved session is protected by Face ID, Touch ID or the device passcode.
- The only network connections are to Ente's server, or your own, during an Ente Auth import.

See the [privacy policy](PRIVACY.md) for the details.

## Development

The app is developed in Xcode. Open `Authenticator.xcodeproj` and run the `Authenticator` scheme. It depends on
the [YubiKit SDK](https://github.com/Yubico/yubikit-swift), and for Ente Auth import on
[swift-sodium](https://github.com/jedisct1/swift-sodium) (libsodium) and
[BigInt](https://github.com/attaswift/BigInt), all added with the Swift Package Manager.

Debug builds in the simulator connect to a simulated YubiKey with demo accounts and can sign in to a fake Ente
server at `https://demo.ente.test` with any email and the password `demo`. None of this is compiled into release
builds. [docs/screenshots.md](docs/screenshots.md) explains how the README screenshots are regenerated, and
[docs/ci.md](docs/ci.md) what CI checks.

## About this fork

Oriel OTP is a fork of [Yubico Authenticator for iOS](https://github.com/Yubico/yubioath-ios). It is not affiliated
with or endorsed by Yubico or Ente; see [NOTICE](NOTICE). [docs/FORK.md](docs/FORK.md) describes how the fork is
kept in step with upstream and what the rebranding changes.

## License

Oriel OTP is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for the copyright and license
information, and [NOTICE](NOTICE) for attribution.

## Support

See [SUPPORT.md](SUPPORT.md) for help, and report problems in
[the issue tracker on GitHub](https://github.com/SINF-KEN/oriel-otp/issues).
