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

Ente Auth data is end-to-end encrypted on Ente's service. The app downloads and decrypts it on your device so you can choose credentials to copy to your YubiKey. The app never changes or deletes your OTP records in Ente. If you turn on **Also add to Ente Auth** when adding an account, the app encrypts that account on your device with your Ente authenticator key and adds it to your Ente account, after reading your Ente accounts to check it isn't already there. Retrieved credentials are held in memory for the sync flow and are written to your YubiKey only when you choose **Add**. The app may send a sign-out request to Ente when you sign out.

Staying signed in is on by default when the device can protect the session, and you can turn it off before signing in. When on, the app stores an Ente session token and your Ente authenticator key, which decrypts your Ente Auth accounts, in the device keychain. They stay on this device and can only be read after Face ID or Touch ID with the current enrollment on iPhone and iPad, or Touch ID or your Mac's password on the Mac. The app also stores the account email and server address in local app preferences so the saved account can be shown in the settings without unlocking. If Ente's server rejects the session, the token and key are deleted and the email and server are kept so you can enter your password again. If you enter a self-hosted server address, it is saved in local app preferences and remains after sign-out. The app never stores your Ente password or your Ente master key.

## Optional Apple Watch app

The Apple Watch app is off until you turn on **Show Ente Auth accounts on Apple Watch** under **Sync from Ente Auth**,
which needs a saved Ente session. When it's on, the iPhone app sends your time-based Ente Auth accounts, including
their secrets, to your paired Apple Watch with Apple's WatchConnectivity framework each time they are synced from
Ente. Counter-based (HOTP) accounts are not sent.

This is different from the YubiKey: the watch keeps a copy of these secrets so it can calculate codes without the
iPhone. They are stored in the watch's keychain, readable only while the watch is unlocked, and not synced to iCloud or
included in backups.
WatchConnectivity also keeps the most recent list that was sent on the iPhone and the watch until it is replaced.
The watch app makes no network connections and doesn't store anything else.

Turning the switch off, or signing out of Ente, sends an empty list that replaces the previous one and makes the
watch delete its copy. If the watch can't be reached at that moment, the iPhone sends it the next time it can.

## Retention, deletion, and revoking access

- To remove a saved Ente session from this device and sign out, choose **Sign out** under **Sync from Ente Auth** or in the Ente Auth section of the settings. This clears the locally saved token, key, email and server and asks Ente to end the server session. If the server cannot be reached, the local session is still removed; you may also revoke the session from your Ente account.
- To remove the Ente Auth accounts from your Apple Watch, turn off **Show Ente Auth accounts on Apple Watch** or sign
  out of Ente. Deleting the watch app also removes them.
- To remove a saved YubiKey password from this device, use **Clear saved passwords** in the YubiKey settings.
- To remove a smart card certificate from this device, tap the minus button next to it under **Smart card extension**.
- OATH credentials copied to a YubiKey remain on that physical key until you remove them using the app or another compatible tool. Removing a credential from a YubiKey does not delete its source from Ente Auth.
- Oriel OTP does not retain a copy of these credentials on a developer-operated server. Uninstalling the app deletes its settings, favorites and saved server address, but does not remove credentials from a YubiKey or from your Ente account. iOS may keep keychain items after an app is deleted, so clear saved passwords, remove smart card certificates and sign out of Ente before uninstalling if you also want to remove the app's keychain data.

To contact the developer, visit the [Oriel OTP issue tracker](https://github.com/SINF-KEN/oriel-otp/issues).
