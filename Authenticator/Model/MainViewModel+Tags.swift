/*
 * Copyright (C) Yubico.
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

// MARK: - Tags

extension MainViewModel {

    /// The tags in the order the list shows them: by name, the same tag in another case only once.
    static func tags(of accounts: [Account]) -> [String] {
        EnteEntry.cleaned(accounts.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Files the account under the tags, in Ente Auth for its accounts, like Ente Auth does.
    func setTags(_ tags: [String], of account: Account) {
        let tags = EnteEntry.cleaned(tags)
        guard tags != account.tags else { return }
        switch account.location {
        case .ente(let id):
            do {
                try cloud.setTags(id, tags)
            } catch {
                sessionError = error
                return
            }
        case .device(let id):
            do {
                try device.setTags(id, tags)
            } catch {
                sessionError = error
                return
            }
        case .yubiKey:
            do {
                try saveKeyTags(tags, for: account.credential.id)
            } catch {
                sessionError = error
                return
            }
        }
        account.tags = tags
        sortAccounts()
    }

    /// Keeps the tags of an account on a YubiKey, or forgets them when there are none.
    func saveKeyTags(_ tags: [String], for credentialId: String, movingFrom oldId: String? = nil) throws {
        guard var all = keyTags ?? tagsStorage.read() else { throw DeviceAccountsError.unavailable }
        if let oldId {
            all[oldId] = nil
        }
        all[credentialId] = tags.isEmpty ? nil : tags
        try tagsStorage.save(all)
        keyTags = all
    }

    /// Whether there are accounts to list, from a YubiKey, Ente Auth or this device.
    var hasAccounts: Bool { accountsLoaded || !cloudAccounts.isEmpty || !deviceAccounts.isEmpty }

    /// Whether rows show where each account is stored: with Ente Auth accounts, or when a YubiKey's are listed with
    /// this device's. Someone who only uses this device has no need to tell them apart.
    var showsAccountLocations: Bool {
        !cloudAccounts.isEmpty || (!deviceAccounts.isEmpty && !keyAccounts.isEmpty)
    }
}
