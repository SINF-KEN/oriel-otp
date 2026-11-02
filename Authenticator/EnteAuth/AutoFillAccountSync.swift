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
import Foundation

/// Keeps the time-based Ente Auth accounts where the AutoFill extension can read them, and their websites in the
/// system's AutoFill suggestions.
///
/// The extension can't read the Ente vault, so the accounts are written to an encrypted file in the app group, like
/// the ones sent to the Apple Watch, each time the vault changes. HOTP accounts are left out: filling one in would
/// have to move its counter on in the vault. The file is deleted when the app signs out of Ente.
///
/// Each account is suggested on the websites guessed from its issuer, unless other websites were chosen for it.
@Observable final class AutoFillAccountSync {

    static let shared = AutoFillAccountSync()

    private static let websitesKey = "AutoFill.Websites"

    /// Whether AutoFill from Oriel OTP is turned on in Settings. Nil until it's known, and before iOS 18 and
    /// macOS 15, which can't fill in codes from other apps.
    private(set) var isEnabled: Bool?
    /// The websites chosen in the app, by account id. The other accounts use the guessed ones.
    private var chosenWebsites: [String: [String]] {
        didSet { defaults.set(chosenWebsites, forKey: Self.websitesKey) }
    }

    @ObservationIgnored private let storage: AutoFillStorage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let updatesSystem: Bool
    /// The accounts of the last update, for when websites change.
    @ObservationIgnored private var accounts: [OTPAccount] = []
    @ObservationIgnored private var written: [AutoFillAccount]?

    /// `updatesSystem` is off in the tests, which mustn't change the device's AutoFill suggestions.
    init(storage: AutoFillStorage = AutoFillFile(), defaults: UserDefaults = .standard, updatesSystem: Bool = true) {
        self.storage = storage
        self.defaults = defaults
        self.updatesSystem = updatesSystem
        chosenWebsites = defaults.dictionary(forKey: Self.websitesKey) as? [String: [String]] ?? [:]
    }

    /// Whether this system can fill in codes from other apps.
    static var isSupported: Bool {
        if #available(iOS 18.0, macOS 15.0, *) { true } else { false }
    }

    // MARK: - Websites

    /// The websites chosen for the account, or the ones guessed from its issuer.
    func websites(for id: String, issuer: String?) -> [String] {
        chosenWebsites[id] ?? AutoFillWebsites.guess(issuer: issuer)
    }

    /// Whether the websites were chosen rather than guessed.
    func hasChosenWebsites(for id: String) -> Bool {
        chosenWebsites[id] != nil
    }

    /// Chooses the account's websites, or goes back to the guessed ones with nil.
    func setWebsites(_ websites: [String]?, for id: String) {
        chosenWebsites[id] = websites
        write()
    }

    // MARK: - Accounts

    /// Writes the accounts for the extension. Counter-based accounts are skipped.
    func update(_ codes: [EnteCode]) {
        accounts = WatchAccountSync.accounts(from: codes, favorites: FavoritesStorage().readFavorites())
        let ids = Set(accounts.map(\.id))
        if chosenWebsites.keys.contains(where: { !ids.contains($0) }) {
            // Accounts that were deleted.
            chosenWebsites = chosenWebsites.filter { ids.contains($0.key) }
        }
        write()
    }

    /// Deletes the accounts and the websites chosen for them, for when the app signs out of Ente.
    func remove() {
        accounts = []
        if !chosenWebsites.isEmpty {
            chosenWebsites = [:]
        }
        write()
    }

    private func write() {
        let autoFillAccounts = accounts.map { AutoFillAccount(account: $0, websites: websites(for: $0.id, issuer: $0.issuer)) }
        guard autoFillAccounts != written else { return }
        do {
            try storage.save(autoFillAccounts)
            written = autoFillAccounts
        } catch {
            return
        }
        updateSuggestions(autoFillAccounts)
    }

    // MARK: - System

    /// Reads whether AutoFill from Oriel OTP is on, e.g. when the app comes back from Settings.
    func refresh() {
        guard updatesSystem, #available(iOS 18.0, macOS 15.0, *) else { return }
        Task {
            isEnabled = await ASCredentialIdentityStore.shared.state().isEnabled
        }
    }

    /// Asks to turn on AutoFill from Oriel OTP, or opens the settings where it's turned on.
    func turnOn() {
        guard #available(iOS 18.0, macOS 15.0, *) else { return }
        Task {
            let isEnabled = await ASSettingsHelper.requestToTurnOnCredentialProviderExtension()
            self.isEnabled = isEnabled
            if isEnabled, let written {
                updateSuggestions(written)
            }
        }
    }

    func openSettings() {
        guard #available(iOS 18.0, macOS 15.0, *) else { return }
        ASSettingsHelper.openVerificationCodeAppSettings(completionHandler: nil)
    }

    private func updateSuggestions(_ accounts: [AutoFillAccount]) {
        guard updatesSystem, #available(iOS 18.0, macOS 15.0, *) else { return }
        Task {
            isEnabled = await AutoFillIdentities.replace(with: accounts)
        }
    }
}
