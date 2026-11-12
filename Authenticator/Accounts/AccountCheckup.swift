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

import SwiftUI

/// The **Account Check-Up**: accounts kept in more than one place, and accounts the YubiKey could hold instead.
///
/// A secret on the YubiKey can't be copied off it, while one in Ente Auth or on this device is in a file the app can
/// read, so the check-up suggests moving the accounts that fit on the key.
nonisolated enum AccountCheckup {

    /// What the check needs to know of an account.
    struct Item: Equatable, Sendable {
        let id: String
        let issuer: String?
        let accountName: String
        let isOnYubiKey: Bool
        /// Nil for a YubiKey account, whose secret can't be read.
        let secret: Data?
        /// Whether the YubiKey could hold it.
        let fitsOnYubiKey: Bool
    }

    struct Result: Equatable, Sendable {
        /// Groups of the same account kept two or more times, each in the order given.
        let duplicates: [[String]]
        /// Accounts in Ente Auth or on this device that fit on the YubiKey and aren't on it already.
        let fitOnYubiKey: [String]
    }

    /// The same issuer and name, ignoring case, accents and spaces around them, or the same secret, is the same account.
    static func check(_ items: [Item]) -> Result {
        // Joins items that share a name or a secret, through as many links as there are.
        var parent = Array(items.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        var byName: [String: Int] = [:]
        var bySecret: [Data: Int] = [:]
        for (index, item) in items.enumerated() {
            let name = normalized(item.issuer) + "\u{0}" + normalized(item.accountName)
            if let other = byName[name] { parent[root(index)] = root(other) } else { byName[name] = index }
            if let secret = item.secret, !secret.isEmpty {
                if let other = bySecret[secret] { parent[root(index)] = root(other) } else { bySecret[secret] = index }
            }
        }
        var groups: [Int: [Int]] = [:]
        var order: [Int] = []
        for index in items.indices {
            let group = root(index)
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(index)
        }
        let duplicates = order.compactMap { groups[$0] }.filter { $0.count > 1 }
        let onYubiKey = Set(duplicates.filter { $0.contains { items[$0].isOnYubiKey } }.flatMap { $0 })
        let fit = items.indices.filter { !items[$0].isOnYubiKey && items[$0].fitsOnYubiKey && !onYubiKey.contains($0) }
        return Result(duplicates: duplicates.map { $0.map { items[$0].id } }, fitOnYubiKey: fit.map { items[$0].id })
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

extension MainViewModel {
    /// The check-up of the accounts in the list.
    func accountCheckup() -> (duplicates: [[Account]], fitOnYubiKey: [Account]) {
        let items = accounts.map {
            AccountCheckup.Item(
                id: $0.accountId, issuer: $0.credential.issuer, accountName: $0.credential.accountName,
                isOnYubiKey: $0.isOnYubiKey, secret: secret(of: $0),
                fitsOnYubiKey: canCopyToYubiKey($0, moving: true))
        }
        let result = AccountCheckup.check(items)
        let byID = Dictionary(accounts.map { ($0.accountId, $0) }, uniquingKeysWith: { first, _ in first })
        return (result.duplicates.map { $0.compactMap { byID[$0] } }, result.fitOnYubiKey.compactMap { byID[$0] })
    }
}

/// Lists what `AccountCheckup` finds, with the actions that fix it.
struct AccountCheckupView: View {

    @Environment(MainViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let checkup = model.accountCheckup()
        NavigationStack {
            Form {
                if checkup.duplicates.isEmpty && checkup.fitOnYubiKey.isEmpty {
                    Section {
                        Label(
                            String(
                                localized: "Nothing to fix. Each account is kept once, and the ones that fit on a YubiKey are on it.",
                                comment: "Account check-up without findings"),
                            systemImage: "checkmark.circle")
                    }
                }
                if !checkup.duplicates.isEmpty {
                    Section {
                        ForEach(Array(checkup.duplicates.enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group[0].title)
                                    .font(.headline)
                                ForEach(group, id: \.accountId) { account in
                                    HStack {
                                        Text(account.subTitle ?? account.title)
                                        Spacer()
                                        Text(account.locationDescription)
                                            .foregroundStyle(.secondary)
                                    }
                                    .contextMenu { CopyToYubiKeyButtons(account: account) }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text(String(localized: "Kept More Than Once", comment: "Account check-up section"))
                    } footer: {
                        Text(
                            String(
                                localized:
                                    "The same name or secret in more than one place. If they're the same account, keep the one you use and delete the others.",
                                comment: "Account check-up section footer"))
                    }
                }
                if !checkup.fitOnYubiKey.isEmpty {
                    Section {
                        ForEach(checkup.fitOnYubiKey, id: \.accountId) { account in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(account.title)
                                    Text(account.locationDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu {
                                    CopyToYubiKeyButtons(account: account)
                                } label: {
                                    Label(String(localized: "Put on YubiKey", comment: "Account check-up button"), systemImage: "key")
                                }
                                .fixedSize()
                            }
                        }
                    } header: {
                        Text(String(localized: "Could Be on Your YubiKey", comment: "Account check-up section"))
                    } footer: {
                        Text(
                            String(
                                localized:
                                    "A secret on a YubiKey can't be copied off it. These accounts are in Ente Auth or on this device, and a YubiKey can hold them.",
                                comment: "Account check-up section footer"))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Account Check-Up", comment: "Account check-up title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Button")) { dismiss() }
                }
            }
        }
    }
}
