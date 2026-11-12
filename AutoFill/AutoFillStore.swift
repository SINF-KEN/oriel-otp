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

/// An account whose codes AutoFill can fill in, with the websites they are suggested on.
nonisolated struct AutoFillAccount: Codable, Sendable, Hashable, Identifiable {
    let account: OTPAccount
    /// Domains, e.g. `github.com`. Their subdomains match too.
    let websites: [String]

    var id: String { account.id }
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
/// Kept like the vault, in an `EncryptedFile` whose key is in the keychain group the app shares with the extension.
nonisolated struct AutoFillFile: AutoFillStorage {

    private let file: EncryptedFile<[AutoFillAccount]>?

    static var defaultURL: URL? {
        AppGroup.containerURL?.appending(components: "AutoFill", "Accounts")
    }

    init(url: URL? = defaultURL,
         keychain: EncryptedFileKey = KeychainFileKey(service: KeychainService.autoFillAccounts, group: .shared)) {
        file = url.map { EncryptedFile(url: $0, keychain: keychain) }
    }

    func load() throws -> [AutoFillAccount]? {
        try file?.load()
    }

    func save(_ accounts: [AutoFillAccount]) throws {
        guard let file else { throw EncryptedFileError.unavailable }
        guard !accounts.isEmpty else {
            file.remove()
            return
        }
        try file.save(accounts)
    }

    func remove() {
        file?.remove()
    }
}
