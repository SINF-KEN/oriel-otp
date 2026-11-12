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
nonisolated struct EnteCode: Identifiable, Sendable {
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
        return OATHCredentialId.key(
            accountName: template.name, issuer: template.issuer,
            period: UInt(template.type.period ?? 0), isTOTP: template.type.period != nil)
    }
}

nonisolated enum EnteCodeParser {

    /// Parses the decrypted data of an authenticator entity. Returns nil for accounts that are in Ente's trash.
    static func parse(id: String, rawData: String) -> EnteCode? {
        let entry = EnteEntry(rawData: rawData)
        guard var components = entry.components else {
            return EnteCode(
                id: id, issuer: nil, accountName: String(localized: "Unknown account", comment: "Ente import unreadable account"),
                template: nil,
                unsupportedReason: String(localized: "This account could not be read.", comment: "Ente import unreadable account"))
        }
        guard !entry.isTrashed else { return nil }

        let otpAccount = OTPAuthURLParser.account(id: id, components: components, isPinned: entry.isPinned)
        let (issuer, accountName) = OTPAuthURLParser.label(of: components)
        do {
            let template: YubiKitOATHSession.CredentialTemplate
            if components.host?.lowercased() == "steam" {
                // A Steam account is a TOTP account that the app recognizes by its issuer and shows as 5 characters.
                components.host = "totp"
                components.queryItems = components.queryItems?.filter { $0.name.lowercased() != "digits" }
                guard let url = components.url else { throw CredentialTemplateError.type }
                let parsed = try YubiKitOATHSession.CredentialTemplate(otpauthURL: url)
                template = try YubiKitOATHSession.CredentialTemplate(
                    type: parsed.type, algorithm: parsed.algorithm, secret: parsed.secret,
                    issuer: "Steam", accountName: parsed.name, digits: 6)
            } else {
                components.host = components.host?.lowercased()
                guard let url = components.url else { throw CredentialTemplateError.type }
                template = try YubiKitOATHSession.CredentialTemplate(otpauthURL: url)
            }
            return EnteCode(
                id: id, issuer: template.issuer, accountName: template.name, template: template, unsupportedReason: nil,
                otpAccount: otpAccount)
        } catch {
            return EnteCode(
                id: id, issuer: issuer, accountName: accountName, template: nil, unsupportedReason: error.localizedDescription,
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
        components.path = OTPAuthURLParser.labelPath(issuer: issuer, accountName: template.name)

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
        case .totp(let period):
            // A template can be made with any period, and converting one that isn't a whole Int traps.
            guard let period = Int(exactly: period) else { return nil }
            items.append(URLQueryItem(name: "period", value: String(period)))
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

/// Reads the accounts stored in Ente Auth, and encrypts and decrypts them. The vault (`EnteVault`) uses it to keep a
/// copy on the device and to write changes back.
nonisolated enum EnteAuthenticatorSync {

    static let pageSize = 500
    /// The largest page asked for, when the server fills a whole page with entities changed at one time.
    static let maxPageSize = 8_000
    /// The most diff requests one sync makes: 500,000 entities at full pages, far more than anyone keeps.
    static let maxPages = 1_000
    /// How far past the device's clock, in microseconds, an entity's `updatedAt` may be: a year, for a device whose
    /// clock is wrong.
    static let maxClockSkew: Int64 = 366 * 24 * 3600 * 1_000_000

    /// Whether an `updatedAt`, in microseconds, is no further past the device's clock than `maxClockSkew`.
    static func isPlausible(updatedAt: Int64) -> Bool {
        updatedAt <= Int64(Date().timeIntervalSince1970 * 1_000_000) + maxClockSkew
    }

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
                try await api.createAuthenticatorKey(
                    token: keys.token, encryptedKey: encrypted.cipherText.base64EncodedString(),
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
            let authenticatorKey = try? EnteCrypto.secretBoxOpen(encryptedKey, nonce: nonce, key: keys.masterKey)
        else {
            throw EnteAuthenticatorSyncError.invalidKey
        }
        return authenticatorKey
    }

    /// Downloads all entities and returns the accounts that aren't deleted or trashed, sorted like the account list.
    @MainActor static func codes(api: EnteAPIClient, token: String, authenticatorKey: Data) async throws -> [EnteCode] {
        try await decryptedEntities(api: api, token: token, authenticatorKey: authenticatorKey)
            .compactMap { id, rawData -> EnteCode? in
                guard let rawData else {
                    return EnteCode(
                        id: id, issuer: nil, accountName: String(localized: "Unknown account", comment: "Ente import unreadable account"),
                        template: nil,
                        unsupportedReason: String(
                            localized: "This account could not be decrypted.", comment: "Ente import undecryptable account"))
                }
                return EnteCodeParser.parse(id: id, rawData: rawData)
            }
            .sorted { ($0.title.lowercased(), $0.accountName.lowercased()) < ($1.title.lowercased(), $1.accountName.lowercased()) }
    }

    /// Returns the decrypted data of each entity, nil for an entity that couldn't be decrypted.
    @concurrent static func decryptedEntities(api: EnteAPIClient, token: String, authenticatorKey: Data) async throws -> [(
        id: String, rawData: String?
    )] {
        try await allEntities(api: api, token: token).map { ($0.id, decrypt($0, authenticatorKey: authenticatorKey)) }
    }

    /// The plain text of an entity, nil if it is deleted or couldn't be decrypted.
    static func decrypt(_ entity: EnteAuthenticatorEntity, authenticatorKey: Data) -> String? {
        guard let encryptedData = entity.encryptedData.flatMap({ Data(enteBase64: $0) }),
            let header = entity.header.flatMap({ Data(enteBase64: $0) }),
            let decrypted = try? EnteCrypto.secretStreamDecrypt(encryptedData, header: header, key: authenticatorKey)
        else {
            return nil
        }
        return String(data: decrypted, encoding: .utf8)
    }

    /// Encrypts the plain text of an entity, returning the cipher text and header the way the API takes them.
    static func encrypt(_ rawData: String, authenticatorKey: Data) throws -> (encryptedData: String, header: String) {
        let (header, cipherText) = try EnteCrypto.secretStreamEncrypt(Data(rawData.utf8), key: authenticatorKey)
        return (cipherText.base64EncodedString(), header.base64EncodedString())
    }

    /// Pages through the diff from the beginning and keeps the latest version of each entity.
    static func allEntities(api: EnteAPIClient, token: String) async throws -> [EnteAuthenticatorEntity] {
        try await changes(api: api, token: token, since: 0).entities.filter { !$0.isDeleted }
    }

    /// Pages through the diff from `sinceTime` and keeps the latest version of each entity that changed, deleted
    /// ones included. Returns them with the time to ask from next time, which is `sinceTime` if nothing changed.
    ///
    /// Ente's server returns the entities changed after `sinceTime`, oldest first, up to `limit`, and a self-hosted
    /// server may return fewer than asked for. So paging only stops on an empty page. Entities changed at the same
    /// time can straddle two pages, so after a page with something new it asks again from just before the page's
    /// latest time and drops the versions it already has. Each request either moves `sinceTime` forward, brings
    /// something new or asks for a larger page. A server can still keep bringing new entities, so paging stops with
    /// an error after `maxPages` requests.
    ///
    /// When the server fills the page it was asked for with entities changed at one time, all seen before, there may
    /// be more of them than fit the page, which no `sinceTime` can reach. It then asks for the same again with a
    /// larger page, up to `maxPageSize`, and fails beyond that. A server that returns fewer entities than asked for
    /// and has more of them at one time than it returns gives no sign of it when nothing changed later: those are
    /// left out, as this API has no way to ask for them.
    ///
    /// An entity with an `updatedAt` of 0 or less could never be asked for again, so such an answer is refused.
    static func changes(api: EnteAPIClient, token: String, since sinceTime: Int64) async throws -> (
        entities: [EnteAuthenticatorEntity], latest: Int64
    ) {
        var latest = [String: EnteAuthenticatorEntity]()
        var sinceTime = sinceTime
        var largestPage = 0
        // Set after a page made only of entities changed at one time, all seen before, and as large as the largest
        // page: the server may have more entities changed at that time than fit a page. If more entities follow,
        // some of those may be missing, and asking again can't get them.
        var fullPageAtOneTime = false
        // `updatedAt` is in microseconds. A time far past the device's clock would become the time every later sync
        // asks from, and nothing changed after it would ever be pulled.
        // A time saved before this check could be one of those: pulling everything again settles it.
        if !isPlausible(updatedAt: sinceTime) {
            sinceTime = 0
        }
        var pages = 0
        var limit = pageSize
        while true {
            try Task.checkCancellation()
            pages += 1
            guard pages <= maxPages else { throw EnteAPIError.invalidResponse }
            let response = try await signedIn { try await api.authenticatorDiff(token: token, sinceTime: sinceTime, limit: limit) }
            guard response.allSatisfy({ $0.updatedAt > 0 && isPlausible(updatedAt: $0.updatedAt) }) else {
                throw EnteAPIError.invalidResponse
            }
            // Ignores anything at or before `sinceTime`, so every page that is kept moves forward.
            let page = response.filter { $0.updatedAt > sinceTime }
            guard let maxUpdatedAt = page.map(\.updatedAt).max() else { break }
            // Entities changed at the time of a full page may be missing, and asking again can't get them: stops
            // with an error rather than go on without them.
            if fullPageAtOneTime { throw EnteAPIError.invalidResponse }
            largestPage = max(largestPage, page.count)
            var foundNew = false
            for entity in page where entity.updatedAt > latest[entity.id]?.updatedAt ?? .min {
                latest[entity.id] = entity
                foundNew = true
            }
            if foundNew {
                // Asks again from just before the latest time, for entities changed then that didn't fit this page.
                sinceTime = maxUpdatedAt - 1
                fullPageAtOneTime = false
            } else {
                if page.allSatisfy({ $0.updatedAt == maxUpdatedAt }) {
                    if response.count >= limit {
                        // As many as asked for, so there may be more changed at that time: asks again for more.
                        guard limit < maxPageSize else { throw EnteAPIError.invalidResponse }
                        limit = min(limit * 4, maxPageSize)
                        continue
                    }
                    if page.count == largestPage {
                        fullPageAtOneTime = true
                    }
                }
                sinceTime = maxUpdatedAt
            }
        }
        return (Array(latest.values), max(sinceTime, latest.values.map(\.updatedAt).max() ?? sinceTime))
    }

    static func signedIn<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch EnteAPIError.http(statusCode: 401) {
            throw EnteAuthenticatorSyncError.signedOut
        }
    }
}
