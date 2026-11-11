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
import Security

/// The key the iPhone encrypts the accounts with before handing them to WatchConnectivity.
///
/// The system keeps the latest application context on disk on both devices, outside the app's keychain, so the
/// context only ever carries the sealed accounts. The key itself is kept in the keychain of each device and only
/// travels in `sendMessage`, which the system doesn't keep.
nonisolated struct WatchSyncKey: Sendable, Equatable {

    static let byteCount = 32

    let data: Data

    init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        self.data = data
    }

    static func generate() -> WatchSyncKey {
        WatchSyncKey(data: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })!
    }

    /// Names the key in the context, so the watch knows whether the key it has is the right one. A hash of the
    /// random key, which reveals nothing about it.
    var id: String {
        var hasher = SHA256()
        hasher.update(data: Data("OrielOTP.WatchSyncKey.id".utf8))
        hasher.update(data: data)
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    var symmetricKey: SymmetricKey {
        SymmetricKey(data: data)
    }
}

/// What a keychain read found.
nonisolated enum KeychainRead: Equatable, Sendable {
    case found(Data)
    case notFound
    /// The keychain refused, e.g. `errSecInteractionNotAllowed` while the device is locked.
    case unavailable
}

/// One keychain item, a seam so the watch sync can be tested without the keychain.
nonisolated protocol WatchKeychainItem: Sendable {
    func read() -> KeychainRead
    /// Replaces the item, or deletes it for nil. False when the keychain refused, e.g. while the device is locked:
    /// then the item is unchanged.
    @discardableResult func write(_ data: Data?) -> Bool
}

