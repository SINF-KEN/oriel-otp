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

enum EnteLoginError: Error, LocalizedError, Equatable {
    case incorrectPassword
    case incorrectCode
    case codeExpired
    case tooManyAttempts
    case sessionExpired
    case invalidAccountData

    var errorDescription: String? {
        switch self {
        case .incorrectPassword:
            return String(localized: "Incorrect email or password.", comment: "Ente sign in error")
        case .incorrectCode:
            return String(localized: "Incorrect code.", comment: "Ente sign in error")
        case .codeExpired:
            return String(localized: "The code has expired. Request a new one.", comment: "Ente sign in error")
        case .tooManyAttempts:
            return String(localized: "Too many attempts. Try again later.", comment: "Ente sign in error")
        case .sessionExpired:
            return String(localized: "The sign in session has expired. Start over.", comment: "Ente sign in error")
        case .invalidAccountData:
            return String(localized: "The account data from Ente could not be read.", comment: "Ente sign in error")
        }
    }
}

/// The keys of a signed in Ente account. The master key never leaves memory.
nonisolated struct EnteAccountKeys: Sendable {
    let userID: Int64
    let token: String
    let masterKey: Data
}

enum EnteLoginStep: Equatable {
    case emailCode
    case secondFactor(totp: Bool, passkey: Bool)
    case complete
}

/// Signs in to Ente the way Ente's own apps do.
///
/// The email and password are entered together. Accounts with SRP and without email verification sign in with the
/// password alone, which never leaves the device. Other accounts first verify a code sent by email, and the password
/// entered at the start then decrypts their keys. Either way a TOTP or passkey second factor may follow.
final class EnteLoginFlow {

    let api: EnteAPIClient
    let email: String

    private enum State {
        case emailCode
        /// Verified, the keys are being decrypted or the password didn't decrypt them. `submitPassword(_:)` tries another one.
        case password(verified: EnteAuthResponse)
        case secondFactor(response: EnteAuthResponse, keyEncryptionKey: Data?)
        case complete(EnteAccountKeys)
    }

    /// Kept until the keys are decrypted when the email code has to be verified first.
    private var password: String?
    private var state: State
    /// Called with true while the password is turned into keys and the keys are decrypted, and with false after.
    private let onDerivingKeys: (Bool) -> Void

    var keys: EnteAccountKeys? {
        if case .complete(let keys) = state { return keys }
        return nil
    }

    /// Whether the email code and second factor were verified but the password was wrong.
    var needsPassword: Bool {
        if case .password = state { return true }
        return false
    }

    private init(api: EnteAPIClient, email: String, password: String?, state: State, onDerivingKeys: @escaping (Bool) -> Void) {
        self.api = api
        self.email = email
        self.password = password
        self.state = state
        self.onDerivingKeys = onDerivingKeys
    }

    /// `onDerivingKeys` tells when the slow part runs, as opposed to waiting for the server.
    static func start(api: EnteAPIClient, email: String, password: String,
                      onDerivingKeys: @escaping (Bool) -> Void = { _ in }) async throws -> (EnteLoginFlow, EnteLoginStep) {
        let attributes = try await api.srpAttributes(email: email)
        if let attributes, !attributes.isEmailMFAEnabled {
            let (response, keyEncryptionKey) = try await signInWithSRP(api: api, password: password, attributes: attributes, onDerivingKeys: onDerivingKeys)
            // advance(_:keyEncryptionKey:) replaces the state with the next step.
            let flow = EnteLoginFlow(api: api, email: email, password: nil, state: .secondFactor(response: response, keyEncryptionKey: keyEncryptionKey),
                                     onDerivingKeys: onDerivingKeys)
            return (flow, try await flow.advance(response, keyEncryptionKey: keyEncryptionKey))
        }
        try await api.sendEmailCode(email: email)
        return (EnteLoginFlow(api: api, email: email, password: password, state: .emailCode, onDerivingKeys: onDerivingKeys), .emailCode)
    }

    func resendEmailCode() async throws {
        try await api.sendEmailCode(email: email)
    }

    /// Tries another password after the one entered at the start didn't decrypt the keys.
    func submitPassword(_ password: String) async throws -> EnteLoginStep {
        guard case .password(let verified) = state else { throw EnteLoginError.sessionExpired }
        self.password = password
        return try await advance(verified, keyEncryptionKey: nil)
    }

