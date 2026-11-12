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
    /// The data of the last upload, recorded before it is sent, so it is recognized when it comes back in the diff, also
    /// when the server's answer was lost.
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
/// change made here is dropped. An entity deleted on the server is deleted here, pending change or not. A HOTP counter
/// never moves back, as the codes before it have been shown: the higher of the two counters is kept.
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
        belongs(email: session.email, server: session.server)
    }

    /// The same server can be written in more than one way, e.g. with a trailing slash.
    func belongs(email: String, server: URL) -> Bool {
        self.email.lowercased() == email.lowercased() && EnteAPIClient.isSameServer(self.server, server)
    }

    /// The accounts added here that never reached Ente, which the vault is the only copy of.
    var accountsNeverUploaded: [String] {
        items.filter { $0.entityID == nil && !$0.isTrashed }.compactMap(\.rawData)
    }

    var hasPendingChanges: Bool {
        items.contains(where: \.isPending)
    }

    /// Merges entities pulled from the server, decrypted, and remembers where to pull from next time.
    mutating func merge(_ pulled: [(entity: EnteAuthenticatorEntity, rawData: String?)], latest: Int64) {
        // By id too, as they come from a dictionary: new accounts are listed in the same order on every device.
        for (entity, rawData) in pulled.sorted(by: { ($0.entity.updatedAt, $0.entity.id) < ($1.entity.updatedAt, $1.entity.id) }) {
            let index = items.firstIndex { $0.entityID == entity.id }
                // An item whose upload reached the server although its answer didn't, maybe changed since.
                ?? items.firstIndex { item in
                    item.entityID == nil && rawData != nil && !entity.isDeleted && (item.uploadedRawData == rawData || item.rawData == rawData)
                }
                // The same, changed on another device before this one saw it: still the account uploaded from here,
                // which the secret tells. Without this it would be listed twice, with two HOTP counters.
                ?? items.firstIndex { item in
                    guard item.entityID == nil, !entity.isDeleted, let uploaded = item.uploadedRawData, let rawData else { return false }
                    return Self.isSameSecret(uploaded, rawData)
                }
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
            // A version that can't be decrypted, e.g. written with another key, mustn't erase the copy that can.
            guard let rawData else { continue }
            if item.entityID == nil {
                item.entityID = entity.id
                item.serverUpdatedAt = entity.updatedAt
                if item.rawData != rawData, let uploaded = item.uploadedRawData, uploaded != rawData {
                    // Changed on another device since the upload, so that version wins, like for any other entity.
                    let merged = Self.keepingHigherCounter(of: item.rawData, in: rawData)
                    item.rawData = merged
                    item.isPending = merged != rawData
                } else {
                    item.isPending = item.rawData != rawData
                }
                item.uploadedRawData = nil
            } else if let uploaded = item.uploadedRawData, uploaded == rawData {
                // This device's own update. Changes made since it was uploaded stay pending.
                item.serverUpdatedAt = entity.updatedAt
                item.uploadedRawData = nil
            } else if !item.isPending || entity.updatedAt > item.serverUpdatedAt {
                let merged = Self.keepingHigherCounter(of: item.rawData, in: rawData)
                item.rawData = merged
                item.serverUpdatedAt = entity.updatedAt
                // A counter that moved further here is uploaded again.
                item.isPending = merged != rawData
                item.uploadedRawData = nil
            }
            items[index] = item
        }
        // A time far past the clock, saved before such times were refused, is replaced by one from a full pull.
        lastSyncTime = EnteAuthenticatorSync.isPlausible(updatedAt: lastSyncTime) ? max(lastSyncTime, latest) : latest
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

    /// Records that `rawData` is about to be uploaded for the item, so it is recognized in the diff even if the
    /// server's answer is lost.
    mutating func markUploading(_ id: String, rawData: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].uploadedRawData = rawData
    }

    /// Records that `rawData` was uploaded for the item, as a new entity if `created` is set.
    mutating func markUploaded(_ id: String, rawData: String, created: EnteAuthenticatorEntity?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let created {
            items[index].entityID = created.id
            items[index].serverUpdatedAt = created.updatedAt
            items[index].uploadedRawData = nil
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

    /// The pulled data, with the local HOTP counter if that one is further on. Codes up to the local counter have been
    /// shown here, so going back would show them again. Only for the same secret: an account that was given a new
    /// secret on another device starts at the counter that device set.
    private static func keepingHigherCounter(of local: String?, in pulled: String) -> String {
        guard let local, let localEditor = EnteEntryEditor(rawData: local), let localCounter = localEditor.counter,
              var editor = EnteEntryEditor(rawData: pulled), localEditor.isHOTP, editor.isHOTP,
              let secret = editor.secret, localEditor.secret == secret, localCounter > editor.counter ?? 0 else { return pulled }
        editor.counter = localCounter
        return editor.rawData ?? pulled
    }

    /// Whether both entities are of the same kind and calculate their codes from the same secret.
    private static func isSameSecret(_ first: String, _ second: String) -> Bool {
        guard let first = EnteEntryEditor(rawData: first), let second = EnteEntryEditor(rawData: second),
              let secret = first.secret, !secret.isEmpty else { return false }
        return secret == second.secret && first.isHOTP == second.isHOTP
    }
}

// MARK: - Editing entities

/// Reads and changes the plain text of an entity the way Ente Auth does, keeping what this app doesn't use, e.g.
/// tags, notes and icons. The result is in the format Ente Auth writes: a JSON string holding the otpauth URL, with
/// the display settings in its `codeDisplay` parameter.
nonisolated struct EnteEntryEditor {

    private var components: URLComponents
    private var display: [String: Any]

    /// Reads the entity with `EnteEntry.read`, like the list does, so an edit changes the account the list shows.
    init?(rawData: String) {
        let (components, display) = EnteEntry.read(rawData: rawData)
        guard var components else { return nil }
        components.percentEncodedQueryItems = components.percentEncodedQueryItems?.filter { !EnteEntry.isNamed("codeDisplay", $0) }
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

    /// The tags, like Ente Auth keeps them: a list of names.
    var tags: [String] {
        get { EnteEntry.cleaned(display["tags"] as? [String] ?? []) }
        set { display["tags"] = EnteEntry.cleaned(newValue) }
    }

    /// Whether the account is counter based.
    var isHOTP: Bool { components.host?.lowercased() == "hotp" }

    /// The secret the codes are calculated from, nil if it can't be read.
    var secret: Data? {
        Self.value(of: "secret", in: components).flatMap(OTPAuthURLParser.base32Decode)
    }

    /// The counter of a HOTP account, nil if it has none or it isn't a whole number.
    var counter: UInt64? {
        get {
            Self.value(of: "counter", in: components).flatMap { OTPAuthURLParser.integer("counter", in: ["counter": $0], default: UInt64(0)) }
        }
        set { Self.set("counter", to: newValue.map(String.init), in: &components) }
    }

    /// Changes the label and the `issuer` parameter, like Ente Auth's edit screen does.
    mutating func rename(issuer: String?, accountName: String) {
        let issuer = issuer.flatMap { $0.isEmpty ? nil : $0 }
        components.path = OTPAuthURLParser.labelPath(issuer: issuer, accountName: accountName)
        Self.set("issuer", to: issuer, in: &components)
    }

    /// The value of a parameter, whatever the case of its name, like `OTPAuthURLParser` reads it.
    private static func value(of name: String, in components: URLComponents) -> String? {
        components.queryItems?.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    /// Sets a parameter, or removes it when the value is nil. It replaces the parameter in every case of its name,
    /// so the value set is the one read back. The other parameters are kept as they are encoded. '+' is encoded too,
    /// as Ente's apps read it as a space.
    private static func set(_ name: String, to value: String?, in components: inout URLComponents) {
        var items = components.percentEncodedQueryItems ?? []
        let encoded = value.map {
            $0.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? $0
        }
        // The names here are still percent-encoded: `%63ounter` is replaced too, rather than given a second value.
        let isNamed = { (item: URLQueryItem) in EnteEntry.isNamed(name, item) }
        // In the place of the first one, which no parameter before it is removed from.
        let index = items.firstIndex(where: isNamed) ?? items.endIndex
        items.removeAll(where: isNamed)
        if let encoded {
            items.insert(URLQueryItem(name: name, value: encoded), at: index)
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
    let tags: [String]
    /// The icon chosen in Ente Auth, nil to use the issuer's.
    let iconID: String?

    /// Returns nil for accounts in Ente's trash and data that can't be read or used.
    init?(rawData: String) {
        let entry = EnteEntry(rawData: rawData)
        guard let components = entry.components, !entry.isTrashed else { return nil }
        if components.host?.lowercased() == "hotp" {
            guard let items = OTPAuthURLParser.parameters(of: components),
                  let secret = items["secret"].flatMap(OTPAuthURLParser.base32Decode), !secret.isEmpty else { return nil }
            let algorithm: OTPAccount.Algorithm
            switch items["algorithm"]?.uppercased() ?? "SHA1" {
            case "SHA1", "": algorithm = .sha1
            case "SHA256": algorithm = .sha256
            case "SHA512": algorithm = .sha512
            default: return nil
            }
            guard let digits = OTPAuthURLParser.integer("digits", in: items, default: 6), (1...10).contains(digits) else { return nil }
            // The counter is moved on once its code has been shown, which the largest one can't be.
            guard let counter = OTPAuthURLParser.integer("counter", in: items, default: UInt64(0)), counter < .max else { return nil }
            let (issuer, accountName) = OTPAuthURLParser.label(of: components)
            self.init(issuer: issuer, accountName: accountName, kind: .hotp, secret: secret, algorithm: algorithm, digits: digits,
                      period: 0, counter: counter, isPinned: entry.isPinned, tags: entry.tags, iconID: entry.iconID)
        } else {
            guard let account = OTPAuthURLParser.account(id: "", components: components, isPinned: entry.isPinned) else { return nil }
            self.init(issuer: account.issuer, accountName: account.accountName, kind: account.kind == .steam ? .steam : .totp,
                      secret: account.secret, algorithm: account.algorithm, digits: account.digits, period: account.period,
                      counter: 0, isPinned: account.isPinned, tags: entry.tags, iconID: entry.iconID)
        }
    }

    private init(issuer: String?, accountName: String, kind: Kind, secret: Data, algorithm: OTPAccount.Algorithm, digits: Int,
                 period: Int, counter: UInt64, isPinned: Bool, tags: [String], iconID: String?) {
        self.issuer = issuer
        self.accountName = accountName
        self.kind = kind
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.counter = counter
        self.isPinned = isPinned
        self.tags = tags
        self.iconID = iconID
    }

    /// Whether both are the same account, ignoring the pin, the tags, the icon and the HOTP counter, which an account
    /// in the list follows without being made again.
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

enum EnteVaultError: Error, LocalizedError {
    /// The file or its key can't be decrypted, e.g. because the device was restored from a backup, or the file was
    /// written by a later version of the app.
    case unreadable
    /// The file or its key can't be read right now, e.g. until the device is unlocked.
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return String(localized: "The copy of your Ente Auth accounts on this device couldn't be read. It was kept, and the accounts are downloaded again from Ente Auth.", comment: "Error when the file with the Ente accounts on the device can't be decrypted")
        case .unavailable:
            return String(localized: "Your Ente Auth accounts on this device can't be read right now. Unlock the device and try again.", comment: "Error when the file with the Ente accounts on the device can't be read yet")
        }
    }
}

/// Where the vault is kept: an encrypted file in the app, memory in the tests.
nonisolated protocol EnteVaultStorage: Sendable {
    func load() throws -> EnteVault?
    func save(_ vault: EnteVault) throws
    func remove()
    /// Moves a file that couldn't be read out of the way, so saving doesn't write over it.
    func setAside() throws
    /// Hands over each vault set aside earlier that can be read now, and deletes its file unless `keep` throws.
    func recoverSetAside(_ keep: (EnteVault) throws -> Void)
}

nonisolated extension EnteVaultStorage {
    func recoverSetAside(_ keep: (EnteVault) throws -> Void) {}
}

/// Keeps the Ente vault in an encrypted file.
nonisolated struct EnteVaultFile: EnteVaultStorage {

    private let file: EncryptedFile<EnteVault>

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(components: "EnteAuth", "Vault")
    }

    init(url: URL = defaultURL, keychain: EncryptedFileKey = KeychainFileKey(service: KeychainService.enteVault)) {
        file = EncryptedFile(url: url, keychain: keychain)
    }

    func load() throws -> EnteVault? {
        do {
            return try file.load()
        } catch EncryptedFileError.unreadable {
            throw EnteVaultError.unreadable
        } catch EncryptedFileError.unavailable {
            throw EnteVaultError.unavailable
        }
    }
    func save(_ vault: EnteVault) throws { try file.save(vault) }
    func remove() { file.remove() }
    func setAside() throws { try file.setAside() }
    func recoverSetAside(_ keep: (EnteVault) throws -> Void) { file.recoverSetAside(keep) }
}
