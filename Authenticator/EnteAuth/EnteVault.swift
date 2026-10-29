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

/// An Ente Auth entity kept on the device.
nonisolated struct EnteVaultItem: Codable, Sendable, Equatable, Identifiable {
    /// Stays the same for the life of the item: the entity id for items from Ente, a new id for ones added here.
    let id: String
    /// The id on Ente's server, nil until an item added here has been uploaded.
    var entityID: String?
    /// The decrypted entity, in the format Ente's apps store. Nil if it couldn't be decrypted.
    var rawData: String?
    /// When the server version this item is based on was written, 0 before it was uploaded.
    var serverUpdatedAt: Int64
    /// Changed here and not uploaded yet.
    var isPending: Bool
    /// The data of the last update uploaded, so it is recognized when it comes back in the diff.
    var uploadedRawData: String?

    var isTrashed: Bool {
        rawData.map { EnteEntry(rawData: $0).isTrashed } ?? false
    }
}

/// The copy of an Ente Auth account's entities on the device, with the changes made here that are waiting to be
/// uploaded.
///
/// Conflicts are settled per entity, by the server's `updatedAt`: a pulled version replaces the item unless the item
/// has a pending change based on that same version or a later one. So a change made here is uploaded unless another
/// device changed the entity since this device last saw it, in which case the other device's version wins and the
/// change made here is dropped. An entity deleted on the server is deleted here, pending change or not.
nonisolated struct EnteVault: Codable, Sendable, Equatable {
    let email: String
    let server: URL
    /// The latest `updatedAt` pulled, where the next pull starts.
    var lastSyncTime: Int64 = 0
    var items: [EnteVaultItem] = []

    init(email: String, server: URL) {
        self.email = email
        self.server = server
    }

    func belongs(to session: EnteSavedSession) -> Bool {
        email.lowercased() == session.email.lowercased() && server == session.server
    }

    var hasPendingChanges: Bool {
        items.contains(where: \.isPending)
    }

    /// Merges entities pulled from the server, decrypted, and remembers where to pull from next time.
    mutating func merge(_ pulled: [(entity: EnteAuthenticatorEntity, rawData: String?)], latest: Int64) {
        for (entity, rawData) in pulled.sorted(by: { $0.entity.updatedAt < $1.entity.updatedAt }) {
            let index = items.firstIndex { $0.entityID == entity.id }
                // An item whose upload reached the server although its answer didn't.
                ?? items.firstIndex { $0.entityID == nil && $0.rawData != nil && $0.rawData == rawData && !entity.isDeleted }
            guard !entity.isDeleted else {
                if let index { items.remove(at: index) }
                continue
            }
            guard let index else {
                items.append(EnteVaultItem(id: entity.id, entityID: entity.id, rawData: rawData, serverUpdatedAt: entity.updatedAt,
                                           isPending: false))
                continue
            }
            var item = items[index]
            if item.entityID == nil {
                item.entityID = entity.id
                item.serverUpdatedAt = entity.updatedAt
                item.isPending = false
            } else if let uploaded = item.uploadedRawData, uploaded == rawData {
                // This device's own update. Changes made since it was uploaded stay pending.
                item.serverUpdatedAt = entity.updatedAt
                item.uploadedRawData = nil
            } else if !item.isPending || entity.updatedAt > item.serverUpdatedAt {
                item.rawData = rawData
                item.serverUpdatedAt = entity.updatedAt
                item.isPending = false
                item.uploadedRawData = nil
            }
            items[index] = item
        }
        lastSyncTime = max(lastSyncTime, latest)
    }

    /// Adds an item to upload. Returns its id.
    mutating func add(rawData: String) -> String {
        let id = "local-" + UUID().uuidString.lowercased()
        items.append(EnteVaultItem(id: id, entityID: nil, rawData: rawData, serverUpdatedAt: 0, isPending: true))
        return id
    }

    /// Changes an item's data and marks it for upload. Returns false if the item doesn't exist, can't be read, or
    /// the change leaves it as it was.
    mutating func edit(_ id: String, _ change: (inout EnteEntryEditor) -> Void) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), let rawData = items[index].rawData,
              var editor = EnteEntryEditor(rawData: rawData) else { return false }
        change(&editor)
        guard let newRawData = editor.rawData, newRawData != rawData else { return false }
        items[index].rawData = newRawData
        items[index].isPending = true
        return true
    }

    /// Records that `rawData` was uploaded for the item, as a new entity if `created` is set.
    mutating func markUploaded(_ id: String, rawData: String, created: EnteAuthenticatorEntity?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let created {
            items[index].entityID = created.id
            items[index].serverUpdatedAt = created.updatedAt
        } else {
            items[index].uploadedRawData = rawData
        }
        // Changed again while it was uploading, so it's uploaded again.
        if items[index].rawData == rawData {
            items[index].isPending = false
        }
    }

    mutating func remove(_ id: String) {
        items.removeAll { $0.id == id }
    }
}

