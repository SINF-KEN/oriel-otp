# iOS application for OATH with YubiKeys

This app is hosted on the iOS App Store as 
[Yubico Authenticator](https://apps.apple.com/se/app/yubico-authenticator/id1476679808).

See the file LICENSE for copyright and license information.

## OATH functionality

This is an authenticator app compatible with the OATH standard for time and
counter based numeric OTPs, as used by many online services. To store these
credentials and generate the codes, it uses a compatible YubiKey, connected
either via NFC or the Lightning port.

Add credentials by tapping the menu icon, selecting `Add account` and then
either add a credential by scanning a QR code, or by tapping the `Enter manually`
button.

Once credentials have been added, simply tap or connect your YubiKey to display
codes.

## Sync from Ente Auth

Accounts stored in [Ente Auth](https://ente.io/auth) can be copied onto a YubiKey by tapping the menu icon and
selecting `Sync from Ente Auth`. Sign in, pick the accounts and tap `Add`. Everything is decrypted on the device
and nothing is changed in Ente Auth. See [docs/ente-auth.md](docs/ente-auth.md) for how it works.

## CryptTokenKit extension

Besides the OATH functionality this app also support authetication using the CTK extension
functionality provided by Apple. The authentication is handled using certificates stored 
in the Smart card application on the YubiKey.

## Development

This app is developed in Xcode and depends on the
[YubiKit iOS SDK](https://github.com/Yubico/yubikit-ios), and for Ente Auth sync on
[swift-sodium](https://github.com/jedisct1/swift-sodium) (libsodium) and
[BigInt](https://github.com/attaswift/BigInt), all added using the Swift Package Manager. To build the app simply open the project file and hit
the build button.

## Issues

Please report app issues in
[the issue tracker on GitHub](https://github.com/Yubico/yubioath-ios).
