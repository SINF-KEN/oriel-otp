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

#if DEBUG && (targetEnvironment(simulator) || os(macOS))

import Foundation
import Testing

@testable import OrielOTP

struct EnteMigrationPlanTests {

    @Test func copiesOnlyWhatTheNewServerLacks() {
        let plan = EnteMigrationPlan(source: ["a", "b", nil], target: ["b", "c", nil])
        #expect(plan.toCopy == ["a"])
        #expect(plan.alreadyOnTarget == 1)
        #expect(plan.unreadable == 1)
    }

    @Test func keepsTwoAccountsThatOnlyShareAName() {
        let first = #""otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP""#
        let second = #""otpauth://totp/GitHub:alice?secret=GEZDGNBVGY3TQOJQ""#
        #expect(EnteMigrationPlan(source: [first, second], target: [first]).toCopy == [second])
    }

    @Test func countsTheTrash() {
        let trashed = #""otpauth://totp/Old:alice?secret=JBSWY3DPEHPK3PXP&codeDisplay=%7B%22trashed%22%3Atrue%7D""#
        #expect(EnteMigrationPlan(source: [trashed, #""otpauth://totp/New:alice?secret=JBSWY3DPEHPK3PXP""#], target: []).trashed == 1)
    }

    @Test func isCompleteOnlyWithEveryReadableAccount() {
        let plan = EnteMigrationPlan(source: ["a", "b", nil], target: [])
        #expect(plan.isComplete(on: ["a", "b", "c"]))
        #expect(!plan.isComplete(on: ["a"]))
    }

    @Test func recognizesTheSameServerHoweverItIsTyped() throws {
        let server = try #require(URL(string: "https://api.ente.io"))
        #expect(EnteAPIClient.isSameServer(server, try #require(URL(string: "HTTPS://API.ente.io:443/"))))
        #expect(!EnteAPIClient.isSameServer(server, try #require(URL(string: "https://api.ente.io:8080"))))
        #expect(!EnteAPIClient.isSameServer(server, try #require(URL(string: "https://ente.example.com"))))
    }

    @Test func anEmptyServerFieldIsEntesServer() throws {
        #expect(try EnteAPIClient.serverURL(from: "  ") == EnteAPIClient.defaultServer)
    }
}

/// Moves accounts between accounts of the fake server, each host being one of its own.
@Suite(.serialized) @MainActor struct EnteMigrationViewModelTests {

    private static let accounts = [#""otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub""#,
                                   #""otpauth://totp/Old:alice?secret=JBSWY3DPEHPK3PXP&codeDisplay=%7B%22trashed%22%3Atrue%7D""#,
                                   #"{"rawData":"otpauth://totp/Dropbox:alice?secret=JBSWY3DPEHPK3PXP","display":{"note":"kept","tags":["work"]}}"#]
    private static let email = "alice@example.com"

    private struct Fixture {
        let model: EnteMigrationViewModel
        let store: EnteSessionStore
        let cloud: EnteCloud
        let defaults: UserDefaults
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeEnteServer.self]
        return URLSession(configuration: configuration)
    }()

