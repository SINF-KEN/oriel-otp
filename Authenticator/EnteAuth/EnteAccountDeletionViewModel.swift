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

enum EnteAccountDeletionError: Error, LocalizedError, Equatable {
    case notAllowedOnEnte
    case refusedByServer

    var errorDescription: String? {
        switch self {
        case .notAllowedOnEnte:
            return String(localized: "Accounts on Ente's servers are deleted from Ente's apps or website.", comment: "Ente account deletion error")
        case .refusedByServer:
            return String(localized: "The server didn't allow deleting this account. Ask the person who runs it to delete it.", comment: "Ente account deletion error")
        }
    }
}

/// Deletes an account on a self-hosted server, the way Ente's own apps do: the password, and any email code or second
/// factor, open the account's keys, whose secret key opens the challenge the server sends. The server then deletes the
/// account and everything in it. A saved session for the account is forgotten on this device too.
@Observable final class EnteAccountDeletionViewModel {

    enum Phase: Equatable {
        case password
        case emailCode
        case secondFactor(totp: Bool, passkey: Bool)
        case deleted
    }

    var phase: Phase = .password
    var email: String
    var password = ""
    var code = ""
    var isBusy = false
    /// Whether the password is being turned into keys, which can take a few seconds.
    var isDerivingKeys = false
    var error: Error?

    let server: URL

    @ObservationIgnored private var flow: EnteLoginFlow?
    /// The token of the sign in made to delete the account, ended if the account isn't deleted.
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let store: EnteSessionStore
    @ObservationIgnored private let cloud: EnteCloud
    @ObservationIgnored private let watch: WatchAccountSync

    init(server: URL, email: String = "", session: URLSession = .ente, store: EnteSessionStore = EnteSessionStore(),
         cloud: EnteCloud = .shared, watch: WatchAccountSync = .shared) {
        self.server = server
        self.email = email
        self.session = session
        self.store = store
        self.cloud = cloud
        self.watch = watch
    }

    var passkeyURL: URL? { flow?.passkeyURL }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canDelete: Bool { !trimmedEmail.isEmpty && !password.isEmpty }

    /// Signs in with the email and password, then deletes the account once any email code or second factor is verified.
    func delete() {
        guard canDelete else { return }
        let email = trimmedEmail
        let password = password
        run {
            defer { self.password = "" }
            guard EnteAPIClient.allowsAccountCreation(on: self.server) else { throw EnteAccountDeletionError.notAllowedOnEnte }
            if let flow = self.flow, flow.needsPassword, flow.email == email {
                try await self.handle { try await flow.submitPassword(password) }
                return
            }
            let api = try EnteAPIClient(server: self.server, session: self.session)
            self.flow = nil
            try await self.handle {
                let (flow, step) = try await EnteLoginFlow.start(api: api, email: email, password: password) {
                    self.isDerivingKeys = $0
                }
                self.flow = flow
                self.email = email
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
        phase = .password
    }

    /// Call when the view goes away. Nothing typed stays in memory, and a sign in that didn't delete the account is ended.
    func close() {
        task?.cancel()
        flow = nil
        password = ""
        code = ""
        endSession()
    }

    private func handle(_ operation: () async throws -> EnteLoginStep) async throws {
        let step: EnteLoginStep
        do {
            step = try await operation()
        } catch EnteLoginError.incorrectPassword {
            phase = .password
            throw EnteLoginError.incorrectPassword
        }
        if case .complete = step, let keys = flow?.keys {
            // Known before anything else is awaited, so close() can end the session.
            token = keys.token
        }
        guard !Task.isCancelled else {
            close()
            throw CancellationError()
        }
        switch step {
        case .emailCode:
            phase = .emailCode
        case .secondFactor(let totp, let passkey):
            phase = .secondFactor(totp: totp, passkey: passkey)
        case .complete:
            guard let flow, let keys = flow.keys else { throw EnteLoginError.invalidAccountData }
            self.flow = nil
            do {
                try await Self.deleteAccount(api: flow.api, keys: keys)
            } catch {
                // Nothing was deleted. Trying again starts from the password, with a new sign in.
                endSession()
                startOver()
                throw error
            }
            token = nil
            forgetSavedAccount(email: flow.email)
            phase = .deleted
        }
    }

    /// Opens the server's challenge with the account's secret key and sends it back, which deletes the account.
    static func deleteAccount(api: EnteAPIClient, keys: EnteAccountKeys) async throws {
        guard let publicKey = keys.publicKey, let secretKey = keys.secretKey else { throw EnteLoginError.invalidAccountData }
        let (allowDelete, encryptedChallenge) = try await api.deleteChallenge(token: keys.token)
        guard allowDelete else { throw EnteAccountDeletionError.refusedByServer }
        guard let encryptedChallenge,
              let opened = try? EnteCrypto.sealedBoxOpen(encryptedChallenge, publicKey: publicKey, secretKey: secretKey),
              let challenge = String(data: opened, encoding: .utf8), isChallenge(challenge) else { throw EnteAPIError.invalidResponse }
        try await api.deleteAccount(token: keys.token, challenge: challenge)
    }

    /// Whether opened text looks like a challenge: a token in base64 or JWT characters. The server gets back what the
    /// secret key opens, so anything else sealed to the account's public key isn't sent back opened.
    static func isChallenge(_ text: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=-_.".unicodeScalars)
        return (16...4096).contains(text.unicodeScalars.count) && text.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// The account no longer exists, so a session saved for it, its accounts on this device and on the watch go too.
    private func forgetSavedAccount(email: String) {
        guard let saved = store.savedAccount, EnteAPIClient.isSameServer(saved.server, server),
              saved.email.caseInsensitiveCompare(email) == .orderedSame else { return }
        store.remove()
        cloud.remove()
        watch.disable()
    }

    private func endSession() {
        guard let token, let api = try? EnteAPIClient(server: server, session: session) else { return }
        self.token = nil
        Task { try? await api.logout(token: token) }
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
