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

import CryptoKit
import Foundation
import Testing
import YubiKit

@testable import OrielOTP

/// Stands in for the vault file.
nonisolated final class InMemoryVaultStorage: EnteVaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var vault: EnteVault?

    func load() throws -> EnteVault? { lock.withLock { vault } }
    func save(_ vault: EnteVault) throws { lock.withLock { self.vault = vault } }
    func remove() { lock.withLock { vault = nil } }
}

/// A vault file that can't be read until the device is unlocked.
nonisolated final class LockedVaultStorage: EnteVaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let storage = InMemoryVaultStorage()
    private var isLocked = true

    func unlock() { lock.withLock { isLocked = false } }
    func load() throws -> EnteVault? {
        if lock.withLock({ isLocked }) { throw EnteVaultError.unavailable }
        return try storage.load()
    }
    func save(_ vault: EnteVault) throws { try storage.save(vault) }
    func remove() { storage.remove() }
}

/// Stands in for the keychain item with the vault file's key.
nonisolated final class InMemoryVaultKey: EnteVaultKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?

    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey {
        lock.withLock {
            let key = SymmetricKey(size: .bits256)
            self.key = key
            return key
        }
    }
    func removeKey() { lock.withLock { key = nil } }
}

/// Fails every request like a device without a network connection.
nonisolated final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// The plain text of an entity as Ente Auth stores it: the otpauth URL as a JSON string.
private func rawData(_ uri: String) -> String {
    String(decoding: try! JSONEncoder().encode(uri), as: UTF8.self)
}

/// The secret of the RFC 4226 and RFC 6238 test vectors, "12345678901234567890".
private let rfcSecret = Data("12345678901234567890".utf8).base32EncodedString

struct EnteEntryEditorTests {

    @Test func renamesAndKeepsWhatTheAppDoesntUse() throws {
        let object = #"{"rawData":"otpauth://totp/Old:alice?secret=JBSWY3DPEHPK3PXP&issuer=Old&period=30&image=x","display":{"tags":["work"],"note":"Backup codes in the safe","pinned":true}}"#
        var editor = try #require(EnteEntryEditor(rawData: object))
        editor.rename(issuer: "New+Co", accountName: "bob#1@example.com")
        let edited = try #require(editor.rawData)

        // Ente Auth's format: a JSON string with the display settings in the URL.
        let url = try #require(try JSONSerialization.jsonObject(with: Data(edited.utf8), options: .fragmentsAllowed) as? String)
        #expect(url.contains("issuer=New%2BCo"))
        #expect(url.contains("image=x"))
        let entry = EnteEntry(rawData: edited)
        #expect(entry.isPinned)
        let components = try #require(entry.components)
        let display = try #require(components.queryItems?.first { $0.name == "codeDisplay" }?.value)
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(display.utf8)) as? [String: Any])
        #expect(settings["tags"] as? [String] == ["work"])
        #expect(settings["note"] as? String == "Backup codes in the safe")

        let code = try #require(EnteCodeParser.parse(id: "1", rawData: edited))
        #expect(code.credentialId == "New+Co:bob#1@example.com")
        #expect(code.template?.secret.starts(with: Data(base32Encoded: "JBSWY3DPEHPK3PXP")!) == true)
    }

    @Test func removesTheIssuerWhenItIsCleared() throws {
        var editor = try #require(EnteEntryEditor(rawData: rawData("otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub")))
        editor.rename(issuer: "", accountName: "alice")
        let edited = try #require(editor.rawData)
        let code = try #require(EnteCodeParser.parse(id: "1", rawData: edited))
        #expect(code.issuer == nil)
        #expect(code.credentialId == "alice")
    }

    @Test func pinsAndTrashes() throws {
        var editor = try #require(EnteEntryEditor(rawData: rawData("otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP")))
        #expect(!editor.isPinned)
        editor.isPinned = true
        #expect(EnteEntry(rawData: editor.rawData ?? "").isPinned)
        editor.isTrashed = true
        let trashed = try #require(editor.rawData)
        #expect(EnteEntry(rawData: trashed).isTrashed)
        #expect(EnteCodeParser.parse(id: "1", rawData: trashed) == nil)
        #expect(EnteCloudCode(rawData: trashed) == nil)
    }

    @Test func movesTheHOTPCounterOn() throws {
        var editor = try #require(EnteEntryEditor(rawData: rawData("otpauth://hotp/A:alice?secret=\(rfcSecret)&counter=4")))
        #expect(editor.counter == 4)
        editor.counter = 5
        #expect(EnteCloudCode(rawData: editor.rawData ?? "")?.counter == 5)
    }

    @Test func rejectsDataThatIsntAnAccount() {
        #expect(EnteEntryEditor(rawData: "not json") == nil)
        #expect(EnteEntryEditor(rawData: rawData("https://example.com")) == nil)
    }
}

