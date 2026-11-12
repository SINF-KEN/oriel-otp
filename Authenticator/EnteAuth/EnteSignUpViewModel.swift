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

/// Creates an account on a self-hosted server: details, the code sent by email, then the recovery key. The account is
/// only finished after the recovery key has been saved, so there's never an account without one.
@Observable final class EnteSignUpViewModel {

    enum Phase: Equatable {
        case details
        case emailCode
        case recoveryKey
        case finished
    }

    /// The server for what's typed in a server field, if accounts can be created on it.
    static func server(from text: String) -> URL? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let url = try? EnteAPIClient.serverURL(from: text),
            url.scheme == "https", EnteAPIClient.allowsAccountCreation(on: url)
        else { return nil }
        return url
    }

    var phase: Phase = .details
    var email: String
    var password = ""
    var confirmation = ""
    var code = ""
    var hasSavedRecoveryKey = false
    var isBusy = false
    /// Whether the password is being turned into keys, which can take a few seconds.
    var isDerivingKeys = false
    var error: Error?

    let server: URL

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var keys: EnteNewAccountKeys?
    /// The server has the keys, so trying again only sets up SRP.
    @ObservationIgnored private var didSaveKeys = false

    init(server: URL, email: String = "", session: URLSession = .ente) {
        self.server = server
        self.email = email
        self.session = session
    }

    var recoveryKey: String? { phase == .recoveryKey ? keys?.recoveryKey : nil }

    var canSendCode: Bool {
        !trimmedEmail.isEmpty && !password.isEmpty && !confirmation.isEmpty
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    func sendCode() {
        guard canSendCode else { return }
        let email = trimmedEmail
        run {
            guard self.password.count >= EnteSignUp.minimumPasswordLength else { throw EnteSignUpError.passwordTooShort }
            guard self.password == self.confirmation else { throw EnteSignUpError.passwordsDiffer }
            let api = try EnteAPIClient(server: self.server, session: self.session)
            do {
                try await api.sendSignUpCode(email: email)
            } catch EnteAPIError.http(statusCode: 403) {
                throw EnteSignUpError.registrationDisabled
            } catch EnteAPIError.http(statusCode: 409) {
                throw EnteSignUpError.accountExists
            }
            self.email = email
            self.phase = .emailCode
        }
    }

    func resendCode() {
        run {
            let api = try EnteAPIClient(server: self.server, session: self.session)
            try await api.sendSignUpCode(email: self.email)
        }
    }

    /// Verifies the email, which gives a token for the new account, and makes the keys.
    func submitCode() {
        guard !code.isEmpty else { return }
        // Ente only takes ASCII digits; a pasted or hardware keyboard code can be in Arabic-Indic digits.
        let code = code.asciiDigits.filter { !$0.isWhitespace }
        let password = password
        run {
            defer { self.code = "" }
            let api = try EnteAPIClient(server: self.server, session: self.session)
            let response: EnteAuthResponse
            do {
                response = try await api.verifyEmail(email: self.email, code: code)
            } catch EnteAPIError.http(let statusCode) {
                switch statusCode {
                case 401: throw EnteLoginError.incorrectCode
                case 404, 410: throw EnteLoginError.codeExpired
                case 429: throw EnteLoginError.tooManyAttempts
                default: throw EnteAPIError.http(statusCode: statusCode)
                }
            }
            // An existing account gets its keys or a second factor instead of a plain token.
            guard response.keyAttributes == nil, response.encryptedToken == nil, !response.secondFactorRequired,
                let token = response.token, !token.isEmpty
            else { throw EnteSignUpError.accountExists }
            self.token = token
            self.isDerivingKeys = true
            defer { self.isDerivingKeys = false }
            let keys = try await EnteSignUp.generateKeys(password: password)
            // The view went away while the keys were made.
            guard !Task.isCancelled else {
                self.close()
                throw CancellationError()
            }
            self.keys = keys
            self.password = ""
            self.confirmation = ""
            self.phase = .recoveryKey
        }
    }

    /// Sends the keys to the server and sets up SRP, then checks the account can be signed in to with SRP.
    func finish() {
        guard hasSavedRecoveryKey, let keys, let token else { return }
        run {
            let api = try EnteAPIClient(server: self.server, session: self.session)
            if !self.didSaveKeys {
                try await api.setKeyAttributes(keys.attributes, token: token)
                self.didSaveKeys = true
            }
            do {
                try await EnteSignUp.setUpSRP(keys, api: api, token: token)
            } catch is EnteSignUp.SRPAlreadySetUp {
                // Set up by an attempt whose answer was lost, so the server's proof was never checked. Signing in
                // with SRP checks it. An error from the request that brings the proof isn't taken for this.
                try await EnteSignUp.verifySRPSignIn(keys, api: api)
            }
            guard let attributes = try await api.srpAttributes(email: self.email), attributes.srpUserID == keys.srpUserID,
                attributes.kekSalt == keys.attributes.kekSalt
            else { throw EnteSignUpError.notVerified }
            self.endSession()
            self.keys = nil
            self.phase = .finished
        }
    }

    /// Call when the view goes away. Nothing that was typed or made stays in memory, and the token is ended.
    func close() {
        task?.cancel()
        password = ""
        confirmation = ""
        code = ""
        keys = nil
        endSession()
    }

    /// The account is signed in to from the sign in screen, which proves the password and the keys work.
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
