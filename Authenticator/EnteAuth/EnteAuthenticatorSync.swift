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

/// An account read from Ente Auth.
struct EnteCode: Identifiable, Sendable {
    let id: String
    let issuer: String?
    let accountName: String
    /// The credential to put on the YubiKey, nil if the YubiKey can't store this account.
    let template: YubiKitOATHSession.CredentialTemplate?
    /// Why the account can't be stored on the YubiKey.
    let unsupportedReason: String?
    /// The account for the Apple Watch, nil for counter based accounts and ones that can't be read.
    var otpAccount: OTPAccount? = nil

    var title: String {
        if let issuer, !issuer.isEmpty { return issuer }
        return accountName
    }

    var subtitle: String? {
        if let issuer, !issuer.isEmpty, !accountName.isEmpty { return accountName }
        return nil
    }

    /// The id the account will have on the YubiKey, matching `Account.accountId`.
    var credentialId: String? {
        guard let template else { return nil }
        return OATHCredentialId.key(accountName: template.name, issuer: template.issuer,
                                    period: UInt(template.type.period ?? 0), isTOTP: template.type.period != nil)
    }
}

enum EnteCodeParser {

    /// Parses the decrypted data of an authenticator entity. Returns nil for accounts that are in Ente's trash.
    static func parse(id: String, rawData: String) -> EnteCode? {
        let entry = EnteEntry(rawData: rawData)
        guard var components = entry.components else {
            return EnteCode(id: id, issuer: nil, accountName: String(localized: "Unknown account", comment: "Ente import unreadable account"),
                            template: nil, unsupportedReason: String(localized: "This account could not be read.", comment: "Ente import unreadable account"))
        }
        guard !entry.isTrashed else { return nil }

        let otpAccount = OTPAuthURLParser.account(id: id, components: components, isPinned: entry.isPinned)
        let (issuer, accountName) = OTPAuthURLParser.label(of: components)
        do {
            let template: YubiKitOATHSession.CredentialTemplate
            if components.host?.lowercased() == "steam" {
                // A Steam account is a TOTP account that the app recognizes by its issuer and shows as 5 characters.
                components.host = "totp"
                components.queryItems = components.queryItems?.filter { $0.name != "digits" }
                guard let url = components.url else { throw CredentialTemplateError.type }
                let parsed = try YubiKitOATHSession.CredentialTemplate(otpauthURL: url)
                template = try YubiKitOATHSession.CredentialTemplate(type: parsed.type, algorithm: parsed.algorithm, secret: parsed.secret,
                                                                    issuer: "Steam", accountName: parsed.name, digits: 6)
            } else {
                components.host = components.host?.lowercased()
                guard let url = components.url else { throw CredentialTemplateError.type }
                template = try YubiKitOATHSession.CredentialTemplate(otpauthURL: url)
            }
            return EnteCode(id: id, issuer: template.issuer, accountName: template.name, template: template, unsupportedReason: nil,
                            otpAccount: otpAccount)
        } catch {
            return EnteCode(id: id, issuer: issuer, accountName: accountName, template: nil, unsupportedReason: error.localizedDescription,
                            otpAccount: otpAccount)
        }
    }
}

enum EnteCodeExporter {

    /// The otpauth URL for an account, in the form Ente's apps store it.
    ///
    /// The secret may differ from the one the account was created with: YubiKit pads short secrets with zeros and
    /// hashes long ones, which gives the same HMAC and so the same codes. Steam accounts get Ente's `steam` type so
    /// Ente shows them as 5 character codes.
    static func otpauthURL(for template: YubiKitOATHSession.CredentialTemplate) -> URL? {
        let isSteam = template.type.period != nil && template.issuer?.lowercased() == "steam"
        var components = URLComponents()
        components.scheme = "otpauth"
        switch template.type {
        case .totp: components.host = isSteam ? "steam" : "totp"
        case .hotp: components.host = "hotp"
        }
        let issuer = template.issuer.flatMap { $0.isEmpty ? nil : $0 }
        components.path = "/" + [issuer, template.name].compactMap { $0 }.joined(separator: ":")

        let algorithm: String
        switch template.algorithm {
        case .sha1: algorithm = "SHA1"
        case .sha256: algorithm = "SHA256"
        case .sha512: algorithm = "SHA512"
        }
        var items = [URLQueryItem(name: "secret", value: template.secret.base32EncodedString)]
        if let issuer {
            items.append(URLQueryItem(name: "issuer", value: issuer))
        }
        items.append(URLQueryItem(name: "algorithm", value: algorithm))
        items.append(URLQueryItem(name: "digits", value: String(isSteam ? 5 : template.digits)))
        switch template.type {
        case .totp(let period): items.append(URLQueryItem(name: "period", value: String(Int(period))))
        case .hotp(let counter): items.append(URLQueryItem(name: "counter", value: String(counter)))
        }
        components.queryItems = items
        return components.url
    }

    /// The plain text of an authenticator entity: the otpauth URL as a JSON string, like Ente's apps store it.
    static func rawData(for template: YubiKitOATHSession.CredentialTemplate) throws -> Data {
        guard let url = otpauthURL(for: template) else { throw CredentialTemplateError.type }
        return try JSONEncoder().encode(url.absoluteString)
    }
}

enum EnteAuthenticatorSyncError: Error, LocalizedError {
    case invalidKey
    case signedOut

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return String(localized: "Your Ente Auth data could not be decrypted.", comment: "Ente sync error")
        case .signedOut:
            return String(localized: "You have been signed out of Ente. Sign in again.", comment: "Ente sync error")
        }
    }
}

