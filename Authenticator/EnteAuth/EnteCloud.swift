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
import Network
import YubiKit

/// The Ente Auth accounts on this device, kept in step with Ente in both directions.
///
/// While an Ente account is saved (**Stay signed in**), its entities are kept in the vault, so their codes are shown
/// in the account list and work offline. Accounts added, renamed, pinned or deleted here are changed in the vault
/// first and uploaded on the next sync, which also pulls what changed on other devices since the last one. See
/// `EnteVault` for how conflicts are settled.
///
/// Syncing needs the saved session, which is unlocked with Face ID or Touch ID once and then kept in memory until the
/// app quits. The app syncs when it comes to the foreground (asking for the unlock only once per launch), when the
/// list is pulled down, after each change made here and when the network comes back with changes waiting.
@Observable final class EnteCloud {

    static let shared = EnteCloud(autoFill: .shared, device: .shared)

    enum AddResult: Equatable {
        case added
        case alreadyPresent
    }

    /// An account in the vault that can be shown in the account list.
    struct Account: Equatable {
        let id: String
        let code: EnteCloudCode
        let isPending: Bool
    }

    /// Nil when no Ente account is saved.
    private(set) var vault: EnteVault?
    private(set) var isSyncing = false
    /// The last error of a sync the user asked for, or the session being rejected.
    var error: Error?

    /// Called after the vault changed.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let store: EnteSessionStore
    @ObservationIgnored private let storage: EnteVaultStorage
    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private let watch: WatchAccountSync
    /// Nil in the tests, which mustn't change the accounts AutoFill uses.
    @ObservationIgnored private let autoFill: AutoFillAccountSync?
    /// Where accounts added here that never reached Ente are kept when the vault is discarded. Nil in the tests that
    /// keep no accounts on the device.
    @ObservationIgnored private let device: DeviceAccounts?
    @ObservationIgnored private var session: EnteSavedSession?
    @ObservationIgnored private var didAskToUnlock = false
    @ObservationIgnored private var unlockTask: Task<EnteSavedSession?, Never>?
    @ObservationIgnored private var runningSync: Task<Void, Error>?
    @ObservationIgnored private var queuedSync: Task<Void, Error>?
    /// Changes when the vault is replaced, so a sync that was under way when it was doesn't write into the new one.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// The vault file couldn't be read because the device was locked, or the accounts only it has couldn't be kept on
    /// the device before discarding it. Nothing is written over the file until it is read again.
    @ObservationIgnored private var isVaultLocked = false
    /// The vault file can't be read at all, e.g. it was written by a later version of the app. It is set aside before
    /// the first save rather than written over: it may hold accounts that were never uploaded.
    @ObservationIgnored private var isVaultUnreadable = false

    init(store: EnteSessionStore = EnteSessionStore(), storage: EnteVaultStorage = EnteVaultFile(), session: URLSession = .ente,
         watch: WatchAccountSync = .shared, autoFill: AutoFillAccountSync? = nil, device: DeviceAccounts? = nil) {
        self.store = store
        self.storage = storage
        self.urlSession = session
        self.watch = watch
        self.autoFill = autoFill
        self.device = device
        loadVault()
        if !isVaultLocked {
            updateAutoFill()
        }
    }