// MARK: - Editing entities

/// Reads and changes the plain text of an entity the way Ente Auth does, keeping what this app doesn't use, e.g.
/// tags, notes and icons. The result is in the format Ente Auth writes: a JSON string holding the otpauth URL, with
/// the display settings in its `codeDisplay` parameter.
nonisolated struct EnteEntryEditor {

    private var components: URLComponents
    private var display: [String: Any]

    init?(rawData: String) {
        var urlString: String?
        var display = [String: Any]()
        if let json = try? JSONSerialization.jsonObject(with: Data(rawData.utf8), options: .fragmentsAllowed) {
            if let string = json as? String {
                urlString = string
            } else if let object = json as? [String: Any] {
                urlString = object["rawData"] as? String
                display = object["display"] as? [String: Any] ?? [:]
            }
        } else if rawData.hasPrefix("otpauth://") {
            urlString = rawData
        }
        guard let urlString, var components = URLComponents(string: urlString.replacingOccurrences(of: "#", with: "%23")),
              components.scheme?.lowercased() == "otpauth" else { return nil }
        if let codeDisplay = Self.value(of: "codeDisplay", in: components),
           let parameter = try? JSONSerialization.jsonObject(with: Data(codeDisplay.utf8)) as? [String: Any] {
            display.merge(parameter) { _, new in new }
        }
        components.percentEncodedQueryItems = components.percentEncodedQueryItems?.filter { $0.name != "codeDisplay" }
        self.components = components
        self.display = display
    }

    init?(otpauthURL url: URL) {
        guard let rawData = try? String(data: JSONEncoder().encode(url.absoluteString), encoding: .utf8) else { return nil }
        self.init(rawData: rawData)
    }

    var rawData: String? {
        var components = components
        guard let codeDisplay = try? JSONSerialization.data(withJSONObject: display, options: .sortedKeys) else { return nil }
        Self.set("codeDisplay", to: String(decoding: codeDisplay, as: UTF8.self), in: &components)
        guard let url = components.string else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(url)).map { String(decoding: $0, as: UTF8.self) }
    }

    var isPinned: Bool {
        get { display["pinned"] as? Bool == true }
        set { display["pinned"] = newValue }
    }

    var isTrashed: Bool {
        get { display["trashed"] as? Bool == true }
        set { display["trashed"] = newValue }
    }

    /// The counter of a HOTP account.
    var counter: UInt64? {
        get { Self.value(of: "counter", in: components).flatMap { UInt64($0) } }
        set { Self.set("counter", to: newValue.map(String.init), in: &components) }
    }

    /// Changes the label and the `issuer` parameter, like Ente Auth's edit screen does.
    mutating func rename(issuer: String?, accountName: String) {
        let issuer = issuer.flatMap { $0.isEmpty ? nil : $0 }
        components.path = "/" + [issuer, accountName].compactMap { $0 }.joined(separator: ":")
        Self.set("issuer", to: issuer, in: &components)
    }

    private static func value(of name: String, in components: URLComponents) -> String? {
        components.queryItems?.first { $0.name == name }?.value
    }

    /// Sets a parameter, or removes it when the value is nil. The other parameters are kept as they are encoded.
    /// '+' is encoded too, as Ente's apps read it as a space.
    private static func set(_ name: String, to value: String?, in components: inout URLComponents) {
        var items = components.percentEncodedQueryItems ?? []
        let encoded = value.map {
            $0.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? $0
        }
        if let index = items.firstIndex(where: { $0.name == name }) {
            if let encoded {
                items[index].value = encoded
            } else {
                items.remove(at: index)
            }
        } else if let encoded {
            items.append(URLQueryItem(name: name, value: encoded))
        }
        components.percentEncodedQueryItems = items.isEmpty ? nil : items
    }

    private static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
}