/// Reads the accounts stored in Ente Auth and adds new ones. Nothing is ever changed or deleted on Ente's server.
nonisolated enum EnteAuthenticatorSync {

    static let pageSize = 500

    /// Fetches and decrypts the authenticator key, creating it like Ente Auth does when the account has never used
    /// Ente Auth: a random key, encrypted with the master key. If another app created the key in the meantime, that
    /// key is used.
    static func authenticatorKeyCreatingIfNeeded(api: EnteAPIClient, keys: EnteAccountKeys) async throws -> Data {
        if let key = try await authenticatorKey(api: api, keys: keys) {
            return key
        }
        let key = EnteCrypto.randomBytes(EnteCrypto.keyLength)
        let encrypted = try EnteCrypto.secretBox(key, key: keys.masterKey)
        do {
            try await signedIn {
                try await api.createAuthenticatorKey(token: keys.token, encryptedKey: encrypted.cipherText.base64EncodedString(),
                                                     header: encrypted.nonce.base64EncodedString())
            }
            return key
        } catch EnteAPIError.http(statusCode: 409) {
            guard let key = try await authenticatorKey(api: api, keys: keys) else { throw EnteAuthenticatorSyncError.invalidKey }
            return key
        }
    }

    /// Fetches and decrypts the key that the authenticator entities are encrypted with.
    /// Returns nil when the account has never stored codes in Ente Auth.
    static func authenticatorKey(api: EnteAPIClient, keys: EnteAccountKeys) async throws -> Data? {
        guard let key = try await signedIn({ try await api.authenticatorKey(token: keys.token) }) else { return nil }
        guard let encryptedKey = Data(enteBase64: key.encryptedKey), let nonce = Data(enteBase64: key.header),
              let authenticatorKey = try? EnteCrypto.secretBoxOpen(encryptedKey, nonce: nonce, key: keys.masterKey) else {
            throw EnteAuthenticatorSyncError.invalidKey
        }
        return authenticatorKey
    }

    /// Downloads all entities and returns the accounts that aren't deleted or trashed, sorted like the account list.
    @MainActor static func codes(api: EnteAPIClient, token: String, authenticatorKey: Data) async throws -> [EnteCode] {
        try await decryptedEntities(api: api, token: token, authenticatorKey: authenticatorKey)
            .compactMap { id, rawData -> EnteCode? in
                guard let rawData else {
                    return EnteCode(id: id, issuer: nil, accountName: String(localized: "Unknown account", comment: "Ente import unreadable account"),
                                    template: nil, unsupportedReason: String(localized: "This account could not be decrypted.", comment: "Ente import undecryptable account"))
                }
                return EnteCodeParser.parse(id: id, rawData: rawData)
            }
            .sorted { ($0.title.lowercased(), $0.accountName.lowercased()) < ($1.title.lowercased(), $1.accountName.lowercased()) }
    }

    /// Returns the decrypted data of each entity, nil for an entity that couldn't be decrypted.
    @concurrent static func decryptedEntities(api: EnteAPIClient, token: String, authenticatorKey: Data) async throws -> [(id: String, rawData: String?)] {
        try await allEntities(api: api, token: token).map { entity in
            guard let encryptedData = entity.encryptedData.flatMap({ Data(enteBase64: $0) }),
                  let header = entity.header.flatMap({ Data(enteBase64: $0) }),
                  let decrypted = try? EnteCrypto.secretStreamDecrypt(encryptedData, header: header, key: authenticatorKey) else {
                return (entity.id, nil)
            }
            return (entity.id, String(data: decrypted, encoding: .utf8))
        }
    }

    /// Pages through the diff from the beginning and keeps the latest version of each entity.
    static func allEntities(api: EnteAPIClient, token: String) async throws -> [EnteAuthenticatorEntity] {
        var latest = [String: EnteAuthenticatorEntity]()
        var sinceTime: Int64 = 0
        while true {
            let page = try await signedIn { try await api.authenticatorDiff(token: token, sinceTime: sinceTime, limit: pageSize) }
            for entity in page where entity.updatedAt >= latest[entity.id]?.updatedAt ?? .min {
                latest[entity.id] = entity
            }
            let maxUpdatedAt = page.map(\.updatedAt).max() ?? sinceTime
            // Stop on a short page, and if the server doesn't move forward so a misbehaving server can't loop forever.
            guard page.count == pageSize, maxUpdatedAt > sinceTime else { break }
            sinceTime = maxUpdatedAt
        }
        return latest.values.filter { !$0.isDeleted }
    }

    enum AddResult: Equatable {
        case added
        case alreadyPresent
    }

    /// Encrypts the account with the authenticator key and adds it to Ente Auth, unless Ente already has an
    /// account with the same name.
    @MainActor static func add(_ template: YubiKitOATHSession.CredentialTemplate, api: EnteAPIClient, token: String,
                               authenticatorKey: Data) async throws -> AddResult {
        let existing = try await codes(api: api, token: token, authenticatorKey: authenticatorKey)
        let credentialId = OATHCredentialId.key(accountName: template.name, issuer: template.issuer,
                                                period: UInt(template.type.period ?? 0), isTOTP: template.type.period != nil)
        guard !existing.contains(where: { $0.credentialId == credentialId }) else { return .alreadyPresent }
        let (header, encryptedData) = try EnteCrypto.secretStreamEncrypt(try EnteCodeExporter.rawData(for: template), key: authenticatorKey)
        try await signedIn {
            try await api.createAuthenticatorEntity(token: token, encryptedData: encryptedData.base64EncodedString(),
                                                    header: header.base64EncodedString())
        }
        return .added
    }

    private static func signedIn<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch EnteAPIError.http(statusCode: 401) {
            throw EnteAuthenticatorSyncError.signedOut
        }
    }
}
