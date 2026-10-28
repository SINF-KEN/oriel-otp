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
        case password
        case secondFactor(totp: Bool, passkey: Bool)
        case accounts
    }

    private static let serverKey = "EnteAuth.ServerURL"

    var phase: Phase
    var email = ""
    var password = ""
    var code = ""
    var server: String
    var staySignedIn = false
    var isBusy = false
    var error: Error?
    var codes: [EnteCode] = []
    var selection: Set<String> = []
    var requiresTouch = false
    private(set) var signedInEmail: String?

    /// The ids of the accounts on the YubiKey, so they can be shown as already added.
    let existingCredentialIds: Set<String>

    @ObservationIgnored private var flow: EnteLoginFlow?
    @ObservationIgnored private var api: EnteAPIClient?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var isSessionSaved = false
    @ObservationIgnored private let store: EnteSessionStore
    @ObservationIgnored private let defaults: UserDefaults

    init(existingCredentialIds: Set<String>, store: EnteSessionStore = EnteSessionStore(), defaults: UserDefaults = .standard) {
        self.existingCredentialIds = existingCredentialIds
        self.store = store
        self.defaults = defaults
        self.server = defaults.string(forKey: Self.serverKey) ?? ""
        if let email = store.savedEmail {
            phase = .savedSession(email: email)
        } else {
            phase = .signIn
        }
    }

    var canSaveSession: Bool { EnteSessionStore.canSave }

    var passkeyURL: URL? { flow?.passkeyURL }

    var importableCodes: [EnteCode] {
        codes.filter { $0.template != nil && !isOnYubiKey($0) }
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

    func selectAll() {
        selection = Set(importableCodes.map(\.id))
    }

    func selectNone() {
        selection = []
    }

    // MARK: - Sign in

    func signIn() {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return }
        run {
            let api = try EnteAPIClient(server: try self.serverURL())
            let (flow, step) = try await EnteLoginFlow.start(api: api, email: email)
            self.api = api
            self.flow = flow
            try await self.handle(step)
        }
    }

    func submitPassword() {
        guard let flow, !password.isEmpty else { return }
        let password = password
        run {
            defer { self.password = "" }
            try await self.handle(try await flow.submitPassword(password))
        }
    }

    func submitCode() {
        guard let flow, !code.isEmpty else { return }
        let code = code
        run {
            defer { self.code = "" }
            try await self.handle(try await flow.submitCode(code))
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
            if let step = try await flow.checkPasskey() {
                try await self.handle(step)
            } else {
                throw EnteSyncError.passkeyNotVerified
            }
        }
    }

    func startOver() {
        flow = nil
        password = ""
        code = ""
        phase = .signIn
    }

    private func handle(_ step: EnteLoginStep) async throws {
        switch step {
        case .password:
            phase = .password
        case .emailCode:
            phase = .emailCode
        case .secondFactor(let totp, let passkey):
            phase = .secondFactor(totp: totp, passkey: passkey)
        case .complete:
            guard let flow, let keys = flow.keys, let api else { throw EnteLoginError.invalidAccountData }
            self.flow = nil
            defaults.set(server.isEmpty ? nil : server, forKey: Self.serverKey)
            // Only the authenticator key is kept, the master key goes away with the flow.
            let authenticatorKey = try await EnteAuthenticatorSync.authenticatorKey(api: api, keys: keys)
            token = keys.token
            signedInEmail = flow.email
            if staySignedIn, canSaveSession, let authenticatorKey {
                try store.save(EnteSavedSession(server: api.server, email: flow.email, token: keys.token, authenticatorKey: authenticatorKey))
                isSessionSaved = true
            }
            try await loadCodes(api: api, token: keys.token, authenticatorKey: authenticatorKey)
        }
    }

    // MARK: - Saved session

    func useSavedSession() {
        run {
            let saved = try await self.store.load()
            let api = try EnteAPIClient(server: saved.server)
            self.api = api
            self.token = saved.token
            self.signedInEmail = saved.email
            self.isSessionSaved = true
            do {
                try await self.loadCodes(api: api, token: saved.token, authenticatorKey: saved.authenticatorKey)
            } catch EnteAuthenticatorSyncError.signedOut {
                // The session was revoked, e.g. from another device.
                self.store.remove()
                self.isSessionSaved = false
                self.email = saved.email
                self.phase = .signIn
                throw EnteAuthenticatorSyncError.signedOut
            }
        }
    }

    func reload() {
        guard isSessionSaved else { return }
        useSavedSession()
    }

    /// Ends the session on Ente's server and forgets it on this device.
    func signOut() {
        revokeSession()
        store.remove()
        isSessionSaved = false
        codes = []
        selection = []
        signedInEmail = nil
        startOver()
    }

    /// Call when the view goes away. A session that wasn't saved is ended so no token is left behind.
    func close() {
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
        Task {
            defer { isBusy = false }
            do {
                try await operation()
            } catch {
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
