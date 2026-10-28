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
import Testing
import YubiKit

@testable import Authenticator

struct EnteCodeParserTests {

    @Test func parsesJSONStringWithCodeDisplay() throws {
        let raw = #""otpauth://totp/GitHub:alice%40example.com?algorithm=SHA1&digits=6&issuer=GitHub&period=30&secret=JBSWY3DPEHPK3PXP&codeDisplay=%7B%22pinned%22%3Atrue%2C%22trashed%22%3Afalse%7D""#
        let code = try #require(EnteCodeParser.parse(id: "1", rawData: raw))
        let template = try #require(code.template)
        #expect(template.issuer == "GitHub")
        #expect(template.name == "alice@example.com")
        #expect(template.type.period == 30)
        // YubiKit pads secrets shorter than the HMAC block minimum with zeros.
        #expect(template.secret.starts(with: Data(base32Encoded: "JBSWY3DPEHPK3PXP")!))
        #expect(code.credentialId == "GitHub:alice@example.com")
    }

    @Test func skipsTrashedAccounts() {
        let raw = #""otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&codeDisplay=%7B%22trashed%22%3Atrue%7D""#
        #expect(EnteCodeParser.parse(id: "1", rawData: raw) == nil)
        let object = #"{"rawData":"otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP","display":{"trashed":true}}"#
        #expect(EnteCodeParser.parse(id: "2", rawData: object) == nil)
    }

    @Test func parsesExportObject() throws {
        let raw = #"{"rawData":"otpauth://hotp/Example:bob?secret=JBSWY3DPEHPK3PXP&counter=5&digits=8","display":{"trashed":false}}"#
        let template = try #require(EnteCodeParser.parse(id: "1", rawData: raw)?.template)
        #expect(template.issuer == "Example")
        #expect(template.digits == 8)
        if case .hotp(let counter) = template.type {
            #expect(counter == 5)
        } else {
            Issue.record("Expected a HOTP credential")
        }
    }

    @Test func mapsSteamToTOTPWithSteamIssuer() throws {
        let raw = #""otpauth://steam/Steam:gamer?secret=JBSWY3DPEHPK3PXP&digits=5&period=30""#
        let template = try #require(EnteCodeParser.parse(id: "1", rawData: raw)?.template)
        #expect(template.issuer == "Steam")
        #expect(template.name == "gamer")
        #expect(template.type.period == 30)
        #expect(template.digits == 6)
    }

    @Test func keepsHashInNames() throws {
        let raw = #""otpauth://totp/Team#1:alice?secret=JBSWY3DPEHPK3PXP""#
        let template = try #require(EnteCodeParser.parse(id: "1", rawData: raw)?.template)
        #expect(template.issuer == "Team#1")
    }

    @Test func reportsAccountsTheYubiKeyCantStore() throws {
        let code = try #require(EnteCodeParser.parse(id: "1", rawData: #""otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&digits=10""#))
        #expect(code.template == nil)
        #expect(code.unsupportedReason != nil)
        #expect(code.title == "Example")
        #expect(code.subtitle == "alice")

        let unreadable = try #require(EnteCodeParser.parse(id: "2", rawData: "not json"))
        #expect(unreadable.template == nil)
    }
}

// Serves canned responses to EnteAPIClient. The tests using it run serialized.
nonisolated final class EnteMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func makeAPI() throws -> EnteAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EnteMockURLProtocol.self]
        return try EnteAPIClient(server: URL(string: "https://ente.test")!, session: URLSession(configuration: configuration))
    }
}

@Suite(.serialized)
struct EnteAuthenticatorSyncTests {

    private func entity(_ id: String, _ uri: String?, key: Data, updatedAt: Int64, isDeleted: Bool = false) throws -> [String: Any] {
        var json: [String: Any] = ["id": id, "isDeleted": isDeleted, "updatedAt": updatedAt]
        if let uri {
            let plain = try JSONSerialization.data(withJSONObject: uri, options: .fragmentsAllowed)
            let (header, cipherText) = try EnteCrypto.secretStreamEncrypt(plain, key: key)
            json["encryptedData"] = cipherText.base64EncodedString()
            json["header"] = header.base64EncodedString()
        }
        return json
    }

