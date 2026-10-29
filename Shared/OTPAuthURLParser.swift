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

/// The decrypted data of an Ente Auth entity, without Ente's encryption or YubiKit.
///
/// Ente Auth stores either a JSON string holding an otpauth URL, with Ente's display settings in a
/// `codeDisplay` query parameter, or a JSON object with the URL in `rawData` and the settings in `display`.
nonisolated struct EnteEntry: Sendable, Equatable {
    /// The otpauth URL, nil if the data can't be read.
    let components: URLComponents?
    let isTrashed: Bool
    let isPinned: Bool

    init(rawData: String) {
        var urlString: String?
        var displays = [[String: Any]]()
        if let json = try? JSONSerialization.jsonObject(with: Data(rawData.utf8), options: .fragmentsAllowed) {
            if let string = json as? String {
                urlString = string
            } else if let object = json as? [String: Any] {
                urlString = object["rawData"] as? String
                if let display = object["display"] as? [String: Any] { displays.append(display) }
            }
        } else if rawData.hasPrefix("otpauth://") {
            urlString = rawData
        }

        // Ente's apps escape '#' the same way before parsing, it is common in issuers and account names.
        if let urlString, let components = URLComponents(string: urlString.replacingOccurrences(of: "#", with: "%23")),
            components.scheme?.lowercased() == "otpauth"
        {
            self.components = components
            if let codeDisplay = components.queryItems?.first(where: { $0.name == "codeDisplay" })?.value,
                let display = try? JSONSerialization.jsonObject(with: Data(codeDisplay.utf8)) as? [String: Any]
            {
                displays.append(display)
            }
        } else {
            self.components = nil
        }
        isTrashed = displays.contains { $0["trashed"] as? Bool == true }
        isPinned = displays.contains { $0["pinned"] as? Bool == true }
    }
}

/// Reads time-based accounts from otpauth URLs.
nonisolated enum OTPAuthURLParser {

    /// The issuer and account name from the label, falling back to the `issuer` parameter.
    static func label(of components: URLComponents) -> (issuer: String?, accountName: String) {
        var name = String(components.path.dropFirst())
        var issuer = components.queryItems?.first { $0.name == "issuer" }?.value
        if let colon = name.firstIndex(of: ":") {
            issuer = String(name[..<colon])
            name = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return (issuer, name)
    }

    /// Returns nil for counter based (HOTP) accounts and URLs that can't be read.
    static func account(id: String, components: URLComponents, isPinned: Bool = false) -> OTPAccount? {
        let kind: OTPAccount.Kind
        switch components.host?.lowercased() {
        case "totp": kind = .totp
        case "steam": kind = .steam
        default: return nil
        }
        let items = Dictionary(
            components.queryItems?.map { ($0.name.lowercased(), $0.value ?? "") } ?? [],
            uniquingKeysWith: { first, _ in first })
        guard let secret = items["secret"].flatMap(base32Decode), !secret.isEmpty else { return nil }

        let algorithm: OTPAccount.Algorithm
        switch items["algorithm"]?.uppercased() ?? "SHA1" {
        case "SHA1", "": algorithm = .sha1
        case "SHA256": algorithm = .sha256
        case "SHA512": algorithm = .sha512
        default: return nil
        }
        let digits = kind == .steam ? 5 : (items["digits"].flatMap { Int($0) } ?? 6)
        let period = items["period"].flatMap { Int($0) } ?? 30
        guard (1...10).contains(digits), period > 0 else { return nil }

        var (issuer, accountName) = label(of: components)
        if kind == .steam {
            issuer = "Steam"
        }
        return OTPAccount(
            id: id, kind: kind, issuer: issuer, accountName: accountName, secret: secret,
            algorithm: algorithm, digits: digits, period: period, isPinned: isPinned)
    }

    /// Decodes RFC 4648 base32, ignoring case, spaces, dashes and padding. Returns nil for other characters.
    static func base32Decode(_ string: String) -> Data? {
        var bytes = [UInt8]()
        var buffer: UInt32 = 0
        var bits = 0
        for character in string.uppercased() where !" -=".contains(character) {
            guard let ascii = character.asciiValue else { return nil }
            let value: UInt32
            switch ascii {
            case 65...90: value = UInt32(ascii - 65)
            case 50...55: value = UInt32(ascii - 50 + 26)
            default: return nil
            }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt32(bits)) & 0xff))
            }
        }
        return Data(bytes)
    }
}
