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

/// Deletes accounts on the fake Ente server, which checks the challenge like Ente's server.
@MainActor struct EnteAccountDeletionTests {

    private let session: URLSession = {
        return URLSession.stubbed([FakeEnteServer.self])
    }()
    private let defaults = makeTestDefaults()
    private let keychain = InMemoryKeychain()
    private var store: EnteSessionStore { EnteSessionStore(keychain: keychain, defaults: defaults, canSave: true) }

    private func model(_ server: URL, email: String = "alice@example.com") -> EnteAccountDeletionViewModel {
        let watch = WatchAccountSync(defaults: defaults)
        return EnteAccountDeletionViewModel(server: server, email: email, session: session, store: store,
                                            cloud: EnteCloud(store: store, storage: InMemoryVaultStorage(), session: session, watch: watch),
                                            watch: watch)
    }

    private func finish(_ model: EnteAccountDeletionViewModel) async throws {
        while model.isBusy {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func delete(_ model: EnteAccountDeletionViewModel, password: String = FakeEnteServer.password) async throws {
        model.password = password
        model.delete()
        try await finish(model)
    }

    private func accountExists(_ server: URL, email: String = "alice@example.com") async throws -> Bool {
        try await EnteAPIClient(server: server, session: session).srpAttributes(email: email) != nil
    }

    @Test func deletesTheAccountWithItsPassword() async throws {
        let server = FakeEnteServer.newAccountServer()
        #expect(try await accountExists(server))
        let model = model(server)
        try await delete(model)
        #expect(model.error == nil)
        #expect(model.phase == .deleted)
        #expect(model.password.isEmpty)
        #expect(try await !accountExists(server))
    }

    @Test func asksForTheEmailCodeFirstWhenTheAccountNeedsIt() async throws {
        let server = FakeEnteServer.newAccountServer()
        let model = model(server, email: "alice+mfa@example.com")
        try await delete(model)
        #expect(model.phase == .emailCode)
        #expect(try await accountExists(server))
        model.code = FakeEnteServer.code
        model.submitCode()
        try await finish(model)
        #expect(model.phase == .deleted)
        #expect(try await !accountExists(server))
    }

    @Test func aWrongPasswordDeletesNothing() async throws {
        let server = FakeEnteServer.newAccountServer()
        let model = model(server)
        try await delete(model, password: "wrong")
        #expect(model.phase == .password)
        #expect(model.error?.localizedDescription == EnteLoginError.incorrectPassword.errorDescription)
        #expect(try await accountExists(server))
    }

    @Test func entesServersAreRefused() async throws {
        let model = model(EnteAPIClient.defaultServer)
        try await delete(model)
        #expect(model.phase == .password)
        #expect(model.error?.localizedDescription == EnteAccountDeletionError.notAllowedOnEnte.errorDescription)
    }

    @Test func forgetsTheSavedSessionOfTheDeletedAccount() async throws {
        let server = FakeEnteServer.newAccountServer()
        try store.save(EnteSavedSession(server: server, email: "Alice@example.com", token: "token", authenticatorKey: EnteCrypto.randomBytes(32)))
        try await delete(model(server))
        #expect(store.savedAccount == nil)
    }

    @Test func keepsTheSavedSessionOfAnotherAccount() async throws {
        let other = FakeEnteServer.newAccountServer()
        try store.save(EnteSavedSession(server: other, email: "alice@example.com", token: "token", authenticatorKey: EnteCrypto.randomBytes(32)))
        try await delete(model(FakeEnteServer.newAccountServer()))
        #expect(store.savedAccount?.server == other)
    }

    /// What the guideline asks for: an account created in the app can be deleted in the app.
    @Test func deletesAnAccountCreatedInTheApp() async throws {
        let server = FakeEnteServer.emptyServer()
        let signUp = EnteSignUpViewModel(server: server, email: "alice@example.com", session: session)
        signUp.password = "correct horse"
        signUp.confirmation = "correct horse"
        signUp.sendCode()
        while signUp.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        signUp.code = FakeEnteServer.code
        signUp.submitCode()
        while signUp.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        signUp.hasSavedRecoveryKey = true
        signUp.finish()
        while signUp.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(signUp.phase == .finished)
        #expect(try await accountExists(server))

        let model = model(server)
        try await delete(model, password: "correct horse")
        #expect(model.error == nil)
        #expect(model.phase == .deleted)
        #expect(try await !accountExists(server))
    }
}

#endif
