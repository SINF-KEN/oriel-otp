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

@testable import OrielOTP

/// Stands in for the keychain. It remembers which items would be protected by Face ID or Touch ID.
nonisolated final class InMemoryKeychain: EnteSessionKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var protectedItems: Set<String> = []

    func hasValue(for userAccount: String) -> Bool {
        lock.withLock { items[userAccount] != nil }
    }

    func isProtected(_ userAccount: String) -> Bool {
        lock.withLock { protectedItems.contains(userAccount) }
    }

    func setValue(_ value: Data, useAuthentication: Bool, for userAccount: String) throws {
        lock.withLock {
            items[userAccount] = value
            if useAuthentication {
                protectedItems.insert(userAccount)
            } else {
                protectedItems.remove(userAccount)
            }
        }
    }

    func getValue(for userAccount: String) async throws -> Data {
        guard let value = lock.withLock({ items[userAccount] }) else { throw SecureStoreError.itemNotFound }
        return value
    }

    func removeValue(for userAccount: String) throws {
        lock.withLock {
            items[userAccount] = nil
            protectedItems.remove(userAccount)
        }
    }
}

/// Preferences of their own for each test, so tests don't see each other's saved account.
func makeTestDefaults() -> UserDefaults {
    let name = "EnteTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor struct EnteSessionStoreTests {

    let keychain = InMemoryKeychain()
    let defaults = makeTestDefaults()
    var store: EnteSessionStore { EnteSessionStore(keychain: keychain, defaults: defaults, canSave: true) }

    let session = EnteSavedSession(server: URL(string: "https://ente.example.org")!, email: "alice@example.com",
                                   token: "the-token", authenticatorKey: Data(repeating: 7, count: 32))

    @Test func savesTheTokenAndKeyBehindAuthentication() async throws {
        try store.save(session)
        #expect(keychain.isProtected("session"))
        #expect(try await store.unlock() == session)
    }

    @Test func showsTheAccountWithoutUnlocking() throws {
        #expect(store.savedAccount == nil)
        try store.save(session)
        #expect(store.savedAccount == EnteSavedAccount(email: "alice@example.com", server: session.server, hasSession: true))
        #expect(store.savedEmail == "alice@example.com")
    }

    @Test func aRejectedSessionKeepsTheAccount() async throws {
        try store.save(session)
        store.forgetSession()
        #expect(store.savedAccount == EnteSavedAccount(email: "alice@example.com", server: session.server, hasSession: false))
        // No session to add accounts with.
        #expect(store.savedEmail == nil)
        await #expect(throws: EnteAuthenticatorSyncError.self) { try await store.unlock() }
    }

    @Test func removeForgetsTheAccount() throws {
        try store.save(session)
        store.remove()
        #expect(store.savedAccount == nil)
        #expect(!keychain.hasValue(for: "session"))
    }

    @Test func sessionsSavedBeforeTheServerWasStoredUseTheSignInServer() throws {
        // Earlier versions only stored the email next to the keychain item.
        try keychain.setValue(Data(), useAuthentication: true, for: "session")
        defaults.set("alice@example.com", forKey: "EnteAuth.SavedSessionEmail")
        #expect(store.savedAccount?.server == EnteAPIClient.defaultServer)
        defaults.set("https://ente.example.org", forKey: "EnteAuth.ServerURL")
        #expect(store.savedAccount?.server == URL(string: "https://ente.example.org")!)
    }
}

#if DEBUG && (targetEnvironment(simulator) || os(macOS))

/// Signs in to the demo server like a user would, then relaunches the sync screen with the same keychain.
@MainActor @Suite(.serialized)
struct EnteSavedAccountTests {

    let keychain = InMemoryKeychain()
    let defaults = makeTestDefaults()

    init() {
        URLProtocol.registerClass(FakeEnteServer.self)
    }

