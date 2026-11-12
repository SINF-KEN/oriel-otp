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
import YubiKit

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
        // A name only: its `.com` could belong to anyone, so it's never used without asking.
        ("Mastodon", []),
        ("My Bank", []),
        ("Home Assistant", []),
        // Anyone can register a site under these.
        ("github.io", []),
        ("co.uk", []),
        ("alice.github.io", ["alice.github.io"])
    ])
    func guessesTheWebsiteFromTheIssuer(issuer: String, websites: [String]) {
        #expect(AutoFillWebsites.guess(issuer: issuer) == websites)
    }

    @Test func guessesNothingWithoutAnIssuer() {
        #expect(AutoFillWebsites.guess(issuer: nil) == [])
    }

    @Test(
        arguments: [
            ("Mastodon", "mastodon.com"),
            ("Home Assistant", "homeassistant.com"),
            ("GitHub", nil),
            ("accounts.google.com", nil),
            ("github.io", nil),
            ("ミクシィ", nil),
            ("A", nil)
        ] as [(String, String?)])
    func suggestsAWebsiteForANameToBeConfirmed(issuer: String, suggestion: String?) {
        #expect(AutoFillWebsites.suggestion(issuer: issuer) == suggestion)
    }

    @Test(
        arguments: [
            ("https://www.GitHub.com/login", "github.com"),
            ("example.com.", "example.com"),
            (" login.example.co.uk ", "login.example.co.uk"),
            ("github", nil),
            ("git hub.com", nil),
            ("co.uk", nil),
            ("https://www.github.io/", nil),
            ("alice.github.io", "alice.github.io"),
            ("", nil)
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
            Self.account("3", issuer: "Other", websites: ["other.com"])
        ]
        let services = [
            ASCredentialServiceIdentifier(identifier: "https://m.example.com/login", type: .URL),
            ASCredentialServiceIdentifier(identifier: "example.com", type: .domain)
        ]
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
        let identities = AutoFillIdentities.identities(for: [Self.account("1", issuer: "Example", websites: ["example.com", "example.org"])]
        )
        #expect(identities.map(\.serviceIdentifier.identifier) == ["example.com", "example.org"])
        #expect(identities.allSatisfy { $0.label == "Example (alice)" && $0.recordIdentifier == "1" })
    }

    static func account(_ id: String, issuer: String, websites: [String]) -> AutoFillAccount {
        AutoFillAccount(
            account: OTPAccount(
                id: id, kind: .totp, issuer: issuer, accountName: "alice", secret: Data("secret".utf8),
                algorithm: .sha1, digits: 6, period: 30, isPinned: false),
            websites: websites)
    }
}

nonisolated final class InMemoryAutoFillStorage: AutoFillStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: [AutoFillAccount]?
    private var saves = 0
    private var fails = false
    private var failsLoading = false

    /// How many times the accounts were written.
    var saveCount: Int { lock.withLock { saves } }
    var failsToSave: Bool {
        get { lock.withLock { fails } }
        set { lock.withLock { fails = newValue } }
    }

    /// Loading throws `EncryptedFileError.unavailable`, as while the device is locked.
    var failsToLoad: Bool {
        get { lock.withLock { failsLoading } }
        set { lock.withLock { failsLoading = newValue } }
    }

    func load() throws -> [AutoFillAccount]? {
        try lock.withLock {
            if failsLoading { throw EncryptedFileError.unavailable }
            return accounts
        }
    }

    func save(_ accounts: [AutoFillAccount]) throws {
        try lock.withLock {
            if fails { throw EncryptedFileError.unavailable }
            saves += 1
            self.accounts = accounts.isEmpty ? nil : accounts
        }
    }

    func remove() {
        lock.withLock { accounts = nil }
    }
}

