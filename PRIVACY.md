# Privacy policy

Oriel OTP does not run analytics or advertising and does not collect personal data for the developer's own use. Its core authenticator features work without an account or network connection.

## Data on your device and YubiKey

- OATH credentials are stored on your YubiKey. The app reads them when you use the key and writes credentials to the key when you add them. The app does not keep a server copy.
- QR scanning starts only when you choose to scan. The app reads the QR code on the device to prepare a credential for your YubiKey; it does not save or send the camera image.
- On the Mac, Scan QR Code on Screen takes one picture of each display, with the app's own windows left out, only when you click it and after you allow screen recording in System Settings. The app looks for a QR code in it on the Mac and does not save or send the picture. Pasted, dropped and imported pictures are handled the same way.
- On the Mac, a copied code is marked so that clipboard managers don't keep it, and is removed from the clipboard after a minute unless you have copied something else since.
- A YubiKey password is saved in the device keychain only if you choose to save it. You can remove saved OATH passwords in the app under the YubiKey settings.
- App settings and favorites are stored locally on the device.

## Optional smart card extension

- When you add a certificate under **Smart card extension**, its public certificate is copied to the device keychain so other apps on the device can find it. The private key never leaves the YubiKey.
- When an app asks to use one of these certificates, Oriel OTP shows a local notification. Notifications are created on the device; no push server is involved.
- The smart card PIN you enter is sent only to the YubiKey to unlock it and is not stored.
- The resulting signature or decrypted data is handed to the app that asked for it through a file in storage shared only by Oriel OTP and its extension. The file is encrypted while the device is locked and is deleted as soon as the extension has read it.

## Optional Ente Auth sync

If you choose **Sync from Ente Auth**, the app sends the email address and sign-in or verification information you enter to Ente's service over HTTPS. If you enter a self-hosted server address, requests go to that server instead. The app uses your password on the device to derive keys; it does not store your password or send it to the app developer. Ente's service receives the sign-in requests and remains subject to its own [privacy policy](https://ente.io/privacy).

Ente Auth data is end-to-end encrypted on Ente's service. The app downloads and decrypts it on your device so you can use the codes in the app and choose credentials to copy to your YubiKey. Credentials are written to your YubiKey only when you choose **Add**. The app may send a sign-out request to Ente when you sign out.

When you stay signed in (see below), the app works as an Ente Auth client: it keeps a copy of your Ente Auth accounts on the device and writes your changes back to Ente. Accounts you add to Ente Auth in the app (including when you save an account to both the YubiKey and Ente Auth), rename, pin, or delete, and the counters of counter-based (HOTP) accounts whose codes you calculate in the app, are encrypted on your device with your Ente authenticator key and uploaded to your Ente account. Deleting an account in the app moves it to the trash in Ente Auth, from which Ente's apps can restore it. Changes made in Ente's other apps are downloaded the next time the app syncs. The app syncs with Ente when it opens, when you refresh the account list, after a change you make, and when the network comes back while changes are waiting. Without **Stay signed in**, the app doesn't keep or change your Ente Auth accounts; they are only held in memory while the sync sheet is open.

Staying signed in is on by default when the device can protect the session, and you can turn it off before signing in. When on, the app stores an Ente session token and your Ente authenticator key, which decrypts your Ente Auth accounts, in the device keychain. If your Ente account has never used Ente Auth and so has no authenticator key yet, the app creates one on your device, like Ente Auth does, and uploads it to Ente encrypted with your master key. The token and key stay on this device and can only be read after Face ID or Touch ID with the current enrollment on iPhone and iPad, or Touch ID or your Mac's password on the Mac. The app also stores the account email and server address in local app preferences so the saved account can be shown in the settings without unlocking. If Ente's server rejects the session, the token and key are deleted and the email and server are kept so you can enter your password again. If you enter a self-hosted server address, it is saved in local app preferences and remains after sign-out. The app never stores your Ente password or your Ente master key.

While you stay signed in, the copy of your Ente Auth accounts, including their secrets, and any changes not yet uploaded, are kept in a file in the app's storage on the device. The file is encrypted with a random key kept in the device keychain, which never leaves the device and can be read while the device is unlocked, without Face ID or Touch ID, so the codes are shown at once and work offline. The file is excluded from backups. If Ente's server rejects the session, the copy is kept so the codes keep working until you sign in again or sign out.

## App lock

If you turn on **App lock**, the app keeps the lock method you chose in the device keychain, only on this device. For a code or password it keeps a salted PBKDF2-SHA256 hash, never the code or password itself. Face ID, Touch ID and the device passcode are checked by the system; the app only learns whether it succeeded. The number of wrong attempts and the time of the last one are kept in local app preferences to make you wait after too many. Nothing about the lock leaves the device. The lock covers this app only: the Apple Watch app keeps showing codes while the watch is unlocked.

## Optional Apple Watch app

The Apple Watch app is off until you turn on **Show Ente Auth accounts on Apple Watch** under **Sync from Ente Auth**,
which needs a saved Ente session. When it's on, the iPhone app sends your time-based Ente Auth accounts, including
their secrets, to your paired Apple Watch with Apple's WatchConnectivity framework each time they are synced from
Ente or changed in the app. Counter-based (HOTP) accounts are not sent.

This is different from the YubiKey: the watch keeps a copy of these secrets so it can calculate codes without the
iPhone. They are stored in the watch's keychain, readable only while the watch is unlocked, and not synced to iCloud or
included in backups.
WatchConnectivity also keeps the most recent list that was sent on the iPhone and the watch until it is replaced.
The watch app makes no network connections and doesn't store anything else.

Turning the switch off, or signing out of Ente, sends an empty list that replaces the previous one and makes the
watch delete its copy. If the watch can't be reached at that moment, the iPhone sends it the next time it can.

## Retention, deletion, and revoking access

- To remove a saved Ente session from this device and sign out, choose **Sign out** under **Sync from Ente Auth** or in the Ente Auth section of the settings. This clears the locally saved token, key, email, server and the copy of your Ente Auth accounts right away, including changes not yet uploaded to Ente, then asks Ente to end the server session. If the server cannot be reached, the local session has already been removed; you may also revoke the session from your Ente account.
- To remove the Ente Auth accounts from your Apple Watch, turn off **Show Ente Auth accounts on Apple Watch** or sign
  out of Ente. Deleting the watch app also removes them.
- To remove a saved YubiKey password from this device, use **Clear saved passwords** in the YubiKey settings.
- To remove a smart card certificate from this device, tap the minus button next to it under **Smart card extension**.
- OATH credentials copied to a YubiKey remain on that physical key until you remove them using the app or another compatible tool. Removing a credential from a YubiKey does not delete its source from Ente Auth. Deleting an Ente Auth account in the app moves it to the trash in Ente Auth on all your devices; to delete it for good, empty it from the trash in Ente's apps.
- Oriel OTP does not retain a copy of these credentials on a developer-operated server. Uninstalling the app deletes its settings, favorites, saved server address and the copy of your Ente Auth accounts, but does not remove credentials from a YubiKey or from your Ente account. iOS may keep keychain items after an app is deleted, so clear saved passwords, remove smart card certificates and sign out of Ente before uninstalling if you also want to remove the app's keychain data.

To contact the developer, visit the [Oriel OTP issue tracker](https://github.com/SINF-KEN/oriel-otp/issues).
