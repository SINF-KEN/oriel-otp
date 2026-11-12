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
import YubiKit

@Observable final class EnteSyncViewModel {

    enum Phase: Equatable {
        case signIn
        case savedSession(email: String)
        case emailCode
        case secondFactor(totp: Bool, passkey: Bool)
        case accounts
    }

    static let serverKey = DefaultsKey.enteServer

    var phase: Phase
    var email = ""
    var password = ""
    var code = ""
    /// The server address as typed, only used when signing in to one's own server.
    var server: String {
        didSet { if !server.isEmpty { usesOwnServer = true } }
    }
    /// Whether to sign in to a self-hosted server rather than Ente's.
    var usesOwnServer: Bool
    var staySignedIn: Bool
    var isBusy = false
    /// Whether the password is being turned into keys, the part of signing in that can take a few seconds.
    var isDerivingKeys = false
    var error: Error?
    var codes: [EnteCode] = []
    var selection: Set<String> = []
    var requiresTouch = false
    private(set) var signedInEmail: String?

    /// The ids of the accounts on the YubiKey, so they can be shown as already added.
    let existingCredentialIds: Set<String>
    /// How many accounts the YubiKey can hold, nil if that isn't known, e.g. no YubiKey has been read yet.
    let capacity: Int?

    @ObservationIgnored private(set) var flow: EnteLoginFlow?
    @ObservationIgnored private var api: EnteAPIClient?
    @ObservationIgnored private var token: String?
    /// Whether the session is saved in the keychain, needed to show the accounts on Apple Watch.
    private(set) var isSessionSaved = false
    @ObservationIgnored private let store: EnteSessionStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored let watch: WatchAccountSync
    /// Keeps the accounts of a saved session on the device and syncs them.
    @ObservationIgnored private let cloud: EnteCloud

    init(existingCredentialIds: Set<String>, capacity: Int? = nil, store: EnteSessionStore = EnteSessionStore(), defaults: UserDefaults = .standard,
         session: URLSession = .ente, watch: WatchAccountSync = .shared, cloud: EnteCloud = .shared) {
        self.existingCredentialIds = existingCredentialIds
        self.capacity = capacity
        self.store = store
        self.defaults = defaults
        self.session = session
        self.watch = watch
        self.cloud = cloud
        let savedServer = defaults.string(forKey: Self.serverKey) ?? ""
        self.server = savedServer
        self.usesOwnServer = !savedServer.isEmpty
        // Staying signed in is the default where the device can protect the session, like in Ente's own apps.
        self.staySignedIn = store.canSave
        if let account = store.savedAccount {
            if account.hasSession {
                phase = .savedSession(email: account.email)
            } else {
                // The server rejected the session, so the account only needs the password again.
                email = account.email
                let accountServer = Self.serverField(for: account.server)
                server = accountServer
                // Observers aren't called in init.
                usesOwnServer = !accountServer.isEmpty
                phase = .signIn
            }
        } else {
            phase = .signIn
        }
    }

    var canSaveSession: Bool { store.canSave }

    /// Changes made on this device that haven't been uploaded, which signing out loses.
    var hasPendingChanges: Bool { cloud.hasPendingChanges }

    var passkeyURL: URL? { flow?.passkeyURL }

    var importableCodes: [EnteCode] {
        codes.filter { $0.template != nil && !isOnYubiKey($0) }
    }

    /// How many more accounts fit on the YubiKey, nil if that isn't known.
    var freeSpaces: Int? {
        capacity.map { max(0, $0 - existingCredentialIds.count) }
    }

    /// More accounts are selected than fit on the YubiKey, so the last ones wouldn't be added.
    var isSelectionTooLarge: Bool {
        freeSpaces.map { selection.count > $0 } ?? false
    }

    /// Whether Select all would select more, it stops when the YubiKey would be full.
    var canSelectMore: Bool {
        selection.count < min(importableCodes.count, freeSpaces ?? .max)
    }

