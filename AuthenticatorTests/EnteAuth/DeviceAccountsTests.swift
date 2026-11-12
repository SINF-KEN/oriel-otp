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

/// Keeps the accounts in memory, and can fail like the file does.
final class MemoryDeviceStorage: DeviceAccountStorage, @unchecked Sendable {
    var items: [DeviceAccountItem]?
    var loadError: Error?
    var saveError: Error?
    var saveCount = 0

    func load() throws -> [DeviceAccountItem]? {
        if let loadError { throw loadError }
        return items
    }

    func save(_ items: [DeviceAccountItem]) throws {
        if let saveError { throw saveError }
        saveCount += 1
        self.items = items
    }

    /// What was set aside, like the file moved out of the way.
    var setAsideItems: [DeviceAccountItem]??

    func setAside() throws {
        setAsideItems = .some(items)
        items = nil
    }
}

private final class MemoryKey: EncryptedFileKey, @unchecked Sendable {
    var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { key }
    func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        self.key = key
        return key
    }
    func removeKey() { key = nil }
}

private struct SaveFailed: Error {}

@MainActor struct DeviceAccountsTests {

    private func template(_ issuer: String, hotp: Bool = false) throws -> YubiKitOATHSession.CredentialTemplate {
        let kind = hotp ? "hotp" : "totp"
        let url = try #require(URL(string: "otpauth://\(kind)/\(issuer):alice?secret=JBSWY3DPEHPK3PXP&issuer=\(issuer)" + (hotp ? "&counter=0" : "")))
        return try YubiKitOATHSession.CredentialTemplate(otpauthURL: url)
    }

    @Test func accountsSurviveARelaunch() throws {
        let storage = MemoryDeviceStorage()
        let accounts = DeviceAccounts(storage: storage)
        #expect(try accounts.add(template("GitHub")) == .added)
        let id = try #require(accounts.accounts.first).id
        try accounts.rename(id, issuer: "GitHub", accountName: "bob")
        try accounts.setPinned(id, true)

        let relaunched = DeviceAccounts(storage: storage)
        let code = try #require(relaunched.accounts.first).code
        #expect(code.issuer == "GitHub")
        #expect(code.accountName == "bob")
        #expect(code.isPinned)
    }

    @Test func anAccountWithTheSameNameIsNotAddedTwice() throws {
        let accounts = DeviceAccounts(storage: MemoryDeviceStorage())
        #expect(try accounts.add(template("GitHub")) == .added)
        #expect(try accounts.add(template("GitHub")) == .alreadyPresent)
        #expect(accounts.accounts.count == 1)
    }

    @Test func aChangeThatCantBeSavedIsReportedAndUndone() throws {
        let storage = MemoryDeviceStorage()
        let accounts = DeviceAccounts(storage: storage)
        storage.saveError = SaveFailed()
        #expect(throws: SaveFailed.self) { try accounts.add(template("GitHub")) }
        #expect(accounts.accounts.isEmpty)
    }

    @Test func nothingIsSavedOverAFileThatCouldntBeRead() throws {
        let storage = MemoryDeviceStorage()
        let existing = DeviceAccounts(storage: storage)
        _ = try existing.add(template("GitHub"))
        let saved = storage.saveCount

        storage.loadError = EncryptedFileError.unavailable
        let accounts = DeviceAccounts(storage: storage)
        #expect(accounts.accounts.isEmpty)
        #expect(throws: DeviceAccountsError.self) { try accounts.add(template("GitLab")) }
        #expect(storage.saveCount == saved)

        storage.loadError = nil
        var changes = 0
        accounts.onChange = { changes += 1 }
        accounts.loadIfLocked()
        #expect(accounts.accounts.map(\.code.issuer) == ["GitHub"])
        #expect(changes == 1)
        #expect(try accounts.add(template("GitLab")) == .added)
    }

    @Test func aHOTPCodeIsNotGivenOutAgain() throws {
        let storage = MemoryDeviceStorage()
        let accounts = DeviceAccounts(storage: storage)
        _ = try accounts.add(template("VPN", hotp: true))
        let id = try #require(accounts.accounts.first).id

        let first = try #require(accounts.nextHOTPCode(id))
        let second = try #require(DeviceAccounts(storage: storage).nextHOTPCode(id))
        #expect(first != second)
        #expect(accounts.accounts.isEmpty == false)

        // Without saving the counter, the same code would come back after a relaunch.
        storage.saveError = SaveFailed()
        #expect(DeviceAccounts(storage: storage).nextHOTPCode(id) == nil)
    }

