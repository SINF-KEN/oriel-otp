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

/// The pinned accounts the widgets and the Copy Code control show, written by the app to an encrypted file in the app
/// group, like the AutoFill accounts. The key is in the keychain group the app shares with its extensions, readable
/// only while the device is unlocked.
nonisolated struct WidgetAccountsFile: Sendable {

    /// The widget's kind, to reload its timelines.
    static let widgetKind = "io.github.sinf-ken.OrielOTP.PinnedCodes"
    /// The Copy Code control's kind.
    static let controlKind = "io.github.sinf-ken.OrielOTP.CopyCode"

    private let file: EncryptedFile<[OTPAccount]>?

    static var defaultURL: URL? {
        AppGroup.containerURL?.appending(components: "Widgets", "Accounts")
    }

    init(
        url: URL? = defaultURL,
        keychain: EncryptedFileKey = KeychainFileKey(service: KeychainService.widgetAccounts, group: .shared)
    ) {
        file = url.map { EncryptedFile(url: $0, keychain: keychain) }
    }

    /// Nil when there's no file: widgets are off or nothing is pinned. Throws `EncryptedFileError.unavailable` while the
    /// device is locked.
    func load() throws -> [OTPAccount]? {
        try file?.load()
    }

    func save(_ accounts: [OTPAccount]) throws {
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
