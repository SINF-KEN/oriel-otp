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

    static let shared = EnteCloud()

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
    @ObservationIgnored private var session: EnteSavedSession?
    @ObservationIgnored private var didAskToUnlock = false
    @ObservationIgnored private var unlockTask: Task<EnteSavedSession?, Never>?
    @ObservationIgnored private var runningSync: Task<Void, Error>?
    @ObservationIgnored private var queuedSync: Task<Void, Error>?
    /// Changes when the vault is replaced, so a sync that was under way when it was doesn't write into the new one.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    init(store: EnteSessionStore = EnteSessionStore(), storage: EnteVaultStorage = EnteVaultFile(), session: URLSession = .shared,
         watch: WatchAccountSync = .shared) {
        self.store = store
        self.storage = storage
        self.urlSession = session
        self.watch = watch
        let saved = store.savedAccount
        let vault = try? storage.load()
        if let saved {
            if let vault, vault.email.lowercased() == saved.email.lowercased(), vault.server == saved.server {
                self.vault = vault
            } else {
                // The first sync fills it. Also when the file couldn't be read, e.g. because the device was restored.
                self.vault = EnteVault(email: saved.email, server: saved.server)
            }
        } else if vault != nil {
            // Signed out while the vault was kept by an earlier version.
            storage.remove()
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
    var codes: [EnteCode] {
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
        self.session = session
        didAskToUnlock = true
        if vault?.belongs(to: session) != true {
            replaceVault(with: EnteVault(email: session.email, server: session.server))
        }
        startMonitoringNetwork()
    }

    /// Deletes the vault, for when the Ente account is signed out or not kept.
    func remove() {
        session = nil
        guard vault != nil else { return }
        replaceVault(with: nil)
    }

    private func replaceVault(with vault: EnteVault?) {
        generation += 1
        self.vault = vault
        if let vault {
            try? storage.save(vault)
        } else {
            storage.remove()
        }
        changed()
    }

    /// The session in memory, or the saved one after Face ID or Touch ID if `unlock` is set. Nil if it can't be had.
    private func unlockedSession(unlock: Bool) async -> EnteSavedSession? {
        if let session { return session }
        guard unlock else { return nil }
        if let unlockTask { return await unlockTask.value }
        didAskToUnlock = true
        let task = Task { () -> EnteSavedSession? in
            do {
                return try await store.unlock()
            } catch EnteAuthenticatorSyncError.signedOut {
                sessionRejected()
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
    /// its changes are uploaded once the password has been entered again.
    private func sessionRejected(showsError: Bool = true) {
        session = nil
        store.forgetSession()
        watch.disable()
        if showsError {
            error = EnteSyncError(EnteAuthenticatorSyncError.signedOut)
        }
    }

    // MARK: - Sync

    /// Syncs if the session is unlocked, or after asking to unlock it the first time since the app started. For when
    /// the app comes to the foreground. Errors aren't shown, except for a rejected session.
    func syncAutomatically() async {
        await sync(unlock: !didAskToUnlock)
    }

    /// Syncs, asking to unlock the session if needed. Errors are shown if `reportsErrors` is set, e.g. when the user
    /// pulled down the list; changes made offline just wait for the next sync.
    func sync(unlock: Bool = true, reportsErrors: Bool = false) async {
        guard vault != nil, let session = await unlockedSession(unlock: unlock) else { return }
        do {
            try await enqueueSync(session).value
        } catch EnteAuthenticatorSyncError.signedOut {
            sessionRejected()
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
            sessionRejected(showsError: false)
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
        update { $0.merge(pulled, latest: changes.latest) }

        for id in self.vault?.items.filter(\.isPending).map(\.id) ?? [] {
            guard generation == self.generation else { throw CancellationError() }
            guard let item = self.vault?.items.first(where: { $0.id == id }), item.isPending, let rawData = item.rawData else { continue }
            if item.entityID == nil && item.isTrashed {
                // Deleted before it was ever uploaded.
                update { $0.remove(id) }
                continue
            }
            let encrypted = try EnteAuthenticatorSync.encrypt(rawData, authenticatorKey: session.authenticatorKey)
            if let entityID = item.entityID {
                do {
                    try await EnteAuthenticatorSync.signedIn {
                        try await api.updateAuthenticatorEntity(token: session.token, id: entityID, encryptedData: encrypted.encryptedData,
                                                                header: encrypted.header)
                    }
                } catch EnteAPIError.http(statusCode: 404) {
                    // Deleted on another device since the pull. Deleting wins over the change made here.
                    guard generation == self.generation else { throw CancellationError() }
                    update { $0.remove(id) }
                    continue
                }
                guard generation == self.generation else { throw CancellationError() }
                update { $0.markUploaded(id, rawData: rawData, created: nil) }
            } else {
                let created = try await EnteAuthenticatorSync.signedIn {
                    try await api.createAuthenticatorEntity(token: session.token, encryptedData: encrypted.encryptedData,
                                                            header: encrypted.header)
                }
                guard generation == self.generation else { throw CancellationError() }
                update { $0.markUploaded(id, rawData: rawData, created: created) }
            }
        }
    }

    @concurrent private static func decrypt(_ entities: [EnteAuthenticatorEntity], authenticatorKey: Data)
        async -> [(entity: EnteAuthenticatorEntity, rawData: String?)] {
        entities.map { ($0, EnteAuthenticatorSync.decrypt($0, authenticatorKey: authenticatorKey)) }
    }

    /// Changes the vault and saves it. Every change goes through here.
    private func update(_ change: (inout EnteVault) -> Void) {
        guard var vault else { return }
        let before = vault
        change(&vault)
        guard vault != before else { return }
        self.vault = vault
        try? storage.save(vault)
        changed()
    }

    private func changed() {
        onChange?()
        // The watch shows what is in the vault. It's only sent while the session is unlocked, i.e. it is still valid.
        if session != nil {
            watch.send(codes)
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
        let rawData = String(decoding: try EnteCodeExporter.rawData(for: template), as: UTF8.self)
        update { _ = $0.add(rawData: rawData) }
        syncChanges()
        return .added
    }

    func rename(_ id: String, issuer: String, accountName: String) {
        edit(id) { $0.rename(issuer: issuer, accountName: accountName) }
    }

    func setPinned(_ id: String, _ isPinned: Bool) {
        edit(id) { $0.isPinned = isPinned }
    }

    /// Moves the account to Ente's trash, like deleting it in Ente Auth does. Ente Auth can restore it or delete it
    /// for good.
    func delete(_ id: String) {
        edit(id) { $0.isTrashed = true }
    }

    /// Returns the next HOTP code and moves the counter on, on all devices.
    func nextHOTPCode(_ id: String) -> String? {
        guard let rawData = vault?.items.first(where: { $0.id == id })?.rawData, let code = EnteCloudCode(rawData: rawData),
              code.kind == .hotp else { return nil }
        edit(id) { $0.counter = code.counter + 1 }
        return code.hotpCode()
    }

    private func edit(_ id: String, _ change: (inout EnteEntryEditor) -> Void) {
        var didChange = false
        update { didChange = $0.edit(id, change) }
        if didChange {
            syncChanges()
        }
    }

    private func syncChanges() {
        Task { await sync() }
    }
}