    /// Reads the vault of the saved account, or of `session` if one is being used. If the device is locked, e.g. when
    /// the app was launched in the background, it is read once the app comes to the foreground, and nothing is written
    /// over it until then. The saved account can't always be read then either, so that doesn't say there is no vault.
    private func loadVault(for session: EnteSavedSession? = nil) {
        let saved: (email: String, server: URL)? = session.map { ($0.email, $0.server) } ?? store.savedAccount.map { ($0.email, $0.server) }
        let vault: EnteVault?
        do {
            vault = try storage.load()
        } catch EnteVaultError.unreadable {
            // Its key is gone or it can't be decoded, which reading it again won't change. The first sync fills a
            // new vault, and the file is kept next to it.
            vault = nil
            isVaultUnreadable = true
            if saved != nil {
                error = EnteVaultError.unreadable
            }
        } catch {
            // The device is locked, or the keychain failed for now. Taking that for "no vault" would write an empty
            // one over the file.
            isVaultLocked = true
            return
        }
        isVaultLocked = false
        recoverSetAsideVaults()
        if let vault, saved.map({ vault.belongs(email: $0.email, server: $0.server) }) != true {
            // Signed out while the vault was kept, or the vault of another account. It is discarded once the accounts
            // only it has are on the device.
            guard keepAccountsNeverUploaded(of: vault) else {
                isVaultLocked = true
                return
            }
            if saved == nil {
                removeFile()
            }
        }
        if let saved {
            if let vault, vault.belongs(email: saved.email, server: saved.server) {
                self.vault = vault
            } else {
                // The first sync fills it. Also when the file couldn't be read, e.g. because the device was restored.
                self.vault = EnteVault(email: saved.email, server: saved.server)
            }
        }
    }

    /// Puts the accounts that never reached Ente from vault files set aside earlier on this device, once those files
    /// can be read, e.g. after the app that wrote them is installed again. Their other accounts are on Ente's server.
    private func recoverSetAsideVaults() {
        storage.recoverSetAside { vault in
            guard keepAccountsNeverUploaded(of: vault) else { throw EnteVaultError.unavailable }
        }
    }

    /// Saves the vault, moving a file that couldn't be read out of the way first.
    private func save(_ vault: EnteVault) throws {
        if isVaultUnreadable {
            try storage.setAside()
            isVaultUnreadable = false
        }
        try storage.save(vault)
    }

    /// Deletes the vault file, except one that couldn't be read, which is set aside.
    private func removeFile() {
        if isVaultUnreadable {
            guard (try? storage.setAside()) != nil else { return }
            isVaultUnreadable = false
        }
        storage.remove()
    }

    /// Reads the vault if it couldn't be read before because the device was locked.
    private func loadVaultIfLocked(for session: EnteSavedSession? = nil) {
        guard isVaultLocked else { return }
        loadVault(for: session)
        if vault != nil {
            changed()
        }
    }

    /// Puts the accounts added here that never reached Ente on this device, as the vault about to be discarded is
    /// their only copy. Returns false if they couldn't be saved there, so the vault must be kept.
    private func keepAccountsNeverUploaded(of vault: EnteVault) -> Bool {
        let accounts = vault.accountsNeverUploaded
        guard !accounts.isEmpty, let device else { return true }
        device.loadIfLocked()
        do {
            try device.keep(rawData: accounts)
            return true
        } catch {
            return false
        }
    }

    var isEnabled: Bool { vault != nil }

    var email: String? { vault?.email }

    var hasPendingChanges: Bool { vault?.hasPendingChanges ?? false }

    /// The accounts whose codes can be calculated here, without the ones in Ente's trash.
    var accounts: [Account] {
        vault?.items.compactMap { item in
            guard let rawData = item.rawData, let code = EnteCloudCode(rawData: rawData) else { return nil }
            return Account(id: item.id, code: code, isPending: item.isPending)
        } ?? []
    }

    /// The accounts as the sync sheet lists them, sorted, including ones that couldn't be read.
    var codes: [EnteCode] { Self.codes(in: vault) }

    nonisolated private static func codes(in vault: EnteVault?) -> [EnteCode] {
        (vault?.items ?? []).compactMap { item -> EnteCode? in
            guard let rawData = item.rawData else {
                return EnteCode(id: item.id, issuer: nil, accountName: String(localized: "Unknown account", comment: "Ente import unreadable account"),
                                template: nil, unsupportedReason: String(localized: "This account could not be decrypted.", comment: "Ente import undecryptable account"))
            }
            return EnteCodeParser.parse(id: item.id, rawData: rawData)
        }
        .sorted { ($0.title.lowercased(), $0.accountName.lowercased()) < ($1.title.lowercased(), $1.accountName.lowercased()) }
    }

    // MARK: - Session

