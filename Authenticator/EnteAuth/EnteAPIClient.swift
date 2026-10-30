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

enum EnteAPIError: Error, Equatable {
    case invalidServerURL
    case invalidResponse
    case http(statusCode: Int)
}

// MARK: - Wire models, named after the JSON of Ente's server (server/ente/*.go).

nonisolated struct EnteSRPAttributes: Decodable, Sendable, Equatable {
    let srpUserID: String
    let srpSalt: String
    let memLimit: UInt64
    let opsLimit: UInt64
    let kekSalt: String
    let isEmailMFAEnabled: Bool
}

nonisolated struct EnteKeyAttributes: Decodable, Sendable, Equatable {
    let kekSalt: String
    let encryptedKey: String
    let keyDecryptionNonce: String
    let publicKey: String
    let encryptedSecretKey: String
    let secretKeyDecryptionNonce: String
    let memLimit: UInt64
    let opsLimit: UInt64
}

/// What the server returns after an SRP, email code, TOTP or passkey verification.
nonisolated struct EnteAuthResponse: Decodable, Sendable, Equatable {
    let id: Int64
    var keyAttributes: EnteKeyAttributes?
    var encryptedToken: String?
    var token: String?
    var twoFactorSessionID: String?
    var twoFactorSessionIDV2: String?
    var passkeySessionID: String?
    var srpM2: String?
    var accountsUrl: String?

    var totpSessionID: String? {
        [twoFactorSessionID, twoFactorSessionIDV2].compactMap { $0 }.first { !$0.isEmpty }
    }

    var passkeyRequired: Bool {
        passkeySessionID?.isEmpty == false
    }

    var secondFactorRequired: Bool {
        totpSessionID != nil || passkeyRequired
    }
}

nonisolated struct EnteAuthenticatorKey: Decodable, Sendable {
    let encryptedKey: String
    let header: String
}

nonisolated struct EnteAuthenticatorEntity: Decodable, Sendable, Equatable {
    let id: String
    let encryptedData: String?
    let header: String?
    let isDeleted: Bool
    let updatedAt: Int64
}

// MARK: - Client

