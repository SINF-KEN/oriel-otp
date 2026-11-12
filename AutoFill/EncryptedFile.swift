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

import CryptoKit
import Foundation
import OSLog

nonisolated enum EncryptedFileError: Error {
    /// The file or its key can't be decrypted, e.g. because the device was restored from a backup, or the file was
    /// written by a later version of the app.
    case unreadable
    /// The file or its key can't be read right now, e.g. until the device is unlocked.
    case unavailable
}

/// The key a file is encrypted with.
nonisolated protocol EncryptedFileKey: Sendable {
    func existingKey() throws -> SymmetricKey?
    func createKey() throws -> SymmetricKey
    func removeKey()
}

/// A value kept in a file encrypted with ChaChaPoly, with a random key in the keychain that is only readable on this
/// device while it is unlocked. The file is excluded from backups, which couldn't decrypt it anyway.
nonisolated struct EncryptedFile<Value: Codable> {

    let url: URL
    let keychain: EncryptedFileKey

    func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let key = try keychain.existingKey() else { throw EncryptedFileError.unreadable }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Its data protection keeps it closed while the device is locked.
            throw EncryptedFileError.unavailable
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: data)
            return try JSONDecoder().decode(Value.self, from: try ChaChaPoly.open(box, using: key))
        } catch {
            throw EncryptedFileError.unreadable
        }
    }

    func save(_ value: Value) throws {
        let key = try keychain.existingKey() ?? keychain.createKey()
        let sealed = try ChaChaPoly.seal(try JSONEncoder().encode(value), using: key).combined
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try sealed.write(to: url, options: .atomic)
        #endif
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            Logger.system.error("Couldn't exclude \(url.lastPathComponent, privacy: .public) from backups: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
        keychain.removeKey()
    }

    private static var setAsidePrefix: String { "Unreadable-" }

    /// Moves a file that couldn't be read out of the way, so saving doesn't write over it. It stays next to the new
    /// one with the same key, so a version of the app that can read it, e.g. the one that wrote it before a
    /// downgrade, still can: see `recoverSetAside`.
    func setAside() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let folder = url.deletingLastPathComponent()
        let stamp = Int(Date().timeIntervalSince1970)
        var target = folder.appending(path: "\(Self.setAsidePrefix)\(stamp)")
        var copy = 1
        // Two files set aside in the same second mustn't fail the second move.
        while FileManager.default.fileExists(atPath: target.path) {
            copy += 1
            target = folder.appending(path: "\(Self.setAsidePrefix)\(stamp)-\(copy)")
        }
        try FileManager.default.moveItem(at: url, to: target)
    }

    /// Hands over the value of each file set aside that can be read now, oldest first, and deletes the file unless
    /// `keep` throws. A file that still can't be read stays: it may be the only copy of what is in it.
    func recoverSetAside(_ keep: (Value) throws -> Void) {
        let folder = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names.filter({ $0.hasPrefix(Self.setAsidePrefix) }).sorted() {
            let file = EncryptedFile(url: folder.appending(path: name), keychain: keychain)
            guard let value = try? file.load() else { continue }
            do {
                try keep(value)
                try FileManager.default.removeItem(at: file.url)
            } catch {
                continue
            }
        }
    }
}

/// A file's key in the keychain: `WhenUnlockedThisDeviceOnly`, so it never leaves the device and can be read without
/// Face ID or Touch ID, like the codes of any authenticator app.
nonisolated struct KeychainFileKey: EncryptedFileKey {

    private let item: KeychainItem

    /// - Parameter group: `.shared` for a file the AutoFill extension reads.
    init(service: String, group: KeychainItem.Group = .app) {
        item = KeychainItem(service: service, account: "key", group: group)
    }

    func existingKey() throws -> SymmetricKey? {
        do {
            return try item.data().map { SymmetricKey(data: $0) }
        } catch .unavailable {
            throw EncryptedFileError.unavailable
        }
    }

    func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        try item.setData(key.withUnsafeBytes { Data($0) })
        return key
    }

    func removeKey() {
        item.delete()
    }
}
