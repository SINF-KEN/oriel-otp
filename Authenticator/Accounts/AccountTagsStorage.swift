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

/// The tags of the accounts on YubiKeys, by credential id, e.g. "GitHub:alice@example.com". A YubiKey has no room
/// for them, so they are kept here. Accounts in Ente Auth and on this device keep theirs in their own data, the way
/// Ente Auth does.
///
/// The ids name the accounts, so they are in an encrypted file like the favorites, which goes away with the app.
nonisolated struct AccountTagsStorage: Sendable {

    private let file: EncryptedFile<[String: [String]]>

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(components: "Tags", "YubiKeyTags")
    }

    init(url: URL = defaultURL, keychain: EnteVaultKeychain = EnteVaultKeychainKey(service: "Tags")) {
        file = EncryptedFile(url: url, keychain: keychain)
    }

    /// Nil while the file can't be read, e.g. before the device was first unlocked, so it isn't written over.
    func read() -> [String: [String]]? {
        do {
            return try file.load() ?? [:]
        } catch EnteVaultError.unreadable {
            // Its key is gone, e.g. after a restore from a backup, which reading it again won't change.
            return [:]
        } catch {
            return nil
        }
    }

    func save(_ tags: [String: [String]]) throws {
        try file.save(tags.filter { !$0.value.isEmpty })
    }
}
