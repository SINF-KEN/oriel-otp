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
import Security

/// The app group the app shares with the AutoFill extension.
nonisolated enum AppGroup {
    static let identifier = AppIdentifier.appGroup

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}

/// The keychain access group the app shares with the AutoFill extension. The app's other items go to its own group,
/// listed first in its entitlements, which the extension can't read. The items the extension needs, the key of the
/// AutoFill file and the app lock, are added to this group explicitly.
nonisolated enum SharedKeychain {
    static let accessGroupKey = "OrielOTPSharedKeychainGroup"

    /// Nil in a build without a team, where there are no access groups.
    static let accessGroup: String? = {
        guard let group = Bundle.main.object(forInfoDictionaryKey: accessGroupKey) as? String,
            let team = group.split(separator: ".").first, team.count == 10, !group.contains("$(")
        else { return nil }
        return group
    }()

    /// Puts an item that is added with `query` in the shared group.
    static func addAccessGroup(to query: inout [String: Any]) {
        if let accessGroup {
            query[String(kSecAttrAccessGroup)] = accessGroup
        }
    }

    /// The app's own group, listed first in its entitlements, which the extensions can't read.
    static var appAccessGroup: String? {
        accessGroup.map { $0 + ".app" }
    }

    /// Moves an item that was just read to the app's own group, if it is in the shared one. Versions before the app
    /// had a group of its own added every item to the shared group, where the AutoFill extension can read them, and
    /// an item stays in the group it was added to. Moved in place, so a refused move leaves the item where it was.
    ///
    /// - Parameters:
    ///   - query: The query the item was found with.
    ///   - attributes: The item's attributes, as returned with `kSecReturnAttributes`.
    /// - Returns: Whether the item was moved.
    @discardableResult static func moveToAppGroup(_ query: [String: Any], attributes: [String: Any]?) -> Bool {
        guard let accessGroup, let appAccessGroup,
            attributes?[String(kSecAttrAccessGroup)] as? String == accessGroup
        else { return false }
        var query = query
        for key in [kSecReturnData, kSecReturnAttributes, kSecReturnRef, kSecReturnPersistentRef, kSecMatchLimit] {
            query[String(key)] = nil
        }
        query[String(kSecAttrAccessGroup)] = accessGroup
        let change = [String(kSecAttrAccessGroup): appAccessGroup]
        return SecItemUpdate(query as CFDictionary, change as CFDictionary) == errSecSuccess
    }
}

nonisolated enum KeychainError: Error, LocalizedError, Equatable {
    /// The keychain can't be read right now, e.g. before the device was first unlocked.
    case unavailable
    case failed(OSStatus)

    init(_ status: OSStatus) {
        self = status == errSecInteractionNotAllowed ? .unavailable : .failed(status)
    }

    var errorDescription: String? {
        switch self {
        case .unavailable:
            SecCopyErrorMessageString(errSecInteractionNotAllowed, nil) as String? ?? String(errSecInteractionNotAllowed)
        case .failed(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? String(status)
        }
    }
}

/// One generic password, only readable on this device while it is unlocked: never in backups, never synced, and
/// gone from other devices. The keychain items without Face ID or Touch ID are kept with it; `SecureStore` keeps
/// the ones with.
///
/// An item saved by an earlier version is repaired when it is read: one that could go into backups is made
/// `ThisDeviceOnly`, and one in the group shared with the AutoFill extension that the extension doesn't need is moved
/// to the app's own group.
nonisolated struct KeychainItem: Sendable {

    enum Group: Sendable {
        /// The app's own group, which the extensions can't read.
        case app
        /// The group shared with the AutoFill extension, see `SharedKeychain`.
        case shared
    }

    let service: String
    let account: String
    var group: Group = .app

    /// Finds the item, in whichever group it is.
    var query: [String: Any] {
        [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrService): service,
            String(kSecAttrAccount): account,
            // The Mac has a second, file-based keychain. Use the same data protection keychain as on iOS.
            String(kSecUseDataProtectionKeychain): true
        ]
    }

    /// Nil when there is no item.
    func data() throws(KeychainError) -> Data? {
        var query = query
        query[String(kSecReturnData)] = true
        query[String(kSecReturnAttributes)] = true
        query[String(kSecMatchLimit)] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let attributes = result as? [String: Any]
            guard let data = attributes?[String(kSecValueData)] as? Data else { throw .failed(errSecDecode) }
            repair(attributes: attributes)
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status)
        }
    }

    /// Replaces the item, or deletes it for nil. Updated in place rather than deleted and added again, so a change
    /// that fails leaves the old item rather than none.
    func setData(_ data: Data?) throws(KeychainError) {
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
            return
        }
        let attributes: [String: Any] = [
            String(kSecValueData): data,
            String(kSecAttrAccessible): kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            if group == .shared {
                SharedKeychain.addAccessGroup(to: &item)
            }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status) }
    }

    /// Deletes the item, if the keychain lets it.
    func delete() {
        try? setData(nil)
    }

    /// The protection of items that can go into backups and onto other devices.
    private static let leavesTheDevice: Set<String> = [
        kSecAttrAccessibleWhenUnlocked as String,
        kSecAttrAccessibleAfterFirstUnlock as String
    ]

    private func repair(attributes: [String: Any]?) {
        if let accessible = attributes?[String(kSecAttrAccessible)] as? String, Self.leavesTheDevice.contains(accessible) {
            let change = [String(kSecAttrAccessible): kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            SecItemUpdate(query as CFDictionary, change as CFDictionary)
        }
        if group == .app {
            SharedKeychain.moveToAppGroup(query, attributes: attributes)
        }
    }
}