struct EnteCloudCodeTests {

    @Test(arguments: [(59, "94287082"), (1_111_111_109, "07081804"), (2_000_000_000, "69279037")])
    func calculatesTheRFC6238Codes(time: Int, expected: String) throws {
        let code = try #require(EnteCloudCode(rawData: rawData("otpauth://totp/RFC:alice?secret=\(rfcSecret)&digits=8")))
        let (otp, validity) = code.code(at: Date(timeIntervalSince1970: TimeInterval(time)))
        #expect(otp == expected)
        #expect(validity.duration == 30)
        #expect(validity.start.timeIntervalSince1970 == TimeInterval(time / 30 * 30))
    }

    @Test func calculatesSHA256Codes() throws {
        let secret = Data("12345678901234567890123456789012".utf8).base32EncodedString
        let code = try #require(EnteCloudCode(rawData: rawData("otpauth://totp/RFC:alice?secret=\(secret)&digits=8&algorithm=SHA256")))
        #expect(code.code(at: Date(timeIntervalSince1970: 59)).code == "46119246")
    }

    @Test func calculatesTheRFC4226Codes() throws {
        let expected = ["755224", "287082", "359152", "969429"]
        for (counter, value) in expected.enumerated() {
            let code = try #require(EnteCloudCode(rawData: rawData("otpauth://hotp/RFC:alice?secret=\(rfcSecret)&counter=\(counter)")))
            #expect(code.kind == .hotp)
            #expect(code.hotpCode() == value)
        }
    }

    @Test func calculatesSteamCodes() throws {
        let code = try #require(EnteCloudCode(rawData: rawData("otpauth://steam/Steam:gamer?secret=JBSWY3DPEHPK3PXP")))
        #expect(code.kind == .steam)
        #expect(code.issuer == "Steam")
        let otp = code.code(at: Date(timeIntervalSince1970: 1_000_000)).code
        #expect(otp.count == 5)
        #expect(otp.allSatisfy { "23456789BCDFGHJKMNPQRTVWXY".contains($0) })
    }

    @Test func usesTheEntesPeriod() throws {
        let code = try #require(EnteCloudCode(rawData: rawData("otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP&period=60")))
        let (_, validity) = code.code(at: Date(timeIntervalSince1970: 100))
        #expect(validity == DateInterval(start: Date(timeIntervalSince1970: 60), duration: 60))
    }

    @Test func samePinnedOrCountedAccountIsTheSameAccount() throws {
        let first = try #require(EnteCloudCode(rawData: rawData("otpauth://hotp/A:alice?secret=JBSWY3DPEHPK3PXP&counter=1")))
        let next = try #require(EnteCloudCode(rawData: rawData("otpauth://hotp/A:alice?secret=JBSWY3DPEHPK3PXP&counter=2&codeDisplay=%7B%22pinned%22%3Atrue%7D")))
        let renamed = try #require(EnteCloudCode(rawData: rawData("otpauth://hotp/B:alice?secret=JBSWY3DPEHPK3PXP&counter=2")))
        #expect(first.isSameAccount(as: next))
        #expect(!first.isSameAccount(as: renamed))
    }
}

struct EnteVaultTests {

    private let server = URL(string: "https://ente.test")!

    private func entity(_ id: String, updatedAt: Int64, isDeleted: Bool = false) -> EnteAuthenticatorEntity {
        EnteAuthenticatorEntity(id: id, encryptedData: nil, header: nil, isDeleted: isDeleted, updatedAt: updatedAt)
    }

    private func vault(with items: [(id: String, uri: String, updatedAt: Int64)]) -> EnteVault {
        var vault = EnteVault(email: "alice@example.com", server: server)
        vault.merge(items.map { (entity($0.id, updatedAt: $0.updatedAt), rawData($0.uri)) }, latest: items.map(\.updatedAt).max() ?? 0)
        return vault
    }

