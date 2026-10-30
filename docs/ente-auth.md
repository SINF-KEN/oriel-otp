# Syncing accounts with Ente Auth

The app can sign in to [Ente Auth](https://ente.io/auth) and copy the TOTP and HOTP accounts stored there onto
a YubiKey. Choose **Sync from Ente Auth** in the menu of the account list, or below the message shown when no
YubiKey has been read yet or the YubiKey has no accounts. It can also add a new account to Ente Auth while adding it
to the YubiKey, see [Adding to Ente Auth](#adding-to-ente-auth).

When you stay signed in, the app also works as an Ente Auth client of its own: the accounts are kept on the device,
listed with the YubiKey's, and their codes are calculated by the app, without a YubiKey. Accounts added, renamed,
pinned or deleted in the app are changed in Ente Auth too, and changes made in Ente's other apps show up here. See
[Ente Auth accounts in the app](#ente-auth-accounts-in-the-app).

Copying onto the YubiKey reads accounts from Ente and writes them to the YubiKey. Accounts with the same name as one
already on the YubiKey are skipped, so it can be run again after adding accounts in Ente Auth.

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
2. `GET /authenticator/entity/diff` is paged from `sinceTime` (0 for everything, or the last time seen for an
   incremental sync, see below) and the latest version of each entity is kept. Deleted entities are dropped.
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

The *Add account* sheet has a **Save to** choice: **YubiKey**, **Ente Auth** or **YubiKey and Ente Auth**
(`AccountDestinations`). It is offered when a YubiKey can be reached (NFC, or one plugged in) and you have signed in
with **Stay signed in**. The last choice is remembered (`AddAccount.Destinations`; the earlier *Also add to Ente Auth*
switch is carried over). Without a YubiKey to reach, the add button saves to Ente Auth; signed out, to the YubiKey.

A YubiKey never gives its OATH secrets back, so an account that is already on a key can't be copied to Ente. The app
only has the secret while an account is being added, and the sheet says so when only the YubiKey is chosen. The
account details of a YubiKey account say it too.

Adding to Ente Auth goes through the [vault](#ente-auth-accounts-in-the-app). After the account is on the YubiKey (when
it goes to both):

1. If the vault has an account with the same name, nothing is added.
2. The otpauth URL is JSON encoded like Ente's apps do and added to the vault, and the list shows it right away.
3. The next sync, which starts at once, encrypts it with the authenticator key as one XChaCha20-Poly1305
   secretstream message and sends it with `POST /authenticator/entity`. Without a network connection it waits in
   the vault.

The secret uploaded may not be byte for byte the one in the QR code: YubiKit pads secrets shorter than 14 bytes
with zeros and hashes ones longer than the HMAC block. HMAC does the same to its key, so the codes are identical.
Steam accounts are added with Ente's `steam` type. A HOTP account is saved in one place only: two copies would keep
two counters, which drift apart as each side is used, so *YubiKey and Ente Auth* isn't offered for it.

If the YubiKey part fails, nothing is added to Ente.

## Copying or moving to the YubiKey

An Ente Auth account can be put on the YubiKey at any time, from the account details, the row's context menu or, on
the Mac, the Account menu:

- **Copy to YubiKey** adds it to the YubiKey and keeps it in Ente Auth. It isn't offered for HOTP accounts, for the
  same reason as above.
- **Move to YubiKey** adds it to the YubiKey, then moves it to Ente's trash, like deleting it does, so Ente Auth can
  still restore it.

The credential is made the same way as **Sync from Ente Auth** makes it (`EnteCodeParser`), without requiring touch.
Accounts the YubiKey can't store, such as ones with 10 digits, offer neither. If the YubiKey already has an account
with the same name, nothing is changed in either place. If the YubiKey is full, an alert says so and the account stays
in Ente Auth. The actions need a YubiKey to reach: NFC on iPhone, or one plugged in.

## Ente Auth accounts in the app

With a saved session the app keeps a copy of the account's entities on the device, the vault (`EnteVault`), and
`EnteCloud` keeps it in step with Ente. The accounts are listed with the YubiKey's, sorted by name, and each row shows
where it lives: a key for the YubiKey, a cloud for Ente Auth, a clock for an Ente Auth account with a change that
hasn't been uploaded yet. The same account can be in both and is then listed twice.

Codes are calculated by the app with `OTPGenerator`, the RFC 4226 and 6238 code the Apple Watch app uses: TOTP with
SHA-1, SHA-256 or SHA-512, Ente's 5 character Steam codes, and HOTP. A HOTP code is calculated when asked for, and
the counter is moved on and uploaded like any other change, as Ente Auth does. Accounts in Ente's trash and ones that
can't be read aren't listed.

### Changes

Renaming, pinning and deleting an Ente Auth account change the entity's plain text in the vault, the way Ente Auth
writes it: the otpauth URL as a JSON string, with Ente's display settings in its `codeDisplay` parameter. Tags,
notes, icons and other settings this app doesn't use are kept. Deleting moves the account to Ente's trash
(`trashed` in the display settings), like Ente Auth's own delete, so the Ente Auth app can restore it or delete it
for good. An account deleted before it was ever uploaded is just dropped.

### Sync

A sync pulls, then pushes:

1. **Pull.** `GET /authenticator/entity/diff` from the vault's `lastSyncTime`, the latest `updatedAt` pulled so far.
   Each entity is decrypted and merged into the vault; one marked `isDeleted` is removed.
2. **Push.** Each item with a pending change is encrypted and sent: `POST /authenticator/entity` for a new one, which
   answers with its id and `updatedAt`, and `PUT /authenticator/entity` (`id`, `encryptedData`, `header`) for a
   changed one. A `404` means another device deleted it meanwhile, and the item is dropped.

**Conflicts** are settled per entity by the server's `updatedAt`. Each item remembers the `updatedAt` of the version its change was made on. A pulled
version replaces the item, pending change or not, if it is newer than that; otherwise the pending change is kept
and uploaded. So a change made here wins unless another device changed the same account since this device last
synced, and a deletion on the server always wins. To tell its own update apart from another device's when it comes
back in the diff (`PUT` answers without the new time), an item remembers what it uploaded last. A `POST` whose
answer was lost isn't uploaded twice: an entity in the diff with the same plain text as an item waiting to be added
is taken to be that item. Ente's server has no compare-and-swap, so two devices writing the same entity within one
sync of each other can still overwrite each other; the last write wins there.

A sync needs the saved session. It is unlocked with Face ID or Touch ID (Touch ID or the password on the Mac) the
first time it is needed after the app starts, and then kept in memory until the app quits. The app syncs:

- when it comes to the foreground, asking for the unlock only once per launch,
- when the list is pulled down (iPhone and iPad) or refreshed (Mac), which also shows errors,
- after each change made in the app,
- when the network comes back while changes are waiting.

Offline, or when the unlock is cancelled, changes wait in the vault and the codes keep working. When the server
rejects the session, the session is forgotten as before but the vault is kept: the codes still work, and the
waiting changes are uploaded once the password has been entered again. Signing in to another account replaces the
vault.

### Apple Watch

The watch gets its accounts from the vault: whenever the vault changes while the session is unlocked, and
**Show Ente Auth accounts on Apple Watch** is on, the time-based accounts are sent as before. So accounts added or
changed in the app, and ones pulled from other devices, reach the watch without opening the sync sheet.

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

Saving deletes any earlier keychain item and adds a new one, because updating an item keeps the access control it
was added with. Sessions saved by earlier versions, protected by Touch ID only on the Mac, are saved again with
the current access control the first time they are unlocked.

The email and server are kept in the app's preferences, so the account is shown without unlocking: in the sheet,
and with **Sign out** in the settings (the YubiKey configuration on iPhone and iPad, Settings ▸ General on the
Mac). **Sign out** asks for the unlock to read the token, deletes the token, the key, the account and the vault right
away, and then revokes the token with `POST /users/logout` without waiting for the answer. If the unlock is cancelled
or the server can't be reached, the account is still deleted from the device. Changes that weren't uploaded yet are
lost, and the confirmation says so.

The vault is a file in the app's Application Support folder (`EnteAuth/Vault`), encrypted with ChaChaPoly
(CryptoKit) under a random 256-bit key. The key is in the keychain as `WhenUnlockedThisDeviceOnly`: it never leaves
the device or goes into a backup, and it can be read without Face ID or Touch ID, so the codes show at once, like in
any authenticator app. On iPhone and iPad the file also has complete data protection. It is excluded from backups,
which couldn't decrypt it anyway; a restored device syncs the vault again from Ente. It holds the decrypted entities,
including their secrets, the time of the last pull, and the changes waiting to be uploaded. Without a saved session
there is no vault.

When the server rejects the token (`401`), e.g. because the session was ended from another device, or when Face ID
or Touch ID changed and the keychain item can no longer be read, the token and key are deleted but the account is
kept. The sheet then asks for the password of that account again and saves the new session.

With **Stay signed in** turned off, nothing is stored and there is no vault: the accounts are only shown in the sheet
for copying onto the YubiKey. The session only lives while the sheet is open, and when it closes the token is
revoked with `POST /users/logout`.

`EnteSessionStore.unlock()` returns the server, token and authenticator key of the saved account after the unlock.
`EnteCloud` uses it to sync.

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
| `EnteAuthenticatorSync.swift` | Downloads, decrypts and parses the accounts, and pages through the diff |
| `EnteVault.swift` | The vault: entities with their pending changes, the conflict rule, editing entities like Ente Auth, codes and the encrypted file |
| `EnteCloud.swift` | Keeps the vault in step with Ente: unlocking, pulling, pushing, and the changes made in the app |
| `EnteSessionStore.swift` | The saved account and session in the keychain |
| `EnteAccountSection.swift` | The saved account and **Sign out** in the settings |
| `EnteSyncViewModel.swift`, `EnteSyncView.swift` | The sheet |
| `FakeEnteServer.swift` | The demo server for Debug builds in the simulator and on the Mac, and the tests |

Outside that folder the feature adds a menu item, buttons in the empty account list and a sheet in `MainView`, the
toggle in `AddAccountView`, and
`MainViewModel.addAccounts(_:requiresTouch:completion:)` / `OATHSession.addCredentials(templates:requiresTouch:)`,
which add several accounts in one YubiKey session. For the vault, `Account` has a `location` (`.yubiKey` or
`.ente(id:)`), `MainViewModel` keeps `keyAccounts` and `cloudAccounts` and lists both as `accounts`, and edits,
deletes and HOTP calculations of an Ente Auth account go to `EnteCloud` instead of the YubiKey.

The fake server handles the write endpoints too (`POST`, `PUT` and `DELETE /authenticator/entity`), with an
`updatedAt` that grows with every change and a diff that returns what changed after `sinceTime`, so the two-way sync
can be tried in the simulator and is tested end to end, including another device writing the same account.

It uses two packages: [swift-sodium](https://github.com/jedisct1/swift-sodium) (ISC, only its `Clibsodium`
product, i.e. libsodium) and [BigInt](https://github.com/attaswift/BigInt) (MIT) for the SRP arithmetic.

Tests are in `AuthenticatorTests/EnteAuth/`. The SRP test uses the vector from Ente's Rust client, whose M1 was
generated by Ente's Go server, so it checks compatibility with the server without network access.

## Limitations

- Accounts already on a YubiKey can't be copied to Ente, only new ones while they are added.
- Accounts removed from the YubiKey aren't removed from Ente Auth, and the other way round.
- Ente's tags, notes and icons are kept in the vault but not shown, and they and the pin aren't carried over to the
  YubiKey.
- A conflict keeps one whole version of the account, the newer one on the server. Changes to different fields aren't
  merged.
- The passkey flow opens Ente's accounts site in the browser and has to be confirmed in the app afterwards.
