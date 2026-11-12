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

/// The websites an account's codes are suggested on. Ente Auth keeps only an issuer, so the website is taken from it
/// when it is a domain or a known service, and can be changed in the app. A website made up from a name is only offered
/// in the app, for the user to confirm.
nonisolated enum AutoFillWebsites {

    /// Services whose website is known, so their codes are suggested there without asking.
    private static let known: [String: [String]] = [
        "1password": ["1password.com"],
        "adobe": ["adobe.com"],
        "airbnb": ["airbnb.com"],
        "amazon": ["amazon.com"],
        "amazonwebservices": ["aws.amazon.com"],
        "apple": ["apple.com", "icloud.com"],
        "appleid": ["apple.com", "icloud.com"],
        "asana": ["asana.com"],
        "atlassian": ["atlassian.com"],
        "aws": ["aws.amazon.com"],
        "battlenet": ["battle.net"],
        "binance": ["binance.com"],
        "bitbucket": ["bitbucket.org"],
        "bitwarden": ["bitwarden.com"],
        "blizzard": ["battle.net"],
        "box": ["box.com"],
        "cloudflare": ["cloudflare.com"],
        "codeberg": ["codeberg.org"],
        "coinbase": ["coinbase.com"],
        "dashlane": ["dashlane.com"],
        "digitalocean": ["digitalocean.com"],
        "discord": ["discord.com"],
        "docker": ["docker.com"],
        "dockerhub": ["docker.com"],
        "dropbox": ["dropbox.com"],
        "ea": ["ea.com"],
        "ebay": ["ebay.com"],
        "electronicarts": ["ea.com"],
        "ente": ["ente.io"],
        "enteauth": ["ente.io"],
        "epicgames": ["epicgames.com"],
        "etsy": ["etsy.com"],
        "evernote": ["evernote.com"],
        "facebook": ["facebook.com"],
        "fastmail": ["fastmail.com"],
        "figma": ["figma.com"],
        "gandi": ["gandi.net"],
        "github": ["github.com"],
        "gitlab": ["gitlab.com"],
        "gmail": ["google.com"],
        "godaddy": ["godaddy.com"],
        "google": ["google.com"],
        "heroku": ["heroku.com"],
        "hetzner": ["hetzner.com"],
        "huggingface": ["huggingface.co"],
        "instagram": ["instagram.com"],
        "kickstarter": ["kickstarter.com"],
        "kraken": ["kraken.com"],
        "lastpass": ["lastpass.com"],
        "linkedin": ["linkedin.com"],
        "linode": ["linode.com"],
        "mailchimp": ["mailchimp.com"],
        "meta": ["facebook.com"],
        "microsoft": ["microsoft.com", "live.com"],
        "namecheap": ["namecheap.com"],
        "netlify": ["netlify.com"],
        "nintendo": ["nintendo.com"],
        "notion": ["notion.so"],
        "npm": ["npmjs.com"],
        "openai": ["openai.com"],
        "outlook": ["live.com", "microsoft.com"],
        "ovh": ["ovh.com"],
        "ovhcloud": ["ovh.com"],
        "patreon": ["patreon.com"],
        "paypal": ["paypal.com"],
        "pinterest": ["pinterest.com"],
        "playstation": ["playstation.com", "sony.com"],
        "porkbun": ["porkbun.com"],
        "proton": ["proton.me"],
        "protonmail": ["proton.me"],
        "pypi": ["pypi.org"],
        "reddit": ["reddit.com"],
        "revolut": ["revolut.com"],
        "robinhood": ["robinhood.com"],
        "roblox": ["roblox.com"],
        "shopify": ["shopify.com"],
        "slack": ["slack.com"],
        "snapchat": ["snapchat.com"],
        "sony": ["sony.com", "playstation.com"],
        "steam": ["steampowered.com", "steamcommunity.com"],
        "stripe": ["stripe.com"],
        "tiktok": ["tiktok.com"],
        "trello": ["trello.com"],
        "tumblr": ["tumblr.com"],
        "tuta": ["tuta.com"],
        "tutanota": ["tuta.com"],
        "twilio": ["twilio.com"],
        "twitch": ["twitch.tv"],
        "twitter": ["x.com", "twitter.com"],
        "uber": ["uber.com"],
        "ubisoft": ["ubisoft.com"],
        "vercel": ["vercel.com"],
        "wise": ["wise.com"],
        "wordpress": ["wordpress.com"],
        "x": ["x.com", "twitter.com"],
        "yahoo": ["yahoo.com"],
        "zoho": ["zoho.com"],
        "zoom": ["zoom.us"]
    ]

    /// Suffixes under which anyone can register a name, e.g. `co.uk` or `github.io`. A website is never one of them, as
    /// it would match every site registered under it. The common ones of the Public Suffix List with more than one
    /// label; a single label like `com` is never taken for a website anyway.
    private static let publicSuffixes: Set<String> = [
        // Countries' second-level domains.
        "ac.jp", "ac.uk", "ac.za", "co.id", "co.il", "co.in", "co.jp", "co.kr", "co.nz", "co.th", "co.uk", "co.za",
        "com.ar", "com.au", "com.br", "com.cn", "com.co", "com.eg", "com.hk", "com.mx", "com.my", "com.ng", "com.pe",
        "com.ph", "com.pk", "com.pl", "com.sa", "com.sg", "com.tr", "com.tw", "com.ua", "com.vn", "edu.au", "gouv.fr",
        "gov.au", "gov.uk", "ltd.uk", "me.uk", "ne.jp", "net.au", "net.br", "net.cn", "net.in", "net.nz", "net.uk",
        "or.jp", "or.kr", "org.au", "org.br", "org.cn", "org.in", "org.nz", "org.uk", "plc.uk",
        // Hosting where each customer gets a subdomain.
        "amazonaws.com", "appspot.com", "azurewebsites.net", "blogspot.com", "cloudfront.net", "duckdns.org",
        "firebaseapp.com", "fly.dev", "github.io", "gitlab.io", "glitch.me", "herokuapp.com", "myshopify.com",
        "netlify.app", "ngrok.io", "onrender.com", "pages.dev", "s3.amazonaws.com", "vercel.app", "web.app",
        "workers.dev"
    ]

    /// The websites an account's codes are suggested on without asking: the issuer itself when it is a domain, or a
    /// known service's. Empty when the issuer is only a name, see `suggestion(issuer:)`.
    static func guess(issuer: String?) -> [String] {
        guard let issuer = issuer?.trimmingCharacters(in: .whitespacesAndNewlines), !issuer.isEmpty else { return [] }
        if !issuer.contains(" "), issuer.contains("."), let website = normalized(issuer) {
            return [website]
        }
        return known[letters(of: issuer)] ?? []
    }

    /// The website an issuer that is only a name might have, its letters and digits followed by `.com`, e.g.
    /// `mastodon.com` for Mastodon. Only ever offered for the user to confirm: whoever owns that domain would otherwise
    /// be offered the account's codes. Nil when the issuer is a domain or a known service, or isn't a name in ASCII.
    static func suggestion(issuer: String?) -> String? {
        guard let issuer = issuer?.trimmingCharacters(in: .whitespacesAndNewlines), guess(issuer: issuer).isEmpty,
            issuer.unicodeScalars.allSatisfy(\.isASCII), !issuer.contains(".")
        else { return nil }
        let name = letters(of: issuer)
        guard name.count >= 2 else { return nil }
        return name + ".com"
    }

    private static func letters(of issuer: String) -> String {
        String(issuer.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
    }

    /// The domain in what was typed, e.g. `github.com` for `https://www.GitHub.com/login`. Nil if it isn't one, or is a
    /// public suffix such as `co.uk`.
    static func normalized(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var host = URLComponents(string: text)?.host, !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), !isPublicSuffix(host) else { return nil }
        return host
    }

    /// Whether anyone can register a name under `website`, so that it can't stand for one site.
    static func isPublicSuffix(_ website: String) -> Bool {
        publicSuffixes.contains(website.lowercased())
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
        -> (matching: [AutoFillAccount], others: [AutoFillAccount])
    {
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
                ASOneTimeCodeCredentialIdentity(
                    serviceIdentifier: ASCredentialServiceIdentifier(identifier: website, type: .domain),
                    label: label, recordIdentifier: account.id)
            }
        }
    }

    /// Replaces the suggestions with the accounts', if AutoFill from Oriel OTP is on. Returns whether it is.
    @discardableResult static func replace(with accounts: [AutoFillAccount]) async -> Bool {
        let store = ASCredentialIdentityStore.shared
        guard await store.state().isEnabled else { return false }
        do {
            try await store.replaceCredentialIdentities(identities(for: accounts))
        } catch {
            // Rather than leave suggestions for accounts that may be gone, e.g. after signing out.
            try? await store.removeAllCredentialIdentities()
        }
        return true
    }
}