    @Test func pullAddsChangesAndDeletes() {
        var vault = vault(with: [("a", "otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP", 1), ("b", "otpauth://totp/B:alice?secret=JBSWY3DPEHPK3PXP", 2)])
        #expect(vault.items.map(\.id) == ["a", "b"])
        #expect(vault.lastSyncTime == 2)

        vault.merge([(entity("a", updatedAt: 3), rawData("otpauth://totp/A2:alice?secret=JBSWY3DPEHPK3PXP")),
                     (entity("b", updatedAt: 4, isDeleted: true), nil)], latest: 4)
        #expect(vault.items.map(\.id) == ["a"])
        #expect(vault.items[0].rawData == rawData("otpauth://totp/A2:alice?secret=JBSWY3DPEHPK3PXP"))
        #expect(vault.items[0].serverUpdatedAt == 3)
        #expect(vault.lastSyncTime == 4)
    }

    @Test func theServersNewerVersionWinsOverAPendingChange() {
        var vault = vault(with: [("a", "otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP", 1)])
        #expect(vault.edit("a") { $0.rename(issuer: "Local", accountName: "alice") })
        #expect(vault.hasPendingChanges)

        let remote = rawData("otpauth://totp/Remote:alice?secret=JBSWY3DPEHPK3PXP")
        vault.merge([(entity("a", updatedAt: 2), remote)], latest: 2)
        #expect(vault.items[0].rawData == remote)
        #expect(!vault.hasPendingChanges)
    }

    @Test func aPendingChangeOnTheLatestVersionIsKept() throws {
        let original = rawData("otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP")
        var vault = vault(with: [("a", "otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP", 1)])
        #expect(vault.edit("a") { $0.isPinned = true })
        let pinned = try #require(vault.items[0].rawData)

        // The same version again, e.g. a page of the diff that was fetched twice.
        vault.merge([(entity("a", updatedAt: 1), original)], latest: 1)
        #expect(vault.items[0].rawData == pinned)
        #expect(vault.hasPendingChanges)
    }

    @Test func thisDevicesOwnUpdateKeepsLaterChanges() throws {
        var vault = vault(with: [("a", "otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP", 1)])
        #expect(vault.edit("a") { $0.isPinned = true })
        let uploaded = try #require(vault.items[0].rawData)
        vault.markUploaded("a", rawData: uploaded, created: nil)
        #expect(!vault.hasPendingChanges)
        // Renamed after the upload, before the update came back in the diff with a newer time.
        #expect(vault.edit("a") { $0.rename(issuer: "B", accountName: "alice") })
        let renamed = try #require(vault.items[0].rawData)

        vault.merge([(entity("a", updatedAt: 5), uploaded)], latest: 5)
        #expect(vault.items[0].rawData == renamed)
        #expect(vault.items[0].serverUpdatedAt == 5)
        #expect(vault.hasPendingChanges)
    }

    @Test func deletingOnTheServerWinsOverAPendingChange() {
        var vault = vault(with: [("a", "otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP", 1)])
        #expect(vault.edit("a") { $0.isPinned = true })
        vault.merge([(entity("a", updatedAt: 2, isDeleted: true), nil)], latest: 2)
        #expect(vault.items.isEmpty)
    }

    @Test func anUploadWhoseAnswerWasLostIsntUploadedAgain() {
        var vault = EnteVault(email: "alice@example.com", server: server)
        let added = rawData("otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP")
        let id = vault.add(rawData: added)
        #expect(vault.items.first?.entityID == nil)

        vault.merge([(entity("server-id", updatedAt: 3), added)], latest: 3)
        #expect(vault.items.count == 1)
        #expect(vault.items[0].id == id)
        #expect(vault.items[0].entityID == "server-id")
        #expect(!vault.hasPendingChanges)
    }

    @Test func aChangeDuringTheUploadIsUploadedAgain() throws {
        var vault = EnteVault(email: "alice@example.com", server: server)
        let added = rawData("otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP")
        let id = vault.add(rawData: added)
        #expect(vault.edit(id) { $0.isTrashed = true })
        vault.markUploaded(id, rawData: added, created: entity("server-id", updatedAt: 3))
        #expect(vault.items[0].entityID == "server-id")
        #expect(vault.items[0].isPending)
        #expect(vault.items[0].isTrashed)
    }