/// A generic password only readable while the device is unlocked, never synced to iCloud or restored on another
/// device.
nonisolated struct SystemKeychainItem: WatchKeychainItem {

    let service: String
    let account: String

    func read() -> KeychainRead {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else { return .unavailable }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable
        }
    }

    @discardableResult func write(_ data: Data?) -> Bool {
        guard let data else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        // Updated in place rather than deleted and added again, so a refused add can't lose the old item.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        switch SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary) {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            let item = baseQuery.merging(attributes) { $1 }
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        default:
            return false
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

/// The watch side of the sync: applies the contexts from the iPhone and keeps the accounts in the watch's keychain.
///
/// Shared so it can be tested with the iPhone app's tests; only the watch app uses it.
final class WatchAccountReceiver {

    enum Outcome: Equatable {
        case applied
        /// The context is sealed with a key the watch doesn't have, ask the iPhone for it.
        case needsKey
        /// Nothing changed: an old or unknown context, or the keychain is locked.
        case unchanged
    }

    private static let pendingClearKey = "Watch.PendingAccountDeletion"
    private static let pendingKeyClearKey = "Watch.PendingKeyDeletion"

    private(set) var accounts: [OTPAccount]

    private let accountsItem: WatchKeychainItem
    private let keyItem: WatchKeychainItem
    private let defaults: UserDefaults
    /// Accounts that couldn't be saved, e.g. while the watch is locked. Saved by `retry()`.
    private var unsavedAccounts: [OTPAccount]?
    /// A key that couldn't be saved. Used anyway until it is.
    private var unsavedKey: WatchSyncKey?
    /// The keychain couldn't be read at launch, so the accounts shown aren't the saved ones.
    private var needsLoad = false

    init(
        accountsItem: WatchKeychainItem = SystemKeychainItem(service: "OrielOTP.WatchAccounts", account: "accounts"),
        keyItem: WatchKeychainItem = SystemKeychainItem(service: "OrielOTP.WatchSyncKey", account: "key"),
        defaults: UserDefaults = .standard
    ) {
        self.accountsItem = accountsItem
        self.keyItem = keyItem
        self.defaults = defaults
        self.accounts = []
        if isClearPending {
            // Deleting failed while the watch was locked: show nothing, and delete them now if possible.
            if accountsItem.write(nil) { isClearPending = false }
        } else {
            load()
        }
        if isKeyClearPending, keyItem.write(nil) { isKeyClearPending = false }
    }

    /// The key the iPhone said to delete is still in the keychain, deleting it failed.
    private(set) var isKeyClearPending: Bool {
        get { defaults.bool(forKey: Self.pendingKeyClearKey) }
        set { newValue ? defaults.set(true, forKey: Self.pendingKeyClearKey) : defaults.removeObject(forKey: Self.pendingKeyClearKey) }
    }

    /// The accounts the iPhone said to delete are still in the keychain, deleting them failed.
    private(set) var isClearPending: Bool {
        get { defaults.bool(forKey: Self.pendingClearKey) }
        set { newValue ? defaults.set(true, forKey: Self.pendingClearKey) : defaults.removeObject(forKey: Self.pendingClearKey) }
    }

    /// Whether everything received was saved.
    var isSaved: Bool {
        !isClearPending && !isKeyClearPending && unsavedAccounts == nil && unsavedKey == nil
    }

    func apply(_ context: [String: Any]) -> Outcome {
        let key: WatchSyncKey?
        switch keyItem.read() {
        case .found(let data):
            // A key that is to be deleted isn't used any more.
            key = unsavedKey ?? (isKeyClearPending ? nil : WatchSyncKey(data: data))
        case .notFound:
            key = unsavedKey
        case .unavailable:
            // Locked: asking the iPhone again wouldn't help unless it already gave a key.
            guard let unsavedKey else {
                return WatchAccountsMessage.content(of: context, key: nil) == .cleared ? clear() : .unchanged
            }
            key = unsavedKey
        }
        switch WatchAccountsMessage.content(of: context, key: key) {
        case .accounts(let accounts):
            replace(with: accounts)
            return .applied
        case .cleared:
            return clear()
        case .needsKey:
            return .needsKey
        case .unreadable:
            return .unchanged
        }
    }

    /// Keeps a key from the iPhone and applies the context with it.
    func receive(_ key: WatchSyncKey, context: [String: Any]) -> Outcome {
        unsavedKey = keyItem.write(key.data) ? nil : key
        // The new key replaces the one that was to be deleted, or is saved over it by `retry()`.
        isKeyClearPending = false
        return apply(context)
    }

    /// Saves what couldn't be saved or deleted earlier, e.g. while the watch was locked.
    func retry() {
        if let unsavedKey {
            if keyItem.write(unsavedKey.data) { self.unsavedKey = nil }
        } else if isKeyClearPending, keyItem.write(nil) {
            isKeyClearPending = false
        }
        if let unsavedAccounts {
            replace(with: unsavedAccounts)
        } else if isClearPending {
            if accountsItem.write(nil) { isClearPending = false }
        } else if needsLoad {
            load()
        }
    }

    private func clear() -> Outcome {
        replace(with: [])
        // The iPhone uses a new key from now on, the old one isn't needed.
        unsavedKey = nil
        // Refused while the watch is locked: deleted by `retry()`, like the accounts.
        isKeyClearPending = !keyItem.write(nil)
        return .applied
    }

    private func replace(with accounts: [OTPAccount]) {
        self.accounts = accounts.sorted(by: OTPAccount.listOrder)
        needsLoad = false
        if accounts.isEmpty {
            unsavedAccounts = nil
            isClearPending = !accountsItem.write(nil)
        } else if let data = try? JSONEncoder().encode(accounts), accountsItem.write(data) {
            unsavedAccounts = nil
            isClearPending = false
        } else {
            // Keeps the clear pending if there was one: the deleted accounts may still be in the keychain.
            unsavedAccounts = accounts
        }
    }

    private func load() {
        switch accountsItem.read() {
        case .found(let data):
            accounts = ((try? JSONDecoder().decode([OTPAccount].self, from: data)) ?? []).sorted(by: OTPAccount.listOrder)
            needsLoad = false
        case .notFound:
            accounts = []
            needsLoad = false
        case .unavailable:
            needsLoad = true
        }
    }
}
