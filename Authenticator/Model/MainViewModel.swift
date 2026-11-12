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
import SwiftUI
import YubiKit


@Observable class MainViewModel {

    /// The accounts on the YubiKey that was read last.
    private(set) var keyAccounts: [Account] = [] {
        didSet { sortAccounts() }
    }
    /// The accounts in the Ente Auth vault on this device, whose codes the app calculates.
    private(set) var cloudAccounts: [Account] = [] {
        didSet {
            sortAccounts()
            spotlight?.update()
        }
    }
    /// The accounts kept only on this device, whose codes the app calculates.
    private(set) var deviceAccounts: [Account] = [] {
        didSet {
            sortAccounts()
            spotlight?.update()
        }
    }
    /// The accounts of all three, by name. Kept rather than calculated, as the list reads it several times each time
    /// it's drawn and the countdown every second.
    private(set) var accounts: [Account] = []
    /// The tags of all accounts, by name.
    private(set) var allTags: [String] = []
    var pinnedAccounts: [Account] { accounts.filter(\.isPinned) }
    var otherAccounts: [Account] { accounts.filter { !$0.isPinned } }
    var accountsLoaded: Bool = false
    var presentPasswordEntry: Bool = false
    var presentPasswordSaveType: Bool = false
    var presentDisableOTP: Bool = false
    var passwordEntryMessage: String = ""
    var isKeyPluggedIn: Bool = false
    /// The OATH version of the YubiKey whose accounts are shown, nil until one has been read.
    var keyVersion: Version?
    var sessionError: Error?
    var connectionError: Error?
    
    var showTouchToast: Bool = false

    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// What shows the countdowns and can be seen now. The main window counts as seen until it says otherwise.
    @ObservationIgnored private var countdownViewers: Set<CountdownViewer> = [.mainWindow]

    /// What shows the countdowns of the codes.
    enum CountdownViewer {
        case mainWindow
        case menuBar
    }

    @ObservationIgnored var accessKeyMemoryCache = AccessKeyCache()
    let accessKeySecureStore = SecureStore(secureStoreQueryable: PasswordQueryable(service: KeychainService.oathPasswords))
    let passwordPreferences = PasswordPreferences()
    
    // Resumed with the password the user entered in the password alert, nil if they cancelled.
    @ObservationIgnored var passwordEntryContinuation: CheckedContinuation<String?, Never>? = nil
    
    // Called once with the choice the user made in the save password dialog.
    @ObservationIgnored var passwordSaveTypeHandler: ((PasswordSaveType?) -> Void)? = nil
    
    @ObservationIgnored private var refreshDebounceTask: Task<Void, Never>? = nil

    @ObservationIgnored private var sessionTask: Task<(), Never>? = nil
    
    @ObservationIgnored private var favoritesStorage = FavoritesStorage()
    @ObservationIgnored private var favorites: Set<String> = []
    @ObservationIgnored let tagsStorage = AccountTagsStorage()
    /// The tags of YubiKey accounts by credential id, nil while they can't be read.
    @ObservationIgnored var keyTags: [String: [String]]?

    @ObservationIgnored private var refreshRequestCount = 0

    @ObservationIgnored let cloud: EnteCloud
    /// The vault code each cloud account was made from, by account id.
    @ObservationIgnored var cloudCodes: [String: EnteCloudCode] = [:]
    @ObservationIgnored let device: DeviceAccounts
    /// The code each account on this device was made from, by account id.
    @ObservationIgnored var deviceCodes: [String: EnteCloudCode] = [:]

    private static let hasReadYubiKeyKey = "HasReadYubiKey"
    /// Whether a YubiKey was ever read here. Until then the app doesn't ask for one next to the accounts it has.
    private(set) var hasReadYubiKey = UserDefaults.standard.bool(forKey: MainViewModel.hasReadYubiKeyKey)

    /// Nil in the tests, which mustn't change what Spotlight has of the app.
    @ObservationIgnored private let spotlight: AccountSpotlight?

