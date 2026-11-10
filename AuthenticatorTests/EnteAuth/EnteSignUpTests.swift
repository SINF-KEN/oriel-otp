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

struct EnteAccountCreationRulesTests {

    private func url(_ string: String) throws -> URL { try #require(URL(string: string)) }

    @Test func entesServersAreRefused() throws {
        for server in ["https://api.ente.io", "https://API.ENTE.IO", "https://ente.io", "https://accounts.ente.com", "https://api.ente.io./",
                       "https://api.ente.io:8443"] {
            #expect(!EnteAPIClient.allowsAccountCreation(on: try url(server)), "\(server)")
        }
    }

    @Test func selfHostedServersAreAllowed() throws {
        for server in ["https://ente.example.com", "https://notente.io", "https://api.ente.io.example.com", "https://192.168.1.2:8080",
                       "https://[fd00::1]:8080", "https://ente.example.com/api/"] {
            #expect(EnteAPIClient.allowsAccountCreation(on: try url(server)), "\(server)")
        }
    }

    /// URLSession decodes a percent-encoded host before connecting, so "api%2Eente%2Eio" is api.ente.io. Hosts that
    /// aren't plain, and server URLs with a user, a query or a fragment, are refused everywhere.
    @Test func serversThatArentPlainAreRefused() throws {
        for server in ["https://api%2Eente%2Eio", "https://api%2eente%2eio/", "https://%61pi.ente.io", "https://api.ente%2Eio:443",
                       "https://ente.example.com%2F@api.ente.io", "https://user@ente.example.com", "https://ente.example.com?a=b",
                       "https://ente.example.com#a", "https://..ente.example.com", "https://"] {
            guard let server = URL(string: server) else { continue }
            #expect(!EnteAPIClient.allowsAccountCreation(on: server), "\(server)")
            #expect(throws: EnteAPIError.invalidServerURL, "\(server)") { try EnteAPIClient.serverURL(from: server.absoluteString) }
            #expect(throws: EnteAPIError.invalidServerURL, "\(server)") { try EnteAPIClient(server: server) }
        }
        for server in ["https://api%2Eente%2Eio", "https://%61pi.ente.io", "https://api.ente%2Eio:443"] {
            let server = try url(server)
            #expect(!EnteAPIClient.isSameServer(server, EnteAPIClient.defaultServer), "\(server)")
            #expect(!EnteRedirectGuard.allows(from: server, to: server), "\(server)")
        }
        // A host that isn't ASCII is either turned into its ASCII form or refused, never let through as typed.
        for server in ["https://api\u{FF0E}ente\u{FF0E}io", "https://API.ENTE.IO\u{3002}"] {
            guard let server = URL(string: server) else { continue }
            #expect(!EnteAPIClient.allowsAccountCreation(on: server), "\(server)")
        }
    }

    @Test func hostsAreComparedAsTheyAreConnectedTo() throws {
        #expect(EnteAPIClient.host(of: try url("https://API.Ente.IO./users")) == "api.ente.io")
        #expect(EnteAPIClient.host(of: try url("https://api%2Eente%2Eio")) == nil)
        #expect(EnteAPIClient.isSameServer(try url("https://API.ENTE.IO./"), EnteAPIClient.defaultServer))
        #expect(EnteRedirectGuard.allows(from: try url("https://api.ente.io/a"), to: try url("https://API.ente.io./b")))
        #expect(!EnteRedirectGuard.allows(from: try url("https://ente.example.com/a"), to: try url("https://ente%2Eexample.com/b")))
    }

    /// Each request that creates an account fails before it's sent: a request that was sent would fail differently.
    @Test func noRequestReachesEntesServers() async throws {
        let api = try EnteAPIClient(session: URLSession.stubbed([FakeEnteServer.self]))
        await #expect(throws: EnteSignUpError.notAllowedOnEnte) {
            try await api.sendSignUpCode(email: "alice@example.com")
        }
        let keys = try await EnteSignUp.generateKeys(password: "password")
        await #expect(throws: EnteSignUpError.notAllowedOnEnte) {
            try await api.setKeyAttributes(keys.attributes, token: "token")
        }
        await #expect(throws: EnteSignUpError.notAllowedOnEnte) {
            try await EnteSignUp.setUpSRP(keys, api: api, token: "token")
        }
        await #expect(throws: EnteSignUpError.notAllowedOnEnte) {
            try await api.completeSRPSetup(token: "token", setupID: "id", srpM1: Data())
        }
    }

    /// Checks the URL itself, as the fake server reads a "+" like URLComponents does, not like Ente's server.
    @Test func aTagInAnEmailReachesTheServerAsAPlus() throws {
        let api = try EnteAPIClient(server: try url("https://ente.example.com"))
        let request = try api.request("GET", "/users/srp/attributes", query: ["email": "alice+tag@example.com"])
        #expect(request.url?.query(percentEncoded: true) == "email=alice%2Btag@example.com")
    }

    @Test func onlySelfHostedServersOfferIt() {
        for text in ["", "  ", "https://api.ente.io", "https://ENTE.io", "http://ente.example.com", "ente.example.com"] {
            #expect(EnteSignUpViewModel.server(from: text) == nil, "\(text)")
        }
        #expect(EnteSignUpViewModel.server(from: " https://ente.example.com ") != nil)
    }

    @Test func theKeysAreWhatEntesServerTakesAndTheRecoveryKeyOpensThem() async throws {
        let keys = try await EnteSignUp.generateKeys(password: "password")
        let attributes = keys.attributes
        #expect(attributes.memLimit * attributes.opsLimit == 4 * 1_073_741_824)
        #expect(attributes.memLimit >= 128 * 1024 * 1024)
        #expect(EnteCrypto.isAllowed(opsLimit: attributes.opsLimit, memLimit: attributes.memLimit))

        // What Ente's apps do with a recovery key in hex: it opens the master key, which opens the secret key.
        #expect(keys.recoveryKey.count == 64)
        let recoveryKey = Data(stride(from: 0, to: 64, by: 2).map { offset in
            UInt8(keys.recoveryKey.dropFirst(offset).prefix(2), radix: 16) ?? 0
        })
        let masterKey = try EnteCrypto.secretBoxOpen(try #require(Data(enteBase64: attributes.masterKeyEncryptedWithRecoveryKey)),
                                                     nonce: try #require(Data(enteBase64: attributes.masterKeyDecryptionNonce)), key: recoveryKey)
        let secretKey = try EnteCrypto.secretBoxOpen(try #require(Data(enteBase64: attributes.encryptedSecretKey)),
                                                     nonce: try #require(Data(enteBase64: attributes.secretKeyDecryptionNonce)), key: masterKey)
        #expect(try EnteCrypto.publicKey(forSecretKey: secretKey) == Data(enteBase64: attributes.publicKey))
        let opened = try EnteCrypto.secretBoxOpen(try #require(Data(enteBase64: attributes.recoveryKeyEncryptedWithMasterKey)),
                                                  nonce: try #require(Data(enteBase64: attributes.recoveryKeyDecryptionNonce)), key: masterKey)
        #expect(opened == recoveryKey)
    }
}

/// Creates accounts on the fake server, which checks them like Ente's.
@Suite(.serialized) @MainActor struct EnteSignUpViewModelTests {

    private static let email = "alice@example.com"
    private static let password = "correct horse"

    private let session: URLSession = {
        return URLSession.stubbed([FakeEnteServer.self])
    }()

    private func finish(_ model: EnteSignUpViewModel) async throws {
        while model.isBusy {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func detailsDone(_ server: URL, email: String = Self.email) async throws -> EnteSignUpViewModel {
        let model = EnteSignUpViewModel(server: server, email: email, session: session)
        model.password = Self.password
        model.confirmation = Self.password
        model.sendCode()
        try await finish(model)
        return model
    }

    private func recoveryKeyShown(_ server: URL) async throws -> EnteSignUpViewModel {
        let model = try await detailsDone(server)
        #expect(model.phase == .emailCode)
        model.code = FakeEnteServer.code
        model.submitCode()
        try await finish(model)
        #expect(model.phase == .recoveryKey)
        return model
    }

    @Test func createsAnAccountThatSignsInWithSRP() async throws {
        let server = FakeEnteServer.emptyServer()
        let model = try await recoveryKeyShown(server)
        #expect(model.password.isEmpty)
        #expect(model.recoveryKey?.count == 64)
        model.hasSavedRecoveryKey = true
        model.finish()
        try await finish(model)
        #expect(model.error == nil)
        #expect(model.phase == .finished)
        #expect(model.recoveryKey == nil)

        let api = try EnteAPIClient(server: server, session: session)
        let (flow, step) = try await EnteLoginFlow.start(api: api, email: Self.email, password: Self.password)
        #expect(step == .complete)
        let keys = try #require(flow.keys)
        // An account the rest of the app can use: it gets an authenticator key and can store codes.
        let key = try await EnteAuthenticatorSync.authenticatorKeyCreatingIfNeeded(api: api, keys: keys)
        try await EnteMigration.copy([#""otpauth://totp/A:b?secret=JBSWY3DPEHPK3PXP""#], api: api, token: keys.token, authenticatorKey: key) { _ in }
        #expect(try await EnteAuthenticatorSync.decryptedEntities(api: api, token: keys.token, authenticatorKey: key).count == 1)
    }

    @Test func aWrongPasswordDoesNotOpenTheNewAccount() async throws {
        let server = FakeEnteServer.emptyServer()
        let model = try await recoveryKeyShown(server)
        model.hasSavedRecoveryKey = true
        model.finish()
        try await finish(model)
        let api = try EnteAPIClient(server: server, session: session)
        await #expect(throws: EnteLoginError.incorrectPassword) {
            try await EnteLoginFlow.start(api: api, email: Self.email, password: "wrong password")
        }
    }

    @Test func nothingReachesTheServerBeforeTheRecoveryKeyIsSaved() async throws {
        let server = FakeEnteServer.emptyServer()
        let model = try await recoveryKeyShown(server)
        model.finish()
        try await finish(model)
        #expect(model.phase == .recoveryKey)
        let api = try EnteAPIClient(server: server, session: session)
        #expect(try await api.srpAttributes(email: Self.email) == nil)
    }

    @Test func closingForgetsEverything() async throws {
        let model = try await recoveryKeyShown(FakeEnteServer.emptyServer())
        model.close()
        #expect(model.recoveryKey == nil)
        #expect(model.password.isEmpty)
        #expect(model.confirmation.isEmpty)
    }

    @Test func asksForAPasswordOfTheRightLengthTwice() async throws {
        let model = EnteSignUpViewModel(server: FakeEnteServer.emptyServer(), email: Self.email, session: session)
        #expect(!model.canSendCode)
        model.password = "short"
        model.confirmation = "short"
        model.sendCode()
        try await finish(model)
        #expect(model.phase == .details)
        #expect(model.error?.localizedDescription == EnteSignUpError.passwordTooShort.errorDescription)
        model.password = Self.password
        model.confirmation = "something else"
        model.sendCode()
        try await finish(model)
        #expect(model.phase == .details)
        #expect(model.error?.localizedDescription == EnteSignUpError.passwordsDiffer.errorDescription)
        model.confirmation = Self.password
        model.sendCode()
        try await finish(model)
        #expect(model.phase == .emailCode)
    }

    @Test func saysWhenRegistrationIsOff() async throws {
        let model = try await detailsDone(FakeEnteServer.emptyServer(), email: "alice+closed@example.com")
        #expect(model.phase == .details)
        #expect(model.error?.localizedDescription == EnteSignUpError.registrationDisabled.errorDescription)
    }

    @Test func saysWhenTheAccountExists() async throws {
        let model = try await detailsDone(FakeEnteServer.newAccountServer())
        #expect(model.phase == .details)
        #expect(model.error?.localizedDescription == EnteSignUpError.accountExists.errorDescription)
    }

    @Test func aWrongCodeCanBeTriedAgain() async throws {
        let model = try await detailsDone(FakeEnteServer.emptyServer())
        model.code = "000000"
        model.submitCode()
        try await finish(model)
        #expect(model.phase == .emailCode)
        #expect(model.error?.localizedDescription == EnteLoginError.incorrectCode.errorDescription)
        model.code = FakeEnteServer.code
        model.submitCode()
        try await finish(model)
        #expect(model.phase == .recoveryKey)
    }
}

#endif