    /// Submits the email code or the TOTP code, depending on the step.
    func submitCode(_ code: String) async throws -> EnteLoginStep {
        let code = code.filter { !$0.isWhitespace }
        switch state {
        case .emailCode:
            let response = try await Self.mapErrors(code: true) { try await api.verifyEmail(email: email, code: code) }
            return try await advance(response, keyEncryptionKey: nil)
        case .secondFactor(let response, let keyEncryptionKey):
            guard let sessionID = response.totpSessionID else { throw EnteLoginError.sessionExpired }
            let verified = try await Self.mapErrors(code: true) { try await api.verifyTOTP(sessionID: sessionID, code: code) }
            return try await advance(verified, keyEncryptionKey: keyEncryptionKey)
        default:
            throw EnteLoginError.sessionExpired
        }
    }

    /// The page on Ente's accounts site that verifies the passkey. Poll `checkPasskey()` afterwards.
    var passkeyURL: URL? {
        guard case .secondFactor(let response, _) = state,
              let sessionID = response.passkeySessionID, !sessionID.isEmpty,
              let accountsURL = response.accountsUrl.flatMap(URL.init(string:)), accountsURL.scheme == "https",
              var components = URLComponents(url: accountsURL.appendingPathComponent("passkeys/verify"), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "clientPackage", value: EnteAPIClient.clientPackage),
                                 URLQueryItem(name: "passkeySessionID", value: sessionID),
                                 URLQueryItem(name: "redirect", value: "orielotp://passkey")]
        return components.url
    }

    /// Returns nil while the passkey hasn't been verified yet.
    func checkPasskey() async throws -> EnteLoginStep? {
        guard case .secondFactor(let response, let keyEncryptionKey) = state,
              let sessionID = response.passkeySessionID else { throw EnteLoginError.sessionExpired }
        let verified = try await Self.mapErrors(code: false) { try await api.passkeyStatus(sessionID: sessionID) }
        guard let verified else { return nil }
        return try await advance(verified, keyEncryptionKey: keyEncryptionKey)
    }

    private func advance(_ response: EnteAuthResponse, keyEncryptionKey: Data?) async throws -> EnteLoginStep {
        if response.secondFactorRequired {
            state = .secondFactor(response: response, keyEncryptionKey: keyEncryptionKey)
            return .secondFactor(totp: response.totpSessionID != nil, passkey: response.passkeyRequired)
        }
        // Verified, so a wrong password can be retried with submitPassword(_:).
        state = .password(verified: response)
        onDerivingKeys(true)
        defer { onDerivingKeys(false) }
        let keyEncryptionKey = if let keyEncryptionKey { keyEncryptionKey } else { try await deriveKeyEncryptionKey(for: response) }
        state = .complete(try await Self.decryptKeys(response, keyEncryptionKey: keyEncryptionKey))
        password = nil
        return .complete
    }

    /// The email code was verified, the password only decrypts the keys.
    private func deriveKeyEncryptionKey(for response: EnteAuthResponse) async throws -> Data {
        guard let password, let attributes = response.keyAttributes,
              let salt = Data(enteBase64: attributes.kekSalt) else { throw EnteLoginError.invalidAccountData }
        return try await Self.deriveKeyEncryptionKey(password: password, salt: salt, opsLimit: attributes.opsLimit, memLimit: attributes.memLimit)
    }

    private static func signInWithSRP(api: EnteAPIClient, password: String, attributes: EnteSRPAttributes,
                                      onDerivingKeys: (Bool) -> Void) async throws -> (EnteAuthResponse, Data) {
        guard let kekSalt = Data(enteBase64: attributes.kekSalt),
              let srpSalt = Data(enteBase64: attributes.srpSalt) else { throw EnteLoginError.invalidAccountData }
        onDerivingKeys(true)
        let keyEncryptionKey: Data
        let client: EnteSRPClient
        do {
            defer { onDerivingKeys(false) }
            keyEncryptionKey = try await deriveKeyEncryptionKey(password: password, salt: kekSalt,
                                                                opsLimit: attributes.opsLimit, memLimit: attributes.memLimit)
            client = try await makeSRPClient(identity: attributes.srpUserID, keyEncryptionKey: keyEncryptionKey, salt: srpSalt)
        }
        let session = try await api.createSRPSession(srpUserID: attributes.srpUserID, srpA: client.publicKey)
        let proofs = try await srpProofs(client, serverPublicKey: session.srpB)
        let response = try await mapErrors(code: false) {
            try await api.verifySRPSession(sessionID: session.sessionID, srpUserID: attributes.srpUserID, srpM1: proofs.clientProof)
        }
        // The server proves it knows the verifier, so a fake server can't hand out keys for the account.
        guard let srpM2 = response.srpM2.flatMap({ Data(enteBase64: $0) }) else { throw EnteSRPError.serverProofMismatch }
        try EnteSRPClient.verify(serverProof: srpM2, expected: proofs.expectedServerProof)
        return (response, keyEncryptionKey)
    }

    private static func mapErrors<T>(code: Bool, _ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch EnteAPIError.http(let statusCode) {
            switch statusCode {
            case 401: throw code ? EnteLoginError.incorrectCode : EnteLoginError.incorrectPassword
            case 404, 410: throw code ? EnteLoginError.codeExpired : EnteLoginError.sessionExpired
            case 429: throw EnteLoginError.tooManyAttempts
            default: throw EnteAPIError.http(statusCode: statusCode)
            }
        }
    }

    // MARK: - Crypto, run off the main actor

    @concurrent nonisolated private static func deriveKeyEncryptionKey(password: String, salt: Data, opsLimit: UInt64, memLimit: UInt64) async throws -> Data {
        try EnteCrypto.deriveKeyEncryptionKey(password: password, salt: salt, opsLimit: opsLimit, memLimit: memLimit)
    }

    @concurrent nonisolated private static func makeSRPClient(identity: String, keyEncryptionKey: Data, salt: Data) async throws -> EnteSRPClient {
        let loginKey = try EnteCrypto.deriveLoginKey(keyEncryptionKey: keyEncryptionKey)
        return EnteSRPClient(identity: identity, password: loginKey, salt: salt)
    }

    @concurrent nonisolated private static func srpProofs(_ client: EnteSRPClient, serverPublicKey: Data) async throws -> (clientProof: Data, expectedServerProof: Data) {
        try client.proofs(serverPublicKey: serverPublicKey)
    }

    /// Decrypts the master key and the auth token with the key encryption key.
    @concurrent nonisolated static func decryptKeys(_ response: EnteAuthResponse, keyEncryptionKey: Data) async throws -> EnteAccountKeys {
        guard let attributes = response.keyAttributes,
              let encryptedKey = Data(enteBase64: attributes.encryptedKey),
              let keyNonce = Data(enteBase64: attributes.keyDecryptionNonce),
              let encryptedSecretKey = Data(enteBase64: attributes.encryptedSecretKey),
              let secretKeyNonce = Data(enteBase64: attributes.secretKeyDecryptionNonce),
              let publicKey = Data(enteBase64: attributes.publicKey) else { throw EnteLoginError.invalidAccountData }

        let masterKey: Data
        do {
            masterKey = try EnteCrypto.secretBoxOpen(encryptedKey, nonce: keyNonce, key: keyEncryptionKey)
        } catch {
            throw EnteLoginError.incorrectPassword
        }
        guard let secretKey = try? EnteCrypto.secretBoxOpen(encryptedSecretKey, nonce: secretKeyNonce, key: masterKey),
              try EnteCrypto.publicKey(forSecretKey: secretKey) == publicKey else { throw EnteLoginError.invalidAccountData }

        let token: String
        if let encryptedToken = response.encryptedToken.flatMap({ Data(enteBase64: $0) }) {
            guard let tokenBytes = try? EnteCrypto.sealedBoxOpen(encryptedToken, publicKey: publicKey, secretKey: secretKey) else {
                throw EnteLoginError.invalidAccountData
            }
            token = tokenBytes.enteURLSafeBase64
        } else if let plainToken = response.token, !plainToken.isEmpty {
            token = plainToken
        } else {
            throw EnteLoginError.invalidAccountData
        }
        return EnteAccountKeys(userID: response.id, token: token, masterKey: masterKey)
    }
}