// MARK: - Codes

/// An account in the vault whose codes are calculated on the device.
nonisolated struct EnteCloudCode: Sendable, Equatable {

    enum Kind: Sendable, Equatable {
        case totp, steam, hotp
    }

    let issuer: String?
    let accountName: String
    let kind: Kind
    let secret: Data
    let algorithm: OTPAccount.Algorithm
    let digits: Int
    /// Seconds per code, 0 for HOTP.
    let period: Int
    /// The counter of the next HOTP code.
    let counter: UInt64
    let isPinned: Bool

    /// Returns nil for accounts in Ente's trash and data that can't be read or used.
    init?(rawData: String) {
        let entry = EnteEntry(rawData: rawData)
        guard let components = entry.components, !entry.isTrashed else { return nil }
        if components.host?.lowercased() == "hotp" {
            let items = Dictionary(components.queryItems?.map { ($0.name.lowercased(), $0.value ?? "") } ?? [],
                                   uniquingKeysWith: { first, _ in first })
            guard let secret = items["secret"].flatMap(OTPAuthURLParser.base32Decode), !secret.isEmpty else { return nil }
            let algorithm: OTPAccount.Algorithm
            switch items["algorithm"]?.uppercased() ?? "SHA1" {
            case "SHA1", "": algorithm = .sha1
            case "SHA256": algorithm = .sha256
            case "SHA512": algorithm = .sha512
            default: return nil
            }
            let digits = items["digits"].flatMap { Int($0) } ?? 6
            guard (1...10).contains(digits) else { return nil }
            let (issuer, accountName) = OTPAuthURLParser.label(of: components)
            self.init(issuer: issuer, accountName: accountName, kind: .hotp, secret: secret, algorithm: algorithm, digits: digits,
                      period: 0, counter: items["counter"].flatMap { UInt64($0) } ?? 0, isPinned: entry.isPinned)
        } else {
            guard let account = OTPAuthURLParser.account(id: "", components: components, isPinned: entry.isPinned) else { return nil }
            self.init(issuer: account.issuer, accountName: account.accountName, kind: account.kind == .steam ? .steam : .totp,
                      secret: account.secret, algorithm: account.algorithm, digits: account.digits, period: account.period,
                      counter: 0, isPinned: account.isPinned)
        }
    }

    private init(issuer: String?, accountName: String, kind: Kind, secret: Data, algorithm: OTPAccount.Algorithm, digits: Int,
                 period: Int, counter: UInt64, isPinned: Bool) {
        self.issuer = issuer
        self.accountName = accountName
        self.kind = kind
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.counter = counter
        self.isPinned = isPinned
    }

    /// Whether both are the same account, ignoring the pin and the HOTP counter.
    func isSameAccount(as other: EnteCloudCode) -> Bool {
        (issuer, accountName, kind) == (other.issuer, other.accountName, other.kind)
            && (secret, algorithm, digits, period) == (other.secret, other.algorithm, other.digits, other.period)
    }

    /// The time-based code valid at `date` and when it is valid. HOTP codes are calculated with `hotpCode()`.
    func code(at date: Date) -> (code: String, validity: DateInterval) {
        let account = OTPAccount(id: "", kind: kind == .steam ? .steam : .totp, issuer: issuer, accountName: accountName, secret: secret,
                                 algorithm: algorithm, digits: digits, period: max(1, period), isPinned: isPinned)
        let period = Double(max(1, period))
        let start = (max(0, date.timeIntervalSince1970) / period).rounded(.down) * period
        return (OTPGenerator.code(for: account, at: date), DateInterval(start: Date(timeIntervalSince1970: start), duration: period))
    }

    /// The HOTP code for the current counter. The counter must be moved on once it has been shown.
    func hotpCode() -> String {
        OTPGenerator.hotp(secret: secret, counter: counter, algorithm: algorithm, digits: digits)
    }
}

