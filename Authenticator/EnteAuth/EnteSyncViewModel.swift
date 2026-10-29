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

    private static let serverKey = "EnteAuth.ServerURL"

    var phase: Phase
    var email = ""
    var password = ""
    var code = ""
    var server: String
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

    init(existingCredentialIds: Set<String>, capacity: Int? = nil, store: EnteSessionStore = EnteSessionStore(), defaults: UserDefaults = .standard,
         session: URLSession = .shared, watch: WatchAccountSync = .shared) {
        self.existingCredentialIds = existingCredentialIds
        self.capacity = capacity
        self.store = store
        self.defaults = defaults
        self.session = session
        self.watch = watch
        self.server = defaults.string(forKey: Self.serverKey) ?? ""
        // Staying signed in is the default where the device can protect the session, like in Ente's own apps.
        self.staySignedIn = store.canSave
        if let account = store.savedAccount {
            if account.hasSession {
                phase = .savedSession(email: account.email)
            } else {
                // The server rejected the session, so the account only needs the password again.
                email = account.email
                server = Self.serverField(for: account.server)
                phase = .signIn
            }
        } else {
            phase = .signIn
        }
    }

    var canSaveSession: Bool { store.canSave }

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

    var canSignIn: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
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
            let server = try self.serverURL()
            if let flow = self.flow, flow.needsPassword, flow.email == email, flow.api.server == server {
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
        let code = code
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
            defaults.set(server.isEmpty ? nil : server, forKey: Self.serverKey)
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
            signedInEmail = flow.email
            if saveSession, let authenticatorKey {
                try store.save(EnteSavedSession(server: api.server, email: flow.email, token: keys.token, authenticatorKey: authenticatorKey))
                isSessionSaved = true
            } else {
                // An account kept from an earlier session isn't signed in any more.
                store.remove()
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
            isBusy = true
            Task {
                await store.signOut(watch: watch)
                isBusy = false
            }
        } else {
            revokeSession()
            store.remove()
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

    private func loadCodes(api: EnteAPIClient, token: String, authenticatorKey: Data?) async throws {
        if let authenticatorKey {
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
        server == EnteAPIClient.defaultServer ? "" : server.absoluteString
    }

    private func serverURL() throws -> URL {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { return EnteAPIClient.defaultServer }
        guard let url = URL(string: server) else { throw EnteAPIError.invalidServerURL }
        return url
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
