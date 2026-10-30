# Oriel OTP support

Oriel OTP shows the one-time codes stored on a YubiKey and can copy accounts from
[Ente Auth](https://ente.io/auth) onto the key. It needs iOS or iPadOS 17 or later and a YubiKey with NFC or USB-C.
YubiKeys can't connect through a Lightning port; on an iPhone with Lightning, use NFC.

## Getting help

Search the [issue tracker](https://github.com/SINF-KEN/oriel-otp/issues) for your problem, or
[open a new issue](https://github.com/SINF-KEN/oriel-otp/issues/new). Please include:

- the iPhone or iPad model and iOS version,
- the YubiKey model and how it connects (NFC or USB-C),
- the Oriel OTP version, shown under **About**,
- what you did, what you expected and what happened instead.

Don't post secrets, QR codes, passwords, PINs or Ente recovery keys in an issue.

## Common questions

**The app doesn't find my YubiKey over NFC.**
Tap **Scan NFC YubiKey** in the account list, or pull the list down. Hold the key flat against the top edge of the
iPhone until the NFC sheet confirms the read. NFC needs an iPhone; iPads don't read NFC tags.

**The app doesn't find my YubiKey over USB-C.**
Unplug the key and plug it in again, and keep the app open. If the key also sends a Yubico OTP when it's plugged in,
you can turn that off under **Configuration > Toggle One-Time Password**.

**The app asks for a password.**
The OATH application on the YubiKey is protected with a password, set in this app or another one. Enter it to see
the codes; you can choose to save it on this device.

**Ente sync doesn't add some accounts.**
Accounts in Ente's trash are left out, and accounts with the same name as one already on the YubiKey are skipped.
Accounts the app can't read are listed with the reason. See [Syncing accounts from Ente Auth](docs/ente-auth.md)
for details. Copying onto the YubiKey doesn't change anything in Ente. Accounts you add, rename, pin or delete
in the app's list while signed in are changed in Ente Auth too.

**An Ente Auth account change was undone.**
If the same account was changed on another device before this one synced, the other device's change wins. Changes
made offline wait on the device and are uploaded at the next sync; a clock next to the account means it hasn't been
uploaded yet.

**Copying accounts from the YubiKey to Ente.**
A YubiKey never gives its secrets back, so accounts already on it can't be copied. Choose **YubiKey and Ente Auth**
under **Save to** when adding an account. It needs **Stay signed in** from **Sync from Ente Auth**. For accounts
already on the key, set up two-factor authentication again in the service's settings and save it to both. The other
way works at any time: **Copy to YubiKey** or **Move to YubiKey** on an Ente Auth account.

**I forgot my app lock code or password.**
It can't be recovered or reset. Delete the app and install it again, which also removes the lock. The accounts are
on your YubiKey and in Ente Auth, not only in the app: sign in to Ente Auth again to get those back. After too many
wrong attempts the app makes you wait before the next one, up to an hour.

**Another app can't use the certificate on my YubiKey.**
Under **Configuration > Smart card extension**, add the certificate to the device and allow notifications. When an
app asks for the certificate, tap the notification and enter the YubiKey's PIN.

## Accessibility

Oriel OTP is made to work with VoiceOver, Voice Control, larger text, dark mode, Increase Contrast, Differentiate
Without Color and Reduce Motion on iPhone, iPad and Mac, and VoiceOver and larger text on Apple Watch. See
[Accessibility](docs/accessibility.md) for what that covers and how it's tested.

If something in the app is hard or impossible to use with the accessibility features you rely on, please
[open an issue](https://github.com/SINF-KEN/oriel-otp/issues/new?labels=accessibility) and say which feature, which
screen and what happened. Barriers are treated as bugs.

## Smart card extension

Certificates in the YubiKey's smart card (PIV) application can be used by other apps on the iPhone or iPad to sign
in and to sign, like any other smart card. The private keys stay on the YubiKey.

1. Open **Configuration > Smart card extension**, and plug in the YubiKey or pull down to scan it over NFC.
2. Tap a certificate under the YubiKey to add it to the device. Certificates already added are listed below it,
   and can be removed there.
3. Allow notifications when asked.
4. When an app asks for the certificate, tap the Oriel OTP notification, enter the YubiKey's PIN and plug in or
   scan the YubiKey. Then go back to the app.

The certificates have to be on the YubiKey already: Oriel OTP doesn't create or import them.

## Privacy

See the [privacy policy](PRIVACY.md).

Oriel OTP is a fork of Yubico Authenticator for iOS and is not affiliated with or endorsed by Yubico or Ente.
For problems with Ente accounts themselves, contact Ente through [ente.io](https://ente.io).
