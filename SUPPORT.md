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
for details. The sync never changes anything in Ente.

**Copying accounts from the YubiKey to Ente.**
A YubiKey never gives its secrets back, so accounts already on it can't be copied. Turn on **Also add to Ente Auth**
when adding an account. It needs **Stay signed in** from **Sync from Ente Auth**. For accounts already on the key,
set up two-factor authentication again in the service's settings with the toggle on.

**Another app can't use the certificate on my YubiKey.**
Under **Configuration > Smart card extension**, add the certificate to the device and allow notifications. When an
app asks for the certificate, tap the notification and enter the YubiKey's PIN.

## Privacy

See the [privacy policy](PRIVACY.md).

Oriel OTP is a fork of Yubico Authenticator for iOS and is not affiliated with or endorsed by Yubico or Ente.
For problems with Ente accounts themselves, contact Ente through [ente.io](https://ente.io).