    var selectedTemplates: [YubiKitOATHSession.CredentialTemplate] {
        codes.filter { selection.contains($0.id) }.compactMap(\.template)
    }

    func isOnYubiKey(_ code: EnteCode) -> Bool {
        code.credentialId.map(existingCredentialIds.contains) ?? false
    }

    func toggleSelection(_ code: EnteCode) {
        guard code.template != nil else { return }
        if selection.contains(code.id) {
            selection.remove(code.id)
        } else {
            selection.insert(code.id)
        }
    }

    /// Selects the importable accounts in list order, as many as fit on the YubiKey.
    func selectAll() {
        let ids = importableCodes.map(\.id)
        selection = Set(ids.prefix(freeSpaces ?? ids.count))
    }

    func selectNone() {
        selection = []
    }

    // MARK: - Sign in

    /// The server accounts can be created on, nil for Ente's own or a server that isn't filled in yet.
    var signUpServer: URL? {
        EnteSignUpViewModel.server(from: selectedServer)
    }

    /// The server to sign in to as typed, empty for Ente's own.
    var selectedServer: String {
        usesOwnServer ? server.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    var canSignIn: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
            && (!usesOwnServer || !selectedServer.isEmpty)
    }

    /// Signs in with the email and password. After a wrong password following the email code, the codes aren't asked
    /// for again if the email and server are the same.
    func signIn() {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSignIn else { return }
        let password = password
        run {
            // Only the flow keeps the password, while the email code or second factor it's needed for can be retried.
            defer { self.password = "" }
            let server = try EnteAPIClient.serverURL(from: self.selectedServer)
            // Signing in to another account, or without staying signed in, replaces the copy of the accounts on this
            // device, whose changes would be lost.
            if self.cloud.hasPendingChanges,
               !(self.staySignedIn && self.canSaveSession && self.cloud.vault?.belongs(email: email, server: server) == true) {
                throw EnteSyncError.unsyncedChanges
            }
            if let flow = self.flow, flow.needsPassword, flow.email == email, EnteAPIClient.isSameServer(flow.api.server, server) {
                try await self.handle { try await flow.submitPassword(password) }
                return
            }
            let api = try EnteAPIClient(server: server, session: self.session)
            self.flow = nil
            try await self.handle {
                let (flow, step) = try await EnteLoginFlow.start(api: api, email: email, password: password) {
                    self.isDerivingKeys = $0
                }
                self.api = api
                self.flow = flow
                return step
            }
        }
    }

    func submitCode() {
        guard let flow, !code.isEmpty else { return }
        // Ente only takes ASCII digits; a pasted or hardware keyboard code can be in Arabic-Indic digits.
        let code = code.asciiDigits
        run {
            defer { self.code = "" }
            try await self.handle { try await flow.submitCode(code) }
        }
    }

    func resendCode() {
        guard let flow else { return }
        run { try await flow.resendEmailCode() }
    }

    /// Call when the user returns from verifying the passkey in the browser.
    func checkPasskey() {
        guard let flow else { return }
        run {
            try await self.handle {
                guard let step = try await flow.checkPasskey() else { throw EnteSyncError.passkeyNotVerified }
                return step
            }
        }
    }

    func startOver() {
        flow = nil
        password = ""
        code = ""
        phase = .signIn
    }

