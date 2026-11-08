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
/// Each account is suggested on the websites guessed from its issuer, unless other websites were chosen for it. Only
/// an issuer that is a domain or a known service gives websites: one made up from a name could belong to anyone. The
/// chosen ones are kept in an encrypted file, as they say where the accounts are used. They can't be read while the
/// device is locked, and nothing is written over them until they have been.
@Observable final class AutoFillAccountSync {

    static let shared = AutoFillAccountSync()

    private static let websitesKey = "AutoFill.Websites"

    /// Whether AutoFill from Oriel OTP is turned on in Settings. Nil until it's known.
    private(set) var isEnabled: Bool?
    /// The websites chosen in the app, by account id. The other accounts use the guessed ones.
    private var chosenWebsites: [String: [String]] = [:]

    @ObservationIgnored private let storage: AutoFillStorage
    @ObservationIgnored private let websitesFile: EncryptedFile<[String: [String]]>
    /// Where earlier versions kept the chosen websites.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var hasReadWebsites = false
    @ObservationIgnored private let updatesSystem: Bool
    /// The accounts of the last update, for when websites change.
    @ObservationIgnored private var accounts: [OTPAccount] = []
    @ObservationIgnored private var written: [AutoFillAccount]?
    /// The last write. Each one waits for the one before, so signing out can't be undone by a write that was under way.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    /// The update under way. Nothing is written until it's done, as `accounts` is about to change.
    @ObservationIgnored private var pendingUpdate: Task<Void, Never>?
    /// Changes with each update and when signing out, so what an earlier update found is dropped.
    @ObservationIgnored private var generation = 0

    static var defaultWebsitesURL: URL {
        URL.applicationSupportDirectory.appending(components: "AutoFill", "Websites")
    }

    /// `updatesSystem` is off in the tests, which mustn't change the device's AutoFill suggestions.
    init(storage: AutoFillStorage = AutoFillFile(), websitesURL: URL = defaultWebsitesURL,
         websitesKeychain: EnteVaultKeychain = EnteVaultKeychainKey(service: "AutoFill.Websites"),
         defaults: UserDefaults = .standard, updatesSystem: Bool = true) {
        self.storage = storage
        websitesFile = EncryptedFile(url: websitesURL, keychain: websitesKeychain)
        self.defaults = defaults
        self.updatesSystem = updatesSystem
    }

    // MARK: - Websites

    /// The websites chosen for the account, or the ones guessed from its issuer. A public suffix chosen before they
    /// were turned down is left out, as it would match every site under it.
    func websites(for id: String, issuer: String?) -> [String] {
        readWebsites()
        return chosenWebsites[id]?.filter { !AutoFillWebsites.isPublicSuffix($0) } ?? AutoFillWebsites.guess(issuer: issuer)
    }

    /// Whether the websites were chosen rather than guessed.
    func hasChosenWebsites(for id: String) -> Bool {
        readWebsites()
        return chosenWebsites[id] != nil
    }

    /// Chooses the account's websites, or goes back to the guessed ones with nil.
    func setWebsites(_ websites: [String]?, for id: String) {
        readWebsites()
        chosenWebsites[id] = websites
        saveWebsites()
        write()
    }

    private func readWebsites() {
        guard !hasReadWebsites else { return }
        finishReadingWebsites(Result { try websitesFile.load() })
    }

    private func finishReadingWebsites(_ result: Result<[String: [String]]?, Error>) {
        guard !hasReadWebsites else { return }
        if case .failure(let error) = result, case .unavailable? = error as? EnteVaultError { return }
        hasReadWebsites = true
        if let saved = try? result.get() {
            chosenWebsites = saved
            return
        }
        chosenWebsites = defaults.dictionary(forKey: Self.websitesKey) as? [String: [String]] ?? [:]
        if !chosenWebsites.isEmpty {
            saveWebsites()
        }
    }

    /// Only once they're safely in the file are they removed from where earlier versions kept them.
    private func saveWebsites() {
        do {
            if chosenWebsites.isEmpty {
                removeWebsitesFile()
            } else {
                try websitesFile.save(chosenWebsites)
            }
            defaults.removeObject(forKey: Self.websitesKey)
        } catch {
            return
        }
    }