    @Test func anEditThatChangesNothingIsntUploaded() {
        var vault = vault(with: [("a", "otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP&codeDisplay=%7B%22pinned%22%3Afalse%7D", 1)])
        // Rewritten in Ente Auth's format once, then a no-op.
        _ = vault.edit("a") { $0.isPinned = false }
        let items = vault.items
        #expect(!vault.edit("a") { $0.isPinned = false })
        #expect(vault.items == items)
        #expect(!vault.edit("missing") { $0.isPinned = true })
    }

    @Test func fileIsEncryptedAndExcludedFromBackups() throws {
        let url = FileManager.default.temporaryDirectory.appending(components: UUID().uuidString, "Vault")
        let keychain = InMemoryVaultKey()
        let file = EnteVaultFile(url: url, keychain: keychain)
        #expect(try file.load() == nil)

        var vault = EnteVault(email: "alice@example.com", server: server)
        _ = vault.add(rawData: rawData("otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP"))
        try file.save(vault)
        #expect(try file.load() == vault)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("JBSWY3DPEHPK3PXP".utf8)) == nil)
        #expect(bytes.range(of: Data("alice".utf8)) == nil)
        #if os(iOS)
        // On the Mac this is Time Machine's, which the temporary folder of CI's runners doesn't keep.
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #endif

        // Without its key, e.g. after a restore on another device, the file can't be read.
        keychain.removeKey()
        #expect(throws: EnteVaultError.self) { try file.load() }
        file.remove()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

/// The Ente Auth accounts in the main list, with codes calculated on the device.
@MainActor struct EnteCloudAccountsTests {

    private let server = URL(string: "https://ente.test")!

    /// A cloud whose vault has the accounts, as if synced before. It is offline, so nothing is uploaded.
    private func cloud(with uris: [String]) throws -> EnteCloud {
        let defaults = makeTestDefaults()
        let store = EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true)
        try store.save(EnteSavedSession(server: server, email: "alice@example.com", token: "t", authenticatorKey: EnteCrypto.randomBytes(32)))
        var vault = EnteVault(email: "alice@example.com", server: server)
        vault.merge(uris.enumerated().map { (EnteAuthenticatorEntity(id: "e\($0)", encryptedData: nil, header: nil, isDeleted: false, updatedAt: Int64($0 + 1)), rawData($1)) },
                    latest: Int64(uris.count))
        let storage = InMemoryVaultStorage()
        try storage.save(vault)
        return EnteCloud(store: store, storage: storage, session: OfflineURLProtocol.session, watch: WatchAccountSync(defaults: defaults))
    }

    @Test func listsTheAccountsWithCodesCalculatedHere() throws {
        let cloud = try cloud(with: ["otpauth://totp/GitHub:alice?secret=\(rfcSecret)",
                                     "otpauth://hotp/VPN:alice?secret=\(rfcSecret)&counter=0",
                                     "otpauth://totp/Old:alice?secret=\(rfcSecret)&codeDisplay=%7B%22trashed%22%3Atrue%7D"])
        let model = MainViewModel(cloud: cloud)
        #expect(model.cloudAccounts.map(\.title) == ["GitHub", "VPN"])
        #expect(model.accounts.allSatisfy { $0.isInEnte })
        #expect(model.hasAccounts)
        #expect(!model.accountsLoaded)

        let totp = try #require(model.cloudAccounts.first { $0.title == "GitHub" })
        let expected = try #require(EnteCloudCode(rawData: rawData("otpauth://totp/GitHub:alice?secret=\(rfcSecret)"))).code(at: AppClock.now)
        #expect(totp.otp?.code == expected.code)
        #expect(totp.accountId != "GitHub:alice")

        // A HOTP code is calculated when asked for, and the counter moves on in the vault.
        let hotp = try #require(model.cloudAccounts.first { $0.title == "VPN" })
        #expect(hotp.otp == nil)
        hotp.calculate()
        #expect(hotp.otp?.code == "755224")
        #expect(hotp.isPendingSync)
        hotp.calculate()
        #expect(hotp.otp?.code == "287082")
        #expect(cloud.accounts.first { $0.code.kind == .hotp }?.code.counter == 2)
    }

    @Test func changesGoToTheVault() throws {
        let cloud = try cloud(with: ["otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP", "otpauth://totp/GitLab:alice?secret=JBSWY3DPEHPK3PXP"])
        let model = MainViewModel(cloud: cloud)
        let github = try #require(model.cloudAccounts.first { $0.title == "GitHub" })

        github.isPinned = true
        #expect(cloud.accounts.first { $0.code.issuer == "GitHub" }?.code.isPinned == true)
        #expect(model.pinnedAccounts.map(\.title) == ["GitHub"])

        model.renameAccount(github, issuer: "GitHub", accountName: "bob") {}
        #expect(model.cloudAccounts.contains { $0.subTitle == "bob" })

        let gitlab = try #require(model.cloudAccounts.first { $0.title == "GitLab" })
        model.deleteAccount(gitlab) {}
        #expect(!model.cloudAccounts.contains { $0.title == "GitLab" })
        // Moved to Ente's trash, so other devices can still restore it.
        #expect(cloud.vault?.items.filter(\.isTrashed).count == 1)
        #expect(cloud.hasPendingChanges)
    }

    @Test func settingWhatIsAlreadyThereUploadsNothing() throws {
        // Not in Ente Auth's own format, so any edit would rewrite it.
        let cloud = try cloud(with: ["otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"])
        let id = try #require(cloud.accounts.first).id
        cloud.setPinned(id, false)
        cloud.rename(id, issuer: "GitHub", accountName: "alice")
        #expect(!cloud.hasPendingChanges)
    }

    @Test func readsAVaultLockedAtLaunchOnceTheDeviceIsUnlocked() async throws {
        let defaults = makeTestDefaults()
        let store = EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true)
        try store.save(EnteSavedSession(server: server, email: "alice@example.com", token: "t", authenticatorKey: EnteCrypto.randomBytes(32)))
        var vault = EnteVault(email: "alice@example.com", server: server)
        vault.merge([(EnteAuthenticatorEntity(id: "e0", encryptedData: nil, header: nil, isDeleted: false, updatedAt: 1),
                      rawData("otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP"))], latest: 1)
        _ = vault.add(rawData: rawData("otpauth://totp/GitLab:alice?secret=JBSWY3DPEHPK3PXP"))
        let storage = LockedVaultStorage()
        try storage.save(vault)

        // Launched in the background while the device is locked.
        let cloud = EnteCloud(store: store, storage: storage, session: OfflineURLProtocol.session, watch: WatchAccountSync(defaults: defaults))
        let model = MainViewModel(cloud: cloud)
        #expect(!cloud.isEnabled)
        #expect(model.cloudAccounts.isEmpty)

        // The change that wasn't uploaded yet is still there, so the vault wasn't replaced with an empty one.
        storage.unlock()
        await cloud.syncAutomatically()
        #expect(model.cloudAccounts.map(\.title) == ["GitHub", "GitLab"])
        #expect(cloud.hasPendingChanges)
    }