    /// Runs a step of the sign in. A wrong password goes back to the sign in screen, also after the email code.
    private func handle(_ operation: () async throws -> EnteLoginStep) async throws {
        let step: EnteLoginStep
        do {
            step = try await operation()
        } catch EnteLoginError.incorrectPassword {
            password = ""
            phase = .signIn
            throw EnteLoginError.incorrectPassword
        }
        if case .complete = step, let keys = flow?.keys {
            // Known before anything else is awaited, so close() can end the session.
            token = keys.token
        }
        // The view went away while signing in.
        guard !Task.isCancelled else {
            abandonSignIn()
            throw CancellationError()
        }
        switch step {
        case .emailCode:
            phase = .emailCode
        case .secondFactor(let totp, let passkey):
            phase = .secondFactor(totp: totp, passkey: passkey)
        case .complete:
            guard let flow, let keys = flow.keys, let api else { throw EnteLoginError.invalidAccountData }
            self.flow = nil
            defaults.set(selectedServer.isEmpty ? nil : selectedServer, forKey: Self.serverKey)
            let saveSession = staySignedIn && canSaveSession
            // Only the authenticator key is kept, the master key goes away with the flow. An account that has never
            // used Ente Auth gets its key now, while the master key is there, so it stays signed in too.
            let authenticatorKey: Data?
            do {
                authenticatorKey = saveSession
                    ? try await EnteAuthenticatorSync.authenticatorKeyCreatingIfNeeded(api: api, keys: keys)
                    : try await EnteAuthenticatorSync.authenticatorKey(api: api, keys: keys)
                try Task.checkCancellation()
            } catch _ where Task.isCancelled {
                abandonSignIn()
                throw CancellationError()
            }
            // Checked when signing in started, but the email code or the passkey can take minutes, and an account
            // added meanwhile would be lost with the copy of the accounts that is replaced below.
            if cloud.hasPendingChanges, !(saveSession && cloud.vault?.belongs(email: flow.email, server: api.server) == true) {
                abandonSignIn()
                phase = .signIn
                throw EnteSyncError.unsyncedChanges
            }
            signedInEmail = flow.email
            if saveSession, let authenticatorKey {
                let saved = EnteSavedSession(server: api.server, email: flow.email, token: keys.token, authenticatorKey: authenticatorKey)
                try store.save(saved)
                isSessionSaved = true
                cloud.use(saved)
            } else {
                // An account kept from an earlier session isn't signed in any more.
                store.remove()
                cloud.remove()
            }
            try await loadCodes(api: api, token: keys.token, authenticatorKey: authenticatorKey)
        }
    }

    // MARK: - Saved session

    func useSavedSession() {
        loadSavedSession()
    }

    /// Turns showing the accounts on Apple Watch on or off. Turning it on sends the accounts right away, reading
    /// them with the saved session first if they haven't been loaded.
    func setShowsAccountsOnWatch(_ isOn: Bool) {
        guard isOn else {
            watch.disable()
            return
        }
        watch.enable()
        if phase == .accounts {
            watch.send(codes)
        } else {
            loadSavedSession(onFailure: { self.watch.disable() })
        }
    }

    private func loadSavedSession(onFailure: @escaping () -> Void = {}) {
        run {
            do {
                try await self.loadSavedCodes()
            } catch {
                onFailure()
                throw error
            }
        }
    }

    private func loadSavedCodes() async throws {
        do {
            let saved = try await store.unlock()
            let api = try EnteAPIClient(server: saved.server, session: session)
            self.api = api
            token = saved.token
            signedInEmail = saved.email
            isSessionSaved = true
            cloud.use(saved)
            try await loadCodes(api: api, token: saved.token, authenticatorKey: saved.authenticatorKey)
        } catch EnteAuthenticatorSyncError.signedOut {
            // The session was revoked, e.g. from another device, or Face ID or Touch ID changed. The account is kept
            // and the password asked for again.
            store.forgetSession()
            watch.disable()
            token = nil
            isSessionSaved = false
            signedInEmail = nil
            phase = .signIn
            if let account = store.savedAccount {
                email = account.email
                server = Self.serverField(for: account.server)
            }
            throw EnteAuthenticatorSyncError.signedOut
        }
    }

    func reload() {
        guard isSessionSaved else { return }
        useSavedSession()
    }

