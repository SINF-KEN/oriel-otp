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

import AuthenticationServices
import Observation

/// The accounts the extension can fill in and what it is showing.
@Observable final class AutoFillModel {

    enum Problem: Equatable {
        /// The accounts can't be read until the device is unlocked.
        case unavailable
        /// There are no time-based Ente Auth accounts in the app.
        case noAccounts
        /// The file can't be decrypted, e.g. after the device was restored from a backup.
        case unreadable
    }

    /// The accounts suggested for the website or app, and the others.
    private(set) var matching: [AutoFillAccount] = []
    private(set) var others: [AutoFillAccount] = []
    private(set) var problem: Problem?
    /// A suggestion chosen while the app is locked, filled in once it's unlocked.
    var pending: AutoFillAccount?

    @ObservationIgnored var fill: (AutoFillAccount) -> Void = { _ in }
    @ObservationIgnored var cancel: () -> Void = {}
    @ObservationIgnored private let storage: AutoFillStorage
    @ObservationIgnored private var accounts: [AutoFillAccount] = []

    init(storage: AutoFillStorage = AutoFillFile()) {
        self.storage = storage
    }

    func load(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        do {
            accounts = try storage.load() ?? []
            problem = accounts.isEmpty ? .noAccounts : nil
        } catch AutoFillStoreError.unavailable {
            accounts = []
            problem = .unavailable
        } catch {
            accounts = []
            problem = .unreadable
        }
        (matching, others) = AutoFillWebsites.sorted(accounts, for: serviceIdentifiers)
    }

    /// The account of a suggestion.
    func account(for request: any ASCredentialRequest) -> AutoFillAccount? {
        guard let id = request.credentialIdentity.recordIdentifier else { return nil }
        return accounts.first { $0.id == id }
    }

    /// The accounts whose name contains `text`, all of them when it's empty.
    func filter(_ accounts: [AutoFillAccount], by text: String) -> [AutoFillAccount] {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return accounts }
        return accounts.filter {
            $0.account.title.localizedStandardContains(text) || $0.account.accountName.localizedStandardContains(text)
                || $0.websites.contains { $0.localizedStandardContains(text) }
        }
    }
}
