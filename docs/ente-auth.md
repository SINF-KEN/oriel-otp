# Syncing accounts with Ente Auth

The app can sign in to [Ente Auth](https://ente.io/auth) and copy the TOTP and HOTP accounts stored there onto
a YubiKey. Choose **Sync from Ente Auth** in the menu of the account list, or below the message shown when no
YubiKey has been read yet or the YubiKey has no accounts. It can also add a new account to Ente Auth while adding it
to the YubiKey, see [Adding to Ente Auth](#adding-to-ente-auth).

The sync reads accounts from Ente and writes them to the YubiKey. Nothing is changed or deleted in Ente Auth.
Accounts with the same name as one already on the YubiKey are skipped, so the sync can be run again after adding
accounts in Ente Auth.

## Sign in

The sign in follows Ente's own apps, with the email and password entered together on one screen:

1. `GET /users/srp/attributes` tells whether the account uses SRP and whether email verification is on.
2. Accounts with SRP and without email verification sign in with
   [SRP-6a](https://datatracker.ietf.org/doc/html/rfc5054) (`/users/srp/create-session`,
   `/users/srp/verify-session`). The password never leaves the device: it is stretched with Argon2id into the
   key encryption key (KEK), and the SRP password is a 16 byte subkey of the KEK. The client also checks the
   server's proof (M2), so a server that doesn't know the account's verifier can't complete the sign in.
3. Other accounts verify a code sent by email (`/users/ott`, `/users/verify-email`). The password entered with
   the email is then used locally to derive the KEK, so it isn't asked for again unless it was wrong.
4. A TOTP second factor (`/users/two-factor/verify`) or a passkey, verified on Ente's accounts site and then
   polled with `/users/two-factor/passkeys/get-token`, may follow.

With the KEK the client decrypts the master key (XSalsa20-Poly1305 secretbox), the X25519 secret key, and the
auth token, which is a sealed box to the account's public key. The public key is checked against the decrypted
secret key.

Requests send `X-Client-Package: io.ente.auth`, like Ente's CLI. Ente's server only lets tokens issued for that
package read authenticator data.

## Reading accounts

1. `GET /authenticator/key` returns the authenticator key, encrypted with the master key. An account that has
   never used Ente Auth has none (`404`) and so no accounts to read.
2. `GET /authenticator/entity/diff` is paged from `sinceTime=0` and the latest version of each entity is kept.
   Deleted entities are dropped.
3. Each entity is one XChaCha20-Poly1305 secretstream message. It decrypts to JSON: either a string with an
   `otpauth://` URL, where Ente keeps its display settings in a `codeDisplay` query parameter, or an object with
   the URL in `rawData` and the settings in `display`. Accounts in Ente's trash are skipped.

Ente's `steam` accounts become TOTP accounts with the issuer `Steam`, which the app shows as Steam codes.
Accounts the YubiKey can't store, e.g. with 10 digits or a name that is too long, are listed with the reason and
can't be selected.

## Room on the YubiKey

A YubiKey holds a fixed number of OATH accounts: 64 from firmware 5.7, 32 on earlier YubiKey 4 and 5 models and
28 on the YubiKey NEO (`OATHSession.credentialCapacity(version:)`). When a YubiKey has been read, the sheet shows
how many spaces are free, selects only as many accounts as fit, in list order, and warns when more are selected.
Accounts already on the YubiKey don't take a space. The Add button shows how many accounts are selected.

The limits are an estimate from the OATH version. The YubiKey has the final say: if it reports that it is full,
adding stops and an alert names the accounts that weren't added.

## Adding to Ente Auth

A YubiKey never gives its OATH secrets back, so an account that is already on a key can't be copied to Ente.
The app only has the secret while an account is being added. Turn on **Also add to Ente Auth** in the *Add account*
sheet to save the account in Ente Auth as well. The choice is remembered.

This uses the saved session, so it is offered once you have signed in with **Stay signed in**. After the account
is on the YubiKey:

1. The saved session is unlocked with Face ID or Touch ID, or Touch ID or the password on the Mac.
2. The accounts in Ente Auth are read as above. If one has the same name, nothing is added.
3. The otpauth URL is JSON encoded like Ente's apps do, encrypted with the authenticator key as one
   XChaCha20-Poly1305 secretstream message, and sent with `POST /authenticator/entity`.

The secret uploaded may not be byte for byte the one in the QR code: YubiKit pads secrets shorter than 14 bytes
with zeros and hashes ones longer than the HMAC block. HMAC does the same to its key, so the codes are identical.
Steam accounts are added with Ente's `steam` type. A HOTP account added to both keeps two counters, which drift
apart as each side is used.

If the YubiKey part fails, nothing is sent to Ente. If the Ente part fails, the account stays on the YubiKey and
the error is shown.

## What is stored

The account stays signed in, like in Ente's own apps. **Stay signed in** is on by default when the device can
protect the session: the auth token and the authenticator key, the key that decrypts the accounts, are saved in
the keychain, only on this device (`WhenPasscodeSetThisDeviceOnly`). Reading them needs Face ID or Touch ID on
iPhone and iPad (`biometryCurrentSet`) and Touch ID or the Mac's password on the Mac (`userPresence`). After a
relaunch, syncing only needs that unlock, not the Ente password. The password is never stored, and neither is the
master key: the authenticator key is all syncing and adding accounts need.

An account that has never used Ente Auth has no authenticator key yet. When the session is saved, signing in
creates one like Ente Auth does, while the master key is still in memory: 32 random bytes, encrypted with the
master key (secretbox) and stored with `POST /authenticator/key` (`encryptedKey`, `header` with the nonce). If
another Ente app created the key in the meantime, the server answers `409` and that key is fetched and used. So a
new account stays signed in too. Without **Stay signed in** no key is created.

The email and server are kept in the app's preferences, so the account is shown without unlocking: in the sheet,
and with **Sign out** in the settings (the YubiKey configuration on iPhone and iPad, Settings ▸ General on the
Mac). **Sign out** asks for the unlock to revoke the token with `POST /users/logout`, then deletes the token, the
key and the account, even if the token couldn't be revoked.

When the server rejects the token (`401`), e.g. because the session was ended from another device, or when Face ID
or Touch ID changed and the keychain item can no longer be read, the token and key are deleted but the account is
kept. The sheet then asks for the password of that account again and saves the new session.

With **Stay signed in** turned off, nothing is stored. The session only lives while the sheet is open, and when it
closes the token is revoked with `POST /users/logout`.

`EnteSessionStore.unlock()` returns the server, token and authenticator key of the saved account after the unlock,
for code that needs to read or add accounts outside the sheet.

## Self-hosted servers

Enter the API URL of the server, e.g. `https://ente.example.com`, under Options. Only `https` URLs are accepted.

## Code

Everything lives in `Authenticator/EnteAuth/` and is added to the project as a synchronized folder:

| File | Purpose |
| --- | --- |
| `EnteCrypto.swift` | libsodium wrappers: Argon2id, KDF, secretbox, sealed box, secretstream |
| `EnteSRPClient.swift` | SRP-6a client matching Ente's server |
| `EnteAPIClient.swift` | HTTP client and wire models |
| `EnteLoginFlow.swift` | Sign in state machine and key decryption |
| `EnteAuthenticatorSync.swift` | Downloads, decrypts and parses the accounts, and encrypts and adds new ones |
| `EnteSessionStore.swift` | The saved account and session in the keychain, and adding an account with it |
| `EnteAccountSection.swift` | The saved account and **Sign out** in the settings |
| `EnteSyncViewModel.swift`, `EnteSyncView.swift` | The sheet |

Outside that folder the feature adds a menu item, buttons in the empty account list and a sheet in `MainView`, the
toggle in `AddAccountView`, and
`MainViewModel.addAccounts(_:requiresTouch:completion:)` / `OATHSession.addCredentials(templates:requiresTouch:)`,
which add several accounts in one YubiKey session.

It uses two packages: [swift-sodium](https://github.com/jedisct1/swift-sodium) (ISC, only its `Clibsodium`
product, i.e. libsodium) and [BigInt](https://github.com/attaswift/BigInt) (MIT) for the SRP arithmetic.

Tests are in `AuthenticatorTests/EnteAuth/`. The SRP test uses the vector from Ente's Rust client, whose M1 was
generated by Ente's Go server, so it checks compatibility with the server without network access.

## Limitations

- Accounts already on a YubiKey can't be copied to Ente, only new ones while they are added.
- Accounts removed from one side aren't removed from the other.
- Ente's tags, notes, icons and pins aren't carried over.
- The passkey flow opens Ente's accounts site in the browser and has to be confirmed in the app afterwards.
