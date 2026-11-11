# Backing up the accounts on this device

Accounts saved to **This device** have one copy: an encrypted file whose key never leaves the device and which isn't in
the device's backups (see [ente-auth.md](ente-auth.md#what-is-stored)). **Back up accounts…** in the settings writes
them to a file protected by a password, and **Restore from backup…** reads one back, on this device or another.

Accounts on a YubiKey aren't in a backup, as the key never gives its secrets back, and neither are Ente Auth accounts,
which are in Ente Auth.

## The file

The file is Ente Auth's encrypted export, so Ente Auth imports a backup made here, as an encrypted export of its
own, and the app restores an encrypted export from Ente Auth:

```json
{
  "version": 1,
  "kdfParams": { "memLimit": 268435456, "opsLimit": 16, "salt": "…" },
  "encryptedData": "…",
  "encryptionNonce": "…"
}
```

- The key is Argon2id over the password, with the salt and limits in `kdfParams`.
- `encryptedData` is one final XChaCha20-Poly1305 secretstream message, with its header in `encryptionNonce`.
- It decrypts to one `otpauth://` URL per line. Ente's `codeDisplay` parameter carries the pin, tags and icon, and a
  HOTP account has its counter. Commas are written as `%2C`, like Ente's export does.

A new backup uses 256 MiB and 16 passes, which is the same work as libsodium's sensitive limits (1 GiB, 4 passes) and
what Ente's apps use on devices short of memory, so a backup made on a Mac opens on a phone. With less memory free, the
memory is halved and the passes doubled, down to 128 MiB.

## Making a backup

1. The app checks who is asking: the app lock's code or password if there is one, otherwise Face ID, Touch ID or the
   device passcode when the device has one. The file holds the secrets under a password its maker chooses, so someone
   handed the unlocked app could otherwise take them along.
2. The password is entered twice and has at least 8 characters. Nothing limits how often a password can be tried
   against a file, so the password is all that protects it. It isn't stored.
3. The key is derived off the main actor, which takes a few seconds, and the system's save dialog takes the encrypted
   file. The plain text is never written to disk.

## Restoring

The limits in the file aren't authenticated, so ones outside what Ente's apps write are refused before the key is
derived (`EnteCrypto.isAllowed`), as are files over 8 MB and limits that need more memory than iOS leaves the app, which
would end it rather than fail.

Each account is added unless the same account, with the same secret, is already on this device. One that is here stays
as it is, with its own HOTP counter, which may have moved on since the backup. Lines the app can't calculate codes for,
such as accounts in Ente Auth's trash, are skipped and counted. Nothing is added if the accounts can't all be saved.

A wrong password and a damaged file can't be told apart: either way the message doesn't authenticate.

## Importing from other apps

**Import from another app…**, in the same section, adds the accounts of another authenticator's export to this
device, with the same rule as restoring: an account that's here already is left as it is. It reads:

- Google Authenticator's export QR codes, `otpauth-migration://offline?data=…`, from a screenshot (every QR code in
  the image is read, with Core Image). Its accounts are a protocol buffer, decoded in `GoogleAuthenticatorMigration`;
  MD5 accounts are skipped. Scanning one of these codes in Add account says to import it instead.
- Aegis's JSON export without encryption, with its TOTP, HOTP and Steam entries.
- 2FAS's `.2fas` file without a password.
- Raivo's JSON.
- Text with one otpauth or otpauth-migration link per line.

Encrypted exports from Aegis, 2FAS and Raivo are recognized and turned down with a message to export without
encryption. A backup made by this app or Ente Auth picked here is restored with its password, as from **Restore from
backup…**. The export holds the secrets in plain text, so the section's footer says to delete it afterwards.

## Code

| File | Purpose |
| --- | --- |
| `Authenticator/Backup/DeviceBackup.swift` | The file format: encrypting, decrypting, and the line of an account |
| `Authenticator/Backup/BackupSection.swift` | The settings section and its two sheets |
| `Authenticator/Backup/AuthenticatorImport.swift` | Other apps' exports, as otpauth URLs |
| `Authenticator/Backup/AuthenticatorImportFile.swift` | The file types, and the QR codes in a screenshot |
| `DeviceAccounts.restore(backupLines:)` | Adds the accounts of a backup |
| `AuthenticatorTests/Backup/DeviceBackupTests.swift` | Includes a file made with PyNaCl the way Ente Auth makes one |
| `AuthenticatorTests/Backup/AuthenticatorImportTests.swift` | Each format, and a QR code drawn into a PNG |