    /// Uses a session that was just saved or unlocked, e.g. in the sync sheet. A vault of another account is replaced.
    func use(_ session: EnteSavedSession) {
        loadVaultIfLocked(for: session)
        self.session = session
        didAskToUnlock = true
        if isVaultLocked {
            // Read on the next sync, rather than written over now.
        } else if vault?.belongs(to: session) != true {
            replaceVault(with: EnteVault(email: session.email, server: session.server))
        } else {
            // A sync that changes nothing doesn't send them, and they may have changed while the session was locked.
            watch.send(codes)
        }
        startMonitoringNetwork()
    }

    /// Deletes the vault, for when the Ente account is signed out or not kept. Accounts added here that never reached
    /// Ente are kept on this device; if they can't be, the file is kept until they can.
    func remove() {
        session = nil
        guard vault != nil else {
            if !isVaultLocked {
                removeFile()
            }
            autoFill?.remove()
            return
        }
        replaceVault(with: nil)
    }

    private func replaceVault(with vault: EnteVault?) {
        generation += 1
        if let old = self.vault, !keepAccountsNeverUploaded(of: old) {
            // The file is kept and read again, and replaced once those accounts are on the device.
            self.vault = nil
            isVaultLocked = true
            changed()
            return
        }
        self.vault = vault
        if let vault {
            try? save(vault)
        } else {
            removeFile()
        }
        changed()
    }

    /// The session in memory, or the saved one after Face ID or Touch ID if `unlock` is set. Nil if it can't be had.
    private func unlockedSession(unlock: Bool, authentication: KeychainAuthentication? = nil) async -> EnteSavedSession? {
        if let session { return session }
        guard unlock else { return nil }
        if let unlockTask { return await unlockTask.value }
        didAskToUnlock = true
        let task = Task { () -> EnteSavedSession? in
            do {
                return try await store.unlock(authentication: authentication)
            } catch EnteAuthenticatorSyncError.signedOut {
                sessionRejected(token: nil)
                return nil
            } catch {
                // Cancelled, or the device is locked. The changes wait for the next sync.
                return nil
            }
        }
        unlockTask = task
        let session = await task.value
        unlockTask = nil
        if let session {
            use(session)
        }
        return session
    }

    /// The server rejected the session or it can't be read any more. The vault is kept, so the codes still work, and
    /// its changes are uploaded once the password has been entered again. A rejected `token` that isn't the one in use
    /// any more, e.g. because the person signed in again while a sync was under way, says nothing about the new one.
    private func sessionRejected(token: String?, showsError: Bool = true) {
        if let token {
            guard session?.token == token else { return }
        }
        session = nil
        store.forgetSession()
        watch.disable()
        if showsError {
            error = EnteSyncError(EnteAuthenticatorSyncError.signedOut)
        }
    }

    // MARK: - Sync

    /// Syncs if the session is unlocked, or after asking to unlock it the first time since the app started. For when
    /// the app comes to the foreground. Errors aren't shown, except for a rejected session. `authentication` is the
    /// Face ID or Touch ID that just unlocked the app, if any, so the session doesn't ask for it a second time.
    func syncAutomatically(authentication: KeychainAuthentication? = nil) async {
        await sync(unlock: !didAskToUnlock, authentication: authentication)
    }

    /// Syncs, asking to unlock the session if needed. Errors are shown if `reportsErrors` is set, e.g. when the user
    /// pulled down the list; changes made offline just wait for the next sync.
    func sync(unlock: Bool = true, reportsErrors: Bool = false, authentication: KeychainAuthentication? = nil) async {
        loadVaultIfLocked()
        guard vault != nil, let session = await unlockedSession(unlock: unlock, authentication: authentication) else { return }
        do {
            try await enqueueSync(session).value
        } catch EnteAuthenticatorSyncError.signedOut {
            sessionRejected(token: session.token)
        } catch is CancellationError {
        } catch {
            if reportsErrors {
                self.error = EnteSyncError(error)
            }
        }
    }

    /// Syncs with the session in memory and throws its errors, for the sync sheet, which shows them.
    func syncNow() async throws {
        guard let session else { throw EnteAuthenticatorSyncError.signedOut }
        do {
            try await enqueueSync(session).value
        } catch EnteAuthenticatorSyncError.signedOut {
            sessionRejected(token: session.token, showsError: false)
            throw EnteAuthenticatorSyncError.signedOut
        }
    }

