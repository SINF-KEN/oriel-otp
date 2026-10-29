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

#if DEBUG && (targetEnvironment(simulator) || os(macOS))

import BigInt
import CryptoKit
import Foundation
import SwiftUI

/// A stand-in for Ente's server at https://demo.ente.test, so Ente Auth sync can be tried in the simulator.
///
/// It plays the server side of everything the app does for real: SRP with its own proof, encrypted key
/// attributes, a sealed auth token and secretstream-encrypted authenticator entities. Any email signs in with
/// the password "demo". Tags in the email turn on the other ways of signing in: "+mfa" asks for an email code,
/// "+2fa" for a TOTP code, "+passkey" for an email code and then a passkey, and "+nosrp" acts like an account without
/// SRP, which also gets an email code. Both codes are 123456. The passkey counts as verified from the second check. The accounts cover the cases the sync handles: an account that is also on the demo
/// YubiKey, a Steam account, a '#' in a name, Ente's export format, one in Ente's trash, a deleted one and one the
/// YubiKey can't store.
///
/// Each `*.new.ente.test` host is an account of its own that has never used Ente Auth: it has no authenticator key
/// and no accounts until the app creates the key.
nonisolated final class FakeEnteServer: URLProtocol, @unchecked Sendable {

    static let server = URL(string: "https://demo.ente.test")!
    static let password = "demo"
    static let code = "123456"
    private static let newAccountDomain = "new.ente.test"

    /// A server with a new account that has never used Ente Auth.
    static func newAccountServer() -> URL {
        URL(string: "https://\(UUID().uuidString.lowercased()).\(newAccountDomain)")!
    }

    /// Whether the account at `server` has an authenticator key.
    static func hasAuthenticatorKey(_ server: URL) -> Bool {
        FakeEnteAccount.account(for: server.host ?? "").hasAuthenticatorKey
    }

    /// Routes requests to the demo server here and preselects it on the sign in screen.
    static func install() {
        URLProtocol.registerClass(FakeEnteServer.self)
        if UserDefaults.standard.string(forKey: "EnteAuth.ServerURL") == nil {
            UserDefaults.standard.set(server.absoluteString, forKey: "EnteAuth.ServerURL")
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == server.host || host.hasSuffix("." + newAccountDomain)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = request
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
            let (status, json) = FakeEnteAccount.account(for: request.url?.host ?? "").respond(to: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// An account on the demo server and its state.
nonisolated private final class FakeEnteAccount: @unchecked Sendable {

    private static let accountsLock = NSLock()
    nonisolated(unsafe) private static var accounts: [String: FakeEnteAccount] = [:]

    static func account(for host: String) -> FakeEnteAccount {
        accountsLock.withLock {
            if let account = accounts[host] { return account }
            let account = FakeEnteAccount(usesEnteAuth: host == FakeEnteServer.server.host)
            accounts[host] = account
            return account
        }
    }

    private let lock = NSLock()
    private var sessions: [String: (srpUserID: String, A: BigUInt, b: BigUInt, B: BigUInt)] = [:]
    private var twoFactorSessions: Set<String> = []
    /// Passkey sessions, with whether they were checked before. The first check finds the passkey not verified yet.
    private var passkeySessions: [String: Bool] = [:]

    private let srpUserID = UUID().uuidString.lowercased()
    private let srpSalt = EnteCrypto.randomBytes(16)
    private let kekSalt = EnteCrypto.randomBytes(16)
    // Low limits so signing in is quick. Real accounts use far more memory.
    private let opsLimit: UInt64 = 2
    private let memLimit: UInt64 = 8 * 1024 * 1024
    private let loginKey: Data
    private let keyAttributes: [String: Any]
    private let encryptedToken: String
    private let token: String
    private var authenticatorKey: [String: Any]?
    private let entities: [[String: Any]]

    var hasAuthenticatorKey: Bool {
        lock.withLock { authenticatorKey != nil }
    }

    private init(usesEnteAuth: Bool) {
        let keyEncryptionKey = try! EnteCrypto.deriveKeyEncryptionKey(password: FakeEnteServer.password, salt: kekSalt,
                                                                      opsLimit: opsLimit, memLimit: memLimit)
        loginKey = try! EnteCrypto.deriveLoginKey(keyEncryptionKey: keyEncryptionKey)

        let masterKey = EnteCrypto.randomBytes(32)
        let (publicKey, secretKey) = try! EnteCrypto.generateKeyPair()
        let encryptedKey = try! EnteCrypto.secretBox(masterKey, key: keyEncryptionKey)
        let encryptedSecretKey = try! EnteCrypto.secretBox(secretKey, key: masterKey)
        keyAttributes = ["kekSalt": kekSalt.base64EncodedString(),
                         "encryptedKey": encryptedKey.cipherText.base64EncodedString(),
                         "keyDecryptionNonce": encryptedKey.nonce.base64EncodedString(),
                         "publicKey": publicKey.base64EncodedString(),
                         "encryptedSecretKey": encryptedSecretKey.cipherText.base64EncodedString(),
                         "secretKeyDecryptionNonce": encryptedSecretKey.nonce.base64EncodedString(),
                         "memLimit": memLimit, "opsLimit": opsLimit]
        let tokenBytes = EnteCrypto.randomBytes(32)
        token = tokenBytes.enteURLSafeBase64
        encryptedToken = try! EnteCrypto.sealedBox(tokenBytes, publicKey: publicKey).base64EncodedString()

        guard usesEnteAuth else {
            authenticatorKey = nil
            entities = []
            return
        }
        let key = EnteCrypto.randomBytes(32)
        let encryptedAuthenticatorKey = try! EnteCrypto.secretBox(key, key: masterKey)
        authenticatorKey = ["encryptedKey": encryptedAuthenticatorKey.cipherText.base64EncodedString(),
                            "header": encryptedAuthenticatorKey.nonce.base64EncodedString()]
        entities = Self.demoEntities(key: key)
    }

    func respond(to request: URLRequest) -> (Int, Any) {
        lock.lock()
        defer { lock.unlock() }
        let path = request.url?.path ?? ""
        let body = Self.body(of: request)
        let authorized = request.value(forHTTPHeaderField: "X-Auth-Token") == token
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/users/srp/attributes"):
            let email = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "email" }?.value ?? ""
            guard !Self.has("nosrp", email) else { return (404, [:]) }
            return (200, ["attributes": ["srpUserID": srpUserID(twoFactor: Self.has("2fa", email)), "srpSalt": srpSalt.base64EncodedString(),
                                         "memLimit": memLimit, "opsLimit": opsLimit,
                                         "kekSalt": kekSalt.base64EncodedString(),
                                         "isEmailMFAEnabled": Self.has("mfa", email) || Self.has("passkey", email)]])
        case ("POST", "/users/srp/create-session"):
            return createSession(body)
        case ("POST", "/users/srp/verify-session"):
            return verifySession(body)
        case ("POST", "/users/ott"):
            return (200, [:])
        case ("POST", "/users/verify-email"):
            guard body["ott"] as? String == FakeEnteServer.code else { return (401, [:]) }
            let email = body["email"] as? String ?? ""
            if Self.has("passkey", email) { return (200, startPasskey()) }
            return Self.has("2fa", email) ? (200, startTwoFactor()) : (200, signedIn())
        case ("POST", "/users/two-factor/verify"):
            guard let sessionID = body["sessionID"] as? String, twoFactorSessions.contains(sessionID) else { return (404, [:]) }
            guard body["code"] as? String == FakeEnteServer.code else { return (401, [:]) }
            twoFactorSessions.remove(sessionID)
            return (200, signedIn())
        case ("GET", "/users/two-factor/passkeys/get-token"):
            let sessionID = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "sessionID" }?.value ?? ""
            guard let checked = passkeySessions[sessionID] else { return (404, [:]) }
            guard checked else {
                passkeySessions[sessionID] = true
                return (400, [:])
            }
            passkeySessions[sessionID] = nil
            return (200, signedIn())
        case ("GET", "/authenticator/key"):
            guard authorized else { return (401, [:]) }
            return authenticatorKey.map { (200, $0) } ?? (404, [:])
        case ("POST", "/authenticator/key"):
            guard authorized else { return (401, [:]) }
            guard authenticatorKey == nil else { return (409, [:]) }
            guard let encryptedKey = body["encryptedKey"] as? String, let header = body["header"] as? String else { return (400, [:]) }
            authenticatorKey = ["encryptedKey": encryptedKey, "header": header]
            return (200, [:])
        case ("GET", "/authenticator/entity/diff"):
            guard authorized else { return (401, [:]) }
            let sinceTime = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "sinceTime" }?.value.flatMap(Int64.init) ?? 0
            return (200, ["diff": sinceTime == 0 ? entities : [], "timestamp": 1_000_000])
        case ("POST", "/users/logout"):
            return (200, [:])
        default:
            return (404, [:])
        }
    }

    /// Whether the email has a tag like "+2fa" before the "@".
    private static func has(_ tag: String, _ email: String) -> Bool {
        email.split(separator: "@").first?.split(separator: "+").dropFirst().contains { $0.lowercased() == tag } ?? false
    }

    /// Accounts with a TOTP second factor get their own SRP user id, the only thing SRP sends that tells them apart.
    private func srpUserID(twoFactor: Bool) -> String {
        twoFactor ? srpUserID + "-2fa" : srpUserID
    }

    private func verifier(srpUserID: String) -> BigUInt {
        let x = BigUInt(Self.hash(srpSalt, Self.hash(Data(srpUserID.utf8), Data(":".utf8), loginKey)))
        return EnteSRPClient.g.power(x, modulus: EnteSRPClient.N)
    }

    private func signedIn() -> [String: Any] {
        ["id": 42, "keyAttributes": keyAttributes, "encryptedToken": encryptedToken]
    }

    private func startTwoFactor() -> [String: Any] {
        let sessionID = UUID().uuidString.lowercased()
        twoFactorSessions.insert(sessionID)
        return ["id": 42, "twoFactorSessionID": sessionID]
    }

    private func startPasskey() -> [String: Any] {
        let sessionID = UUID().uuidString.lowercased()
        passkeySessions[sessionID] = false
        return ["id": 42, "passkeySessionID": sessionID, "accountsUrl": "https://accounts.ente.test"]
    }

    private func createSession(_ body: [String: Any]) -> (Int, Any) {
        let N = EnteSRPClient.N
        guard let srpUserID = body["srpUserID"] as? String,
              [self.srpUserID(twoFactor: false), self.srpUserID(twoFactor: true)].contains(srpUserID),
              let srpA = (body["srpA"] as? String).flatMap({ Data(enteBase64: $0) }) else { return (400, [:]) }
        let A = BigUInt(srpA)
        guard !(A % N).isZero else { return (400, [:]) }
        let b = BigUInt(EnteCrypto.randomBytes(64))
        let B = (EnteSRPClient.k * verifier(srpUserID: srpUserID) + EnteSRPClient.g.power(b, modulus: N)) % N
        let sessionID = UUID().uuidString.lowercased()
        sessions[sessionID] = (srpUserID, A, b, B)
        return (200, ["sessionID": sessionID, "srpB": B.serialize().base64EncodedString()])
    }

    private func verifySession(_ body: [String: Any]) -> (Int, Any) {
        guard let sessionID = body["sessionID"] as? String, let session = sessions.removeValue(forKey: sessionID),
              let srpM1 = (body["srpM1"] as? String).flatMap({ Data(enteBase64: $0) }) else { return (400, [:]) }
        let N = EnteSRPClient.N
        let paddedA = EnteSRPClient.pad(session.A.serialize())
        let paddedB = EnteSRPClient.pad(session.B.serialize())
        let u = BigUInt(Self.hash(paddedA, paddedB))
        // S = (A * v^u)^b % N, the server's side of the shared secret.
        let S = (session.A * verifier(srpUserID: session.srpUserID).power(u, modulus: N) % N).power(session.b, modulus: N)
        let paddedS = EnteSRPClient.pad(S.serialize())
        let expectedM1 = Self.hash(paddedA, paddedB, paddedS)
        // A wrong password gives a different S, so the proof doesn't match.
        guard srpM1 == expectedM1 else { return (401, [:]) }
        let srpM2 = Self.hash(paddedA, expectedM1, Self.hash(paddedS))
        var response = session.srpUserID == srpUserID(twoFactor: true) ? startTwoFactor() : signedIn()
        response["srpM2"] = srpM2.base64EncodedString()
        return (200, response)
    }

    private static func demoEntities(key: Data) -> [[String: Any]] {
        func entity(_ id: String, _ rawData: Any, updatedAt: Int64, isDeleted: Bool = false) -> [String: Any] {
            var json: [String: Any] = ["id": id, "isDeleted": isDeleted, "updatedAt": updatedAt]
            guard !isDeleted else { return json }
            let plain = try! JSONSerialization.data(withJSONObject: rawData, options: .fragmentsAllowed)
            let (header, cipherText) = try! EnteCrypto.secretStreamEncrypt(plain, key: key)
            json["encryptedData"] = cipherText.base64EncodedString()
            json["header"] = header.base64EncodedString()
            return json
        }
        func url(_ type: String, _ label: String, _ query: String = "") -> String {
            let codeDisplay = "%7B%22pinned%22%3Afalse%2C%22trashed%22%3Afalse%7D"
            return "otpauth://\(type)/\(label)?secret=JBSWY3DPEHPK3PXP\(query)&codeDisplay=\(codeDisplay)"
        }
        return [
            // Also on the demo YubiKey, so it shows as already added.
            entity("e1", url("totp", "GitHub:alice@example.com", "&issuer=GitHub"), updatedAt: 1),
            entity("e2", url("totp", "Proton:alice@proton.me", "&issuer=Proton"), updatedAt: 2),
            entity("e3", url("totp", "Discord:alice#1234", "&issuer=Discord"), updatedAt: 3),
            entity("e4", ["rawData": "otpauth://totp/Dropbox:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Dropbox",
                          "display": ["trashed": false, "pinned": true]], updatedAt: 4),
            entity("e5", url("totp", "Bitwarden:alice", "&issuer=Bitwarden"), updatedAt: 5),
            entity("e6", url("totp", "Cloudflare:ops@example.com", "&issuer=Cloudflare&algorithm=SHA256&digits=8"), updatedAt: 6),
            entity("e7", url("totp", "Tailscale:alice@github", "&issuer=Tailscale"), updatedAt: 7),
            entity("e8", url("steam", "Steam:gamer", "&digits=5"), updatedAt: 8),
            entity("e9", url("totp", "Nintendo:alice", "&issuer=Nintendo&period=60"), updatedAt: 9),
            entity("e10", url("hotp", "Home%20VPN:alice", "&issuer=Home%20VPN&counter=3"), updatedAt: 10),
            // Not shown: in Ente's trash, deleted, and one the YubiKey can't store.
            entity("e11", "otpauth://totp/Old%20forum:alice?secret=JBSWY3DPEHPK3PXP&codeDisplay=%7B%22trashed%22%3Atrue%7D", updatedAt: 11),
            entity("e12", url("totp", "Closed%20bank:alice"), updatedAt: 12),
            entity("e12", "", updatedAt: 13, isDeleted: true),
            entity("e13", url("totp", "Legacy%20portal:alice", "&issuer=Legacy%20portal&digits=10"), updatedAt: 14),
        ]
    }

    private static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func hash(_ parts: Data...) -> Data {
        var hasher = SHA256()
        parts.forEach { hasher.update(data: $0) }
        return Data(hasher.finalize())
    }
}

// MARK: - Yubico OTP

extension Notification.Name {
    static let simulatedYubicoOTP = Notification.Name("SimulatedYubicoOTP")
}

/// Acts as if a YubiKey's NFC OTP link was scanned, which shows the Yubico OTP row on the main screen.
struct SimulatedYubicoOTPButton: View {
    var body: some View {
        Button("Tap NFC OTP", systemImage: "wave.3.right") {
            // A Yubico OTP is a 12 character public id followed by 32 characters of encrypted data, in modhex.
            let modhex = Array("cbdefghijklnrtuv")
            let otp = "ccccccjlkgjb" + String((0..<32).map { _ in modhex.randomElement()! })
            NotificationCenter.default.post(name: .simulatedYubicoOTP, object: otp)
        }
    }
}

#endif