    @Test func downloadsAndDecryptsAccounts() async throws {
        let account = try FakeEnteAccount()
        let authenticatorKey = EnteCrypto.randomBytes(32)
        let encryptedAuthenticatorKey = try EnteCrypto.secretBox(authenticatorKey, key: account.masterKey)
        let diff: [[String: Any]] = [
            try entity("a", "otpauth://totp/Zeta:alice?secret=JBSWY3DPEHPK3PXP", key: authenticatorKey, updatedAt: 1),
            try entity("b", "otpauth://totp/Alpha:bob?secret=JBSWY3DPEHPK3PXP", key: authenticatorKey, updatedAt: 2),
            try entity("c", "otpauth://totp/Deleted:carol?secret=JBSWY3DPEHPK3PXP", key: authenticatorKey, updatedAt: 3),
            try entity("c", nil, key: authenticatorKey, updatedAt: 4, isDeleted: true),
        ]
        EnteMockURLProtocol.requests = []
        EnteMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/authenticator/key":
                let body = ["encryptedKey": encryptedAuthenticatorKey.cipherText.base64EncodedString(),
                            "header": encryptedAuthenticatorKey.nonce.base64EncodedString()]
                return (200, try! JSONSerialization.data(withJSONObject: body))
            case "/authenticator/entity/diff":
                return (200, try! JSONSerialization.data(withJSONObject: ["diff": diff]))
            default:
                return (404, Data())
            }
        }
        let api = try EnteMockURLProtocol.makeAPI()
        let keys = EnteAccountKeys(userID: 1, token: "the-token", masterKey: account.masterKey)

        let key = try #require(try await EnteAuthenticatorSync.authenticatorKey(api: api, keys: keys))
        #expect(key == authenticatorKey)
        let codes = try await EnteAuthenticatorSync.codes(api: api, token: keys.token, authenticatorKey: key)
        #expect(codes.map(\.title) == ["Alpha", "Zeta"])

        for request in EnteMockURLProtocol.requests {
            #expect(request.value(forHTTPHeaderField: "X-Client-Package") == "io.ente.auth")
            #expect(request.value(forHTTPHeaderField: "X-Auth-Token") == "the-token")
        }
        let diffRequest = try #require(EnteMockURLProtocol.requests.last?.url)
        #expect(diffRequest.query?.contains("sinceTime=0") == true)
    }

    @Test func missingAuthenticatorKeyMeansNoAccounts() async throws {
        EnteMockURLProtocol.handler = { _ in (404, Data()) }
        let api = try EnteMockURLProtocol.makeAPI()
        let keys = EnteAccountKeys(userID: 1, token: "t", masterKey: EnteCrypto.randomBytes(32))
        #expect(try await EnteAuthenticatorSync.authenticatorKey(api: api, keys: keys) == nil)
    }

    @Test func revokedTokenIsReportedAsSignedOut() async throws {
        EnteMockURLProtocol.handler = { _ in (401, Data()) }
        let api = try EnteMockURLProtocol.makeAPI()
        await #expect(throws: EnteAuthenticatorSyncError.self) {
            try await EnteAuthenticatorSync.codes(api: api, token: "t", authenticatorKey: EnteCrypto.randomBytes(32))
        }
    }

    @Test func emailMFAAccountsStartWithEmailCode() async throws {
        EnteMockURLProtocol.requests = []
        EnteMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/users/srp/attributes":
                let attributes: [String: Any] = ["srpUserID": "id", "srpSalt": "AA==", "memLimit": 1, "opsLimit": 1,
                                                 "kekSalt": "AA==", "isEmailMFAEnabled": true]
                return (200, try! JSONSerialization.data(withJSONObject: ["attributes": attributes]))
            case "/users/ott":
                return (200, Data("{}".utf8))
            default:
                return (404, Data())
            }
        }
        let (_, step) = try await EnteLoginFlow.start(api: try EnteMockURLProtocol.makeAPI(), email: "a@b.c")
        #expect(step == .emailCode)
        #expect(EnteMockURLProtocol.requests.map(\.url?.path) == ["/users/srp/attributes", "/users/ott"])
    }

    @Test func srpAccountsStartWithPassword() async throws {
        EnteMockURLProtocol.handler = { _ in
            let attributes: [String: Any] = ["srpUserID": "id", "srpSalt": "AA==", "memLimit": 1, "opsLimit": 1,
                                             "kekSalt": "AA==", "isEmailMFAEnabled": false]
            return (200, try! JSONSerialization.data(withJSONObject: ["attributes": attributes]))
        }
        let (_, step) = try await EnteLoginFlow.start(api: try EnteMockURLProtocol.makeAPI(), email: "a@b.c")
        #expect(step == .password)
    }

    @Test func rejectsInsecureServers() {
        #expect(throws: EnteAPIError.invalidServerURL) { try EnteAPIClient(server: URL(string: "http://ente.test")!) }
    }
}
