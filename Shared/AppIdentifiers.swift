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

/// Identifiers that more than one target, or more than one file, has to agree on.
nonisolated enum AppIdentifier {
    /// The app group of the app, its AutoFill extension and its token extension.
    static let appGroup = "group.io.github.sinf-ken.OrielOTP"
    /// The bundle ID of the CryptoTokenKit extension, which is also its token driver's class ID.
    static let tokenExtension = "io.github.sinf-ken.OrielOTP.TokenExtension"
}

/// The keychain services the app's items are kept under. Changing one loses the items saved under the old name.
nonisolated enum KeychainService {
    /// The saved YubiKey OATH passwords, by device ID.
    static let oathPasswords = "OATH"
    /// The Ente session.
    static let enteSession = "EnteAuth"
    /// The keys of the encrypted files, see `EncryptedFile`.
    static let enteVault = "EnteAuth.Vault"
    static let deviceAccounts = "DeviceAccounts"
    static let tags = "Tags"
    static let favorites = "Favorites"
    /// The key of the file with how often each account's code was copied, see `AccountUsage`.
    static let usage = "Usage"
    static let autoFillWebsites = "AutoFill.Websites"
    static let autoFillAccounts = "AutoFill.Accounts"
    /// The app lock and its wrong attempts.
    static let appLock = "AppLock"
    /// The key the accounts sent to the Apple Watch are sealed with, on both devices.
    static let watchSyncKey = "OrielOTP.WatchSyncKey"
    /// The accounts on the Apple Watch.
    static let watchAccounts = "OrielOTP.WatchAccounts"
}

/// Preference keys read in more than one place.
nonisolated enum DefaultsKey {
    /// The Ente server chosen on the sign-in screen, empty or missing for Ente's own.
    static let enteServer = "EnteAuth.ServerURL"
}