    private func fixture(saved: EnteSavedSession? = nil, canSave: Bool = true) throws -> Fixture {
        // The session is kept in memory: the Mac build CI tests is signed without the keychain access group.
        let defaults = makeTestDefaults()
        let store = EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: canSave)
        if let saved {
            try store.save(saved)
        }
        let cloud = EnteCloud(store: store, storage: InMemoryVaultStorage(), session: session, watch: WatchAccountSync(defaults: defaults))
        return Fixture(model: EnteMigrationViewModel(store: store, defaults: defaults, session: session, cloud: cloud),
                       store: store, cloud: cloud, defaults: defaults)
    }

    /// Signs in to the server and adds the accounts, returning the session.
    private func seed(_ server: URL, with accounts: [String]) async throws -> EnteSavedSession {
        let api = try EnteAPIClient(server: server, session: session)
        let (flow, _) = try await EnteLoginFlow.start(api: api, email: Self.email, password: FakeEnteServer.password)
        let keys = try #require(flow.keys)
        let key = try await EnteAuthenticatorSync.authenticatorKeyCreatingIfNeeded(api: api, keys: keys)
        try await EnteMigration.copy(accounts, api: api, token: keys.token, authenticatorKey: key) { _ in }
        return EnteSavedSession(server: server, email: Self.email, token: keys.token, authenticatorKey: key)
    }

    private func accounts(on session: EnteSavedSession) async throws -> [String] {
        let api = try EnteAPIClient(server: session.server, session: self.session)
        return try await EnteAuthenticatorSync.decryptedEntities(api: api, token: session.token, authenticatorKey: session.authenticatorKey)
            .compactMap { $0.rawData }
    }

    private func finish(_ model: EnteMigrationViewModel) async throws {
        while model.isBusy {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func signIn(_ model: EnteMigrationViewModel, email: String = Self.email) async throws {
        model.email = email
        model.password = FakeEnteServer.password
        model.signIn()
        try await finish(model)
    }

    /// Gets to the review screen, signing in to whichever servers ask for it.
    private func review(_ model: EnteMigrationViewModel, from: URL, to: URL) async throws {
        model.from = from.absoluteString
        model.to = to.absoluteString
        model.start()
        try await finish(model)
        if model.phase == .signIn(.source) {
            try await signIn(model)
        }
        #expect(model.phase == .signIn(.target))
        try await signIn(model)
        #expect(model.phase == .review)
    }

    @Test func movesEverythingAndSwitchesTheDevice() async throws {
        let source = FakeEnteServer.newAccountServer()
        let target = FakeEnteServer.newAccountServer()
        let saved = try await seed(source, with: Self.accounts)
        let fixture = try fixture(saved: saved)
        try await review(fixture.model, from: source, to: target)
        #expect(fixture.model.plan?.toCopy.count == 3)
        #expect(fixture.model.plan?.trashed == 1)
        // Nothing happens until it's confirmed.
        #expect(fixture.store.savedAccount?.server == source)

        fixture.model.move()
        try await finish(fixture.model)

        #expect(fixture.model.phase == .finished)
        #expect(fixture.model.error == nil)
        #expect(fixture.model.didSwitch)
        #expect(fixture.model.copied == 3)
        #expect(fixture.store.savedAccount?.server == target)
        #expect(fixture.store.savedAccount?.hasSession == true)
        #expect(fixture.defaults.string(forKey: EnteSyncViewModel.serverKey) == target.absoluteString)
        // The plain text is the same, tags and notes and all, and the device reads it from the new server.
        let unlocked = try await fixture.store.unlock()
        #expect(try await Set(accounts(on: unlocked)) == Set(Self.accounts))
        #expect(fixture.cloud.vault?.server == target)
        #expect(Set(fixture.cloud.vault?.items.compactMap(\.rawData) ?? []) == Set(Self.accounts))
        // The old server keeps its copy.
        #expect(try await Set(accounts(on: saved)) == Set(Self.accounts))
    }

    @Test func uploadsWaitingChangesBeforeMoving() async throws {
        let source = FakeEnteServer.newAccountServer()
        let target = FakeEnteServer.newAccountServer()
        let saved = try await seed(source, with: [Self.accounts[0]])
        let fixture = try fixture(saved: saved)
        fixture.cloud.use(saved)
        try await fixture.cloud.syncNow()
        _ = try fixture.cloud.add(rawData: Self.accounts[2])
        try await review(fixture.model, from: source, to: target)
        #expect(fixture.model.plan?.toCopy.count == 2)
        fixture.model.move()
        try await finish(fixture.model)
        #expect(fixture.model.phase == .finished)
        let unlocked = try await fixture.store.unlock()
        #expect(try await accounts(on: unlocked).count == 2)
    }

    @Test func movingAgainDoesNotCopyTwice() async throws {
        let source = FakeEnteServer.newAccountServer()
        let target = FakeEnteServer.newAccountServer()
        let saved = try await seed(source, with: Self.accounts)
        // What a move that stopped halfway leaves behind.
        let existing = try await seed(target, with: [Self.accounts[0]])
        let fixture = try fixture(saved: saved)
        try await review(fixture.model, from: source, to: target)
        #expect(fixture.model.plan?.toCopy.count == 2)
        #expect(fixture.model.plan?.alreadyOnTarget == 1)
        fixture.model.move()
        try await finish(fixture.model)
        #expect(fixture.model.phase == .finished)
        #expect(try await accounts(on: existing).count == 3)
    }

    @Test func signsInToBothServersWithoutASavedAccount() async throws {
        let source = FakeEnteServer.newAccountServer()
        let target = FakeEnteServer.newAccountServer()
        _ = try await seed(source, with: Self.accounts)
        let fixture = try fixture()
        fixture.model.from = source.absoluteString
        fixture.model.to = target.absoluteString
        fixture.model.start()
        try await finish(fixture.model)
        #expect(fixture.model.phase == .signIn(.source))
        try await signIn(fixture.model)
        // The same email is the likely one on the new server.
        #expect(fixture.model.phase == .signIn(.target))
        #expect(fixture.model.email == Self.email)
        #expect(fixture.model.password.isEmpty)
        try await signIn(fixture.model, email: "alice+mfa@example.com")
        #expect(fixture.model.phase == .emailCode(.target))
        fixture.model.code = FakeEnteServer.code
        fixture.model.submitCode()
        try await finish(fixture.model)
        #expect(fixture.model.phase == .review)
        fixture.model.move()
        try await finish(fixture.model)
        #expect(fixture.model.phase == .finished)
        #expect(fixture.store.savedAccount?.server == target)
        #expect(fixture.store.savedAccount?.email == "alice+mfa@example.com")
    }

    @Test func leavesASavedAccountOnAThirdServerAlone() async throws {
        let source = FakeEnteServer.newAccountServer()
        let target = FakeEnteServer.newAccountServer()
        let other = try await seed(FakeEnteServer.newAccountServer(), with: [])
        _ = try await seed(source, with: Self.accounts)
        let fixture = try fixture(saved: other)
        try await review(fixture.model, from: source, to: target)
        #expect(!fixture.model.willSwitch)
        fixture.model.move()
        try await finish(fixture.model)
        #expect(fixture.model.phase == .finished)
        #expect(!fixture.model.didSwitch)
        #expect(fixture.store.savedAccount?.server == other.server)
    }

    @Test func aWrongPasswordStaysOnTheSignIn() async throws {
        let source = FakeEnteServer.newAccountServer()
        let saved = try await seed(source, with: Self.accounts)
        let fixture = try fixture(saved: saved)
        fixture.model.to = FakeEnteServer.newAccountServer().absoluteString
        fixture.model.start()
        try await finish(fixture.model)
        fixture.model.password = "wrong"
        fixture.model.signIn()
        try await finish(fixture.model)
        #expect(fixture.model.phase == .signIn(.target))
        #expect(fixture.model.error != nil)
        #expect(fixture.store.savedAccount?.server == source)
    }

    @Test func refusesTheSameServer() async throws {
        let fixture = try fixture()
        fixture.model.from = "https://api.ente.io"
        fixture.model.to = "https://API.ente.io/"
        fixture.model.start()
        try await finish(fixture.model)
        #expect(fixture.model.phase == .servers)
        #expect(fixture.model.error?.localizedDescription == EnteMigrationError.sameServer.errorDescription)
    }

    @Test func refusesAPlainHTTPServer() async throws {
        let fixture = try fixture()
        fixture.model.to = "http://ente.example.com"
        fixture.model.start()
        try await finish(fixture.model)
        #expect(fixture.model.phase == .servers)
        #expect(fixture.model.error != nil)
    }

    @Test func aServerWithoutAccountsStopsBeforeTheNewServer() async throws {
        let source = FakeEnteServer.newAccountServer()
        let fixture = try fixture()
        fixture.model.from = source.absoluteString
        fixture.model.to = FakeEnteServer.newAccountServer().absoluteString
        fixture.model.start()
        try await finish(fixture.model)
        try await signIn(fixture.model)
        #expect(fixture.model.phase == .servers)
        #expect(fixture.model.error?.localizedDescription == EnteMigrationError.noAccounts.errorDescription)
    }

    @Test func anEndedSessionAsksToSignInAgainFirst() async throws {
        let saved = try await seed(FakeEnteServer.newAccountServer(), with: Self.accounts)
        let fixture = try fixture(saved: saved)
        fixture.store.forgetSession()
        fixture.model.to = FakeEnteServer.newAccountServer().absoluteString
        fixture.model.start()
        try await finish(fixture.model)
        #expect(fixture.model.phase == .servers)
        #expect(fixture.model.error?.localizedDescription == EnteMigrationError.sessionEnded.errorDescription)
    }

    @Test func closingForgetsThePasswordAndKeepsTheDeviceAsItWas() async throws {
        let source = FakeEnteServer.newAccountServer()
        let saved = try await seed(source, with: Self.accounts)
        let fixture = try fixture(saved: saved)
        try await review(fixture.model, from: source, to: FakeEnteServer.newAccountServer())
        fixture.model.close()
        #expect(fixture.model.plan == nil)
        #expect(fixture.model.password.isEmpty)
        #expect(fixture.store.savedAccount?.server == source)
        #expect(fixture.store.savedAccount?.hasSession == true)
    }
}

#endif