// MARK: - Storage

enum EnteVaultError: Error {
    case unreadable
}

/// Where the vault is kept: an encrypted file in the app, memory in the tests.
nonisolated protocol EnteVaultStorage: Sendable {
    func load() throws -> EnteVault?
    func save(_ vault: EnteVault) throws
    func remove()
}

/// The key the vault file is encrypted with.
nonisolated protocol EnteVaultKeychain: Sendable {
    func existingKey() throws -> SymmetricKey?
    func createKey() throws -> SymmetricKey
    func removeKey()
}

/// Keeps the vault in a file encrypted with ChaChaPoly, with a random key in the keychain that is only readable on
/// this device while it is unlocked. The file is excluded from backups, which couldn't decrypt it anyway.
nonisolated struct EnteVaultFile: EnteVaultStorage {

    let url: URL
    let keychain: EnteVaultKeychain

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(components: "EnteAuth", "Vault")
    }

    init(url: URL = defaultURL, keychain: EnteVaultKeychain = EnteVaultKeychainKey()) {
        self.url = url
        self.keychain = keychain
    }

    func load() throws -> EnteVault? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let key = try keychain.existingKey() else { throw EnteVaultError.unreadable }
        do {
            let box = try ChaChaPoly.SealedBox(combined: try Data(contentsOf: url))
            return try JSONDecoder().decode(EnteVault.self, from: try ChaChaPoly.open(box, using: key))
        } catch {
            throw EnteVaultError.unreadable
        }
    }

    func save(_ vault: EnteVault) throws {
        let key = try keychain.existingKey() ?? keychain.createKey()
        let sealed = try ChaChaPoly.seal(try JSONEncoder().encode(vault), using: key).combined
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try sealed.write(to: url, options: .atomic)
        #endif
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
        keychain.removeKey()
    }
}

/// The vault key in the keychain: `WhenUnlockedThisDeviceOnly`, so it never leaves the device and can be read
/// without Face ID or Touch ID, like the codes of any authenticator app.
nonisolated struct EnteVaultKeychainKey: EnteVaultKeychain {

    private let service = "EnteAuth.Vault"
    private let account = "key"

    private var query: [String: Any] {
        var query: [String: Any] = [String(kSecClass): kSecClassGenericPassword,
                                    String(kSecAttrService): service,
                                    String(kSecAttrAccount): account]
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
            guard let data = result as? Data else { throw SecureStoreError.dataCastError }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStoreError.unhandledError(message: SecCopyErrorMessageString(status, nil) as String? ?? String(status))
        }
    }

    func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        var query = query
        query[String(kSecValueData)] = key.withUnsafeBytes { Data($0) }
        query[String(kSecAttrAccessible)] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemDelete(self.query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStoreError.unhandledError(message: SecCopyErrorMessageString(status, nil) as String? ?? String(status))
        }
        return key
    }

    func removeKey() {
        SecItemDelete(query as CFDictionary)
    }
}