    /// Ends the session on Ente's server and forgets the account on this device.
    func signOut() {
        if token == nil {
            // The saved session hasn't been unlocked, the store unlocks it to end it on the server. Signing in again
            // waits for the unlock, so the account it saves isn't deleted with this one.
            let store = store
            let watch = watch
            let cloud = cloud
            isBusy = true
            Task {
                await store.signOut(watch: watch, cloud: cloud, session: session)
                isBusy = false
            }
        } else {
            revokeSession()
            store.remove()
            cloud.remove()
            watch.disable()
        }
        isSessionSaved = false
        codes = []
        selection = []
        signedInEmail = nil
        startOver()
    }

    /// Call when the view goes away. The sign in is abandoned so the password doesn't stay in memory, and a session
    /// that wasn't saved is ended so no token is left behind.
    func close() {
        task?.cancel()
        abandonSignIn()
    }

    private func abandonSignIn() {
        flow = nil
        password = ""
        code = ""
        guard !isSessionSaved else { return }
        revokeSession()
    }

    private func revokeSession() {
        guard let api, let token else { return }
        self.token = nil
        Task { try? await api.logout(token: token) }
    }

    /// Reads the accounts. With a saved session they come from the vault, after syncing it.
    private func loadCodes(api: EnteAPIClient, token: String, authenticatorKey: Data?) async throws {
        if isSessionSaved {
            try await cloud.syncNow()
            codes = cloud.codes
        } else if let authenticatorKey {
            codes = try await EnteAuthenticatorSync.codes(api: api, token: token, authenticatorKey: authenticatorKey)
        } else {
            codes = []
        }
        selectAll()
        phase = .accounts
        if isSessionSaved {
            watch.send(codes)
        }
    }

    /// The server as typed on the sign in screen, empty for Ente's own server.
    private static func serverField(for server: URL) -> String {
        EnteAPIClient.isSameServer(server, EnteAPIClient.defaultServer) ? "" : server.absoluteString
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        task = Task {
            defer { isBusy = false }
            do {
                try await operation()
            } catch {
                // Cancelled by close(), the view is gone.
                guard !Task.isCancelled else { return }
                self.error = EnteSyncError(error)
            }
        }
    }
}

/// Errors shown in the Ente sync view, with messages for the errors from the layers below.
enum EnteSyncError: Error, LocalizedError {
    case passkeyNotVerified
    /// Signing in would replace a vault with changes that haven't been uploaded.
    case unsyncedChanges
    case wrapped(Error)

    init(_ error: Error) {
        if let error = error as? EnteSyncError {
            self = error
        } else {
            self = .wrapped(error)
        }
    }

    var errorDescription: String? {
        switch self {
        case .passkeyNotVerified:
            return String(localized: "The passkey hasn't been verified yet. Verify it in the browser, then try again.", comment: "Ente sign in error")
        case .unsyncedChanges:
            return String(localized: "Some changes made on this device haven't been synced with Ente Auth yet. Sign in to the same account with Stay signed in on to sync them, or sign out in Settings to discard them.", comment: "Ente sign in error when signing in would replace changes that weren't uploaded")
        case .wrapped(let error):
            switch error {
            case let error as EnteLoginError:
                return error.errorDescription
            case let error as EnteAuthenticatorSyncError:
                return error.errorDescription
            case EnteAPIError.invalidServerURL:
                return String(localized: "Enter a server URL that starts with https://.", comment: "Ente sign in error")
            case EnteAPIError.http(statusCode: 429):
                return EnteLoginError.tooManyAttempts.errorDescription
            case is EnteAPIError, is DecodingError:
                return String(localized: "Ente's server sent an unexpected response.", comment: "Ente sign in error")
            case is EnteSRPError:
                return String(localized: "The server could not prove it knows your password. Check the server address.", comment: "Ente sign in error")
            case is EnteCryptoError:
                return String(localized: "Your keys could not be derived. The device may be low on memory.", comment: "Ente sign in error")
            case let error as URLError:
                return error.localizedDescription
            default:
                return error.localizedDescription
            }
        }
    }
}
