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

/// Stands in for the keychain. It remembers which items would be protected by Face ID or Touch ID, and how each
/// item was written: an update keeps the access control an item was added with.
nonisolated final class InMemoryKeychain: EnteSessionKeychain, @unchecked Sendable {
    enum Write: Equatable {
        case add, update, remove
    }

    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var protectedItems: Set<String> = []
    private var _writes: [Write] = []

    var writes: [Write] {
        lock.withLock { _writes }
    }

    func hasValue(for userAccount: String) -> Bool {
        lock.withLock { items[userAccount] != nil }
    }

    func isProtected(_ userAccount: String) -> Bool {
        lock.withLock { protectedItems.contains(userAccount) }
    }

    func setValue(_ value: Data, useAuthentication: Bool, for userAccount: String) throws {
        lock.withLock {
            _writes.append(items[userAccount] == nil ? .add : .update)
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
            if items[userAccount] != nil {
                _writes.append(.remove)
            }
            items[userAccount] = nil
            protectedItems.remove(userAccount)
        }
    }
}

/// A server that doesn't answer `POST /users/logout` until told to fail it.
nonisolated final class UnansweredLogoutServer: URLProtocol, @unchecked Sendable {
    static let server = URL(string: "https://unanswered-logout.ente.test")!

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [UnansweredLogoutServer] = []
    nonisolated(unsafe) private static var receivedTokens: [String] = []

    /// The tokens of the logout requests received.
    static var tokens: [String] {
        lock.withLock { receivedTokens }
    }

    /// Answers the waiting requests with a server error.
    static func fail() {
        let requests = lock.withLock {
            defer { pending = [] }
            return pending
        }
        for request in requests {
            let response = HTTPURLResponse(url: request.request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocolDidFinishLoading(request)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == server.host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock {
            Self.receivedTokens.append(request.value(forHTTPHeaderField: "X-Auth-Token") ?? "")
            Self.pending.append(self)
        }
    }
    override func stopLoading() {}
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

    @Test func saveReplacesTheItemSoItGetsTheCurrentAccessControl() throws {
        try store.save(session)
        try store.save(session)
        #expect(keychain.writes == [.add, .remove, .add])
        #expect(keychain.isProtected("session"))
    }

    @Test func aSessionSavedByAnEarlierVersionIsSavedAgainAfterUnlocking() async throws {
        // Earlier versions protected the item with Touch ID only on the Mac, and wrote no version.
        try keychain.setValue(try JSONEncoder().encode(session), useAuthentication: true, for: "session")
        defaults.set("alice@example.com", forKey: "EnteAuth.SavedSessionEmail")
        #expect(try await store.unlock() == session)
        #expect(keychain.writes == [.add, .remove, .add])
        #expect(try await store.unlock() == session)
        #expect(keychain.writes == [.add, .remove, .add])
    }

    @Test func signOutForgetsTheSessionWithoutWaitingForTheServer() async throws {
        URLProtocol.registerClass(UnansweredLogoutServer.self)
        let watch = WatchAccountSync(defaults: defaults)
        watch.enable()
        try store.save(EnteSavedSession(server: UnansweredLogoutServer.server, email: "alice@example.com", token: "old-token",
                                        authenticatorKey: Data(repeating: 7, count: 32)))
        await store.signOut(watch: watch, cloud: EnteCloud(store: store, storage: InMemoryVaultStorage(), watch: watch))
        #expect(store.savedAccount == nil)
        #expect(!keychain.hasValue(for: "session"))
        #expect(!watch.isEnabled)

        // The server is still asked to end the old session. When it fails later, a new session is kept.
        for _ in 0..<100 where UnansweredLogoutServer.tokens.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(UnansweredLogoutServer.tokens == ["old-token"])
        try store.save(session)
        UnansweredLogoutServer.fail()
        try await Task.sleep(for: .milliseconds(100))
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
    /// Kept across relaunches, like the vault file.
    let vaultStorage = InMemoryVaultStorage()

    init() {
        URLProtocol.registerClass(FakeEnteServer.self)
    }

    private func makeModel(canSave: Bool = true) -> EnteSyncViewModel {
        let store = EnteSessionStore(keychain: keychain, defaults: defaults, canSave: canSave)
        let watch = WatchAccountSync(defaults: defaults)
        return EnteSyncViewModel(existingCredentialIds: [], store: store, defaults: defaults, watch: watch,
                                 cloud: EnteCloud(store: store, storage: vaultStorage, watch: watch))
    }

    /// Waits for the model's network and crypto work to finish. On CI signing in can take most of a minute, as the
    /// other tests derive keys at the same time.
    private func settle(_ model: EnteSyncViewModel) async throws {
        for _ in 0..<2400 where model.isBusy {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!model.isBusy)
    }

    private func signIn(_ model: EnteSyncViewModel, server: URL = FakeEnteServer.server) async throws {
        model.email = "alice@example.com"
        model.server = server.absoluteString
        model.password = FakeEnteServer.password
        model.signIn()
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

    @Test func aNewAccountGetsAnAuthenticatorKeyAndStaysSignedIn() async throws {
        let server = FakeEnteServer.newAccountServer()
        let model = makeModel()
        try await signIn(model, server: server)
        #expect(model.codes.isEmpty)
        #expect(FakeEnteServer.hasAuthenticatorKey(server))
        #expect(try await EnteSessionStore(keychain: keychain, defaults: defaults, canSave: true).unlock().server == server)

        let relaunched = makeModel()
        #expect(relaunched.phase == .savedSession(email: "alice@example.com"))
        relaunched.useSavedSession()
        try await settle(relaunched)
        #expect(relaunched.error == nil)
        #expect(relaunched.phase == .accounts)
    }

    @Test func notStayingSignedInCreatesNoAuthenticatorKey() async throws {
        let server = FakeEnteServer.newAccountServer()
        let model = makeModel()
        model.staySignedIn = false
        try await signIn(model, server: server)
        #expect(!FakeEnteServer.hasAuthenticatorKey(server))
        model.close()
    }

    @Test func aRejectedTokenAsksForThePasswordAndKeepsTheAccount() async throws {
        let store = EnteSessionStore(keychain: keychain, defaults: defaults, canSave: true)
        try store.save(EnteSavedSession(server: FakeEnteServer.server, email: "alice@example.com", token: "revoked",
                                        authenticatorKey: EnteCrypto.randomBytes(32)))
        let model = makeModel()
        model.useSavedSession()
        try await settle(model)
        #expect(model.phase == .signIn)
        #expect(model.email == "alice@example.com")
        #expect(store.savedAccount == EnteSavedAccount(email: "alice@example.com", server: FakeEnteServer.server, hasSession: false))

        // Opening the sync screen again goes straight to signing in to the same account.
        let reopened = makeModel()
        #expect(reopened.phase == .signIn)
        #expect(reopened.email == "alice@example.com")
        #expect(reopened.server == FakeEnteServer.server.absoluteString)

        model.password = FakeEnteServer.password
        model.signIn()
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
        let cloud = EnteCloud(store: store, storage: vaultStorage, watch: watch)
        #expect(cloud.isEnabled)
        await store.signOut(watch: watch, cloud: cloud)
        #expect(store.savedAccount == nil)
        #expect(!keychain.hasValue(for: "session"))
        #expect(!watch.isEnabled)
        // The copy of the accounts goes too.
        #expect(!cloud.isEnabled)
        #expect(try vaultStorage.load() == nil)
    }

    @Test func signingInKeepsTheAccountsOnTheDevice() async throws {
        let model = makeModel()
        try await signIn(model)
        let saved = try #require(try vaultStorage.load())
        #expect(saved.email == "alice@example.com")
        #expect(saved.lastSyncTime > 0)
        // After a relaunch the accounts are there before syncing, without the ones in Ente's trash or deleted.
        let relaunched = EnteCloud(store: EnteSessionStore(keychain: keychain, defaults: defaults, canSave: true), storage: vaultStorage,
                                   watch: WatchAccountSync(defaults: defaults))
        #expect(relaunched.codes.map(\.id) == model.codes.map(\.id))
        #expect(!relaunched.codes.contains { ["e11", "e12"].contains($0.id) })
        #expect(relaunched.accounts.contains { $0.code.kind == .steam })
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
        #expect(try vaultStorage.load() == nil)
        model.close()
    }
}

#endif