    @Test func sortsTheAccountsByName() throws {
        let cloud = try cloud(with: ["otpauth://totp/B:alice?secret=JBSWY3DPEHPK3PXP", "otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP"])
        let model = MainViewModel(cloud: cloud)
        #expect(model.accounts.map(\.title) == ["A", "B"])
    }
}

#if DEBUG && (targetEnvironment(simulator) || os(macOS))

/// Syncs the vault with the fake Ente server in both directions, with another device changing the same account.
@MainActor @Suite(.serialized)
struct EnteCloudSyncTests {

    /// Another device signed in to the same account, which writes to Ente directly.
    struct OtherDevice {
        let api: EnteAPIClient
        let token: String
        let key: Data

        @discardableResult
        func add(_ uri: String) async throws -> String {
            let encrypted = try EnteAuthenticatorSync.encrypt(rawData(uri), authenticatorKey: key)
            return try await api.createAuthenticatorEntity(token: token, encryptedData: encrypted.encryptedData, header: encrypted.header).id
        }

        func update(_ id: String, _ uri: String) async throws {
            let encrypted = try EnteAuthenticatorSync.encrypt(rawData(uri), authenticatorKey: key)
            try await api.updateAuthenticatorEntity(token: token, id: id, encryptedData: encrypted.encryptedData, header: encrypted.header)
        }

        func delete(_ id: String) async throws {
            try await api.deleteAuthenticatorEntity(token: token, id: id)
        }

