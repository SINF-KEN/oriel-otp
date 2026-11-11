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

/// What a new account stores on the server: every key, encrypted, so the server can't read any of them.
nonisolated struct EnteNewKeyAttributes: Codable, Sendable, Equatable {
    let kekSalt: String
    let encryptedKey: String
    let keyDecryptionNonce: String
    let publicKey: String
    let encryptedSecretKey: String
    let secretKeyDecryptionNonce: String
    let memLimit: UInt64
    let opsLimit: UInt64
    let masterKeyEncryptedWithRecoveryKey: String
    let masterKeyDecryptionNonce: String
    let recoveryKeyEncryptedWithMasterKey: String
    let recoveryKeyDecryptionNonce: String
}

// MARK: - Client

/// The few endpoints of Ente's API needed to sign in and to read, add, change and delete authenticator codes.
nonisolated struct EnteAPIClient: Sendable {

    static let defaultServer = URL(string: "https://api.ente.io")!

    /// Ente's server sorts clients by the prefix of this header and only lets tokens issued for "io.ente.auth*" use
    /// the authenticator endpoints. The suffix tells this app apart from Ente's own, which send "io.ente.auth".
    static let clientPackage = "io.ente.auth.orielotp"

    /// The server for what was typed in a server field, Ente's own if it's empty.
    static func serverURL(from text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return defaultServer }
        guard let url = URL(string: text), isPlainServer(url) else { throw EnteAPIError.invalidServerURL }
        return url
    }

    /// The host of a URL as URLSession connects to it, in lower case and without a trailing dot. Nil unless it's a plain
    /// host name or IP address: a percent-encoded or non-ASCII host is decoded before connecting, so it would be checked
    /// as one host and connected to as another. A host with more than one trailing dot is refused too: `api.ente.io..`
    /// would otherwise not be taken for Ente's server.
    static func host(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: true)?.lowercased() else { return nil }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-._:[]".unicodeScalars)
        guard !host.isEmpty, !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
              host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return host
    }

    /// Whether a URL can be a server: https, a plain host, and nothing a server URL doesn't need, like a user name, a
    /// query or a fragment.
    static func isPlainServer(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", host(of: url) != nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.percentEncodedUser == nil && components.percentEncodedPassword == nil
            && components.percentEncodedQuery == nil && components.percentEncodedFragment == nil
    }

    /// Whether two URLs are the same server, however they were typed.
    static func isSameServer(_ first: URL, _ second: URL) -> Bool {
        func parts(_ url: URL) -> [String?] {
            [url.scheme?.lowercased(), host(of: url), String(url.port ?? 443),
             url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
        }
        guard host(of: first) != nil else { return false }
        return parts(first) == parts(second)
    }

    /// Whether accounts can be created on the server. Never on Ente's own servers: only on servers people host themselves.
    static func allowsAccountCreation(on server: URL) -> Bool {
        guard isPlainServer(server), let host = host(of: server) else { return false }
        return !["ente.io", "ente.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    let server: URL
    let session: URLSession

    init(server: URL = defaultServer, session: URLSession = .ente) throws {
        // Credentials and tokens must never travel unencrypted.
        guard server.scheme == "https", Self.isPlainServer(server) else { throw EnteAPIError.invalidServerURL }
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

    // MARK: Creating an account, only on self-hosted servers

    /// Every request that creates an account goes through this, so none can reach Ente's servers.
    private func requireAccountCreation() throws {
        guard Self.allowsAccountCreation(on: server) else { throw EnteSignUpError.notAllowedOnEnte }
    }

    func sendSignUpCode(email: String) async throws {
        try requireAccountCreation()
        let _: Empty = try await send("POST", "/users/ott", body: ["email": email, "purpose": "signup"])
    }

    func setKeyAttributes(_ attributes: EnteNewKeyAttributes, token: String) async throws {
        struct Request: Encodable { let keyAttributes: EnteNewKeyAttributes }
        try requireAccountCreation()
        let _: Empty = try await send("PUT", "/users/attributes", token: token, json: JSONEncoder().encode(Request(keyAttributes: attributes)))
    }

    func setUpSRP(token: String, srpUserID: String, srpSalt: Data, srpVerifier: Data, srpA: Data) async throws -> (setupID: String, srpB: Data) {
        struct Response: Decodable { let setupID: String; let srpB: String }
        try requireAccountCreation()
        let response: Response = try await send("POST", "/users/srp/setup", token: token,
                                                body: ["srpUserID": srpUserID, "srpSalt": srpSalt.base64EncodedString(),
                                                       "srpVerifier": srpVerifier.base64EncodedString(), "srpA": srpA.base64EncodedString()])
        guard let srpB = Data(enteBase64: response.srpB) else { throw EnteAPIError.invalidResponse }
        return (response.setupID, srpB)
    }

    /// Returns the server's proof, `srpM2`.
    func completeSRPSetup(token: String, setupID: String, srpM1: Data) async throws -> Data {
        struct Response: Decodable { let srpM2: String }
        try requireAccountCreation()
        let response: Response = try await send("POST", "/users/srp/complete", token: token,
                                                body: ["setupID": setupID, "srpM1": srpM1.base64EncodedString()])
        guard let srpM2 = Data(enteBase64: response.srpM2) else { throw EnteAPIError.invalidResponse }
        return srpM2
    }

    // MARK: Deleting an account

    /// Asks for the challenge that proves the account's keys are at hand. Ente's server seals it to the account's
    /// public key, so only the secret key opens it.
    func deleteChallenge(token: String) async throws -> (allowDelete: Bool, encryptedChallenge: Data?) {
        struct Response: Decodable { let allowDelete: Bool; let encryptedChallenge: String? }
        let response: Response = try await send("GET", "/users/delete-challenge", token: token)
        return (response.allowDelete, response.encryptedChallenge.flatMap { Data(enteBase64: $0) })
    }

    /// Deletes the account and everything in it, for good, with the opened challenge.
    func deleteAccount(token: String, challenge: String) async throws {
        let _: Empty = try await send("DELETE", "/users/delete", token: token, body: ["challenge": challenge])
    }

    // MARK: Signing in

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

    // MARK: - Transport

    private struct Empty: Decodable {}

    func request(_ method: String, _ path: String, token: String? = nil, query: [String: String] = [:], body: [String: String]? = nil,
                 json: Data? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw EnteAPIError.invalidServerURL
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves "+" as it is, and Ente's server reads that as a space: an email with a tag wouldn't be found.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
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
        if let json = try json ?? body.map({ try JSONEncoder().encode($0) }) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = json
        }
        return request
    }

    /// The most an answer may hold. A page of the authenticator diff, the largest answer Ente gives, is far smaller, and
    /// a server that sends more could otherwise use up the app's memory.
    static let maxResponseSize = 16 << 20

    /// Reads an answer, stopping with an error past `maxResponseSize`.
    ///
    /// Off the caller's actor: the bytes come one at a time, and read from the main actor each one leaves it and comes
    /// back, which took a quarter of an hour for 16 MiB.
    @concurrent static func body(of bytes: URLSession.AsyncBytes, expectedLength: Int64) async throws -> Data {
        guard expectedLength <= Int64(maxResponseSize) else {
            bytes.task.cancel()
            throw EnteAPIError.invalidResponse
        }
        var data = Data()
        data.reserveCapacity(Int(max(0, expectedLength)))
        for try await byte in bytes {
            guard data.count < maxResponseSize else {
                bytes.task.cancel()
                throw EnteAPIError.invalidResponse
            }
            data.append(byte)
        }
        return data
    }

    private func send<T: Decodable>(_ method: String, _ path: String, token: String? = nil, query: [String: String] = [:], body: [String: String]? = nil,
                                    json: Data? = nil) async throws -> T {
        let request = try request(method, path, token: token, query: query, body: body, json: json)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw EnteAPIError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            bytes.task.cancel()
            throw EnteAPIError.http(statusCode: response.statusCode)
        }
        let data = try await Self.body(of: bytes, expectedLength: response.expectedContentLength)
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

/// Keeps a redirect on the server it started from. A redirect keeps the request's headers, so following one elsewhere,
/// or to plain http, would hand over the session token. A refused redirect fails as an HTTP error.
nonisolated final class EnteRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {

    static func allows(from origin: URL?, to destination: URL?) -> Bool {
        guard let origin, let destination, origin.scheme?.lowercased() == "https", destination.scheme?.lowercased() == "https",
              let host = EnteAPIClient.host(of: origin), host == EnteAPIClient.host(of: destination) else { return false }
        return (origin.port ?? 443) == (destination.port ?? 443)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.allows(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }
}

extension URLSession {
    /// For talking to Ente's server: keeps nothing on disk, and redirects stay on the server.
    nonisolated static let ente: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // URLSession's default lets a server that trickles its answer hold a request, and every sync queued behind it,
        // for a week.
        configuration.timeoutIntervalForResource = 300
        #if DEBUG && (targetEnvironment(simulator) || os(macOS))
        // URLProtocol.registerClass only reaches the shared session. It only answers for its own hosts.
        configuration.protocolClasses = [FakeEnteServer.self] + (configuration.protocolClasses ?? [])
        // Tests must never reach a real server, so there every other request fails. Signing in with 4096-bit SRP takes
        // the fake server longer than the default 60 second timeout in an unoptimised build, and it answers locally.
        if UnstubbedRequestFailure.isTesting {
            configuration.protocolClasses = [FakeEnteServer.self, UnstubbedRequestFailure.self]
            configuration.timeoutIntervalForRequest = 3600
            configuration.timeoutIntervalForResource = 3600
        }
        #endif
        return URLSession(configuration: configuration, delegate: EnteRedirectGuard(), delegateQueue: nil)
    }()
}
