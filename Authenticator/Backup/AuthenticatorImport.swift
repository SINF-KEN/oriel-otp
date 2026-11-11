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

enum AuthenticatorImportError: Error, LocalizedError, Equatable {
    /// Not an export this app reads.
    case unknownFormat
    /// An export that is encrypted, which this app can't open yet. Names the app.
    case encrypted(app: String)
    /// A file this app reads, without any account in it.
    case noAccounts

    var errorDescription: String? {
        switch self {
        case .unknownFormat:
            String(localized: "This file isn't an export this app can read. Export from Google Authenticator, Aegis, 2FAS or Raivo, or choose a text file of otpauth links.", comment: "Import error")
        case .encrypted(let app):
            String(localized: "This \(app) export is encrypted. Export it again without encryption, import it, then delete the file.", comment: "Import error. The placeholder is the name of another authenticator app, e.g. Aegis.")
        case .noAccounts:
            String(localized: "There are no accounts in this file.", comment: "Import error")
        }
    }
}

/// Reads the accounts exported by other authenticator apps, as otpauth URLs for `DeviceAccounts.restore`:
///
/// - Google Authenticator's export QR codes, `otpauth-migration://offline?data=…`, which hold several accounts each;
/// - Aegis's plain JSON export (`{"version": 1, "header": {"slots": null, …}, "db": {"entries": […]}}`);
/// - 2FAS's `.2fas` file without a password (`{"services": […], "schemaVersion": …}`);
/// - Raivo's JSON (`[{"issuer": …, "account": …, "secret": …, "kind": "TOTP", …}]`);
/// - text with one otpauth or otpauth-migration link per line, e.g. Ente Auth's plain export.
///
/// Encrypted exports are recognized and turned down with a message that says how to export without encryption.
nonisolated enum AuthenticatorImport {

    /// Larger files aren't read. An account takes a few hundred bytes.
    static let maximumFileSize = 8 * 1024 * 1024

    /// The otpauth URLs of the accounts in an export.
    static func otpauthURLs(from data: Data) throws -> [String] {
        guard data.count <= maximumFileSize else { throw AuthenticatorImportError.unknownFormat }
        let urls: [String]
        if let json = try? JSONSerialization.jsonObject(with: data) {
            urls = try otpauthURLs(fromJSON: json)
        } else if let text = String(data: data, encoding: .utf8) {
            urls = try otpauthURLs(fromText: text)
        } else {
            throw AuthenticatorImportError.unknownFormat
        }
        guard !urls.isEmpty else { throw AuthenticatorImportError.noAccounts }
        return urls
    }

    /// The otpauth URLs in text, one link a line, e.g. scanned from a QR code. Lines that are neither otpauth nor
    /// otpauth-migration links are ignored.
    static func otpauthURLs(fromText text: String) throws -> [String] {
        var urls: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            let lowercased = line.lowercased()
            if lowercased.hasPrefix("otpauth-migration://") {
                urls += try GoogleAuthenticatorMigration.otpauthURLs(fromLink: line)
            } else if lowercased.hasPrefix("otpauth://") {
                urls.append(line)
            }
        }
        return urls
    }

    /// Whether a scanned QR code is one of Google Authenticator's exports.
    static func isMigrationLink(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("otpauth-migration://")
    }

    private static func otpauthURLs(fromJSON json: Any) throws -> [String] {
        if let object = json as? [String: Any] {
            if object["db"] != nil, let header = object["header"] as? [String: Any] {
                return try aegis(object, header: header)
            }
            if object["services"] != nil || object["servicesEncrypted"] != nil {
                return try twoFAS(object)
            }
            if object["reference"] != nil, object["data"] != nil {
                // Raivo's encrypted export.
                throw AuthenticatorImportError.encrypted(app: "Raivo")
            }
        }
        if let entries = json as? [[String: Any]], entries.contains(where: { $0["secret"] != nil && $0["kind"] != nil }) {
            return raivo(entries)
        }
        throw AuthenticatorImportError.unknownFormat
    }

    // MARK: - Aegis

    private static func aegis(_ object: [String: Any], header: [String: Any]) throws -> [String] {
        // An encrypted vault has key slots and its database as a Base64 string.
        guard header["slots"] == nil || header["slots"] is NSNull, let db = object["db"] as? [String: Any] else {
            throw AuthenticatorImportError.encrypted(app: "Aegis")
        }
        let entries = db["entries"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let info = entry["info"] as? [String: Any], let secret = info["secret"] as? String else { return nil }
            let type = (entry["type"] as? String)?.lowercased() ?? "totp"
            guard ["totp", "hotp", "steam"].contains(type) else { return nil }
            return otpauthURL(type: type, issuer: entry["issuer"] as? String, name: entry["name"] as? String, secret: secret,
                              algorithm: info["algo"] as? String, digits: integer(info["digits"]),
                              period: integer(info["period"]), counter: integer(info["counter"]))
        }
    }

    // MARK: - 2FAS

    private static func twoFAS(_ object: [String: Any]) throws -> [String] {
        let services = object["services"] as? [[String: Any]] ?? []
        if services.isEmpty, let encrypted = object["servicesEncrypted"] as? String, !encrypted.isEmpty {
            throw AuthenticatorImportError.encrypted(app: "2FAS")
        }
        return services.compactMap { service in
            guard let secret = service["secret"] as? String else { return nil }
            let otp = service["otp"] as? [String: Any] ?? [:]
            let type = (otp["tokenType"] as? String)?.lowercased() ?? "totp"
            guard ["totp", "hotp", "steam"].contains(type) else { return nil }
            let issuer = (otp["issuer"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? service["name"] as? String
            return otpauthURL(type: type, issuer: issuer, name: otp["account"] as? String ?? otp["label"] as? String, secret: secret,
                              algorithm: otp["algorithm"] as? String, digits: integer(otp["digits"]),
                              period: integer(otp["period"]), counter: integer(otp["counter"]))
        }
    }

    // MARK: - Raivo

    private static func raivo(_ entries: [[String: Any]]) -> [String] {
        entries.compactMap { entry in
            guard let secret = entry["secret"] as? String else { return nil }
            let type = (entry["kind"] as? String)?.lowercased() ?? "totp"
            guard ["totp", "hotp"].contains(type) else { return nil }
            return otpauthURL(type: type, issuer: entry["issuer"] as? String, name: entry["account"] as? String, secret: secret,
                              algorithm: entry["algorithm"] as? String, digits: integer(entry["digits"]),
                              period: integer(entry["timer"]), counter: integer(entry["counter"]))
        }
    }

    // MARK: - URLs

    /// Numbers come as numbers or as strings, depending on the app and its version.
    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let string as String: Int(string)
        default: nil
        }
    }

    /// An otpauth URL in the form every authenticator reads: the label is "issuer:name", and the issuer is repeated
    /// as a parameter. Default values are left out.
    static func otpauthURL(type: String, issuer: String?, name: String?, secret: String, algorithm: String?,
                           digits: Int?, period: Int?, counter: Int?) -> String? {
        let secret = secret.uppercased().filter { !" -=".contains($0) }
        guard !secret.isEmpty, OTPAuthURLParser.base32Decode(secret) != nil else { return nil }
        let issuer = issuer?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let name = name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        var components = URLComponents()
        components.scheme = "otpauth"
        components.host = type == "steam" ? "totp" : type
        // A colon in either name would split the label in the wrong place.
        let labelParts = [issuer, name ?? issuer ?? ""].compactMap { $0?.replacingOccurrences(of: ":", with: " ") }
        components.path = "/" + labelParts.joined(separator: ":")
        var items = [URLQueryItem(name: "secret", value: secret)]
        if let issuer {
            items.append(URLQueryItem(name: "issuer", value: type == "steam" ? "Steam" : issuer))
        } else if type == "steam" {
            items.append(URLQueryItem(name: "issuer", value: "Steam"))
        }
        if let algorithm = algorithm?.uppercased().replacingOccurrences(of: "-", with: ""), algorithm != "SHA1",
           ["SHA256", "SHA512"].contains(algorithm) {
            items.append(URLQueryItem(name: "algorithm", value: algorithm))
        }
        if let digits, digits != 6, type != "steam" {
            items.append(URLQueryItem(name: "digits", value: String(digits)))
        }
        if type != "hotp", let period, period > 0, period != 30 {
            items.append(URLQueryItem(name: "period", value: String(period)))
        }
        if type == "hotp" {
            items.append(URLQueryItem(name: "counter", value: String(max(counter ?? 0, 0))))
        }
        components.queryItems = items
        // `+` in a query reads as a space in some parsers.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.string
    }
}