    private func removeWebsitesFile() {
        if FileManager.default.fileExists(atPath: websitesFile.url.path) {
            websitesFile.remove()
        }
    }

    // MARK: - Accounts

    /// Writes the accounts for the extension. Counter-based accounts are skipped. `codes` reads them, which happens off
    /// the main actor as it parses every account, and that happens each time the app starts.
    func update(_ codes: @escaping @Sendable () -> [EnteCode]) {
        generation += 1
        let generation = generation
        let websitesFile = hasReadWebsites ? nil : websitesFile
        pendingUpdate = Task { [weak self] in
            let (accounts, websites) = await Self.read(codes, websitesFile: websitesFile)
            guard let self, generation == self.generation else { return }
            pendingUpdate = nil
            self.accounts = accounts
            if let websites {
                finishReadingWebsites(websites)
            }
            let ids = Set(accounts.map(\.id))
            if hasReadWebsites, chosenWebsites.keys.contains(where: { !ids.contains($0) }) {
                // Accounts that were deleted.
                chosenWebsites = chosenWebsites.filter { ids.contains($0.key) }
                saveWebsites()
            }
            write()
        }
    }

    @concurrent nonisolated private static func read(_ codes: @Sendable () -> [EnteCode], websitesFile: EncryptedFile<[String: [String]]>?) async
        -> (accounts: [OTPAccount], websites: Result<[String: [String]]?, Error>?) {
        let accounts = WatchAccountSync.accounts(from: codes(), favorites: FavoritesStorage().readFavorites())
        return (accounts, websitesFile.map { file in Result { try file.load() } })
    }

    /// Deletes the accounts and the websites chosen for them, for when the app signs out of Ente.
    func remove() {
        generation += 1
        pendingUpdate = nil
        accounts = []
        hasReadWebsites = true
        if !chosenWebsites.isEmpty {
            chosenWebsites = [:]
        }
        removeWebsitesFile()
        defaults.removeObject(forKey: Self.websitesKey)
        write()
    }

    private func write() {
        guard pendingUpdate == nil else { return }
        let autoFillAccounts = accounts.map { AutoFillAccount(account: $0, websites: websites(for: $0.id, issuer: $0.issuer)) }
        guard autoFillAccounts != written else { return }
        written = autoFillAccounts
        let storage = storage
        let previous = lastWrite
        lastWrite = Task { [weak self] in
            await previous?.value
            let isSaved = await Self.save(autoFillAccounts, to: storage)
            guard let self else { return }
            if isSaved {
                updateSuggestions(autoFillAccounts)
            } else if written == autoFillAccounts {
                // Tried again with the next update.
                written = nil
            }
        }
    }

    /// Waits for the accounts to be written.
    func finishWriting() async {
        await pendingUpdate?.value
        await lastWrite?.value
    }

    /// Leaves a file that already has the accounts as it is, which is what happens each time the app starts.
    @concurrent nonisolated private static func save(_ accounts: [AutoFillAccount], to storage: AutoFillStorage) async -> Bool {
        if let saved = try? storage.load(), saved == accounts { return true }
        do {
            try storage.save(accounts)
            return true
        } catch {
            return false
        }
    }

    // MARK: - System

    /// Reads whether AutoFill from Oriel OTP is on, e.g. when the app comes back from Settings.
    func refresh() {
        guard updatesSystem else { return }
        Task {
            isEnabled = await ASCredentialIdentityStore.shared.state().isEnabled
        }
    }

    /// Asks to turn on AutoFill from Oriel OTP, or opens the settings where it's turned on.
    func turnOn() {
        Task {
            let isEnabled = await ASSettingsHelper.requestToTurnOnCredentialProviderExtension()
            self.isEnabled = isEnabled
            if isEnabled, let written {
                updateSuggestions(written)
            }
        }
    }

    func openSettings() {
        ASSettingsHelper.openVerificationCodeAppSettings(completionHandler: nil)
    }

    private func updateSuggestions(_ accounts: [AutoFillAccount]) {
        guard updatesSystem else { return }
        Task {
            isEnabled = await AutoFillIdentities.replace(with: accounts)
        }
    }
}
