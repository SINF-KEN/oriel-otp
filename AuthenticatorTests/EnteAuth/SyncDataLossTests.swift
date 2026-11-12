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
import Testing
import YubiKit

@testable import OrielOTP

/// A vault file whose writes fail, e.g. a full disk, or a write while the device is locked.
nonisolated final class FailingVaultStorage: EnteVaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let storage = InMemoryVaultStorage()
    private var failsSaving = false

    func setFailsSaving(_ fails: Bool) { lock.withLock { failsSaving = fails } }
    func load() throws -> EnteVault? { try storage.load() }
    func save(_ vault: EnteVault) throws {
        if lock.withLock({ failsSaving }) { throw CocoaError(.fileWriteOutOfSpace) }
        try storage.save(vault)
    }
    func remove() { storage.remove() }
    func setAside() throws { try storage.setAside() }
}

/// Answers each request with `handler`, after waiting for `gate` if it is set, so a test can act while a request is
/// under way.
nonisolated final class GatedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var gate: DispatchSemaphore?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        Self.gate?.wait()
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatedURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// The plain text of an entity as Ente Auth stores it: the otpauth URL as a JSON string.
private func rawData(_ uri: String) -> String {
    String(decoding: try! JSONEncoder().encode(uri), as: UTF8.self)
}

/// Accounts must never be lost on the way between this device, the vault and Ente.
@MainActor @Suite(.serialized)
struct SyncDataLossTests {

    private let server = URL(string: "https://api.example.com")!

    private func template(_ issuer: String, _ type: YubiKitOATHSession.CredentialType = .totp(period: 30)) throws -> YubiKitOATHSession.CredentialTemplate {
        try YubiKitOATHSession.CredentialTemplate(type: type, algorithm: .sha1, secret: Data(base32Encoded: "JBSWY3DPEHPK3PXP")!,
                                                  issuer: issuer, accountName: "alice", digits: 6)
    }

    private func signedIn(storage: EnteVaultStorage, defaults: UserDefaults = makeTestDefaults(), keychain: InMemoryKeychain = InMemoryKeychain(),
                          device: DeviceAccounts? = nil, session: URLSession = OfflineURLProtocol.session) throws -> (EnteCloud, EnteSessionStore) {
        let store = EnteSessionStore(keychain: keychain, defaults: defaults, canSave: true)
        try store.save(EnteSavedSession(server: server, email: "alice@example.com", token: "t", authenticatorKey: EnteCrypto.randomBytes(32)))
        try storage.save(EnteVault(email: "alice@example.com", server: server))
        let cloud = EnteCloud(store: store, storage: storage, session: session, watch: WatchAccountSync(defaults: defaults), device: device)
        return (cloud, store)
    }

    // MARK: - Discarding the vault

    /// An account moved to Ente while offline is only in the vault. Signing out from the sync sheet puts it back on
    /// the device rather than losing it.
    @Test func signingOutFromTheSyncSheetKeepsAnAccountMovedOffline() async throws {
        let defaults = makeTestDefaults()
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        let (cloud, store) = try signedIn(storage: InMemoryVaultStorage(), defaults: defaults, device: device)
        let model = MainViewModel(cloud: cloud, device: device)
        _ = try model.addDeviceAccount(template("Bank"))
        let account = try #require(model.deviceAccounts.first)
        #expect(try model.moveToEnte(account) == .moved)
        #expect(cloud.hasPendingChanges)

        let sheet = EnteSyncViewModel(existingCredentialIds: [], store: store, defaults: defaults,
                                      session: OfflineURLProtocol.session, cloud: cloud)
        #expect(sheet.hasPendingChanges)
        sheet.signOut()
        while sheet.isBusy { await Task.yield() }

        #expect(!cloud.isEnabled)
        #expect(model.deviceAccounts.map(\.title) == ["Bank"])
    }

