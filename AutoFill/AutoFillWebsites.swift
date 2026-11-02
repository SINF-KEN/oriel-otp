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

import AuthenticationServices
import Foundation

/// The websites an account's codes are suggested on. Ente Auth keeps only an issuer, so the website is guessed from
/// it, and can be changed in the app.
nonisolated enum AutoFillWebsites {

    /// Services whose website isn't the issuer followed by `.com`.
    private static let known: [String: [String]] = [
        "amazonwebservices": ["aws.amazon.com"],
        "aws": ["aws.amazon.com"],
        "battlenet": ["battle.net"],
        "blizzard": ["battle.net"],
        "docker": ["docker.com"],
        "dockerhub": ["docker.com"],
        "ea": ["ea.com"],
        "electronicarts": ["ea.com"],
        "ente": ["ente.io"],
        "enteauth": ["ente.io"],
        "gandi": ["gandi.net"],
        "meta": ["facebook.com"],
        "microsoft": ["microsoft.com", "live.com"],
        "notion": ["notion.so"],
        "npm": ["npmjs.com"],
        "ovh": ["ovh.com"],
        "ovhcloud": ["ovh.com"],
        "playstation": ["playstation.com", "sony.com"],
        "proton": ["proton.me"],
        "protonmail": ["proton.me"],
        "pypi": ["pypi.org"],
        "sony": ["sony.com", "playstation.com"],
        "steam": ["steampowered.com", "steamcommunity.com"],
        "tuta": ["tuta.com"],
        "tutanota": ["tuta.com"],
        "twitch": ["twitch.tv"],
        "twitter": ["x.com", "twitter.com"],
        "x": ["x.com", "twitter.com"],
        "zoom": ["zoom.us"],
    ]

    /// The websites guessed from an issuer: the issuer itself when it is a domain, a known service's, or the issuer's
    /// letters and digits followed by `.com`. Empty when there's nothing to guess from.
    static func guess(issuer: String?) -> [String] {
        guard let issuer = issuer?.trimmingCharacters(in: .whitespacesAndNewlines), !issuer.isEmpty else { return [] }
        if !issuer.contains(" "), issuer.contains("."), let website = normalized(issuer) {
            return [website]
        }
        let name = String(issuer.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
        if let websites = known[name] { return websites }
        // Not a name that can be a domain, e.g. one in another script.
        guard name.count >= 2, issuer.unicodeScalars.allSatisfy(\.isASCII) else { return [] }
        return [name + ".com"]
    }

    /// The domain in what was typed, e.g. `github.com` for `https://www.GitHub.com/login`. Nil if it isn't one.
    static func normalized(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var host = URLComponents(string: text)?.host, !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return host
    }

    /// Whether a website the system asks for, e.g. `accounts.example.com`, is `website` or one of its subdomains.
    static func matches(host: String, website: String) -> Bool {
        let host = host.lowercased()
        return host == website || host.hasSuffix("." + website)
    }

    /// The host of a website or app the system asks for a code for.
    static func host(of serviceIdentifier: ASCredentialServiceIdentifier) -> String? {
        switch serviceIdentifier.type {
        case .domain:
            return normalized(serviceIdentifier.identifier)
        case .URL:
            return URLComponents(string: serviceIdentifier.identifier)?.host.flatMap(normalized)
        default:
            return nil
        }
    }

    /// The accounts suggested for the websites the system asks for, most specific first, then the other accounts.
    static func sorted(_ accounts: [AutoFillAccount], for serviceIdentifiers: [ASCredentialServiceIdentifier])
        -> (matching: [AutoFillAccount], others: [AutoFillAccount]) {
        let hosts = serviceIdentifiers.compactMap(host(of:))
        let ordered = accounts.sorted { OTPAccount.listOrder($0.account, $1.account) }
        // The first host an account matches, then its longest website that does, e.g. m.example.com before example.com.
        func rank(_ account: AutoFillAccount) -> (host: Int, length: Int)? {
            for (index, host) in hosts.enumerated() {
                let lengths = account.websites.filter { matches(host: host, website: $0) }.map(\.count)
                if let length = lengths.max() { return (index, length) }
            }
            return nil
        }
        let matching = ordered.compactMap { account in rank(account).map { (account, $0) } }
            .sorted { ($0.1.host, -$0.1.length) < ($1.1.host, -$1.1.length) }
            .map(\.0)
        return (matching, ordered.filter { rank($0) == nil })
    }
}

/// The accounts' websites in the system's list of AutoFill suggestions.
nonisolated enum AutoFillIdentities {

    static func identities(for accounts: [AutoFillAccount]) -> [ASOneTimeCodeCredentialIdentity] {
        accounts.flatMap { account in
            let label = account.account.subtitle.map { "\(account.account.title) (\($0))" } ?? account.account.title
            return account.websites.map { website in
                ASOneTimeCodeCredentialIdentity(serviceIdentifier: ASCredentialServiceIdentifier(identifier: website, type: .domain),
                                                label: label, recordIdentifier: account.id)
            }
        }
    }

    /// Replaces the suggestions with the accounts', if AutoFill from Oriel OTP is on. Returns whether it is.
    @discardableResult static func replace(with accounts: [AutoFillAccount]) async -> Bool {
        let store = ASCredentialIdentityStore.shared
        guard await store.state().isEnabled else { return false }
        try? await store.replaceCredentialIdentities(identities(for: accounts))
        return true
    }
}