/// Whether AutoFill from Oriel OTP is on in Settings.
private nonisolated final class ProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
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
    private let provider = ProviderState()

    private func sync(keychain: EncryptedFileKey? = nil) -> AutoFillAccountSync {
        let provider = provider
        return AutoFillAccountSync(
            storage: storage, websitesURL: websitesURL, websitesKeychain: keychain ?? websitesKey, defaults: defaults,
            updatesSystem: false, providerIsEnabled: { provider.isEnabled })
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
        code("bank", "otpauth://hotp/Bank:alice?secret=JBSWY3DPEHPK3PXP&issuer=Bank&counter=3")
    ]

    private func template(_ issuer: String) throws -> YubiKitOATHSession.CredentialTemplate {
        try YubiKitOATHSession.CredentialTemplate(
            type: .totp(period: 30), algorithm: .sha1, secret: Data(base32Encoded: "JBSWY3DPEHPK3PXP")!,
            issuer: issuer, accountName: "alice", digits: 6)
    }

    /// The accounts on this device are filled in too, without an Ente account, and stay when Ente is signed out of.
    @Test func fillsInTheAccountsOnThisDevice() async throws {
        let sync = sync()
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        let defaults = makeTestDefaults()
        let cloud = EnteCloud(
            store: EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true),
            storage: InMemoryVaultStorage(), session: OfflineURLProtocol.session,
            watch: WatchAccountSync(defaults: defaults), autoFill: sync, device: device)
        let model = MainViewModel(cloud: cloud, device: device)
        _ = try model.addDeviceAccount(template("GitLab"))
        await sync.finishWriting()
        let accounts = try #require(try storage.load())
        #expect(accounts.map(\.account.issuer) == ["GitLab"])
        #expect(accounts.first?.websites == ["gitlab.com"])

        cloud.remove()
        await sync.finishWriting()
        #expect(try storage.load()?.map(\.account.issuer) == ["GitLab"])

        // Deleting the last one deletes the file.
        let account = try #require(model.deviceAccounts.first)
        await withCheckedContinuation { done in model.deleteAccount(account) { done.resume() } }
        await sync.finishWriting()
        #expect(try storage.load() == nil)
    }

    /// A launch in the background on a locked device can't read the accounts on this device yet. That isn't taken for
    /// none: they stay in AutoFill with their chosen websites, and are written again once they can be read.
    @Test func keepsTheAccountsOnThisDeviceWhileTheyCantBeRead() async throws {
        let deviceStorage = MemoryDeviceStorage()
        let defaults = makeTestDefaults()
        func cloud(autoFill: AutoFillAccountSync, device: DeviceAccounts) -> EnteCloud {
            EnteCloud(
                store: EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true),
                storage: InMemoryVaultStorage(), session: OfflineURLProtocol.session,
                watch: WatchAccountSync(defaults: defaults), autoFill: autoFill, device: device)
        }
        let sync = sync()
        let device = DeviceAccounts(storage: deviceStorage)
        let model = MainViewModel(cloud: cloud(autoFill: sync, device: device), device: device)
        _ = try model.addDeviceAccount(template("GitLab"))
        await sync.finishWriting()
        let id = try #require(try storage.load()?.first?.id)
        sync.setWebsites(["git.example.com"], for: id)
        await sync.finishWriting()

        deviceStorage.loadError = EncryptedFileError.unavailable
        let relaunched = self.sync()
        let lockedDevice = DeviceAccounts(storage: deviceStorage)
        #expect(lockedDevice.isLocked)
        let relaunchedCloud = cloud(autoFill: relaunched, device: lockedDevice)
        await relaunched.finishWriting()
        #expect(try storage.load()?.map(\.id) == [id])
        #expect(self.sync().hasChosenWebsites(for: id))

        // Unlocked, they're read and written again, with the websites chosen for them.
        deviceStorage.loadError = nil
        lockedDevice.onChange = { relaunchedCloud.updateAutoFill() }
        lockedDevice.loadIfLocked()
        await relaunched.finishWriting()
        #expect(try storage.load()?.first?.websites == ["git.example.com"])
    }

    @Test func writesTheTimeBasedAccountsWithTheirGuessedWebsites() async throws {
        await update(sync())
        let accounts = try #require(try storage.load())
        #expect(accounts.map(\.id) == ["github"])
        #expect(accounts.first?.websites == ["github.com"])
        #expect(accounts.first.map { OTPGenerator.code(for: $0.account, at: Date(timeIntervalSince1970: 59)) } == "996554")
    }

    @Test func aNameIsNotTurnedIntoAWebsite() async throws {
        await update(sync(), with: [Self.code("mastodon", "otpauth://totp/Mastodon:alice?secret=JBSWY3DPEHPK3PXP&issuer=Mastodon")])
        #expect(try storage.load()?.first?.websites == [])
    }

    @Test func aPublicSuffixChosenEarlierIsLeftOut() async throws {
        let sync = sync()
        await update(sync)
        sync.setWebsites(["co.uk", "example.co.uk"], for: "github")
        await sync.finishWriting()
        #expect(try storage.load()?.first?.websites == ["example.co.uk"])
    }

    @Test func keepsNoAccountsWhileAutoFillIsOff() async throws {
        provider.isEnabled = false
        await update(sync())
        #expect(try storage.load() == nil)

        let sync = sync()
        provider.isEnabled = true
        await update(sync)
        #expect(try storage.load()?.map(\.id) == ["github"])

        // Turned off in Settings, then the app starts again.
        provider.isEnabled = false
        await update(self.sync())
        #expect(try storage.load() == nil)
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
        // Waits for the parsing too, so the test can't end before it.
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
        // Waits for the slower first update too, so the test can't end before it.
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
private nonisolated struct LockedVaultKey: EncryptedFileKey {
    func existingKey() throws -> SymmetricKey? { throw EncryptedFileError.unavailable }
    func createKey() throws -> SymmetricKey { throw EncryptedFileError.unavailable }
    func removeKey() {}
}
