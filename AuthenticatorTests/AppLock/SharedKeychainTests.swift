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
import Testing

@testable import OrielOTP

#if os(macOS)
    // On the Mac the data protection keychain needs a provisioned keychain access group, which ad-hoc signed CI builds
    // don't have.
    nonisolated private let hasKeychainAccessGroup: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
    }()
#else
    nonisolated private let hasKeychainAccessGroup = SharedKeychain.accessGroup != nil
#endif

/// The app's items go to its own keychain group, except the ones the AutoFill extension reads.
@Suite(.serialized, .enabled(if: hasKeychainAccessGroup, "Needs a keychain access group"))
struct SharedKeychainTests {

    private static func accessGroup(service: String, account: String) -> String? {
        var query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword, String(kSecAttrService): service,
            String(kSecAttrAccount): account, String(kSecReturnAttributes): true,
            String(kSecMatchLimit): kSecMatchLimitOne
        ]
        #if os(macOS)
            query[String(kSecUseDataProtectionKeychain)] = true
        #endif
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as? [String: Any])?[String(kSecAttrAccessGroup)] as? String
    }

    @Test func theAppsOwnItemsAreNotShared() throws {
        let store = SecureStore(secureStoreQueryable: PasswordQueryable(service: "SharedKeychainTests"))
        defer { try? store.removeAllValues() }
        try store.setValue("secret", useAuthentication: false, for: "item")
        let group = try #require(Self.accessGroup(service: "SharedKeychainTests", account: "item"))
        #expect(group != SharedKeychain.accessGroup)
        #expect(group.hasSuffix(".app"))
    }

    @Test func theAutoFillKeyIsShared() throws {
        let key = KeychainFileKey(service: KeychainService.autoFillAccounts, group: .shared)
        let existing = try key.existingKey()
        defer {
            // Leaves the simulator's app as it was.
            if existing == nil { key.removeKey() }
        }
        if existing == nil { _ = try key.createKey() }
        #expect(Self.accessGroup(service: "AutoFill.Accounts", account: "key") == SharedKeychain.accessGroup)
    }

    @Test func theAppLockIsShared() throws {
        let keychain = AppLockKeychain()
        let saved = try keychain.load()
        try #require(saved == nil, "The simulator's app has a lock")
        defer { try? keychain.save(nil) }
        try keychain.save(AppLockConfiguration(method: .device))
        #expect(Self.accessGroup(service: "AppLock", account: "configuration") == SharedKeychain.accessGroup)
    }
}
