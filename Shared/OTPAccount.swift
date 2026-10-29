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

/// What the iPhone sends to the watch in the application context.
nonisolated enum WatchAccountsMessage {

    static let accountsKey = "accounts"
    static let version = 1
    static let versionKey = "version"

    /// An empty list tells the watch to delete everything.
    static func context(for accounts: [OTPAccount]) throws -> [String: Any] {
        [versionKey: version, accountsKey: try JSONEncoder().encode(accounts)]
    }

    /// Returns nil for a context this version doesn't understand.
    static func accounts(from context: [String: Any]) -> [OTPAccount]? {
        guard context[versionKey] as? Int == version, let data = context[accountsKey] as? Data else { return nil }
        return try? JSONDecoder().decode([OTPAccount].self, from: data)
    }
}