    /// Syncs run one after the other. A sync asked for while one runs is done once after it, for all who asked.
    private func enqueueSync(_ session: EnteSavedSession) -> Task<Void, Error> {
        if let queuedSync { return queuedSync }
        let previous = runningSync
        let task = Task {
            _ = await previous?.result
            self.queuedSync = nil
            try await self.performSync(session)
        }
        queuedSync = task
        runningSync = task
        return task
    }

    private func performSync(_ session: EnteSavedSession) async throws {
        guard let vault, vault.belongs(to: session) else { return }
        isSyncing = true
        defer { isSyncing = false }
        let generation = generation
        let api = try EnteAPIClient(server: session.server, session: urlSession)

        let changes = try await EnteAuthenticatorSync.changes(api: api, token: session.token, since: vault.lastSyncTime)
        let pulled = await Self.decrypt(changes.entities, authenticatorKey: session.authenticatorKey)
        guard generation == self.generation else { throw CancellationError() }
        try update { $0.merge(pulled, latest: changes.latest) }

        for id in self.vault?.items.filter(\.isPending).map(\.id) ?? [] {
            guard generation == self.generation else { throw CancellationError() }
            guard let item = self.vault?.items.first(where: { $0.id == id }), item.isPending, let rawData = item.rawData else { continue }
            if item.entityID == nil && item.isTrashed {
                // Deleted before it was ever uploaded: the pull would have found it if its upload had reached Ente.
                try update { $0.remove(id) }
                continue
            }
            let encrypted = try EnteAuthenticatorSync.encrypt(rawData, authenticatorKey: session.authenticatorKey)
            // Recorded before it is sent, so if the answer is lost the upload is recognized as this device's own when
            // it comes back in the diff, rather than taken for another device's change.
            try update { $0.markUploading(id, rawData: rawData) }
            if let entityID = item.entityID {
                do {
                    try await EnteAuthenticatorSync.signedIn {
                        try await api.updateAuthenticatorEntity(token: session.token, id: entityID, encryptedData: encrypted.encryptedData,
                                                                header: encrypted.header)
                    }
                } catch EnteAPIError.http(statusCode: 404) {
                    // Deleted on another device since the pull. Deleting wins over the change made here.
                    guard generation == self.generation else { throw CancellationError() }
                    try update { $0.remove(id) }
                    continue
                }
                guard generation == self.generation else { throw CancellationError() }
                try update { $0.markUploaded(id, rawData: rawData, created: nil) }
            } else {
                let created = try await EnteAuthenticatorSync.signedIn {
                    try await api.createAuthenticatorEntity(token: session.token, encryptedData: encrypted.encryptedData,
                                                            header: encrypted.header)
                }
                guard generation == self.generation else { throw CancellationError() }
                try update { $0.markUploaded(id, rawData: rawData, created: created) }
            }
        }
    }

    @concurrent private static func decrypt(_ entities: [EnteAuthenticatorEntity], authenticatorKey: Data)
        async -> [(entity: EnteAuthenticatorEntity, rawData: String?)] {
        entities.map { ($0, EnteAuthenticatorSync.decrypt($0, authenticatorKey: authenticatorKey)) }
    }

    /// Changes the vault and saves it. Every change goes through here, and is undone if it can't be saved: a change
    /// that is only in memory would be gone at the next launch, e.g. an account moved here from the device.
    private func update(_ change: (inout EnteVault) -> Void) throws {
        guard var vault else { return }
        let before = vault
        change(&vault)
        guard vault != before else { return }
        try save(vault)
        self.vault = vault
        changed()
    }

    private func changed() {
        onChange?()
        updateAutoFill()
        // The watch shows what is in the vault. It's only sent while the session is unlocked, i.e. it is still valid.
        if session != nil, watch.isEnabled {
            watch.send(codes)
        }
    }

