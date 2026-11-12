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

#if os(iOS)

import Foundation
import Testing
import YubiKit
@testable import OrielOTP

/// The Apple Watch gets the accounts on this device as well as Ente Auth's.
@MainActor struct WatchDeviceAccountsTests {

    private let session = FakeWatchSession()
    private let keyItem = MemoryKeychainItem()
    private let defaults = makeTestDefaults()

    private func watch(enabled: Bool = true) -> WatchAccountSync {
        let watch = WatchAccountSync(session: session, keyItem: keyItem, defaults: defaults)
        if enabled { watch.enable() }
        return watch
    }

    private func cloud(watch: WatchAccountSync, device: DeviceAccounts, store: EnteSessionStore? = nil,
                       storage: InMemoryVaultStorage = InMemoryVaultStorage()) -> EnteCloud {
        EnteCloud(store: store ?? EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true),
                  storage: storage, session: OfflineURLProtocol.session, watch: watch, device: device)
    }

    private func template(_ issuer: String) throws -> YubiKitOATHSession.CredentialTemplate {
        try YubiKitOATHSession.CredentialTemplate(type: .totp(period: 30), algorithm: .sha1, secret: Data(base32Encoded: "JBSWY3DPEHPK3PXP")!,
                                                  issuer: issuer, accountName: "alice", digits: 6)
    }

    /// The issuers on the watch, nil if it has none or the context can't be opened.
    private var sentIssuers: [String]? {
        let key = keyItem.data.flatMap(WatchSyncKey.init(data:))
        guard case .accounts(let accounts) = WatchAccountsMessage.content(of: session.applicationContext, key: key)
        else { return nil }
        return accounts.compactMap(\.issuer).sorted()
    }

    private var isCleared: Bool {
        WatchAccountsMessage.content(of: session.applicationContext, key: nil) == .cleared
    }

    @Test func sendsTheAccountsOnThisDeviceWithoutEnte() throws {
        let watch = watch()
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        let model = MainViewModel(cloud: cloud(watch: watch, device: device), device: device)
        _ = try model.addDeviceAccount(template("GitLab"))
        #expect(sentIssuers == ["GitLab"])
    }

    @Test func nothingIsSentWhileTheSwitchIsOff() throws {
        let watch = watch(enabled: false)
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        let model = MainViewModel(cloud: cloud(watch: watch, device: device), device: device)
        _ = try model.addDeviceAccount(template("GitLab"))
        #expect(session.applicationContext.isEmpty)
    }

    /// Ente Auth's accounts are sent with the ones on this device. Signing out of Ente takes them off the watch and
    /// leaves the switch on with the accounts on this device; deleting the last one clears the watch.
    @Test func signingOutOfEnteKeepsTheAccountsOnThisDevice() async throws {
        let watch = watch()
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        let store = EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true)
        let session = EnteSavedSession(server: URL(string: "https://ente.test")!, email: "alice@example.com", token: "t",
                                       authenticatorKey: EnteCrypto.randomBytes(32))
        try store.save(session)
        // An account already synced from Ente. One that never reached Ente would be kept on this device when signing out.
        var vault = EnteVault(email: session.email, server: session.server)
        let rawData = String(decoding: try JSONEncoder().encode("otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"),
                             as: UTF8.self)
        vault.merge([(EnteAuthenticatorEntity(id: "github", encryptedData: nil, header: nil, isDeleted: false, updatedAt: 1), rawData)],
                    latest: 1)
        let storage = InMemoryVaultStorage()
        try storage.save(vault)
        let cloud = cloud(watch: watch, device: device, store: store, storage: storage)
        let model = MainViewModel(cloud: cloud, device: device)
        cloud.use(session)
        _ = try model.addDeviceAccount(template("GitLab"))
        #expect(sentIssuers == ["GitHub", "GitLab"])

        await store.signOut(cloud: cloud, session: OfflineURLProtocol.session)
        #expect(watch.isEnabled)
        #expect(sentIssuers == ["GitLab"])

        let account = try #require(model.deviceAccounts.first)
        await withCheckedContinuation { done in model.deleteAccount(account) { done.resume() } }
        #expect(isCleared)
    }

    /// Until the accounts on this device can be read, e.g. after a launch on a locked device, they'd look like none:
    /// nothing is sent, so they aren't taken off the watch.
    @Test func nothingIsSentWhileTheAccountsOnThisDeviceCantBeRead() throws {
        let storage = MemoryDeviceStorage()
        storage.loadError = EncryptedFileError.unavailable
        let device = DeviceAccounts(storage: storage)
        #expect(device.isLocked)
        let cloud = cloud(watch: watch(), device: device)
        cloud.updateWatch()
        #expect(session.applicationContext.isEmpty)

        storage.loadError = nil
        storage.items = []
        device.onChange = { cloud.updateWatch() }
        device.loadIfLocked()
        #expect(isCleared)
    }
}

#endif