    /// If the accounts can't be put on the device, the vault file is kept, and read again when it can be.
    @Test func theVaultIsKeptUntilItsAccountsAreOnTheDevice() throws {
        let defaults = makeTestDefaults()
        let deviceStorage = MemoryDeviceStorage()
        let storage = InMemoryVaultStorage()
        let (cloud, store) = try signedIn(storage: storage, defaults: defaults, device: DeviceAccounts(storage: deviceStorage))
        _ = try cloud.add(template("Bank"))

        deviceStorage.saveError = CocoaError(.fileWriteOutOfSpace)
        store.remove()
        cloud.remove()
        #expect(!cloud.isEnabled)
        #expect(try storage.load()?.accountsNeverUploaded.count == 1)

        // The next launch, with room on the disk.
        deviceStorage.saveError = nil
        let device = DeviceAccounts(storage: deviceStorage)
        _ = EnteCloud(store: store, storage: storage, session: OfflineURLProtocol.session, watch: WatchAccountSync(defaults: defaults), device: device)
        #expect(device.accounts.map(\.code.issuer) == ["Bank"])
        #expect(try storage.load() == nil)
    }

    /// Signing in to another account, or without staying signed in, would replace a vault with changes that weren't
    /// uploaded. That is refused before anything is sent.
    @Test(arguments: [("bob@example.com", true), ("alice@example.com", false)])
    func signingInIsRefusedWhenItWouldLoseChanges(email: String, staySignedIn: Bool) async throws {
        let defaults = makeTestDefaults()
        // The cloud syncs offline on its own; the sheet's requests are counted.
        let (cloud, store) = try signedIn(storage: InMemoryVaultStorage(), defaults: defaults)
        _ = try cloud.add(template("Bank"))
        GatedURLProtocol.requestCount = 0

        let sheet = EnteSyncViewModel(existingCredentialIds: [], store: store, defaults: defaults,
                                      session: GatedURLProtocol.session, cloud: cloud)
        sheet.usesOwnServer = true
        sheet.server = server.absoluteString + "/"
        sheet.email = email
        sheet.password = "password"
        sheet.staySignedIn = staySignedIn
        sheet.signIn()
        while sheet.isBusy { await Task.yield() }

        guard case .unsyncedChanges = try #require(sheet.error as? EnteSyncError) else {
            Issue.record("Expected unsyncedChanges, got \(String(describing: sheet.error))")
            return
        }
        #expect(GatedURLProtocol.requestCount == 0)
        #expect(cloud.hasPendingChanges)
        #expect(cloud.email == "alice@example.com")
    }

    /// The same account comes back with its server written differently, e.g. with a trailing slash.
    @Test func aDifferentlySpelledServerKeepsTheVault() throws {
        let (cloud, _) = try signedIn(storage: InMemoryVaultStorage())
        _ = try cloud.add(template("Bank"))

        cloud.use(EnteSavedSession(server: URL(string: "https://API.example.com/")!, email: "Alice@example.com", token: "t2",
                                   authenticatorKey: EnteCrypto.randomBytes(32)))
        #expect(cloud.hasPendingChanges)
        #expect(cloud.accounts.map(\.code.issuer) == ["Bank"])
    }

    /// Before the first unlock after a restart, neither the vault file nor the saved account can be read. The file
    /// mustn't be taken for missing and written over.
    @Test func aVaultUnavailableBeforeTheFirstUnlockIsntWrittenOver() throws {
        let defaults = makeTestDefaults()
        let storage = LockedVaultStorage()
        var vault = EnteVault(email: "alice@example.com", server: server)
        _ = vault.add(rawData: rawData("otpauth://totp/Bank:alice?secret=JBSWY3DPEHPK3PXP&issuer=Bank"))
        try storage.save(vault)
        let cloud = EnteCloud(store: EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true), storage: storage,
                              session: OfflineURLProtocol.session, watch: WatchAccountSync(defaults: defaults))
        #expect(!cloud.isEnabled)

        // Still locked: nothing is written.
        let saved = EnteSavedSession(server: server, email: "alice@example.com", token: "t", authenticatorKey: EnteCrypto.randomBytes(32))
        cloud.use(saved)
        storage.unlock()
        #expect(try storage.load()?.items.count == 1)

        // Unlocked: the vault is read for the session.
        cloud.use(saved)
        #expect(cloud.accounts.map(\.code.issuer) == ["Bank"])
        #expect(try storage.load()?.items.count == 1)
    }

    // MARK: - Saving

    /// A vault that can't be saved keeps nothing in memory, so moving to Ente fails and the device keeps its copy.
    @Test func movingToEnteKeepsTheDeviceCopyIfTheVaultCantBeSaved() throws {
        let storage = FailingVaultStorage()
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        let (cloud, _) = try signedIn(storage: storage, device: device)
        let model = MainViewModel(cloud: cloud, device: device)
        _ = try model.addDeviceAccount(template("Bank"))
        let account = try #require(model.deviceAccounts.first)

        storage.setFailsSaving(true)
        #expect(throws: CocoaError.self) { try model.moveToEnte(account) }
        #expect(model.deviceAccounts.map(\.title) == ["Bank"])
        #expect(cloud.accounts.isEmpty)
        #expect(try storage.load()?.items.isEmpty == true)
    }

    /// A HOTP code whose counter couldn't be saved would be shown again after a relaunch.
    @Test func aHOTPCodeIsntGivenOutIfItsCounterCantBeSaved() throws {
        let storage = FailingVaultStorage()
        let (cloud, _) = try signedIn(storage: storage)
        _ = try cloud.add(template("VPN", .hotp(counter: 0)))
        let id = try #require(cloud.accounts.first).id

        storage.setFailsSaving(true)
        #expect(cloud.nextHOTPCode(id) == nil)
        #expect(throws: CocoaError.self) { try cloud.rename(id, issuer: "VPN", accountName: "bob") }
        #expect(cloud.accounts.first?.code.counter == 0)
        #expect(cloud.accounts.first?.code.accountName == "alice")
    }

    /// The last counter has no next one, and adding one would crash.
    @Test func theLastHOTPCounterGivesNoCode() throws {
        let uri = "otpauth://hotp/VPN:alice?secret=JBSWY3DPEHPK3PXP&issuer=VPN&counter=\(UInt64.max)"
        let (cloud, _) = try signedIn(storage: InMemoryVaultStorage())
        _ = try cloud.add(rawData: rawData(uri))
        let id = try #require(cloud.vault?.items.first).id
        #expect(cloud.nextHOTPCode(id) == nil)

        let deviceStorage = MemoryDeviceStorage()
        deviceStorage.items = [DeviceAccountItem(id: "d", rawData: rawData(uri))]
        #expect(DeviceAccounts(storage: deviceStorage).nextHOTPCode("d") == nil)
    }

    // MARK: - Merging

    private func entity(_ id: String, updatedAt: Int64) -> EnteAuthenticatorEntity {
        EnteAuthenticatorEntity(id: id, encryptedData: nil, header: nil, isDeleted: false, updatedAt: updatedAt)
    }

    private func hotp(_ counter: UInt64, name: String = "alice") -> String {
        rawData("otpauth://hotp/VPN:\(name)?secret=JBSWY3DPEHPK3PXP&issuer=VPN&counter=\(counter)")
    }

    private func counter(of item: EnteVaultItem) -> UInt64? {
        item.rawData.flatMap(EnteEntryEditor.init(rawData:))?.counter
    }

    /// Another device that moved the counter less far doesn't bring back codes shown here.
    @Test func aHOTPCounterNeverMovesBack() throws {
        var vault = EnteVault(email: "alice@example.com", server: server)
        vault.merge([(entity("e", updatedAt: 1), hotp(5))], latest: 1)
        vault.merge([(entity("e", updatedAt: 2), hotp(3, name: "bob"))], latest: 2)
        let item = try #require(vault.items.first)
        #expect(counter(of: item) == 5)
        #expect(item.rawData.flatMap(EnteCloudCode.init(rawData:))?.accountName == "bob")
        // Uploaded, so the other devices move on too.
        #expect(item.isPending)

        vault.merge([(entity("e", updatedAt: 3), hotp(7))], latest: 3)
        #expect(counter(of: vault.items[0]) == 7)
        #expect(!vault.items[0].isPending)
    }

    /// An update whose answer was lost comes back in the diff as this device's own, so a later change stays.
    @Test func anUpdateWhoseAnswerWasLostIsRecognized() throws {
        var vault = EnteVault(email: "alice@example.com", server: server)
        vault.merge([(entity("e", updatedAt: 1), hotp(0))], latest: 1)
        #expect(vault.edit("e") { $0.counter = 1 })
        vault.markUploading("e", rawData: hotp(1))
        // The answer is lost, and the next code is shown.
        #expect(vault.edit("e") { $0.isPinned = true })
        let pinned = try #require(vault.items[0].rawData)

        vault.merge([(entity("e", updatedAt: 2), hotp(1))], latest: 2)
        #expect(vault.items[0].rawData == pinned)
        #expect(vault.items[0].serverUpdatedAt == 2)
        #expect(vault.items[0].isPending)
    }

    /// An entity that can't be decrypted, e.g. written with another key, keeps the copy that can.
    @Test func anUndecryptableVersionKeepsTheGoodCopy() {
        var vault = EnteVault(email: "alice@example.com", server: server)
        vault.merge([(entity("e", updatedAt: 1), hotp(2))], latest: 1)
        vault.merge([(entity("e", updatedAt: 2), nil)], latest: 2)
        #expect(vault.items[0].rawData == hotp(2))
        #expect(vault.lastSyncTime == 2)
    }

    /// An account was uploaded but the answer was lost, then it was changed or deleted. It is matched with its entity
    /// rather than uploaded twice, and the change goes to that entity.
    @Test(arguments: [false, true])
    func aCreateWhoseAnswerWasLostIsMatchedAfterAChange(deleting: Bool) throws {
        var vault = EnteVault(email: "alice@example.com", server: server)
        let added = rawData("otpauth://totp/Bank:alice?secret=JBSWY3DPEHPK3PXP&issuer=Bank")
        let id = vault.add(rawData: added)
        vault.markUploading(id, rawData: added)
        #expect(vault.edit(id) { deleting ? ($0.isTrashed = true) : $0.rename(issuer: "Bank", accountName: "bob") })
        let changed = try #require(vault.items[0].rawData)

        vault.merge([(entity("server-id", updatedAt: 3), added)], latest: 3)
        #expect(vault.items.count == 1)
        #expect(vault.items[0].entityID == "server-id")
        #expect(vault.items[0].rawData == changed)
        #expect(vault.items[0].isPending)
        #expect(vault.accountsNeverUploaded.isEmpty)
    }

    // MARK: - Session

    /// A sync that was under way when the person signed in again gets the old token rejected. That says nothing about
    /// the new one, which is kept.
    @Test func aStaleRejectionKeepsTheNewSession() async throws {
        let defaults = makeTestDefaults()
        let keychain = InMemoryKeychain()
        let (cloud, store) = try signedIn(storage: InMemoryVaultStorage(), defaults: defaults, keychain: keychain, session: GatedURLProtocol.session)
        let old = EnteSavedSession(server: server, email: "alice@example.com", token: "old", authenticatorKey: EnteCrypto.randomBytes(32))
        cloud.use(old)
        let gate = DispatchSemaphore(value: 0)
        GatedURLProtocol.requestCount = 0
        GatedURLProtocol.gate = gate
        GatedURLProtocol.handler = { _ in (401, Data()) }
        defer {
            GatedURLProtocol.gate = nil
            GatedURLProtocol.handler = nil
        }

        let sync = Task { await cloud.sync(unlock: false) }
        while GatedURLProtocol.requestCount == 0 { await Task.yield() }
        let new = EnteSavedSession(server: server, email: "alice@example.com", token: "new", authenticatorKey: old.authenticatorKey)
        try store.save(new)
        cloud.use(new)
        gate.signal()
        await sync.value

        #expect(store.savedAccount?.hasSession == true)
        #expect(cloud.error == nil)
    }

    // MARK: - Device accounts

    /// A file that can't be read, e.g. after going back to an earlier version, is set aside rather than written over.
    @Test func anUnreadableDeviceFileIsSetAside() throws {
        let storage = MemoryDeviceStorage()
        let existing = [DeviceAccountItem(id: "a", rawData: rawData("otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP"))]
        storage.items = existing
        storage.loadError = EncryptedFileError.unreadable
        let accounts = DeviceAccounts(storage: storage)
        #expect(accounts.accounts.isEmpty)
        #expect(storage.setAsideItems == nil)

        #expect(try accounts.add(template("GitLab")) == .added)
        #expect(storage.setAsideItems == .some(existing))
        #expect(storage.items?.count == 1)
    }

    /// The setting aside of the real file keeps it next to the new one.
    @Test func theRealFileIsSetAsideNextToTheNewOne() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Accounts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a sealed box".utf8).write(to: url)
        let key = InMemoryVaultKey()
        _ = try key.createKey()
        let file = DeviceAccountFile(url: url, keychain: key)

        let accounts = DeviceAccounts(storage: file)
        _ = try accounts.add(template("GitLab"))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains("Accounts"))
        let aside = try #require(names.first { $0.hasPrefix("Unreadable-") })
        #expect(try Data(contentsOf: directory.appending(path: aside)) == Data("not a sealed box".utf8))
    }
}
