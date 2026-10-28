# Syncing accounts from Ente Auth

The app can sign in to [Ente Auth](https://ente.io/auth) and copy the TOTP and HOTP accounts stored there onto
a YubiKey. Choose **Sync from Ente Auth** in the menu of the account list, or below the message shown when no
YubiKey has been read yet or the YubiKey has no accounts.

The sync is one way and read only: accounts are read from Ente and written to the YubiKey. Nothing is created,
changed or deleted in Ente Auth. Accounts with the same name as one already on the YubiKey are skipped, so the
sync can be run again after adding accounts in Ente Auth.

## Sign in

The sign in follows Ente's own apps:

1. `GET /users/srp/attributes` tells whether the account uses SRP and whether email verification is on.
2. Accounts with SRP and without email verification sign in with
   [SRP-6a](https://datatracker.ietf.org/doc/html/rfc5054) (`/users/srp/create-session`,
   `/users/srp/verify-session`). The password never leaves the device: it is stretched with Argon2id into the
   key encryption key (KEK), and the SRP password is a 16 byte subkey of the KEK. The client also checks the
   server's proof (M2), so a server that doesn't know the account's verifier can't complete the sign in.
3. Other accounts verify a code sent by email (`/users/ott`, `/users/verify-email`) and then enter the password,
   which is used locally to derive the KEK.
4. A TOTP second factor (`/users/two-factor/verify`) or a passkey, verified on Ente's accounts site and then
   polled with `/users/two-factor/passkeys/get-token`, may follow.

With the KEK the client decrypts the master key (XSalsa20-Poly1305 secretbox), the X25519 secret key, and the
auth token, which is a sealed box to the account's public key. The public key is checked against the decrypted
secret key.

Requests send `X-Client-Package: io.ente.auth`, like Ente's CLI. Ente's server only lets tokens issued for that
package read authenticator data.

## Reading accounts

1. `GET /authenticator/key` returns the authenticator key, encrypted with the master key.
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

## What is stored

By default nothing is stored. The session only lives while the sheet is open, and when it closes the token is
revoked with `POST /users/logout`.

With **Stay signed in**, offered when the device has a passcode, the auth token and the authenticator key are
saved in the keychain, protected by Face ID, Touch ID or the passcode (`biometryCurrentSet`,
`WhenPasscodeSetThisDeviceOnly`), so later syncs need no password. The master key and the password are never
stored. **Sign out** revokes the token and removes the keychain item.

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
| `EnteAuthenticatorSync.swift` | Downloads, decrypts and parses the accounts |
| `EnteSessionStore.swift` | Optional saved session in the keychain |
| `EnteSyncViewModel.swift`, `EnteSyncView.swift` | The sheet |

Outside that folder the feature adds a menu item, buttons in the empty account list and a sheet in `MainView`, and
`MainViewModel.addAccounts(_:requiresTouch:completion:)` / `OATHSession.addCredentials(templates:requiresTouch:)`,
which add several accounts in one YubiKey session.

It uses two packages: [swift-sodium](https://github.com/jedisct1/swift-sodium) (ISC, only its `Clibsodium`
product, i.e. libsodium) and [BigInt](https://github.com/attaswift/BigInt) (MIT) for the SRP arithmetic.

Tests are in `AuthenticatorTests/EnteAuth/`. The SRP test uses the vector from Ente's Rust client, whose M1 was
generated by Ente's Go server, so it checks compatibility with the server without network access.

## Limitations

- Sync is one way, from Ente to the YubiKey. Accounts removed from Ente aren't removed from the YubiKey.
- Ente's tags, notes, icons and pins aren't carried over.
- The passkey flow opens Ente's accounts site in the browser and has to be confirmed in the app afterwards.
