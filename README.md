# Oriel OTP

An iOS authenticator for OATH codes stored on a YubiKey, with syncing from
[Ente Auth](https://ente.io/auth).

Oriel OTP is a fork of [Yubico Authenticator for iOS](https://github.com/Yubico/yubioath-ios). It is not affiliated
with or endorsed by Yubico or Ente; see [NOTICE](NOTICE). See the file LICENSE for copyright and license
information, and [docs/FORK.md](docs/FORK.md) for how the fork is kept in step with upstream.

## OATH functionality

This is an authenticator app compatible with the OATH standard for time and counter based numeric OTPs, as used
by many online services. The credentials are stored on a YubiKey, which generates the codes. The key connects over
NFC, Lightning or USB-C.

Add a credential with the `+` button in the account list, then scan its QR code or tap `Enter manually`.

Once credentials have been added, plug in the YubiKey, or tap `Scan NFC YubiKey` (or pull the list down) and hold
the key to the iPhone, to show the codes.

## Sync from Ente Auth

Accounts stored in [Ente Auth](https://ente.io/auth) can be copied onto a YubiKey by tapping the menu icon and
selecting `Sync from Ente Auth`, or the same button in the empty account list. Sign in, pick the accounts and tap
`Add`. The sheet shows how much room is left on the YubiKey and only selects as many accounts as fit. Everything is decrypted on the device
and nothing is changed in Ente Auth. See [docs/ente-auth.md](docs/ente-auth.md) for how it works.

## CryptoTokenKit extension

Besides the OATH functionality this app also supports authentication using the CTK extension
functionality provided by Apple. The authentication is handled using certificates stored 
in the Smart card application on the YubiKey.

## Development

This app is developed in Xcode and depends on the
[YubiKit iOS SDK](https://github.com/Yubico/yubikit-ios), and for Ente Auth sync on
[swift-sodium](https://github.com/jedisct1/swift-sodium) (libsodium) and
[BigInt](https://github.com/attaswift/BigInt), all added using the Swift Package Manager. To build the app simply open the project file and hit
the build button.

## Support and privacy

See [SUPPORT.md](SUPPORT.md) for help, and report app issues in
[the issue tracker on GitHub](https://github.com/SINF-KEN/oriel-otp/issues). The privacy policy is in
[PRIVACY.md](PRIVACY.md).