    private func makeModel(canSave: Bool = true) -> EnteSyncViewModel {
        EnteSyncViewModel(existingCredentialIds: [], store: EnteSessionStore(keychain: keychain, defaults: defaults, canSave: canSave),
                          defaults: defaults, watch: WatchAccountSync(defaults: defaults))
    }

    /// Waits for the model's network and crypto work to finish.
    private func settle(_ model: EnteSyncViewModel) async throws {
        for _ in 0..<400 where model.isBusy {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!model.isBusy)
    }

    private func signIn(_ model: EnteSyncViewModel) async throws {
        model.email = "alice@example.com"
        model.server = FakeEnteServer.server.absoluteString
        model.signIn()
        try await settle(model)
        #expect(model.phase == .password)
        model.password = FakeEnteServer.password
        model.submitPassword()
        try await settle(model)
        #expect(model.error == nil)
        #expect(model.phase == .accounts)
    }

    @Test func staysSignedInByDefault() {
        #expect(makeModel().staySignedIn)
        #expect(!makeModel(canSave: false).staySignedIn)
    }

    @Test func syncsAfterARelaunchWithoutThePassword() async throws {
        try await signIn(makeModel())
        let saved = try await EnteSessionStore(keychain: keychain, defaults: defaults, canSave: true).unlock()
        #expect(saved.server == FakeEnteServer.server)
        #expect(!saved.token.isEmpty)
        #expect(saved.authenticatorKey.count == 32)

        let relaunched = makeModel()
        #expect(relaunched.phase == .savedSession(email: "alice@example.com"))
        relaunched.useSavedSession()
        try await settle(relaunched)
        #expect(relaunched.error == nil)
        #expect(relaunched.phase == .accounts)
        #expect(!relaunched.codes.isEmpty)
        #expect(relaunched.password.isEmpty)
    }

    @Test func aRejectedTokenAsksForThePasswordAndKeepsTheAccount() async throws {
        let store = EnteSessionStore(keychain: keychain, defaults: defaults, canSave: true)
        try store.save(EnteSavedSession(server: FakeEnteServer.server, email: "alice@example.com", token: "revoked",
                                        authenticatorKey: EnteCrypto.randomBytes(32)))
        let model = makeModel()
        model.useSavedSession()
        try await settle(model)
        #expect(model.phase == .password)
        #expect(model.email == "alice@example.com")
        #expect(store.savedAccount == EnteSavedAccount(email: "alice@example.com", server: FakeEnteServer.server, hasSession: false))

        // Opening the sync screen again goes straight to signing in to the same account.
        let reopened = makeModel()
        #expect(reopened.phase == .signIn)
        #expect(reopened.email == "alice@example.com")
        #expect(reopened.server == FakeEnteServer.server.absoluteString)

        model.password = FakeEnteServer.password
        model.submitPassword()
        try await settle(model)
        #expect(model.phase == .accounts)
        #expect(store.savedAccount?.hasSession == true)
    }

    @Test func signOutForgetsTheAccountAndDisablesTheWatch() async throws {
        let store = EnteSessionStore(keychain: keychain, defaults: defaults, canSave: true)
        let watch = WatchAccountSync(defaults: defaults)
        watch.enable()
        try store.save(EnteSavedSession(server: FakeEnteServer.server, email: "alice@example.com", token: "the-token",
                                        authenticatorKey: EnteCrypto.randomBytes(32)))
        await store.signOut(watch: watch)
        #expect(store.savedAccount == nil)
        #expect(!keychain.hasValue(for: "session"))
        #expect(!watch.isEnabled)
    }

    @Test func notStayingSignedInForgetsTheAccount() async throws {
        let store = EnteSessionStore(keychain: keychain, defaults: defaults, canSave: true)
        try store.save(EnteSavedSession(server: FakeEnteServer.server, email: "alice@example.com", token: "revoked",
                                        authenticatorKey: EnteCrypto.randomBytes(32)))
        store.forgetSession()
        let model = makeModel()
        model.staySignedIn = false
        try await signIn(model)
        #expect(store.savedAccount == nil)
        model.close()
    }
}

#endif
