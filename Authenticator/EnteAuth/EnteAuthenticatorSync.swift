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
    ///
    /// Ente Auth stores either a JSON string holding an otpauth URL, with Ente's display settings in a
    /// `codeDisplay` query parameter, or a JSON object with the URL in `rawData` and the settings in `display`.
    static func parse(id: String, rawData: String) -> EnteCode? {
        var urlString: String?
        var isTrashed = false
        if let json = try? JSONSerialization.jsonObject(with: Data(rawData.utf8), options: .fragmentsAllowed) {
            if let string = json as? String {
                urlString = string
            } else if let object = json as? [String: Any] {
                urlString = object["rawData"] as? String
                isTrashed = (object["display"] as? [String: Any])?["trashed"] as? Bool ?? false
            }
        } else if rawData.hasPrefix("otpauth://") {
            urlString = rawData
        }

        // Ente's apps escape '#' the same way before parsing, it is common in issuers and account names.
        guard let urlString, var components = URLComponents(string: urlString.replacingOccurrences(of: "#", with: "%23")),
              components.scheme?.lowercased() == "otpauth" else {
            return EnteCode(id: id, issuer: nil, accountName: String(localized: "Unknown account", comment: "Ente import unreadable account"),
                            template: nil, unsupportedReason: String(localized: "This account could not be read.", comment: "Ente import unreadable account"))
        }

        if let codeDisplay = components.queryItems?.first(where: { $0.name == "codeDisplay" })?.value,
           let display = try? JSONSerialization.jsonObject(with: Data(codeDisplay.utf8)) as? [String: Any],
           display["trashed"] as? Bool == true {
            isTrashed = true
        }
        guard !isTrashed else { return nil }

        let (issuer, accountName) = label(of: components)
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
            return EnteCode(id: id, issuer: template.issuer, accountName: template.name, template: template, unsupportedReason: nil)
        } catch {
            return EnteCode(id: id, issuer: issuer, accountName: accountName, template: nil, unsupportedReason: error.localizedDescription)
        }
    }

    private static func label(of components: URLComponents) -> (issuer: String?, accountName: String) {
        var name = String(components.path.dropFirst())
        var issuer = components.queryItems?.first { $0.name == "issuer" }?.value
        if let colon = name.firstIndex(of: ":") {
            issuer = String(name[..<colon])
            name = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return (issuer, name)
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

/// Reads the accounts stored in Ente Auth. This is read only, nothing is changed on Ente's server.
nonisolated enum EnteAuthenticatorSync {

    static let pageSize = 500

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

    private static func signedIn<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch EnteAPIError.http(statusCode: 401) {
            throw EnteAuthenticatorSyncError.signedOut
        }
    }
}
