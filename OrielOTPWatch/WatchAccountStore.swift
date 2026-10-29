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
import WatchConnectivity

/// The Ente Auth accounts sent by the iPhone, kept in the watch's keychain so codes work without the iPhone.
@Observable final class WatchAccountStore: NSObject {

    private(set) var accounts: [OTPAccount]

    @ObservationIgnored private let keychain: AccountKeychain

    init(keychain: AccountKeychain = AccountKeychain()) {
        self.keychain = keychain
        self.accounts = keychain.load().sorted(by: OTPAccount.listOrder)
        super.init()
    }

    func activate() {
        guard WCSession.isSupported(), WCSession.default.delegate == nil else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Replaces the accounts. An empty list deletes everything.
    func replace(with accounts: [OTPAccount]) {
        // Saving fails while the watch is locked. The iPhone's latest list is applied again on the next launch.
        keychain.save(accounts)
        self.accounts = accounts.sorted(by: OTPAccount.listOrder)
    }
}

extension WatchAccountStore: WCSessionDelegate {

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard let accounts = WatchAccountsMessage.accounts(from: session.receivedApplicationContext) else { return }
        Task { @MainActor in self.replace(with: accounts) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let accounts = WatchAccountsMessage.accounts(from: applicationContext) else { return }
        Task { @MainActor in self.replace(with: accounts) }
    }
}

/// One keychain item holding all accounts. Only readable while the watch is unlocked, and never synced to iCloud.
nonisolated struct AccountKeychain: Sendable {

    private let service: String
    private let account = "accounts"

    init(service: String = "OrielOTP.WatchAccounts") {
        self.service = service
    }

    func load() -> [OTPAccount] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([OTPAccount].self, from: data)) ?? []
    }

    @discardableResult func save(_ accounts: [OTPAccount]) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        guard !accounts.isEmpty else { return true }
        guard let data = try? JSONEncoder().encode(accounts) else { return false }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}
