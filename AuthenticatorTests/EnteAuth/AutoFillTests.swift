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
import CryptoKit
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
    private var saves = 0
    private var fails = false

    /// How many times the accounts were written.
    var saveCount: Int { lock.withLock { saves } }
    var failsToSave: Bool {
        get { lock.withLock { fails } }
        set { lock.withLock { fails = newValue } }
    }

    func load() throws -> [AutoFillAccount]? {
        lock.withLock { accounts }
    }

    func save(_ accounts: [AutoFillAccount]) throws {
        try lock.withLock {
            if fails { throw AutoFillStoreError.unavailable }
            saves += 1
            self.accounts = accounts.isEmpty ? nil : accounts
        }
    }

    func remove() {
        lock.withLock { accounts = nil }
    }
}

/// Runs a value's reads and tells where they ran.
private nonisolated final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ranOnMain: Bool?
    var wasOnMain: Bool? { lock.withLock { ranOnMain } }
    func record() { lock.withLock { ranOnMain = Thread.isMainThread } }
}

@MainActor
struct AutoFillAccountSyncTests {

    private let storage = InMemoryAutoFillStorage()
    private let defaults = UserDefaults(suiteName: "AutoFillAccountSyncTests-\(UUID().uuidString)")!
    private let websitesURL = URL.temporaryDirectory.appending(components: "AutoFillAccountSyncTests-\(UUID().uuidString)", "Websites")
    private let websitesKey = InMemoryVaultKey()

    private func sync(keychain: EnteVaultKeychain? = nil) -> AutoFillAccountSync {
        AutoFillAccountSync(storage: storage, websitesURL: websitesURL, websitesKeychain: keychain ?? websitesKey, defaults: defaults, updatesSystem: false)
    }

    private func update(_ sync: AutoFillAccountSync, with codes: [EnteCode] = Self.codes) async {
        sync.update { codes }
        await sync.finishWriting()
    }

    private static func code(_ id: String, _ url: String) -> EnteCode {
        EnteCodeParser.parse(id: id, rawData: "\"\(url)\"")!
    }

    private static let codes = [
        code("github", "otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"),
        code("bank", "otpauth://hotp/Bank:alice?secret=JBSWY3DPEHPK3PXP&issuer=Bank&counter=3"),
    ]

    @Test func writesTheTimeBasedAccountsWithTheirGuessedWebsites() async throws {
        await update(sync())
        let accounts = try #require(try storage.load())
        #expect(accounts.map(\.id) == ["github"])
        #expect(accounts.first?.websites == ["github.com"])
        #expect(accounts.first.map { OTPGenerator.code(for: $0.account, at: Date(timeIntervalSince1970: 59)) } == "996554")
    }

    @Test func parsesTheAccountsOffTheMainThread() async {
        let sync = sync()
        let recorder = Recorder()
        let codes = Self.codes
        sync.update {
            recorder.record()
            return codes
        }
        await sync.finishWriting()
        #expect(recorder.wasOnMain == false)
    }

    @Test func usesTheChosenWebsites() async throws {
        let sync = sync()
        await update(sync)
        sync.setWebsites(["github.example.com"], for: "github")
        await sync.finishWriting()
        #expect(try storage.load()?.first?.websites == ["github.example.com"])
        #expect(sync.hasChosenWebsites(for: "github"))

        // Kept when the app starts again.
        let relaunched = self.sync()
        await update(relaunched)
        #expect(relaunched.websites(for: "github", issuer: "GitHub") == ["github.example.com"])

        relaunched.setWebsites(nil, for: "github")
        await relaunched.finishWriting()
        #expect(try storage.load()?.first?.websites == ["github.com"])
    }

    @Test func forgetsTheWebsitesOfDeletedAccounts() async {
        let sync = sync()
        await update(sync)
        sync.setWebsites([], for: "github")
        await update(sync, with: [Self.codes[1]])
        #expect(!sync.hasChosenWebsites(for: "github"))
    }

    @Test func deletesEverythingWhenSignedOut() async throws {
        let sync = sync()
        await update(sync)
        sync.setWebsites([], for: "github")
        // Not waiting first: a write that's under way mustn't bring the accounts back.
        sync.remove()
        await sync.finishWriting()
        #expect(try storage.load() == nil)
        #expect(!sync.hasChosenWebsites(for: "github"))
        #expect(!FileManager.default.fileExists(atPath: websitesURL.path))
    }

    @Test func signingOutWhileTheAccountsAreParsedDoesNotBringThemBack() async throws {
        let sync = sync()
        let codes = Self.codes
        sync.update {
            Thread.sleep(forTimeInterval: 0.05)
            return codes
        }
        sync.remove()
        try await Task.sleep(for: .milliseconds(150))
        await sync.finishWriting()
        #expect(try storage.load() == nil)
    }

    @Test func theLastUpdateWinsWhenAnEarlierOneTakesLonger() async throws {
        let sync = sync()
        let codes = Self.codes
        sync.update {
            Thread.sleep(forTimeInterval: 0.05)
            return codes
        }
        sync.update { [] }
        try await Task.sleep(for: .milliseconds(150))
        await sync.finishWriting()
        #expect(try storage.load() == nil)
    }

    @Test func aFileWithTheSameAccountsIsLeftAsItIsWhenTheAppStarts() async throws {
        await update(sync())
        let saves = storage.saveCount
        await update(sync())
        #expect(storage.saveCount == saves)
    }

    @Test func aWriteThatFailedIsTriedAgain() async throws {
        let sync = sync()
        storage.failsToSave = true
        await update(sync)
        #expect(try storage.load() == nil)

        storage.failsToSave = false
        await update(sync)
        #expect(try storage.load()?.map(\.id) == ["github"])
    }

    // Chosen websites used to be kept in UserDefaults, in the clear.
    @Test func chosenWebsitesAreMovedOutOfUserDefaults() async throws {
        defaults.set(["github": ["github.example.com"]], forKey: "AutoFill.Websites")
        await update(sync())
        #expect(defaults.object(forKey: "AutoFill.Websites") == nil)
        #expect(try storage.load()?.first?.websites == ["github.example.com"])

        let file = try Data(contentsOf: websitesURL)
        #expect(file.range(of: Data("example".utf8)) == nil)
        #expect(sync().websites(for: "github", issuer: "GitHub") == ["github.example.com"])
    }

    @Test func websitesThatCanNotBeReadYetAreNotWrittenOver() async throws {
        let first = sync()
        await update(first)
        first.setWebsites(["github.example.com"], for: "github")
        await first.finishWriting()
        let saved = try Data(contentsOf: websitesURL)

        // While the device is locked, updating with other accounts mustn't forget them.
        await update(sync(keychain: LockedVaultKey()), with: [Self.codes[1]])
        #expect(try Data(contentsOf: websitesURL) == saved)
        #expect(sync().hasChosenWebsites(for: "github"))
    }
}

/// A keychain that can't be read, like while the device is locked.
private nonisolated struct LockedVaultKey: EnteVaultKeychain {
    func existingKey() throws -> SymmetricKey? { throw EnteVaultError.unavailable }
    func createKey() throws -> SymmetricKey { throw EnteVaultError.unavailable }
    func removeKey() {}
}