    /// AutoFill uses what is in the vault, also while the session is locked: the codes are calculated on the device.
    private func updateAutoFill() {
        if let vault {
            autoFill?.update { Self.codes(in: vault) }
        } else {
            autoFill?.remove()
        }
    }

    /// Syncs when the network comes back with changes waiting to be uploaded.
    private func startMonitoringNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.hasPendingChanges else { return }
                await self.sync(unlock: false)
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    // MARK: - Changes

    /// Adds an account to the vault and uploads it, unless the vault has one with the same name.
    func add(_ template: YubiKitOATHSession.CredentialTemplate) throws -> AddResult {
        guard vault != nil else { throw EnteAuthenticatorSyncError.signedOut }
        let credentialId = OATHCredentialId.key(accountName: template.name, issuer: template.issuer,
                                                period: UInt(template.type.period ?? 0), isTOTP: template.type.period != nil)
        guard !codes.contains(where: { $0.credentialId == credentialId }) else { return .alreadyPresent }
        return try insert(rawData: String(decoding: try EnteCodeExporter.rawData(for: template), as: UTF8.self))
    }

    /// Adds an account kept on this device and uploads it, with its pin and HOTP counter, unless the vault has one
    /// with the same name.
    func add(rawData: String) throws -> AddResult {
        guard vault != nil else { throw EnteAuthenticatorSyncError.signedOut }
        if let credentialId = EnteCodeParser.parse(id: "", rawData: rawData)?.credentialId,
           codes.contains(where: { $0.credentialId == credentialId }) {
            return .alreadyPresent
        }
        return try insert(rawData: rawData)
    }

    private func insert(rawData: String) throws -> AddResult {
        try update { _ = $0.add(rawData: rawData) }
        syncChanges()
        return .added
    }

    func rename(_ id: String, issuer: String, accountName: String) throws {
        guard let code = code(of: id), (code.issuer ?? "", code.accountName) != (issuer, accountName) else { return }
        try edit(id) { $0.rename(issuer: issuer, accountName: accountName) }
    }

    /// A pin that can't be saved is simply gone at the next launch, so it isn't reported.
    func setPinned(_ id: String, _ isPinned: Bool) {
        guard let code = code(of: id), code.isPinned != isPinned else { return }
        try? edit(id) { $0.isPinned = isPinned }
    }

    /// Files the account under the tags, which Ente Auth shows too.
    func setTags(_ id: String, _ tags: [String]) throws {
        guard let code = code(of: id), code.tags != EnteEntry.cleaned(tags) else { return }
        try edit(id) { $0.tags = tags }
    }

    /// The credential to put the account on a YubiKey with, nil if a YubiKey can't store it.
    func yubiKeyTemplate(of id: String) -> YubiKitOATHSession.CredentialTemplate? {
        vault?.items.first { $0.id == id }?.rawData.flatMap { EnteCodeParser.parse(id: id, rawData: $0)?.template }
    }

    private func code(of id: String) -> EnteCloudCode? {
        vault?.items.first { $0.id == id }?.rawData.flatMap(EnteCloudCode.init(rawData:))
    }

    /// Moves the account to Ente's trash, like deleting it in Ente Auth does. Ente Auth can restore it or delete it
    /// for good.
    func delete(_ id: String) throws {
        try edit(id) { $0.isTrashed = true }
    }

    /// Returns the next HOTP code and moves the counter on, on all devices. Nil if the counter can't be moved on or
    /// saved, as the code would be given out again.
    func nextHOTPCode(_ id: String) -> String? {
        guard let code = code(of: id), code.kind == .hotp else { return nil }
        let (next, overflow) = code.counter.addingReportingOverflow(1)
        guard !overflow else { return nil }
        do {
            try edit(id) { $0.counter = next }
        } catch {
            return nil
        }
        return code.hotpCode()
    }

    private func edit(_ id: String, _ change: (inout EnteEntryEditor) -> Void) throws {
        var didChange = false
        try update { didChange = $0.edit(id, change) }
        if didChange {
            syncChanges()
        }
    }

    private func syncChanges() {
        Task { await sync() }
    }
}