        /// The plain text of each entity that isn't deleted, by id.
        func entities() async throws -> [String: String] {
            let decrypted = try await EnteAuthenticatorSync.decryptedEntities(api: api, token: token, authenticatorKey: key)
            return Dictionary(uniqueKeysWithValues: decrypted.compactMap { id, rawData in rawData.map { (id, $0) } })
        }
    }

    let defaults = makeTestDefaults()
    let keychain = InMemoryKeychain()
    /// Kept across the clouds of a test, like the vault file across launches.
    let storage = InMemoryVaultStorage()
    let online: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeEnteServer.self]
        online = URLSession(configuration: configuration)
    }

    private var store: EnteSessionStore {
        EnteSessionStore(keychain: keychain, defaults: defaults, canSave: true)
    }

    /// Signs in to a new account on the fake server and saves the session, like signing in with Stay signed in does.
    /// The account signs in with an email code rather than SRP, whose arithmetic is slow in Debug builds.
    private func signIn() async throws -> OtherDevice {
        let api = try EnteAPIClient(server: FakeEnteServer.newAccountServer(), session: online)
        let (flow, step) = try await EnteLoginFlow.start(api: api, email: "alice+nosrp@example.com", password: FakeEnteServer.password)
        #expect(step == .emailCode)
        #expect(try await flow.submitCode(FakeEnteServer.code) == .complete)
        let keys = try #require(flow.keys)
        let key = try await EnteAuthenticatorSync.authenticatorKeyCreatingIfNeeded(api: api, keys: keys)
        try store.save(EnteSavedSession(server: api.server, email: "alice@example.com", token: keys.token, authenticatorKey: key))
        return OtherDevice(api: api, token: keys.token, key: key)
    }

    private func cloud(session: URLSession? = nil) -> EnteCloud {
        EnteCloud(store: store, storage: storage, session: session ?? online, watch: WatchAccountSync(defaults: defaults))
    }

    private func template(_ issuer: String, _ type: YubiKitOATHSession.CredentialType = .totp(period: 30)) throws -> YubiKitOATHSession.CredentialTemplate {
        try YubiKitOATHSession.CredentialTemplate(type: type, algorithm: .sha1, secret: Data(base32Encoded: "JBSWY3DPEHPK3PXP")!,
                                                  issuer: issuer, accountName: "alice", digits: 6)
    }

    private func id(of issuer: String, in cloud: EnteCloud) throws -> String {
        try #require(cloud.accounts.first { $0.code.issuer == issuer }).id
    }

    @Test func changesGoBothWays() async throws {
        let other = try await signIn()
        let cloud = cloud()
        let gitHub = try await other.add("otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub")

        await cloud.sync()
        #expect(cloud.accounts.map(\.code.issuer) == ["GitHub"])

        // Added here, seen by the other device.
        #expect(try cloud.add(template("GitLab")) == .added)
        await cloud.sync()
        #expect(!cloud.hasPendingChanges)
        var entities = try await other.entities()
        #expect(entities.values.compactMap { EnteCodeParser.parse(id: "", rawData: $0)?.credentialId }.sorted() == ["GitHub:alice", "GitLab:alice"])

        // Renamed on the other device, then here.
        try await other.update(gitHub, "otpauth://totp/GitHub:bob?secret=JBSWY3DPEHPK3PXP&issuer=GitHub")
        await cloud.sync()
        #expect(cloud.accounts.first { $0.code.issuer == "GitHub" }?.code.accountName == "bob")
        cloud.rename(try id(of: "GitHub", in: cloud), issuer: "GitHub", accountName: "carol")
        await cloud.sync()
        entities = try await other.entities()
        #expect(EnteCodeParser.parse(id: "", rawData: entities[gitHub] ?? "")?.accountName == "carol")

        // Deleted here: moved to Ente's trash, like Ente Auth does.
        let gitLab = try #require(cloud.vault?.items.first { EnteCloudCode(rawData: $0.rawData ?? "")?.issuer == "GitLab" }?.entityID)
        cloud.delete(try id(of: "GitLab", in: cloud))
        await cloud.sync()
        entities = try await other.entities()
        #expect(EnteEntry(rawData: entities[gitLab] ?? "").isTrashed)
        #expect(!cloud.accounts.contains { $0.code.issuer == "GitLab" })

        // Deleted for good on the other device.
        try await other.delete(gitHub)
        await cloud.sync()
        #expect(cloud.accounts.isEmpty)
        #expect(cloud.vault?.items.count == 1)
    }

    @Test func changesMadeOfflineAreUploadedLater() async throws {
        let other = try await signIn()
        try await other.add("otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub")
        await cloud().sync()

        let offline = cloud(session: OfflineURLProtocol.session)
        #expect(offline.accounts.count == 1)
        #expect(try offline.add(template("GitLab")) == .added)
        offline.setPinned(try id(of: "GitHub", in: offline), true)
        await offline.sync(reportsErrors: false)
        #expect(offline.hasPendingChanges)
        #expect(offline.error == nil)
        #expect(offline.accounts.count == 2)

        // Back online, e.g. after a relaunch.
        let online = cloud()
        #expect(online.hasPendingChanges)
        await online.sync()
        #expect(!online.hasPendingChanges)
        let entities = try await other.entities().values
        #expect(entities.count == 2)
        #expect(entities.contains { EnteCodeParser.parse(id: "", rawData: $0)?.credentialId == "GitLab:alice" })
        #expect(entities.contains { EnteEntry(rawData: $0).isPinned })
    }

    @Test func anotherDevicesNewerChangeWins() async throws {
        let other = try await signIn()
        let id = try await other.add("otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub")
        await cloud().sync()

        // Renamed here while offline, and on the other device before this one synced again.
        let offline = cloud(session: OfflineURLProtocol.session)
        offline.rename(try self.id(of: "GitHub", in: offline), issuer: "GitHub", accountName: "here")
        await offline.sync()
        try await other.update(id, "otpauth://totp/GitHub:there?secret=JBSWY3DPEHPK3PXP&issuer=GitHub")

        let online = cloud()
        await online.sync()
        #expect(online.accounts.map(\.code.accountName) == ["there"])
        #expect(!online.hasPendingChanges)
        let entities = try await other.entities()
        #expect(EnteCodeParser.parse(id: "", rawData: entities[id] ?? "")?.accountName == "there")
    }

    @Test func aChangeToAnAccountDeletedElsewhereIsDropped() async throws {
        let other = try await signIn()
        let id = try await other.add("otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub")
        await cloud().sync()

        let offline = cloud(session: OfflineURLProtocol.session)
        offline.setPinned(try self.id(of: "GitHub", in: offline), true)
        try await other.delete(id)

        let online = cloud()
        await online.sync()
        #expect(online.vault?.items.isEmpty == true)
        #expect(try await other.entities().isEmpty)
    }

    @Test func hotpCountersMoveOnEverywhere() async throws {
        let other = try await signIn()
        let id = try await other.add("otpauth://hotp/VPN:alice?secret=\(rfcSecret)&issuer=VPN&counter=0")
        let cloud = cloud()
        await cloud.sync()

        #expect(cloud.nextHOTPCode(try self.id(of: "VPN", in: cloud)) == "755224")
        await cloud.sync()
        let entities = try await other.entities()
        #expect(EnteCloudCode(rawData: entities[id] ?? "")?.counter == 1)
    }

    @Test func aRejectedSessionKeepsTheVault() async throws {
        let other = try await signIn()
        try await other.add("otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub")
        await cloud().sync()

        // Ended from another device.
        try store.save(EnteSavedSession(server: other.api.server, email: "alice@example.com", token: "revoked", authenticatorKey: other.key))
        let cloud = cloud()
        _ = try? cloud.add(template("GitLab"))
        await cloud.sync()
        #expect(cloud.error != nil)
        #expect(store.savedAccount?.hasSession == false)
        // The codes still work and the change waits for the password.
        #expect(cloud.accounts.count == 2)
        #expect(cloud.hasPendingChanges)
    }

    @Test func signingInToAnotherAccountReplacesTheVault() async throws {
        let other = try await signIn()
        try await other.add("otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub")
        let cloud = cloud()
        await cloud.sync()
        #expect(cloud.accounts.count == 1)

        cloud.use(EnteSavedSession(server: other.api.server, email: "bob@example.com", token: other.token, authenticatorKey: other.key))
        #expect(cloud.email == "bob@example.com")
        #expect(cloud.accounts.isEmpty)
    }
}

#endif
