# App Store Connect

Values and texts for the App Store listing, kept here so they stay in step with the app. See [issue 1](https://github.com/SINF-KEN/oriel-otp/issues/1) for the release
checklist.

## URLs

| Field | Value |
| --- | --- |
| Privacy Policy URL | https://github.com/SINF-KEN/oriel-otp/blob/main/PRIVACY.md |
| Support URL | https://github.com/SINF-KEN/oriel-otp/blob/main/SUPPORT.md |
| Marketing URL (optional) | https://github.com/SINF-KEN/oriel-otp |

The app links to the same privacy policy and support page under **About**.

## Availability

- iPhone and iPad only. "Designed for iPad" on Mac is turned off in the build settings
  (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`); also leave the app unavailable on Mac under
  **Pricing and Availability**.

## App Privacy

Both privacy manifests (`Authenticator/PrivacyInfo.xcprivacy`, `TokenExtension/PrivacyInfo.xcprivacy`) declare no
tracking and no collected data types. The only required-reason API is `UserDefaults`: `CA92.1` for the app's own
settings, and `1C8F.1` for the app group the app shares with the smart card extension.

Suggested answer: **Data Not Collected**. The developer runs no server, analytics or crash reporting. Ente sync
sends the email and sign-in data the person enters to their own Ente account (or their own server), at their
request, to sign in to that service; the developer never receives it. Revisit this answer if Apple asks, or if
anything is ever sent to a service the developer runs.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `true`: the app uses standard algorithms (libsodium for Ente sync) in a mass
market app. Answer the questions in App Store Connect to match, and add the France declaration if they ask for it.

## Review notes (draft)

> Oriel OTP is a fork of Yubico Authenticator for iOS (Apache 2.0), published with a new name, icon and artwork. It is
> not affiliated with Yubico or Ente. It adds one feature: copying TOTP and HOTP accounts from the person's own
> Ente Auth account onto a YubiKey. The sync is read only for Ente; nothing is changed there.
>
> The app needs a YubiKey (NFC, Lightning or USB-C) to show codes. A video of the app on a device is attached,
> showing NFC and USB-C, adding an account by QR code, Ente sync from sign-in to writing to the key, and the smart
> card extension. We can send a YubiKey on request.
>
> Ente demo account (no two-factor or email codes): email `…`, password `…`.

Fill in the demo account and attach the video before submitting.