    @Test func theFileIsEncryptedAndReadBack() throws {
        let url = FileManager.default.temporaryDirectory.appending(components: UUID().uuidString, "Accounts")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keychain = MemoryKey()
        let file = DeviceAccountFile(url: url, keychain: keychain)
        let accounts = DeviceAccounts(storage: file)
        _ = try accounts.add(template("GitHub"))

        let data = try Data(contentsOf: url)
        #expect(data.range(of: Data("JBSWY3DPEHPK3PXP".utf8)) == nil)
        #expect(data.range(of: Data("GitHub".utf8)) == nil)
        #expect(DeviceAccounts(storage: file).accounts.map(\.code.issuer) == ["GitHub"])
    }

    // MARK: - In the list

    @Test func aPersonWithoutAKeyOrEnteAccountGetsCodes() throws {
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        let model = MainViewModel(cloud: signedOutCloud(), device: device)
        #expect(!model.hasAccounts)

        _ = try model.addDeviceAccount(template("GitHub"))
        #expect(model.hasAccounts)
        #expect(!model.accountsLoaded)
        #expect(!model.showsAccountLocations)
        let account = try #require(model.accounts.first)
        #expect(account.isOnDevice)
        #expect(account.canRename)
        #expect(account.otp?.code.count == 6)

        var deleted = false
        model.deleteAccount(account) { deleted = true }
        #expect(deleted)
        #expect(!model.hasAccounts)
    }

    @Test func theAccountsStayWhenSigningOutOfEnte() throws {
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        let cloud = try signedInCloud()
        let model = MainViewModel(cloud: cloud, device: device)
        _ = try model.addDeviceAccount(template("GitHub"))

        cloud.remove()
        #expect(model.deviceAccounts.map(\.title) == ["GitHub"])
    }

    @Test func movingToEnteKeepsTheAccountOnceAndItsPin() throws {
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        let cloud = try signedInCloud()
        let model = MainViewModel(cloud: cloud, device: device)
        _ = try model.addDeviceAccount(template("GitHub"))
        let account = try #require(model.deviceAccounts.first)
        account.isPinned = true
        #expect(model.canMoveToEnte(account))

        #expect(try model.moveToEnte(account) == .moved)
        #expect(model.deviceAccounts.isEmpty)
        let moved = try #require(model.cloudAccounts.first)
        #expect(moved.title == "GitHub")
        #expect(moved.isPinned)
    }

    @Test func movingToEnteLeavesTheAccountWhenEnteHasOneWithTheSameName() throws {
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        let cloud = try signedInCloud()
        let model = MainViewModel(cloud: cloud, device: device)
        _ = try model.addCloudAccount(template("GitHub"))
        _ = try model.addDeviceAccount(template("GitHub"))
        let account = try #require(model.deviceAccounts.first)

        #expect(try model.moveToEnte(account) == .alreadyInEnte)
        #expect(model.deviceAccounts.count == 1)
        #expect(model.cloudAccounts.count == 1)
        #expect(model.showsAccountLocations)
    }

    @Test func aHOTPAccountCanBeMovedToAYubiKeyButNotCopied() throws {
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        let model = MainViewModel(cloud: signedOutCloud(), device: device)
        _ = try model.addDeviceAccount(template("VPN", hotp: true))
        let account = try #require(model.deviceAccounts.first)
        #expect(model.canCopyToYubiKey(account, moving: true))
        #expect(!model.canCopyToYubiKey(account, moving: false))
    }

    private func signedOutCloud() -> EnteCloud {
        let defaults = makeTestDefaults()
        return EnteCloud(store: EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true), storage: InMemoryVaultStorage(),
                         session: OfflineURLProtocol.session, watch: WatchAccountSync(defaults: defaults))
    }

    private func signedInCloud() throws -> EnteCloud {
        let defaults = makeTestDefaults()
        let server = try #require(URL(string: "https://api.example.com"))
        let store = EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true)
        try store.save(EnteSavedSession(server: server, email: "alice@example.com", token: "t", authenticatorKey: EnteCrypto.randomBytes(32)))
        let storage = InMemoryVaultStorage()
        try storage.save(EnteVault(email: "alice@example.com", server: server))
        return EnteCloud(store: store, storage: storage, session: OfflineURLProtocol.session, watch: WatchAccountSync(defaults: defaults))
    }
}
