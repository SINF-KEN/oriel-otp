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
import Testing

@testable import OrielOTP

struct AutoFillWebsitesTests {

    @Test(arguments: [
        ("GitHub", ["github.com"]),
        ("Epic Games", ["epicgames.com"]),
        ("Amazon Web Services", ["aws.amazon.com"]),
        ("Steam", ["steampowered.com", "steamcommunity.com"]),
        ("accounts.Google.com", ["accounts.google.com"]),
        ("ミクシィ", []),
        ("X", ["x.com", "twitter.com"]),
        ("", []),
    ])
    func guessesTheWebsiteFromTheIssuer(issuer: String, websites: [String]) {
        #expect(AutoFillWebsites.guess(issuer: issuer) == websites)
    }

    @Test func guessesNothingWithoutAnIssuer() {
        #expect(AutoFillWebsites.guess(issuer: nil) == [])
    }

    @Test(arguments: [
        ("https://www.GitHub.com/login", "github.com"),
        ("example.com.", "example.com"),
        (" login.example.co.uk ", "login.example.co.uk"),
        ("github", nil),
        ("git hub.com", nil),
        ("", nil),
    ] as [(String, String?)])
    func normalizesTypedWebsites(text: String, website: String?) {
        #expect(AutoFillWebsites.normalized(text) == website)
    }

    @Test func matchesTheWebsiteAndItsSubdomains() {
        #expect(AutoFillWebsites.matches(host: "github.com", website: "github.com"))
        #expect(AutoFillWebsites.matches(host: "Gist.GitHub.com", website: "github.com"))
        #expect(!AutoFillWebsites.matches(host: "notgithub.com", website: "github.com"))
        #expect(!AutoFillWebsites.matches(host: "github.com", website: "gist.github.com"))
    }

    @Test func suggestsTheAccountsOfTheMostSpecificWebsiteFirst() {
        let accounts = [
            Self.account("1", issuer: "Example", websites: ["example.com"]),
            Self.account("2", issuer: "Mobile", websites: ["m.example.com"]),
            Self.account("3", issuer: "Other", websites: ["other.com"]),
        ]
        let services = [ASCredentialServiceIdentifier(identifier: "https://m.example.com/login", type: .URL),
                        ASCredentialServiceIdentifier(identifier: "example.com", type: .domain)]
        let (matching, others) = AutoFillWebsites.sorted(accounts, for: services)
        #expect(matching.map(\.id) == ["2", "1"])
        #expect(others.map(\.id) == ["3"])
    }

    @Test func listsEveryAccountWithoutAWebsite() {
        let accounts = [Self.account("1", issuer: "B", websites: []), Self.account("2", issuer: "A", websites: ["a.com"])]
        let (matching, others) = AutoFillWebsites.sorted(accounts, for: [])
        #expect(matching.isEmpty)
        #expect(others.map(\.id) == ["2", "1"])
    }

    @available(iOS 18.0, macOS 15.0, *)
    @Test func suggestsEachWebsiteWithTheAccountsName() {
        let identities = AutoFillIdentities.identities(for: [Self.account("1", issuer: "Example", websites: ["example.com", "example.org"])])
        #expect(identities.map(\.serviceIdentifier.identifier) == ["example.com", "example.org"])
        #expect(identities.allSatisfy { $0.label == "Example (alice)" && $0.recordIdentifier == "1" })
    }

    static func account(_ id: String, issuer: String, websites: [String]) -> AutoFillAccount {
        AutoFillAccount(account: OTPAccount(id: id, kind: .totp, issuer: issuer, accountName: "alice", secret: Data("secret".utf8),
                                            algorithm: .sha1, digits: 6, period: 30, isPinned: false),
                        websites: websites)
    }
}

nonisolated final class InMemoryAutoFillStorage: AutoFillStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: [AutoFillAccount]?

    func load() throws -> [AutoFillAccount]? {
        lock.withLock { accounts }
    }

    func save(_ accounts: [AutoFillAccount]) throws {
        lock.withLock { self.accounts = accounts.isEmpty ? nil : accounts }
    }

    func remove() {
        lock.withLock { accounts = nil }
    }
}

@MainActor
struct AutoFillAccountSyncTests {

    private let storage = InMemoryAutoFillStorage()
    private let defaults = UserDefaults(suiteName: "AutoFillAccountSyncTests-\(UUID().uuidString)")!

    private func sync() -> AutoFillAccountSync {
        AutoFillAccountSync(storage: storage, defaults: defaults, updatesSystem: false)
    }

    private static func code(_ id: String, _ url: String) -> EnteCode {
        EnteCodeParser.parse(id: id, rawData: "\"\(url)\"")!
    }

    private static let codes = [
        code("github", "otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"),
        code("bank", "otpauth://hotp/Bank:alice?secret=JBSWY3DPEHPK3PXP&issuer=Bank&counter=3"),
    ]

    @Test func writesTheTimeBasedAccountsWithTheirGuessedWebsites() throws {
        sync().update(Self.codes)
        let accounts = try #require(try storage.load())
        #expect(accounts.map(\.id) == ["github"])
        #expect(accounts.first?.websites == ["github.com"])
        #expect(accounts.first.map { OTPGenerator.code(for: $0.account, at: Date(timeIntervalSince1970: 59)) } == "996554")
    }

    @Test func usesTheChosenWebsites() throws {
        let sync = sync()
        sync.update(Self.codes)
        sync.setWebsites(["github.example.com"], for: "github")
        #expect(try storage.load()?.first?.websites == ["github.example.com"])
        #expect(sync.hasChosenWebsites(for: "github"))

        // Kept when the app starts again.
        let relaunched = self.sync()
        relaunched.update(Self.codes)
        #expect(relaunched.websites(for: "github", issuer: "GitHub") == ["github.example.com"])

        relaunched.setWebsites(nil, for: "github")
        #expect(try storage.load()?.first?.websites == ["github.com"])
    }

    @Test func forgetsTheWebsitesOfDeletedAccounts() {
        let sync = sync()
        sync.update(Self.codes)
        sync.setWebsites([], for: "github")
        sync.update([Self.codes[1]])
        #expect(!sync.hasChosenWebsites(for: "github"))
    }

    @Test func deletesEverythingWhenSignedOut() throws {
        let sync = sync()
        sync.update(Self.codes)
        sync.setWebsites([], for: "github")
        sync.remove()
        #expect(try storage.load() == nil)
        #expect(!sync.hasChosenWebsites(for: "github"))
    }
}
