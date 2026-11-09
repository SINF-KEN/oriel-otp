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

/// A time-based account whose codes are calculated on the device, used by the Apple Watch app.
///
/// This file is shared by the iPhone app and the watch app, so it must not use YubiKit or UIKit.
nonisolated struct OTPAccount: Codable, Sendable, Hashable, Identifiable {

    enum Algorithm: String, Codable, Sendable {
        case sha1, sha256, sha512
    }

    enum Kind: String, Codable, Sendable {
        case totp
        /// A TOTP account shown as 5 characters, like the Steam app does.
        case steam
    }

    let id: String
    let kind: Kind
    let issuer: String?
    let accountName: String
    let secret: Data
    let algorithm: Algorithm
    let digits: Int
    let period: Int
    var isPinned: Bool

    var title: String {
        if let issuer, !issuer.isEmpty { return issuer }
        return accountName
    }

    var subtitle: String? {
        if let issuer, !issuer.isEmpty, !accountName.isEmpty { return accountName }
        return nil
    }

    /// Pinned accounts first, then by name.
    static func listOrder(_ lhs: OTPAccount, _ rhs: OTPAccount) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        let left = (lhs.title.lowercased(), lhs.accountName.lowercased(), lhs.id)
        let right = (rhs.title.lowercased(), rhs.accountName.lowercased(), rhs.id)
        return left < right
    }
}

/// What the iPhone sends to the watch.
///
/// The application context, which the system keeps on disk on both devices, carries the accounts sealed with a
/// `WatchSyncKey`, or only a mark that there are none. The key travels in `sendMessage`, which isn't kept: the iPhone
/// sends it when it makes a new one, and the watch asks for it when it has a context it can't open.
nonisolated enum WatchAccountsMessage {

    /// Version 1 put the accounts in the context unencrypted. Only the iPhone reads it, once, to replace it.
    static let version = 2
    static let versionKey = "version"
    static let keyIDKey = "keyID"
    static let sealedKey = "sealed"
    static let clearedKey = "cleared"
    static let keyRequestKey = "requestKey"
    static let keyKey = "key"

    private static let legacyVersion = 1
    private static let legacyAccountsKey = "accounts"

    enum Content: Equatable {
        case accounts([OTPAccount])
        /// There are no accounts, delete them.
        case cleared
        /// Sealed with a key the watch doesn't have, the one with this ID.
        case needsKey(id: String)
        /// An old, unknown or damaged context.
        case unreadable
    }

    /// An empty list tells the watch to delete everything, and needs no key.
    static func context(for accounts: [OTPAccount], key: WatchSyncKey) throws -> [String: Any] {
        guard !accounts.isEmpty else { return clearedContext }
        let sealed = try ChaChaPoly.seal(
            try JSONEncoder().encode(accounts), using: key.symmetricKey,
            authenticating: associatedData(keyID: key.id))
        return [versionKey: version, keyIDKey: key.id, sealedKey: sealed.combined]
    }

    static var clearedContext: [String: Any] {
        [versionKey: version, clearedKey: true]
    }

    static func content(of context: [String: Any], key: WatchSyncKey?) -> Content {
        guard context[versionKey] as? Int == version else { return .unreadable }
        if context[clearedKey] as? Bool == true { return .cleared }
        guard let keyID = context[keyIDKey] as? String, let sealed = context[sealedKey] as? Data else { return .unreadable }
        guard let key, key.id == keyID else { return .needsKey(id: keyID) }
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
            let data = try? ChaChaPoly.open(box, using: key.symmetricKey, authenticating: associatedData(keyID: keyID)),
            let accounts = try? JSONDecoder().decode([OTPAccount].self, from: data)
        else { return .unreadable }
        return .accounts(accounts)
    }

    /// Whether the context is in the current format, so nothing needs replacing. An empty context was never sent.
    static func isCurrent(_ context: [String: Any]) -> Bool {
        context.isEmpty || context[versionKey] as? Int == version
    }

    /// The unencrypted accounts of a version 1 context, read by the iPhone only to replace it with a sealed one.
    static func legacyAccounts(from context: [String: Any]) -> [OTPAccount]? {
        guard context[versionKey] as? Int == legacyVersion, let data = context[legacyAccountsKey] as? Data else { return nil }
        return try? JSONDecoder().decode([OTPAccount].self, from: data)
    }

    static var keyRequest: [String: Any] {
        [versionKey: version, keyRequestKey: true]
    }

    static func isKeyRequest(_ message: [String: Any]) -> Bool {
        message[keyRequestKey] as? Bool == true
    }

    static func keyMessage(_ key: WatchSyncKey) -> [String: Any] {
        [versionKey: version, keyKey: key.data]
    }

    static func key(from message: [String: Any]) -> WatchSyncKey? {
        (message[keyKey] as? Data).flatMap(WatchSyncKey.init(data:))
    }

    private static func associatedData(keyID: String) -> Data {
        Data("OrielOTP.WatchAccounts.v\(version).\(keyID)".utf8)
    }
}