    init(cloud: EnteCloud = .shared, device: DeviceAccounts = .shared, spotlight: AccountSpotlight? = nil) {
        self.cloud = cloud
        self.device = device
        self.spotlight = spotlight
        favoritesStorage.migrate()
        self.favorites = favoritesStorage.readFavorites()
        self.keyTags = tagsStorage.read()
        cloud.onChange = { [weak self] in self?.updateCloudAccounts() }
        device.onChange = { [weak self] in
            self?.updateDeviceAccounts()
            self?.cloud.updateAutoFill()
        }
        updateCloudAccounts()
        updateDeviceAccounts()
    }

    /// Makes the accounts for the vault's entries, keeping the ones whose account didn't change so their codes stay.
    private func updateCloudAccounts() {
        var codes = [String: EnteCloudCode]()
        let previous = Dictionary(cloudAccounts.map { ($0.accountId, $0) }, uniquingKeysWith: { first, _ in first })
        cloudAccounts = cloud.accounts.map { entry in
            let accountId = "ente/" + entry.id
            codes[accountId] = entry.code
            if let account = previous[accountId], let code = cloudCodes[accountId], code.isSameAccount(as: entry.code) {
                account.isPendingSync = entry.isPending
                if account.isPinned != entry.code.isPinned {
                    account.isPinned = entry.code.isPinned
                }
                Self.updateDisplay(of: account, from: entry.code)
                return account
            }
            return cloudAccount(id: entry.id, code: entry.code, isPending: entry.isPending)
        }
        cloudCodes = codes
    }

    /// Makes the accounts for the ones on this device, keeping the ones that didn't change so their codes stay.
    private func updateDeviceAccounts() {
        var codes = [String: EnteCloudCode]()
        let previous = Dictionary(deviceAccounts.map { ($0.accountId, $0) }, uniquingKeysWith: { first, _ in first })
        deviceAccounts = device.accounts.map { entry in
            let accountId = "device/" + entry.id
            codes[accountId] = entry.code
            if let account = previous[accountId], let code = deviceCodes[accountId], code.isSameAccount(as: entry.code) {
                if account.isPinned != entry.code.isPinned {
                    account.isPinned = entry.code.isPinned
                }
                Self.updateDisplay(of: account, from: entry.code)
                return account
            }
            return deviceAccount(id: entry.id, code: entry.code)
        }
        deviceCodes = codes
    }

    /// Takes a deleted account off the YubiKey's list without reading the YubiKey again.
    func removeKeyAccount(_ account: Account) {
        keyAccounts.removeAll { $0.accountId == account.accountId }
    }

    func sortAccounts() {
        accounts = (keyAccounts + cloudAccounts + deviceAccounts).sorted()
        let tags = Self.tags(of: accounts)
        if tags != allTags {
            allTags = tags
        }
    }