/// The few endpoints of Ente's API needed to sign in and to read, add, change and delete authenticator codes.
nonisolated struct EnteAPIClient: Sendable {

    static let defaultServer = URL(string: "https://api.ente.io")!

    /// Ente's server tells its apps apart by this header and only lets tokens issued for "io.ente.auth*" use the
    /// authenticator endpoints. Ente's own CLI sends the same value.
    static let clientPackage = "io.ente.auth"

    let server: URL
    let session: URLSession

    init(server: URL = defaultServer, session: URLSession = .shared) throws {
        // Credentials and tokens must never travel unencrypted.
        guard server.scheme == "https", server.host?.isEmpty == false else { throw EnteAPIError.invalidServerURL }
        self.server = server
        self.session = session
    }

    func srpAttributes(email: String) async throws -> EnteSRPAttributes? {
        struct Response: Decodable { let attributes: EnteSRPAttributes }
        do {
            let response: Response = try await send("GET", "/users/srp/attributes", query: ["email": email])
            return response.attributes
        } catch EnteAPIError.http(statusCode: 404) {
            // Accounts that haven't set up SRP sign in with an email code.
            return nil
        }
    }

    func createSRPSession(srpUserID: String, srpA: Data) async throws -> (sessionID: String, srpB: Data) {
        struct Response: Decodable { let sessionID: String; let srpB: String }
        let response: Response = try await send("POST", "/users/srp/create-session",
                                                body: ["srpUserID": srpUserID, "srpA": srpA.base64EncodedString()])
        guard let srpB = Data(enteBase64: response.srpB) else { throw EnteAPIError.invalidResponse }
        return (response.sessionID, srpB)
    }

    func verifySRPSession(sessionID: String, srpUserID: String, srpM1: Data) async throws -> EnteAuthResponse {
        try await send("POST", "/users/srp/verify-session",
                       body: ["sessionID": sessionID, "srpUserID": srpUserID, "srpM1": srpM1.base64EncodedString()])
    }

    func sendEmailCode(email: String) async throws {
        let _: Empty = try await send("POST", "/users/ott", body: ["email": email, "purpose": "login"])
    }

    func verifyEmail(email: String, code: String) async throws -> EnteAuthResponse {
        try await send("POST", "/users/verify-email", body: ["email": email, "ott": code])
    }

    func verifyTOTP(sessionID: String, code: String) async throws -> EnteAuthResponse {
        try await send("POST", "/users/two-factor/verify", body: ["sessionID": sessionID, "code": code])
    }

    /// Returns nil while the passkey hasn't been verified in the browser yet.
    func passkeyStatus(sessionID: String) async throws -> EnteAuthResponse? {
        do {
            return try await send("GET", "/users/two-factor/passkeys/get-token", query: ["sessionID": sessionID])
        } catch EnteAPIError.http(statusCode: 400) {
            return nil
        }
    }

    func logout(token: String) async throws {
        let _: Empty = try await send("POST", "/users/logout", token: token)
    }

    /// Returns nil when the account has never used Ente Auth.
    func authenticatorKey(token: String) async throws -> EnteAuthenticatorKey? {
        do {
            return try await send("GET", "/authenticator/key", token: token)
        } catch EnteAPIError.http(statusCode: 404) {
            return nil
        }
    }

    /// Stores a new authenticator key for an account that has never used Ente Auth. Throws `http(statusCode: 409)`
    /// when the account already has one.
    func createAuthenticatorKey(token: String, encryptedKey: String, header: String) async throws {
        let _: Empty = try await send("POST", "/authenticator/key", token: token,
                                      body: ["encryptedKey": encryptedKey, "header": header])
    }

    func authenticatorDiff(token: String, sinceTime: Int64, limit: Int) async throws -> [EnteAuthenticatorEntity] {
        struct Response: Decodable { let diff: [EnteAuthenticatorEntity] }
        let response: Response = try await send("GET", "/authenticator/entity/diff", token: token,
                                                query: ["sinceTime": String(sinceTime), "limit": String(limit)])
        return response.diff
    }

    /// Returns the new entity, with the id and time the server gave it.
    @discardableResult
    func createAuthenticatorEntity(token: String, encryptedData: String, header: String) async throws -> EnteAuthenticatorEntity {
        try await send("POST", "/authenticator/entity", token: token, body: ["encryptedData": encryptedData, "header": header])
    }

    /// Replaces the data of an entity. Ente's server answers without the entity, its new time comes with the next diff.
    func updateAuthenticatorEntity(token: String, id: String, encryptedData: String, header: String) async throws {
        let _: Empty = try await send("PUT", "/authenticator/entity", token: token,
                                      body: ["id": id, "encryptedData": encryptedData, "header": header])
    }

    /// Deletes an entity for good. Other devices see it in the diff with `isDeleted` set.
    func deleteAuthenticatorEntity(token: String, id: String) async throws {
        let _: Empty = try await send("DELETE", "/authenticator/entity", token: token, query: ["id": id])
    }

    // MARK: - Transport

    private struct Empty: Decodable {}

    func request(_ method: String, _ path: String, token: String? = nil, query: [String: String] = [:], body: [String: String]? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw EnteAPIError.invalidServerURL
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw EnteAPIError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(Self.clientPackage, forHTTPHeaderField: "X-Client-Package")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func send<T: Decodable>(_ method: String, _ path: String, token: String? = nil, query: [String: String] = [:], body: [String: String]? = nil) async throws -> T {
        let request = try request(method, path, token: token, query: query, body: body)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw EnteAPIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw EnteAPIError.http(statusCode: response.statusCode) }
        if T.self == Empty.self {
            return Empty() as! T
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw EnteAPIError.invalidResponse
        }
    }
}
