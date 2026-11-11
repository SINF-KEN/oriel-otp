# App Store Connect

Values and texts for the App Store listing, kept here so they stay in step with the app. See [issue 1](https://github.com/SINF-KEN/oriel-otp/issues/1) for the release
checklist.

## URLs

| Field | Value |
| --- | --- |
| Privacy Policy URL | https://github.com/SINF-KEN/oriel-otp/blob/main/PRIVACY.md |
| Support URL | https://github.com/SINF-KEN/oriel-otp/blob/main/SUPPORT.md |
| Marketing URL (optional) | https://github.com/SINF-KEN/oriel-otp |

The app links to the same privacy policy and support page under **About**, which also has the support email
(opensource@net01.io).

## Availability

- iPhone, iPad and Mac. The Mac version is a native macOS build of the same target (see [macos.md](macos.md)), not
  the iPad app: "Designed for iPad" stays turned off (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`).
- A companion Apple Watch app (watchOS 10 or later) is embedded in the iPhone app. The watch app needs the iPhone app
  (`WKRunsIndependentlyOfCompanionApp = NO`). The Mac app has no watch app.
- Add the macOS platform to the same app record in App Store Connect, so it's a universal purchase with one bundle
  id (`io.github.sinf-ken.OrielOTP`). The Mac needs its own provisioning profile for the keychain access group.
- Mac screenshots: `docs/screenshots/mac-accounts.png`, `mac-add-account.png` and `mac-ente-accounts.png` are
  2560 × 1600, an accepted Mac size (see [screenshots.md](screenshots.md)).
- Category on the Mac: Utilities (`LSApplicationCategoryType` in `Authenticator/Info-macOS.plist`).

## App Privacy

The privacy manifests (`Authenticator/PrivacyInfo.xcprivacy`, `TokenExtension/PrivacyInfo.xcprivacy`,
`AutoFillExtension/PrivacyInfo.xcprivacy`, `OrielOTPWatch/PrivacyInfo.xcprivacy`) declare no tracking and no collected
data types. The required-reason APIs are `UserDefaults`: `CA92.1` for the app's own settings, and `1C8F.1` for the
app group the app shares with the smart card and AutoFill extensions, and the system boot time: `35F9.1` in the app and
the AutoFill extension, to measure the wait after too many wrong app lock attempts. The watch app declares `UserDefaults` with `CA92.1`, for its own record of what is still to be deleted. The Mac
app uses the same manifest as the iOS app; it adds no other required-reason APIs (the pasteboard, ScreenCaptureKit,
notifications and login item aren't on the list). Reading a QR code from the screen happens on the Mac and the
picture isn't kept or sent.

Recommended App Store Connect answer, based on the developer's confirmation: **Data Not Collected**. Oriel OTP
does not use analytics, advertising, crash reporting, diagnostics reporting, or a developer-operated server.
Ente sync is optional and started by the user. When used, the user enters their email and sign-in or verification
information, which the app sends to Ente or to the self-hosted server address the user chose. If the user chooses to
save an account in Ente Auth, it is encrypted on the device and added to their Ente account. The developer
does not receive or retain that information.

This recommendation assumes Ente (or a self-hosted endpoint) is an independent service used for the user's own
account, not a vendor or partner collecting data on Oriel OTP's behalf. Apple's definition of collection covers
off-device transmission that lets the developer or a third-party partner access data beyond servicing the request
in real time. If Ente is considered Oriel OTP's partner for this feature, disclose the data types it can access;
the optional-disclosure exception is limited to infrequent submissions outside the app's primary functionality.
See [Apple's App Privacy Details guidance](https://developer.apple.com/app-store/app-privacy-details/).

## Listing (draft)

Ente sync is what sets the app apart, so the listing leads with it. Subtitle, promotional text and keywords are
within App Store Connect's limits of 30, 170 and 100 characters.

Guideline 2.3.7 doesn't allow other companies' names in the subtitle or keywords, so those fields are generic. Ente
is named in the promotional text and description, and YubiKey only to say what the app works with.

| Field | Value |
| --- | --- |
| Subtitle | Two-factor codes, key optional |
| Promotional text | Get your two-factor codes right in the app, synced both ways with Ente Auth if you use it. No hardware needed, and a YubiKey works too. |
| Keywords | 2fa,totp,hotp,otp,authenticator,security key,hardware key,nfc,usb-c,mfa,two factor,token,sync |

Description:

> Oriel OTP gives you two-factor codes on your iPhone, iPad and Mac. Add an account and get its codes right away, with
> no hardware or sign-in needed. Syncs with Ente Auth if you use it. Also works with YubiKey.
>
> SYNC FROM ENTE AUTH
> Sign in to Ente Auth, pick the accounts you want and add them to your YubiKey in one go. The app shows how much
> room is left on the YubiKey, so you decide which accounts go on it. Your Ente Auth data is decrypted on this
> device and your password never leaves it. Self-hosted Ente servers work too.
>
> Stay signed in and your Ente Auth accounts are listed with the YubiKey's, with their codes generated by the app,
> also offline and without a YubiKey. Accounts you add, rename, pin or delete are synced back to Ente Auth, and
> changes from your other devices show up here. Choose for each new account whether it goes on the YubiKey, in Ente
> Auth or both, and copy or move an Ente Auth account onto the YubiKey at any time.
>
> YOUR CODES ON HARDWARE, IF YOU WANT
> • TOTP and HOTP codes generated by the YubiKey over NFC or USB-C
> • Add accounts by scanning a QR code or typing them in
> • Tap a code to copy it
> • Pin, rename and delete accounts, and require a touch of the YubiKey per account
> • Works with password-protected YubiKeys, and can keep the password in the Keychain
> • Lock the app with Face ID, a 4 or 6 digit code or a password
>
> AUTOFILL
> Fill in the codes of your time-based Ente Auth accounts in Safari and other apps on iPhone, iPad and Mac. Stay
> signed in to Ente Auth and turn on Oriel OTP in the system's AutoFill settings, and each account is suggested on its
> websites. Codes of accounts on your YubiKey can't be filled in.
>
> SMART CARD
> Use the certificates in the YubiKey's smart card application with apps that support smart card sign-in on iOS.
>
> MAC AND APPLE WATCH
> The Mac app reads the YubiKey over USB, and can copy codes from the menu bar. The Apple Watch app shows the codes
> of your time-based Ente Auth accounts on your wrist.
>
> Oriel OTP is an independent fork of Yubico Authenticator and isn't affiliated with Yubico or Ente. It has no
> analytics, advertising or tracking.

## Accessibility

App Store Connect's [Accessibility Nutrition Labels](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/)
are answered per platform, for the common tasks: add an account (QR code, by hand, from Ente Auth), read and copy a
code, search, pin, rename, delete, sync with Ente Auth, the YubiKey settings and the app lock. What each feature
covers and how it's tested is in [accessibility.md](accessibility.md); the work is tracked in
[issue 57](https://github.com/SINF-KEN/oriel-otp/issues/57).

| Feature | iPhone, iPad | Mac | Apple Watch |
| --- | --- | --- | --- |
| VoiceOver | Yes | Yes | Yes |
| Voice Control | Yes | Yes | Not applicable on watchOS |
| Larger Text | Yes | Yes (the app's own text size, up to 200%) | Yes |
| Dark Interface | Yes | Yes | Yes (always dark) |
| Differentiate Without Color Alone | Yes | Yes | Yes |
| Sufficient Contrast | Yes | Yes | Yes |
| Reduced Motion | Yes | Yes | Yes (nothing moves but the countdown) |
| Captions | No: the app has no video | No | No |
| Audio Descriptions | No: the app has no video | No | No |

Claim only the features marked Yes, and only after checking them on a device with the release build: the tests
run in the Simulator and on the Mac, not with a person using VoiceOver or Voice Control. Note in the review notes or
here which checks were done on a device.

Any video added to the app, the tutorial or the listing's in-app help needs captions and an audio description (or a
text alternative with the same content) before it's released, so Captions and Audio Descriptions can be claimed
then.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false`. The app uses standard algorithms (libsodium for Ente sync), and App
Store Connect's App Encryption Documentation questions, answered with standard algorithms and no distribution in
France, need no documents. Apple then issues no compliance code, and an upload with the key set to `true` but no
`ITSEncryptionExportComplianceCode` is rejected. Leave France out of the app's availability. To add it, upload the
French encryption declaration under App Encryption Documentation and set the key to `true` with the code Apple
gives.

## Review notes (draft)

> Oriel OTP is a fork of Yubico Authenticator for iOS (Apache 2.0), published with a new name, icon and artwork. It is
> not affiliated with Yubico or Ente. It adds Ente Auth support: copying TOTP and HOTP accounts from the person's own
> Ente Auth account onto a YubiKey, and, when they stay signed in, showing the codes of their Ente Auth accounts in
> the app and syncing accounts they add, rename, pin or delete back to Ente Auth.
>
> The app doesn't need a YubiKey or an Ente account. To test it without either, tap **Add account**, scan a QR code or
> enter one by hand, and save it to **This device**: the app shows its codes. The YubiKey is optional. A video of the
> app on a device, including the YubiKey features (NFC and USB-C, adding an account by QR code, Ente sync from sign-in
> to writing to the key, the smart card extension) and AutoFill, is at: `…`.
>
> Ente sync is optional and only signs in to the person's own Ente account, through the same API Ente's open-source
> (AGPL-3.0) apps use. The app is an independent client and identifies itself to Ente's server as
> `io.ente.auth.orielotp`; the server requires the `io.ente.auth` prefix for the authenticator endpoints. The email and sign-in requests go only to Ente, or to the self-hosted server
> the person enters, as the sign-in screen says; the password is checked with SRP and never leaves the device. We
> run no server and receive none of this data, so the App Privacy answer is Data Not Collected. Oriel OTP is not
> affiliated with Ente.
>
> Ente demo account (no two-factor or email codes): email `…`, password `…`.
>
> The app lock is off by default, so the app opens without a code. It can be turned on under Configuration > App
> lock.
>
> Apple Watch: the watch app shows codes for the Ente Auth accounts only; it doesn't use the YubiKey. To test it,
> on the iPhone choose **Sync from Ente Auth** in the account list menu, turn on **Stay signed in**, sign in with
> the demo account, then turn on **Show Ente Auth accounts on Apple Watch** (shown when a watch with the app is
> paired). The demo accounts appear on the watch within a few seconds. Turning the switch off deletes them from the
> watch.
>
> AutoFill: the app includes an AutoFill extension that fills in the codes of Ente Auth accounts in Safari and other
> apps; it doesn't use the YubiKey. To test it, choose **Sync from Ente Auth** in the account list menu, turn on **Stay
> signed in** and sign in with the demo account. Under Configuration > AutoFill, tap **Turn on AutoFill** and turn on
> Oriel OTP in the system's AutoFill settings if asked. Then open a page with a verification code field in Safari, on
> a website in the account's details (**AutoFill websites** on the account changes them), and choose the suggested
> code above the keyboard. Codes of accounts on the YubiKey aren't offered.

Fill in the demo account and the link to the video, including AutoFill, before submitting. TestFlight's Review Notes
are text, so the video needs a link that opens without signing in.

If App Review asks about guideline 5.2.2 (using Ente's service), reply with the text below. We don't have Ente's
permission, so never claim or imply that we do.

> Oriel OTP is an independent client, and we don't have written permission from Ente. People sign in to their own Ente
> accounts with their own credentials, and Ente's apps and server are open source under AGPL-3.0. The app identifies
> itself to Ente's server as `io.ente.auth.orielotp`. [Ente's terms](https://ente.com/terms) (updated May 5, 2026)
> don't mention third-party clients. Section 11(a)(xiii) says not to access Ente's websites or apps "by any means other
> than through the interface provided by Ente", and the terms count Ente's API as part of its Services, while
> 11(a)(iv), (v) and (viii) make exceptions for what open-source licenses permit. They don't say whether a client
> like this one is allowed.

We don't ship hardware to App Review. To answer the Guideline 2.1 request for a demo video and hardware, reply with the
text below in App Store Connect, once the video link is filled in.

> Thank you for your message. Oriel OTP no longer needs a YubiKey: every account feature can be tested without one by
> saving an account to **This device**, as the Review Notes explain. The YubiKey is an optional extra, so we aren't
> sending hardware. The features that do need a key (NFC and USB-C, writing accounts to the key, the smart card
> extension) are shown in this video, recorded on a real device: `…`.

If Apple still requires hardware, order a YubiKey from a seller in the US and have it delivered straight to the address
in Apple's message. Nothing is then imported, and Apple only asks for FCC Form 740 on shipments from outside the US.
The form is the importer's declaration for one shipment, so Yubico doesn't provide it and it means nothing on its own.

If App Review asks why the smart card extension needs notifications: a CryptoTokenKit extension has no user interface
and can't open the app, so a local notification is the only way to reach the person when another app asks for a
certificate. Tapping it opens the app to enter the PIN and connect the YubiKey. The notifications are created on the
device, and on iPhone and iPad the app only asks for them on the Smart card extension screen, for this feature.

Add watch screenshots to the Apple Watch section of the listing. App Store Connect takes one size and scales it for
the others, so make them on the largest, the Ultra (422 × 514 pixels):

```bash
DEVICE_TYPE="Apple Watch Ultra 3 (49mm)" OUTPUT=build/app-store/watch tools/watch-screenshots.sh
```

Upload `watch-accounts.png` and `watch-wrist-down.png`. The time in the corner is the time the script ran.

Mac review notes (draft):

> The Mac version doesn't need a YubiKey: choose File > Add Account and save to **This device**. A YubiKey is optional
> and connects over USB only (USB-C or USB-A, e.g. a YubiKey 5C NFC), as a smart card. Plug it in and its codes appear;
> touch the key when asked. Codes can also be copied from the menu bar icon, and with the
> Copy Code action in Shortcuts. To add an account, choose File > Add Account and use Scan QR Code on Screen (this
> opens the system's window picker, to pick the window with the QR code; the app doesn't ask for the Screen Recording
> permission) or enter it manually. Ente sync works as on iOS, under File > Sync from Ente Auth. AutoFill works as on
> iOS too: after signing in with **Stay signed in**, choose **Turn on AutoFill** under Settings > General, and turn on
> Oriel OTP in the system's AutoFill settings if asked. A video of the Mac app with a YubiKey is at: `…`.