    /// Refresh requests arriving within 100 ms of each other are coalesced. A single request refreshes
    /// only that account, several requests refresh all accounts.
    private func requestRefresh(_ account: Account) {
        refreshRequestCount += 1
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            let requestCount = self.refreshRequestCount
            self.refreshRequestCount = 0
            guard self.sessionTask != nil else { return }
            // The timer of a code outlives its YubiKey being unplugged, and looking for the key would then ask for NFC.
            guard self.keyAccounts.contains(where: { $0 === account }) else { return }
            // Run the refresh outside the debounce task so a later request doesn't cancel it.
            if requestCount == 1 {
                Task { [weak self] in
                    await self?.updateAccount(account)
                }
            } else {
                Task { [weak self] in
                    await self?.updateAccounts()
                }
            }
        }
    }
    
    private func stopObservingPinnedState() {
        keyAccounts.forEach { $0.onPinnedChange = nil }
    }

    func start() {
        // start() is called again to retry after a connection error.
        tickTask?.cancel()
        sessionTask?.cancel()
        device.loadIfLocked()
        refreshCalculatedCodes()

        startTicking()

        sessionTask = Task { [weak self] in
            do {
                for try await session in OATHSessionHandler.shared.wiredSessions() {
                    self?.isKeyPluggedIn = true
                    await self?.updateAccounts(using: session)
                    let error = await session.sessionDidEnd()
                    // stop() was called while the YubiKey was inserted and start() may have been called since.
                    guard !Task.isCancelled else { return }
                    self?.stopObservingPinnedState()
                    self?.keyAccounts.removeAll()
                    self?.accountsLoaded = false
                    self?.keyVersion = nil
                    self?.isKeyPluggedIn = false
                    self?.sessionError = error
                }
            } catch {
                if let sessionError = error as? OATHSessionError {
                    if sessionError == .otpEnabledError {
                        self?.isKeyPluggedIn = true
                        self?.presentDisableOTP = true
                    } else if sessionError == .oathDisabledError {
                        // Don't set connectionError to avoid restart loop - use sessionError instead
                        self?.sessionError = error
                    } else if sessionError != .connectionCancelled {
                        self?.connectionError = error
                    }
                } else {
                    self?.connectionError = error
                }
            }
        }
    }

    /// Whether a viewer of the countdowns can be seen. While none can, e.g. when the window is covered by others or on
    /// another Space, the countdowns aren't updated every second, which saves energy. They catch up as soon as one can be
    /// seen again. The codes are still renewed as they expire, each on its own timer.
    func setCountdownsVisible(_ isVisible: Bool, in viewer: CountdownViewer) {
        let wasTicking = !countdownViewers.isEmpty
        if isVisible {
            countdownViewers.insert(viewer)
        } else {
            countdownViewers.remove(viewer)
        }
        guard isStarted, wasTicking == countdownViewers.isEmpty else { return }
        startTicking()
    }

    /// Updates the countdowns now and then every second, while a viewer can see them.
    private func startTicking() {
        tickTask?.cancel()
        tickTask = nil
        guard !countdownViewers.isEmpty else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                for account in self?.accounts ?? [] {
                    account.updateState()
                }
                // The tolerance lets the system wake the app together with other work. Too little to see in the countdown.
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(50))
            }
        }
    }

    func closeConnections() async {
        await ConnectionManager.shared.suspendWiredConnections()
    }

    /// Whether ``start()`` has been called and ``stop()`` hasn't since.
    var isStarted: Bool { sessionTask != nil }

    /// Reads the accounts and codes from the inserted YubiKey again, and syncs with Ente Auth.
    func refresh() {
        Task { await cloud.sync(reportsErrors: true) }
        guard isStarted, accountsLoaded else { return }
        Task { await updateAccounts() }
    }

    /// Whether there is something to refresh: a YubiKey that was read, or Ente Auth accounts to sync.
    var canRefresh: Bool { accountsLoaded || cloud.isEnabled }

    func stop() {
        sessionTask?.cancel()
        sessionTask = nil

        tickTask?.cancel()
        tickTask = nil

        stopObservingPinnedState()
        keyAccounts.removeAll()
        accountsLoaded = false
        keyVersion = nil
        isKeyPluggedIn = false
        sessionError = nil
        connectionError = nil
    }
    
    private func updateAccount(_ account: Account) async {
        do {
            let session = try await OATHSessionHandler.shared.anySession()
            
            // We can't know if a HOTP requires touch. Instead we wait for 0.5 seconds for a response and if
            // the key doesn't return we assume it requires touch.
            let isWired = session.type == .wired
            let showTouchAlert = Task { [weak self] in
                try await Task.sleep(for: .milliseconds(500))
                guard isWired, let self else { return }
                self.showTouchToast = true
                Platform.notify(.error)
                #if os(macOS)
                TouchPrompt.show(for: account.title)
                #endif
            }
            
            // The prompt stays up until the YubiKey has been touched, or the calculation failed.
            defer {
                showTouchAlert.cancel()
                showTouchToast = false
                #if os(macOS)
                TouchPrompt.hide()
                #endif
            }
            let otp = try await session.calculate(credential: account.credential)
            
            if let account = (keyAccounts.filter { $0.accountId == account.accountId }).first {
                account.update(otp: otp)
            }

            session.endNFC(message: String(localized: "Code calculated", comment: "OATH NFC code calculated"))
        } catch {
            handle(error: error, retry: { Task { await self.updateAccount(account) }})
        }
    }
    
    func updateAccounts(using session: OATHSession? = nil) async {
        do {
            stopObservingPinnedState()
            let useSession: OATHSession
            if let session {
                useSession = session
            } else {
                useSession = try await OATHSessionHandler.shared.anySession()
            }
            
            // They can't be read if the app was started while the device was locked.
            favorites = favoritesStorage.readFavorites()
            if let tags = tagsStorage.read() {
                keyTags = tags
            }
            let credentials = try await useSession.calculateAll()
            let updatedAccounts = try await credentials.asyncMap { (credential, otp)  in
                if credential.type == .totp && (
                    (!credential.requiresTouch && credential.isSteam) ||
                    (useSession.type == .nfc && credential.requiresTouch && SettingsConfig.isBypassTouchEnabled)) {
                    let otp = try await useSession.calculate(credential: credential)
                    return self.account(credential: credential, code: otp, keyVersion: useSession.version, connectionType: useSession.type)
                } else {
                    return self.account(credential: credential, code: otp, keyVersion: useSession.version, connectionType: useSession.type)
                }
            }
            
            self.keyAccounts = updatedAccounts
            
            updatedAccounts.forEach { account in
                account.onPinnedChange = { [weak self] account in
                    guard let self else { return }
                    if account.isPinned {
                        self.favorites.insert(account.accountId)
                    } else {
                        self.favorites.remove(account.accountId)
                    }
                    self.favoritesStorage.saveFavorites(self.favorites)
                }
            }
            
            self.keyVersion = useSession.version
            self.accountsLoaded = true
            if !hasReadYubiKey {
                hasReadYubiKey = true
                UserDefaults.standard.set(true, forKey: Self.hasReadYubiKeyKey)
            }
            let message = SettingsConfig.showNFCSwipeHint ? String(localized: "Success!\nHint: swipe down to dismiss", comment: "iOS NFC alert success with hint") : String(localized: "Successfully read", comment: "iOS NFC alert successfully read")
            useSession.endNFC(message: message)
        } catch {
            handle(error: error, retry: { Task { await self.updateAccounts() }})
        }
    }
    
    private func account(credential: OATHSession.Credential, code: OATHSession.OTP?, keyVersion: Version, connectionType: OATHSession.ConnectionType) -> Account {
        let tags = keyTags?[credential.id] ?? []
        if let account = (keyAccounts.filter { $0.credential.id == credential.id }).first {
            account.update(otp: code)
            if account.tags != tags {
                account.tags = tags
            }
            return account
        } else {
            let account = Account(credential: credential, code: code, keyVersion: keyVersion, requestRefresh: { [weak self] in self?.requestRefresh($0) }, connectionType: connectionType, isPinned: favorites.contains(credential.id))
            account.tags = tags
            return account
        }
    }

    /// How many accounts the YubiKey whose accounts are shown can hold, nil if that isn't known.
    var credentialCapacity: Int? {
        keyVersion.map(OATHSession.credentialCapacity(version:))
    }

    func updateAccountsOverNFC() {
        Task {
            do {
                let session = try await OATHSessionHandler.shared.nfcSession()
                await updateAccounts(using: session)
            } catch {
                if !error.isNFCCancelledByUser {
                    ConnectionManager.shared.closeNFC(errorMessage: String(localized: "Something went wrong"))
                    self.sessionError = error
                }
            }
        }
    }
    
}

extension OATHSession.Credential {
    var id: String {
        OATHCredentialId.key(accountName: accountName, issuer: issuer, period: period, isTOTP: type == .totp)
    }
}


extension Sequence {
    nonisolated(nonsending) func asyncMap<T>(_ transform: nonisolated(nonsending) (Element) async throws -> T) async rethrows -> [T] {
        var values = [T]()
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}
