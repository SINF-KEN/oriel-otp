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
    let accessKeySecureStore = SecureStore(secureStoreQueryable: PasswordQueryable(service: "OATH"))
    let passwordPreferences = PasswordPreferences()
    
    // Resumed with the password the user entered in the password alert, nil if they cancelled.
    @ObservationIgnored private var passwordEntryContinuation: CheckedContinuation<String?, Never>? = nil
    
    // Called once with the choice the user made in the save password dialog.
    @ObservationIgnored private var passwordSaveTypeHandler: ((PasswordSaveType?) -> Void)? = nil
    
    @ObservationIgnored private var refreshDebounceTask: Task<Void, Never>? = nil

    @ObservationIgnored private var sessionTask: Task<(), Never>? = nil
    
    @ObservationIgnored private var favoritesStorage = FavoritesStorage()
    @ObservationIgnored private var favorites: Set<String> = []
    @ObservationIgnored private let tagsStorage = AccountTagsStorage()
    /// The tags of YubiKey accounts by credential id, nil while they can't be read.
    @ObservationIgnored private var keyTags: [String: [String]]?

    @ObservationIgnored private var refreshRequestCount = 0

    @ObservationIgnored let cloud: EnteCloud
    /// The vault code each cloud account was made from, by account id.
    @ObservationIgnored private var cloudCodes: [String: EnteCloudCode] = [:]
    @ObservationIgnored let device: DeviceAccounts
    /// The code each account on this device was made from, by account id.
    @ObservationIgnored private var deviceCodes: [String: EnteCloudCode] = [:]

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
        device.onChange = { [weak self] in self?.updateDeviceAccounts() }
        updateCloudAccounts()
        updateDeviceAccounts()
    }

    private func sortAccounts() {
        accounts = (keyAccounts + cloudAccounts + deviceAccounts).sorted()
        let tags = Self.tags(of: accounts)
        if tags != allTags {
            allTags = tags
        }
    }

    // MARK: - Tags

    /// The tags of all accounts, by name.
    private(set) var allTags: [String] = []

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
    private func saveKeyTags(_ tags: [String], for credentialId: String, movingFrom oldId: String? = nil) throws {
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

    // MARK: - Ente Auth

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

    private func cloudAccount(id: String, code: EnteCloudCode, isPending: Bool) -> Account {
        let credential = OATHSession.Credential(type: code.kind == .hotp ? .hotp : .totp, issuer: code.issuer, accountName: code.accountName,
                                                period: UInt(code.period))
        let otp = code.kind == .hotp ? nil : code.code(at: AppClock.now)
        // Calculated like on a YubiKey that is plugged in: a new code is calculated when one expires.
        let account = calculatedAccount(credential: credential, otp: otp, code: code, location: .ente(id: id))
        account.isPendingSync = isPending
        account.onPinnedChange = { [weak self] account in
            do {
                try self?.cloud.setPinned(id, account.isPinned)
            } catch {
                // Otherwise the pin would look saved, and be gone at the next launch.
                self?.sessionError = error
            }
        }
        return account
    }

    private func calculatedAccount(credential: OATHSession.Credential, otp: (code: String, validity: DateInterval)?, code: EnteCloudCode,
                                   location: Account.Location) -> Account {
        let account = Account(credential: credential, code: otp.map { OATHSession.OTP(code: $0.code, validity: $0.validity) },
                              keyVersion: Version("0.0.0")!, requestRefresh: { [weak self] in self?.calculateCode(for: $0) },
                              connectionType: .wired, isPinned: code.isPinned, location: location)
        Self.updateDisplay(of: account, from: code)
        return account
    }

    /// The tags and icon, which can change without the account being made again.
    private static func updateDisplay(of account: Account, from code: EnteCloudCode) {
        if account.tags != code.tags {
            account.tags = code.tags
        }
        if account.iconID != code.iconID {
            account.iconID = code.iconID
        }
    }

    /// Calculates the code of an account in Ente Auth or on this device.
    private func calculateCode(for account: Account) {
        let nextHOTPCode: () -> String?
        let code: EnteCloudCode?
        switch account.location {
        case .yubiKey:
            return
        case .ente(let id):
            code = cloudCodes[account.accountId]
            nextHOTPCode = { [cloud] in cloud.nextHOTPCode(id) }
        case .device(let id):
            code = deviceCodes[account.accountId]
            nextHOTPCode = { [device] in device.nextHOTPCode(id) }
        }
        guard let code else { return }
        if code.kind == .hotp {
            guard let otp = nextHOTPCode() else { return }
            account.update(otp: OATHSession.OTP(code: otp, validity: DateInterval(start: AppClock.now, end: .distantFuture)))
        } else {
            // A refresh scheduled for when the code expires can fire a moment early. It still gets the next code.
            var date = AppClock.now
            if let end = account.otp?.validity.end, end > date, end.timeIntervalSince(date) < 1 {
                date = end
            }
            let (otp, validity) = code.code(at: date)
            account.update(otp: OATHSession.OTP(code: otp, validity: validity))
        }
    }

    /// Calculates the codes of the time-based accounts the app calculates again, e.g. after it was in the background.
    private func refreshCalculatedCodes() {
        for account in cloudAccounts + deviceAccounts where account.credential.type == .totp {
            calculateCode(for: account)
        }
    }

    /// Adds an account to the Ente Auth vault and uploads it.
    func addCloudAccount(_ template: YubiKitOATHSession.CredentialTemplate) throws -> EnteCloud.AddResult {
        try cloud.add(template)
    }

    // MARK: - This device

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

    private func deviceAccount(id: String, code: EnteCloudCode) -> Account {
        let credential = OATHSession.Credential(type: code.kind == .hotp ? .hotp : .totp, issuer: code.issuer, accountName: code.accountName,
                                                period: UInt(code.period))
        let otp = code.kind == .hotp ? nil : code.code(at: AppClock.now)
        let account = calculatedAccount(credential: credential, otp: otp, code: code, location: .device(id: id))
        account.onPinnedChange = { [weak self] account in
            do {
                try self?.device.setPinned(id, account.isPinned)
            } catch {
                // Otherwise the pin would look saved, and be gone at the next launch.
                self?.sessionError = error
            }
        }
        return account
    }

    /// Adds an account to this device.
    func addDeviceAccount(_ template: YubiKitOATHSession.CredentialTemplate) throws -> DeviceAccounts.AddResult {
        try device.add(template)
    }

    enum MoveToEnteResult {
        case moved
        /// Ente Auth has an account with the same name. Nothing was changed, also not on this device.
        case alreadyInEnte
    }

    /// Whether the account on this device can be moved to Ente Auth, which also backs it up.
    func canMoveToEnte(_ account: Account) -> Bool {
        account.isOnDevice && cloud.isEnabled
    }

    /// Puts an account on this device in Ente Auth, and deletes it here once it is saved in the vault. Until it has
    /// been uploaded the vault is its only copy, so if the vault is discarded before then, e.g. by signing out, the
    /// account is put back on this device (see `EnteCloud`).
    func moveToEnte(_ account: Account) throws -> MoveToEnteResult {
        guard case .device(let id) = account.location, let rawData = device.rawData(of: id) else { return .alreadyInEnte }
        guard try cloud.add(rawData: rawData) == .added else { return .alreadyInEnte }
        try device.delete(id)
        return .moved
    }

    // MARK: - YubiKey

    enum CopyToYubiKeyResult {
        case copied, moved
        /// The YubiKey has an account with the same name. Nothing was changed, also not where the account is now.
        case alreadyOnYubiKey
    }

    /// The credential to put the account on a YubiKey with, nil if a YubiKey can't store it.
    private func yubiKeyTemplate(of account: Account) -> YubiKitOATHSession.CredentialTemplate? {
        switch account.location {
        case .yubiKey: nil
        case .ente(let id): cloud.yubiKeyTemplate(of: id)
        case .device(let id): device.yubiKeyTemplate(of: id)
        }
    }

    /// Whether the account can be copied to a YubiKey. It can't if a YubiKey can't store it. A HOTP account can only
    /// be moved, as a copy would count codes on its own and fall out of step with the original.
    func canCopyToYubiKey(_ account: Account, moving: Bool) -> Bool {
        guard moving || account.credential.type != .hotp else { return false }
        return yubiKeyTemplate(of: account) != nil
    }

    /// Puts an account in Ente Auth or on this device on the YubiKey. Moving it also moves it to Ente's trash or
    /// deletes it from this device, once it is on the YubiKey. The completion isn't called when the YubiKey couldn't
    /// be reached, which `handle(error:)` reports.
    func copyToYubiKey(_ account: Account, moving: Bool, completion: @escaping (CopyToYubiKeyResult) -> Void) {
        guard let template = yubiKeyTemplate(of: account) else { return }
        addAccounts([template], requiresTouch: false) { [weak self] result in
            if let error = result.error {
                self?.sessionError = error.isOATHStorageFull ? OATHSessionError.storageFull(notAdded: [template.displayName]) : error
                return
            } else if result.added.isEmpty {
                completion(.alreadyOnYubiKey)
                return
            }
            // The copy on the YubiKey is filed under the same tags.
            if !account.tags.isEmpty {
                let id = OATHCredentialId.key(accountName: template.name, issuer: template.issuer,
                                              period: UInt(template.type.period ?? 0), isTOTP: template.type.period != nil)
                do {
                    try self?.saveKeyTags(account.tags, for: id)
                } catch {
                    // The account is on the key; only its tags are missing, which the user is told.
                    self?.sessionError = error
                }
                self?.keyAccounts.first { $0.credential.id == id }?.tags = account.tags
                self?.sortAccounts()
            }
            if moving {
                // If the source can't be removed, the account is on both: "copied", with the error.
                completion(self?.removeAfterMove(account) == true ? .moved : .copied)
            } else {
                completion(.copied)
            }
        }
    }
    
    /// Removes the account from where it was moved from. Returns false, and shows the error, if it couldn't be.
    private func removeAfterMove(_ account: Account) -> Bool {
        do {
            switch account.location {
            case .yubiKey: break
            case .ente(let id): try cloud.delete(id)
            case .device(let id): try device.delete(id)
            }
            return true
        } catch {
            sessionError = error
            return false
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
    
    /// Called by the password alert in MainView.
    func submitPassword(_ password: String) {
        resumePasswordEntry(with: password)
    }

    /// Called when the password alert in MainView is cancelled.
    func cancelPasswordEntry() {
        resumePasswordEntry(with: nil)
    }

    private func resumePasswordEntry(with password: String?) {
        let continuation = passwordEntryContinuation
        passwordEntryContinuation = nil
        continuation?.resume(returning: password)
    }
    
    /// Called by the save password dialog in MainView. `nil` means "Not now".
    func selectPasswordSaveType(_ type: PasswordSaveType?) {
        let handler = passwordSaveTypeHandler
        passwordSaveTypeHandler = nil
        handler?(type)
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
    
    private func updateAccounts(using session: OATHSession? = nil) async {
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
    
    /// Adds an account to the YubiKey. The completion is called only if the account was added.
    func addAccount(_ template: YubiKitOATHSession.CredentialTemplate, requiresTouch: Bool, completion: (() -> Void)? = nil) {
        Task {
            do {
                let session = try await OATHSessionHandler.shared.anySession()
                try await session.addCredential(template: template, requiresTouch: requiresTouch)
                await updateAccounts(using: session)
                completion?()
            } catch {
                handle(error: error, retry: { self.addAccount(template, requiresTouch: requiresTouch, completion: completion) })
            }
        }
    }
    
    /// Adds several accounts in one YubiKey session, e.g. when importing. Accounts already on the YubiKey are skipped.
    func addAccounts(_ templates: [YubiKitOATHSession.CredentialTemplate], requiresTouch: Bool, completion: @escaping (OATHSession.AddCredentialsResult) -> Void) {
        Task {
            do {
                let session = try await OATHSessionHandler.shared.anySession()
                let result = try await session.addCredentials(templates: templates, requiresTouch: requiresTouch)
                await updateAccounts(using: session)
                completion(result)
            } catch {
                handle(error: error, retry: { self.addAccounts(templates, requiresTouch: requiresTouch, completion: completion) })
            }
        }
    }

    func renameAccount(_ account: Account, issuer: String, accountName: String, completion: @escaping () -> Void) {
        if case .ente(let id) = account.location {
            do {
                try cloud.rename(id, issuer: issuer, accountName: accountName)
                completion()
            } catch {
                sessionError = error
            }
            return
        }
        if case .device(let id) = account.location {
            do {
                try device.rename(id, issuer: issuer, accountName: accountName)
                completion()
            } catch {
                sessionError = error
            }
            return
        }
        Task {
            do {
                let wasPinned = account.isPinned
                let session = try await OATHSessionHandler.shared.anySession()
                let oldId = account.credential.id
                let credential = try await session.renameCredential(account.credential, issuer: issuer, accountName: accountName)
                // The tags are kept by the account's id, which the new name changes.
                if !account.tags.isEmpty {
                    do {
                        try saveKeyTags(account.tags, for: credential.id, movingFrom: oldId)
                    } catch {
                        // Renamed on the key; only the tags didn't follow, which the user is told.
                        sessionError = error
                    }
                }
                if wasPinned {
                    account.isPinned = false
                }
                account.credential = credential
                account.updateTitles()
                sortAccounts()
                account.isPinned = wasPinned
                await updateAccounts(using: session)
                ConnectionManager.shared.closeNFC(message: String(localized: "Account renamed", comment: "OATH NFC account renamed"))
                completion()
            } catch {
                handle(error: error, retry: { self.renameAccount(account, issuer: issuer, accountName: accountName, completion: completion) })
            }
        }
    }
    
    /// Deletes the account from the YubiKey or this device, or moves an Ente Auth account to Ente's trash.
    func deleteAccount(_ account: Account, completion: @escaping () -> Void) {
        if case .ente(let id) = account.location {
            do {
                try cloud.delete(id)
                completion()
            } catch {
                sessionError = error
            }
            return
        }
        if case .device(let id) = account.location {
            do {
                try device.delete(id)
                completion()
            } catch {
                sessionError = error
            }
            return
        }
        Task {
            do {
                let session = try await OATHSessionHandler.shared.anySession()
                try await session.deleteCredential(account.credential)
                keyAccounts.removeAll { $0.accountId == account.accountId }
                if !account.tags.isEmpty {
                    do {
                        try saveKeyTags([], for: account.credential.id)
                    } catch {
                        // Left behind, they'd come back on an account added later with the same name.
                        sessionError = error
                    }
                }
                session.endNFC(message: String(localized: "Account deleted", comment: "OATH NFC account deleted"))
                completion()
            } catch {
                handle(error: error, retry: { self.deleteAccount(account, completion: completion) })
            }
        }
    }
    
    /// Deletes the accounts one after the other, as the YubiKey handles one command at a time.
    func deleteAccounts(_ accounts: [Account], completion: @escaping () -> Void) {
        guard let account = accounts.first else {
            completion()
            return
        }
        deleteAccount(account) { [weak self] in
            self?.deleteAccounts(Array(accounts.dropFirst()), completion: completion)
        }
    }

    /// Shows the password alert and returns the entered password, or nil if the user cancelled.
    private func requestPassword(isRetry: Bool) async -> String? {
        ConnectionManager.shared.closeNFC(errorMessage: String(localized: "Key is password protected", comment: "OATH NFC password protected key"))
        passwordEntryMessage = isRetry ? String(localized: "Incorrect password. Re-enter password.", comment: "OATH password entry retry") : String(localized: "To prevent unauthorized access this YubiKey is protected with a password.", comment: "OATH password entry enter password")
        // Only one password alert can be shown, an earlier request is treated as cancelled.
        cancelPasswordEntry()
        presentPasswordEntry = true
        return await withCheckedContinuation { passwordEntryContinuation = $0 }
    }

    /// Asks for the password and unlocks the YubiKey with it. Returns false if the user cancelled.
    private func collectPasswordAndUnlock(isRetry: Bool) async throws -> Bool {
        guard let password = await requestPassword(isRetry: isRetry) else { return false }
        let session = try await OATHSessionHandler.shared.anySession()
        let accessKey = try await session.unlock(withPassword: password)
        accessKeyMemoryCache.setAccessKey(accessKey, forKey: session.deviceId)
        handleAccessKeyStorage(accessKey: accessKey, forKey: session.deviceId)
        return true
    }

    /// Unlocks with the cached access key. Returns false if there is none or it didn't work.
    private func unlockWithCachedAccessKey() async -> Bool {
        guard let accessKey = await cachedAccessKey(),
              let session = try? await OATHSessionHandler.shared.anySession() else { return false }
        return (try? await session.unlock(withAccessKey: accessKey)) != nil
    }

    func handle(error: Error, retry: (() -> Void)? = nil) {
        if error.isOATHAuthenticationRequired || error.isOATHWrongPassword {
            Task {
                do {
                    if error.isOATHAuthenticationRequired, await unlockWithCachedAccessKey() {
                        retry?()
                    } else if try await collectPasswordAndUnlock(isRetry: error.isOATHWrongPassword) {
                        retry?()
                    }
                } catch {
                    ConnectionManager.shared.closeNFC(errorMessage: String(localized: "Something went wrong"))
                    handle(error: error, retry: retry)
                }
            }
        } else if error.isNFCCancelledByUser {
            // The user dismissed the NFC sheet.
        } else {
            ConnectionManager.shared.closeNFC(errorMessage: LocalizedErrorWrapper(error: error).localizedDescription)
            self.sessionError = error
        }
    }
    
    private func cachedAccessKey() async -> Data? {
        guard let session = try? await OATHSessionHandler.shared.anySession() else { return nil }
        let keyIdentifier = session.deviceId
        // Check memory cache
        if let accessKey = self.accessKeyMemoryCache.accessKey(forKey: keyIdentifier) {
            return accessKey
        }
        // Finally check key chain
        return try? await self.accessKeySecureStore.getValue(for: keyIdentifier)
    }

    func handleAccessKeyStorage(accessKey: Data, forKey keyIdentifier: String) {
        guard !self.passwordPreferences.neverSavePassword(keyIdentifier: keyIdentifier) else { return }
        Task { [weak self] in
            guard let secureStore = self?.accessKeySecureStore else { return }
            let currentAccessKey: Data? = try? await secureStore.getValue(for: keyIdentifier)
            guard let self, accessKey != currentAccessKey else { return }
            self.presentPasswordSaveType = true
            self.passwordSaveTypeHandler = { [weak self] type in
                guard let type, let self else { return }
                self.passwordPreferences.setPasswordPreference(saveType: type, keyIdentifier: keyIdentifier)
                if type == .save || type == .lock {
                    do {
                        try self.accessKeySecureStore.setValue(accessKey, useAuthentication: self.passwordPreferences.useScreenLock(keyIdentifier: keyIdentifier), for: keyIdentifier)
                    } catch {
                        self.passwordPreferences.resetPasswordPreference(keyIdentifier: keyIdentifier)
                        self.sessionError = error
                    }
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
