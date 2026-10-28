# Privacy policy

Oriel OTP does not run analytics or advertising and does not collect personal data for the developer's own use. Its core authenticator features work without an account or network connection.

## Data on your device and YubiKey

- OATH credentials are stored on your YubiKey. The app reads them when you use the key and writes credentials to the key when you add them. The app does not keep a server copy.
- QR scanning starts only when you choose to scan. The app reads the QR code on the device to prepare a credential for your YubiKey; it does not save or send the camera image.
- A YubiKey password is saved in the device keychain only if you choose to save it. You can remove saved OATH passwords in the app under the YubiKey settings.
- App settings and favorites are stored locally on the device.

## Optional smart card extension

- When you add a certificate under **Smart card extension**, its public certificate is copied to the device keychain so other apps on the device can find it. The private key never leaves the YubiKey.
- When an app asks to use one of these certificates, Oriel OTP shows a local notification. Notifications are created on the device; no push server is involved.
- The smart card PIN you enter is sent only to the YubiKey to unlock it and is not stored.
- The resulting signature or decrypted data is handed to the app that asked for it through a file in storage shared only by Oriel OTP and its extension. The file is encrypted while the device is locked and is deleted as soon as the extension has read it.

## Optional Ente Auth sync

If you choose **Sync from Ente Auth**, the app sends the email address and sign-in or verification information you enter to Ente's service over HTTPS. If you enter a self-hosted server address, requests go to that server instead. The app uses your password on the device to derive keys; it does not store your password or send it to the app developer. Ente's service receives the sign-in requests and remains subject to its own [privacy policy](https://ente.io/privacy).

Ente Auth data is end-to-end encrypted on Ente's service. The app downloads and decrypts it on your device so you can choose credentials to copy to your YubiKey. The app does not write or delete your OTP records in Ente. Retrieved credentials are held in memory for the sync flow and are written to your YubiKey only when you choose **Add**. The app may send a sign-out request to Ente when you sign out.

Staying signed in is optional. If enabled, the app stores an Ente session token and authenticator key in the device keychain, protected by the current Face ID or Touch ID enrollment. It also stores the account email in local app preferences so the saved session can be identified. If you enter a self-hosted server address, it is saved in local app preferences and remains after sign-out. The app never stores your Ente password.

## Retention, deletion, and revoking access

- To remove a saved Ente session from this device and sign out, open **Sync from Ente Auth** and choose **Sign out**. This clears the locally saved token, key, and email and asks Ente to end the server session. If the server cannot be reached, the local session is still removed; you may also revoke the session from your Ente account.
- To remove a saved YubiKey password from this device, use **Clear saved passwords** in the YubiKey settings.
- To remove a smart card certificate from this device, tap the minus button next to it under **Smart card extension**.
- OATH credentials copied to a YubiKey remain on that physical key until you remove them using the app or another compatible tool. Removing a credential from a YubiKey does not delete its source from Ente Auth.
- Oriel OTP does not retain a copy of these credentials on a developer-operated server. Uninstalling the app deletes its settings, favorites and saved server address, but does not remove credentials from a YubiKey or from your Ente account. iOS may keep keychain items after an app is deleted, so clear saved passwords, remove smart card certificates and sign out of Ente before uninstalling if you also want to remove the app's keychain data.

To contact the developer, visit the [Oriel OTP issue tracker](https://github.com/SINF-KEN/oriel-otp/issues).
