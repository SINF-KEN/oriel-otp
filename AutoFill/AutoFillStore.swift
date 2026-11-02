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

/// The app group the app shares with the AutoFill extension.
nonisolated enum AppGroup {
    static let identifier = "group.io.github.sinf-ken.OrielOTP"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}

/// An account whose codes AutoFill can fill in, with the websites they are suggested on.
nonisolated struct AutoFillAccount: Codable, Sendable, Hashable, Identifiable {
    let account: OTPAccount
    /// Domains, e.g. `github.com`. Their subdomains match too.
    let websites: [String]

    var id: String { account.id }
}

nonisolated enum AutoFillStoreError: Error {
    /// The file or its key can't be read until the device is unlocked.
    case unavailable
    /// The file or its key can't be decrypted, e.g. because the device was restored from a backup.
    case unreadable
}

/// Where the AutoFill accounts are kept: an encrypted file in the app group, memory in the tests.
nonisolated protocol AutoFillStorage: Sendable {
    /// Nil when there is no file, i.e. the app hasn't written one or there are no accounts.
    func load() throws -> [AutoFillAccount]?
    func save(_ accounts: [AutoFillAccount]) throws
    func remove()
}

/// The time-based Ente Auth accounts, written by the app for the AutoFill extension, which can't read the Ente vault.
///
/// Kept like the vault: a file encrypted with ChaChaPoly, with a random key in the keychain that is only readable on
/// this device while it is unlocked, and excluded from backups.
nonisolated struct AutoFillFile: AutoFillStorage {

    let url: URL?
    let keychain: AutoFillKeychainKey

    static var defaultURL: URL? {
        AppGroup.containerURL?.appending(components: "AutoFill", "Accounts")
    }

    init(url: URL? = defaultURL, keychain: AutoFillKeychainKey = AutoFillKeychainKey()) {
        self.url = url
        self.keychain = keychain
    }

    func load() throws -> [AutoFillAccount]? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let key = try keychain.existingKey() else { throw AutoFillStoreError.unreadable }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Its data protection keeps it closed while the device is locked.
            throw AutoFillStoreError.unavailable
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: data)
            return try JSONDecoder().decode([AutoFillAccount].self, from: try ChaChaPoly.open(box, using: key))
        } catch {
            throw AutoFillStoreError.unreadable
        }
    }

    func save(_ accounts: [AutoFillAccount]) throws {
        guard let url else { throw AutoFillStoreError.unavailable }
        guard !accounts.isEmpty else {
            remove()
            return
        }
        let key = try keychain.existingKey() ?? keychain.createKey()
        let sealed = try ChaChaPoly.seal(try JSONEncoder().encode(accounts), using: key).combined
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try sealed.write(to: url, options: .atomic)
        #endif
        var fileURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? fileURL.setResourceValues(values)
    }

    func remove() {
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        keychain.removeKey()
    }
}

/// The key of the AutoFill file in the keychain group the app shares with the extension: `WhenUnlockedThisDeviceOnly`,
/// so it never leaves the device.
nonisolated struct AutoFillKeychainKey: Sendable {

    private var query: [String: Any] {
        var query: [String: Any] = [String(kSecClass): kSecClassGenericPassword,
                                    String(kSecAttrService): "AutoFill.Accounts",
                                    String(kSecAttrAccount): "key"]
        #if os(macOS)
        query[String(kSecUseDataProtectionKeychain)] = true
        #endif
        return query
    }

    func existingKey() throws -> SymmetricKey? {
        var query = query
        query[String(kSecReturnData)] = true
        query[String(kSecMatchLimit)] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw AutoFillStoreError.unreadable }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw AutoFillStoreError.unavailable
        default:
            throw Self.error(status)
        }
    }

    func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        var query = query
        query[String(kSecValueData)] = key.withUnsafeBytes { Data($0) }
        query[String(kSecAttrAccessible)] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemDelete(self.query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(status) }
        return key
    }

    func removeKey() {
        SecItemDelete(query as CFDictionary)
    }

    private static func error(_ status: OSStatus) -> Error {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? String(status)])
    }
}
