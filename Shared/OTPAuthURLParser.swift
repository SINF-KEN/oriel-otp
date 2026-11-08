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
    /// The tags the account is filed under in Ente Auth, in the order they were added.
    let tags: [String]
    /// The icon chosen for the account in Ente Auth, by name, nil to use the one of its issuer.
    let iconID: String?

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
        // The URL's settings win over the object's, like the editor reads them.
        let tags = displays.last { $0["tags"] != nil }?["tags"] as? [String] ?? []
        self.tags = Self.cleaned(tags)
        let iconID = displays.last { $0["iconID"] != nil }?["iconID"] as? String
        self.iconID = iconID.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// Tags without spaces around them, empty ones or the same one twice, ignoring case.
    static func cleaned(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

/// Reads time-based accounts from otpauth URLs.
nonisolated enum OTPAuthURLParser {

    /// The periods accepted, in seconds. Services use 30 or 60 seconds. A day is far longer than any of them uses,
    /// and keeps the period within the range of every integer type it is converted to, where a larger one crashed.
    static let periods = 1...86_400

    /// The parameters that decide the account. A URL that gives one of them twice is rejected, rather than having
    /// each reader pick one of the values.
    static let uniqueParameters: Set = ["secret", "issuer", "counter", "period", "digits", "algorithm"]

    /// The query parameters by lower-cased name, with an empty value for a name without one. Returns nil when a
    /// parameter in `uniqueParameters` appears more than once in any case. Every reader of otpauth URLs goes through
    /// this so they all see the same values.
    static func parameters(of components: URLComponents) -> [String: String]? {
        var parameters = [String: String]()
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            guard parameters[name] == nil else {
                if uniqueParameters.contains(name) { return nil }
                continue
            }
            parameters[name] = item.value ?? ""
        }
        return parameters
    }

    /// The issuer and account name from the label, falling back to the `issuer` parameter. Both are cleaned with
    /// `cleanedName(_:)`, and an empty issuer is nil.
    static func label(of components: URLComponents) -> (issuer: String?, accountName: String) {
        var name = String(components.path.dropFirst())
        var issuer = components.queryItems?.first { $0.name.lowercased() == "issuer" }?.value
        if let colon = name.firstIndex(of: ":") {
            issuer = String(name[..<colon])
            name = String(name[name.index(after: colon)...])
        }
        let cleanedIssuer = issuer.map(cleanedName)
        return (cleanedIssuer?.isEmpty == false ? cleanedIssuer : nil, cleanedName(name))
    }

    /// The name without control characters, line breaks and invisible formatting characters such as direction
    /// overrides and zero-width spaces, and without spaces around it. These would let an account look like another
    /// one, or show its name backwards, while being a different account.
    static func cleanedName(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    /// The path of a label for the issuer and account name, which reads back as the same issuer and account name. An
    /// account name containing a colon gets an empty issuer before it, so the part before its colon isn't read as
    /// the issuer.
    static func labelPath(issuer: String?, accountName: String) -> String {
        let issuer = issuer.flatMap { $0.isEmpty ? nil : $0 }
        if issuer == nil && accountName.contains(":") {
            return "/:" + accountName
        }
        return "/" + [issuer, accountName].compactMap { $0 }.joined(separator: ":")
    }

    /// Returns nil for counter based (HOTP) accounts and URLs that can't be read.
    static func account(id: String, components: URLComponents, isPinned: Bool = false) -> OTPAccount? {
        let kind: OTPAccount.Kind
        switch components.host?.lowercased() {
        case "totp": kind = .totp
        case "steam": kind = .steam
        default: return nil
        }
        guard let items = parameters(of: components),
              let secret = items["secret"].flatMap(base32Decode), !secret.isEmpty else { return nil }

        let algorithm: OTPAccount.Algorithm
        switch items["algorithm"]?.uppercased() ?? "SHA1" {
        case "SHA1", "": algorithm = .sha1
        case "SHA256": algorithm = .sha256
        case "SHA512": algorithm = .sha512
        default: return nil
        }
        let digits = kind == .steam ? 5 : (items["digits"].flatMap { Int($0) } ?? 6)
        let period = items["period"].flatMap { Int($0) } ?? 30
        guard (1...10).contains(digits), periods.contains(period) else { return nil }

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
        // Checked one scalar at a time before changing the case: upper-casing turns some other letters into ASCII
        // ones, e.g. ß into SS, and a letter followed by a combining mark is a single character.
        for scalar in string.unicodeScalars where !" -=".unicodeScalars.contains(scalar) {
            let value: UInt32
            switch scalar {
            case "A"..."Z": value = scalar.value - 65
            case "a"..."z": value = scalar.value - 97
            case "2"..."7": value = scalar.value - 50 + 26
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
