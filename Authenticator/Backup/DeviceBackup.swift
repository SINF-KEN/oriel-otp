/*
 * Copyright (C) 2026 Kenzi Voyer.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *       http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

enum DeviceBackupError: Error, LocalizedError, Equatable {
    /// The file isn't an encrypted export in Ente Auth's format.
    case notABackup
    /// A later version of the format, or key limits this app doesn't take.
    case unsupported
    /// The password is wrong, or the file was changed.
    case wrongPassword
    /// Deriving the key takes more memory than the system leaves the app.
    case notEnoughMemory
    /// There's nothing to back up.
    case noAccounts

    var errorDescription: String? {
        switch self {
        case .notABackup:
            String(
                localized: "This file isn't a backup made by Oriel OTP or an encrypted export from Ente Auth.",
                comment: "Backup restore error")
        case .unsupported:
            String(localized: "This backup was made in a way this version of the app can't read.", comment: "Backup restore error")
        case .wrongPassword:
            String(localized: "The password is wrong, or the file is damaged.", comment: "Backup restore error")
        case .notEnoughMemory:
            String(
                localized:
                    "This device doesn't have enough free memory to open this backup. Close other apps and try again, or restore it on another device.",
                comment: "Backup restore error")
        case .noAccounts:
            String(localized: "There are no accounts on this device to back up.", comment: "Backup error")
        }
    }
}

/// A password-protected file holding the accounts kept only on this device, the only copy of which is otherwise lost
/// with the device.
///
/// It is Ente Auth's encrypted export, so Ente Auth imports it too, and the app restores Ente Auth's exports:
///
///     {"version": 1, "kdfParams": {"memLimit": …, "opsLimit": …, "salt": "…"}, "encryptedData": "…", "encryptionNonce": "…"}
///
/// The key is Argon2id over the password with the salt and limits, and the data is one XChaCha20-Poly1305 secretstream
/// message, with its header in `encryptionNonce`. It decrypts to one otpauth URL per line, which carries the account's
/// pin, tags and icon in Ente's `codeDisplay` parameter and the counter of a HOTP account.
nonisolated enum DeviceBackup {

    /// The file can be tried offline as often as someone likes, so the password is all that protects it.
    static let minimumPasswordLength = 8

    /// Larger files aren't read. An account takes a few hundred bytes.
    static let maximumFileSize = 8 * 1024 * 1024

    /// The most memory deriving the key of a new backup takes: libsodium's moderate limit, which Ente's apps use on
    /// devices short of memory, with 16 passes for the same work as the sensitive limits. A backup is for another
    /// device, which may be a smaller one than this.
    static let maximumMemory: UInt64 = 256 * 1024 * 1024

    private struct File: Codable {
        struct KeyLimits: Codable {
            let memLimit: UInt64
            let opsLimit: UInt64
            let salt: String
        }

        let version: Int
        let kdfParams: KeyLimits
        let encryptedData: String
        let encryptionNonce: String
    }

    /// Encrypts the accounts, given as `DeviceAccountItem.rawData`. This derives a key, which is slow and memory
    /// hungry by design: call it off the main actor.
    static func encrypt(rawData: [String], password: String) throws -> Data {
        let lines = rawData.compactMap(line(forRawData:))
        guard !lines.isEmpty else { throw DeviceBackupError.noAccounts }
        var derived = try EnteCrypto.deriveNewKeyEncryptionKey(password: password, maximumMemory: maximumMemory)
        defer { derived.key.wipe() }
        // Each line ends with a line break, like Ente's.
        var plainText = Data(lines.map { $0 + "\n" }.joined().utf8)
        defer { plainText.wipe() }
        let (header, cipherText) = try EnteCrypto.secretStreamEncrypt(plainText, key: derived.key)
        let file = File(
            version: 1, kdfParams: .init(memLimit: derived.memLimit, opsLimit: derived.opsLimit, salt: derived.salt.base64EncodedString()),
            encryptedData: cipherText.base64EncodedString(), encryptionNonce: header.base64EncodedString())
        return try JSONEncoder().encode(file)
    }

    /// Decrypts a backup. Returns its lines, one account each, for `DeviceAccounts.restore`. This derives a key, which
    /// is slow and memory hungry by design: call it off the main actor.
    static func decrypt(_ data: Data, password: String) throws -> [String] {
        guard data.count <= maximumFileSize, let file = try? JSONDecoder().decode(File.self, from: data),
            let salt = Data(base64Encoded: file.kdfParams.salt), let cipherText = Data(base64Encoded: file.encryptedData),
            let header = Data(base64Encoded: file.encryptionNonce)
        else { throw DeviceBackupError.notABackup }
        // The limits aren't authenticated: ones outside what Ente's apps use could keep the app busy for minutes.
        guard file.version == 1, EnteCrypto.isAllowed(opsLimit: file.kdfParams.opsLimit, memLimit: file.kdfParams.memLimit) else {
            throw DeviceBackupError.unsupported
        }
        // Running out of memory on iOS ends the app rather than failing.
        guard EnteCrypto.hasMemory(for: file.kdfParams.memLimit) else { throw DeviceBackupError.notEnoughMemory }
        do {
            var key = try EnteCrypto.deriveKeyEncryptionKey(
                password: password, salt: salt, opsLimit: file.kdfParams.opsLimit,
                memLimit: file.kdfParams.memLimit)
            defer { key.wipe() }
            var plainText = try EnteCrypto.secretStreamDecrypt(cipherText, header: header, key: key)
            defer { plainText.wipe() }
            return String(decoding: plainText, as: UTF8.self).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } catch EnteCryptoError.keyDerivationFailed {
            throw DeviceBackupError.notEnoughMemory
        } catch EnteCryptoError.decryptionFailed {
            throw DeviceBackupError.wrongPassword
        } catch EnteCryptoError.invalidLength {
            throw DeviceBackupError.notABackup
        }
    }

    /// Whether data is a backup, whatever its password, to turn down another file before asking for one.
    static func isBackup(_ data: Data) -> Bool {
        data.count <= maximumFileSize && (try? JSONDecoder().decode(File.self, from: data)) != nil
    }

    /// The line of an account in the backup: its otpauth URL with the display settings in `codeDisplay`. Commas are
    /// escaped like Ente's export does. Nil for data that can't be read, which no app could restore.
    static func line(forRawData rawData: String) -> String? {
        guard let json = EnteEntryEditor(rawData: rawData)?.rawData,
            let url = try? JSONDecoder().decode(String.self, from: Data(json.utf8)),
            !url.contains(where: \.isNewline)
        else { return nil }
        return url.replacingOccurrences(of: ",", with: "%2C")
    }

    /// The data to keep for a line of a backup, in the format `DeviceAccounts` stores. Nil if it isn't an account.
    static func rawData(forLine line: String) -> String? {
        EnteEntryEditor(rawData: line)?.rawData
    }

    /// The name suggested for a new backup, like Ente's with the app's name: the date sorts and tells backups apart.
    static func fileName(at date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "oriel-otp-backup-\(formatter.string(from: date))"
    }
}