/// Google Authenticator's export: `otpauth-migration://offline?data=<Base64>`, a protocol buffer of this shape:
///
///     message MigrationPayload {
///       repeated OtpParameters otp_parameters = 1;
///       int32 version = 2; int32 batch_size = 3; int32 batch_index = 4; int32 batch_id = 5;
///     }
///     message OtpParameters {
///       bytes secret = 1; string name = 2; string issuer = 3;
///       Algorithm algorithm = 4;  // 1 SHA1, 2 SHA256, 3 SHA512, 4 MD5
///       DigitCount digits = 5;    // 1 six, 2 eight
///       OtpType type = 6;         // 1 HOTP, 2 TOTP
///       int64 counter = 7;
///     }
nonisolated enum GoogleAuthenticatorMigration {

    static func otpauthURLs(fromLink link: String) throws -> [String] {
        guard let components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "otpauth-migration",
              let encoded = components.queryItems?.first(where: { $0.name == "data" })?.value,
              let payload = Data(base64Encoded: base64Padded(encoded)) else {
            throw AuthenticatorImportError.unknownFormat
        }
        return try accounts(inPayload: payload).compactMap(\.otpauthURL)
    }

    struct Account: Equatable {
        var secret = Data()
        var name = ""
        var issuer = ""
        var algorithm = 0
        var digits = 0
        var type = 0
        var counter: Int64 = 0

        var otpauthURL: String? {
            let type = switch type {
            case 1: "hotp"
            case 2, 0: "totp"
            default: ""
            }
            guard !type.isEmpty, !secret.isEmpty else { return nil }
            let algorithm: String? = switch algorithm {
            case 2: "SHA256"
            case 3: "SHA512"
            case 0, 1: nil
            default: "unsupported"
            }
            // MD5 isn't an algorithm the app calculates.
            guard algorithm != "unsupported" else { return nil }
            // A name may start with the issuer, e.g. "GitHub:alice", like the label of an otpauth URL.
            var name = name
            if !issuer.isEmpty, name.hasPrefix(issuer + ":") {
                name = String(name.dropFirst(issuer.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            return AuthenticatorImport.otpauthURL(type: type, issuer: issuer, name: name, secret: Self.base32(secret),
                                                  algorithm: algorithm, digits: digits == 2 ? 8 : 6, period: 30,
                                                  counter: Int(clamping: counter))
        }

        private static func base32(_ data: Data) -> String {
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
            var result = ""
            var buffer: UInt32 = 0
            var bits = 0
            for byte in data {
                buffer = (buffer << 8) | UInt32(byte)
                bits += 8
                while bits >= 5 {
                    bits -= 5
                    result.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
                }
            }
            if bits > 0 {
                result.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)])
            }
            return result
        }
    }

    static func accounts(inPayload payload: Data) throws -> [Account] {
        var reader = ProtobufReader(data: payload)
        var accounts: [Account] = []
        while let (field, value) = try reader.next() {
            if field == 1, case .bytes(let bytes) = value {
                accounts.append(try account(from: bytes))
            }
        }
        return accounts
    }

    private static func account(from data: Data) throws -> Account {
        var reader = ProtobufReader(data: data)
        var account = Account()
        while let (field, value) = try reader.next() {
            switch (field, value) {
            case (1, .bytes(let bytes)): account.secret = bytes
            case (2, .bytes(let bytes)): account.name = String(decoding: bytes, as: UTF8.self)
            case (3, .bytes(let bytes)): account.issuer = String(decoding: bytes, as: UTF8.self)
            case (4, .varint(let number)): account.algorithm = Int(clamping: number)
            case (5, .varint(let number)): account.digits = Int(clamping: number)
            case (6, .varint(let number)): account.type = Int(clamping: number)
            case (7, .varint(let number)): account.counter = Int64(bitPattern: number)
            default: break
            }
        }
        return account
    }

    /// Google leaves out the padding, and a link copied from a QR code reader may have `+` turned into a space.
    private static func base64Padded(_ string: String) -> String {
        var string = string.replacingOccurrences(of: " ", with: "+").replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        string += String(repeating: "=", count: (4 - string.count % 4) % 4)
        return string
    }
}

/// Reads the fields of a protocol buffer message, enough for Google Authenticator's export.
nonisolated struct ProtobufReader {

    enum Value: Equatable {
        case varint(UInt64)
        case bytes(Data)
        case fixed
    }

    struct Malformed: Error {}

    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = [UInt8](data)
    }

    /// The next field number and value, nil at the end.
    mutating func next() throws -> (Int, Value)? {
        guard index < bytes.count else { return nil }
        let key = try varint()
        let field = Int(key >> 3)
        switch key & 7 {
        case 0:
            return (field, .varint(try varint()))
        case 1:
            try skip(8)
            return (field, .fixed)
        case 2:
            let length = try varint()
            guard length <= UInt64(bytes.count - index) else { throw Malformed() }
            let start = index
            index += Int(length)
            return (field, .bytes(Data(bytes[start..<index])))
        case 5:
            try skip(4)
            return (field, .fixed)
        default:
            throw Malformed()
        }
    }

    private mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count, shift < 64 else { throw Malformed() }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private mutating func skip(_ count: Int) throws {
        guard count <= bytes.count - index else { throw Malformed() }
        index += count
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
