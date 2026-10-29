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

/// Signs in to the fake Ente server with the email and password entered together, the way the sign in screen does.
struct EnteFakeServerLoginTests {

    private func start(_ email: String, password: String = FakeEnteServer.password) async throws -> (EnteLoginFlow, EnteLoginStep) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeEnteServer.self]
        let api = try EnteAPIClient(server: FakeEnteServer.server, session: URLSession(configuration: configuration))
        return try await EnteLoginFlow.start(api: api, email: email, password: password)
    }

    @Test func srpAccountSignsInWithThePasswordAlone() async throws {
        let (flow, step) = try await start("alice@example.com")
        #expect(step == .complete)
        let keys = try #require(flow.keys)
        #expect(keys.userID == 42)
        #expect(!keys.token.isEmpty)
    }

    @Test func srpAccountRejectsAWrongPassword() async throws {
        await #expect(throws: EnteLoginError.incorrectPassword) {
            try await start("alice@example.com", password: "wrong")
        }
    }

    @Test func srpAccountWithTOTPAsksOnlyForTheCode() async throws {
        let (flow, step) = try await start("alice+2fa@example.com")
        #expect(step == .secondFactor(totp: true, passkey: false))
        await #expect(throws: EnteLoginError.incorrectCode) {
            try await flow.submitCode("000000")
        }
        #expect(try await flow.submitCode(FakeEnteServer.code) == .complete)
        #expect(flow.keys != nil)
    }

    @Test func emailMFAAccountUsesThePasswordAfterTheCode() async throws {
        let (flow, step) = try await start("alice+mfa@example.com")
        #expect(step == .emailCode)
        #expect(try await flow.submitCode(FakeEnteServer.code) == .complete)
        #expect(flow.keys != nil)
    }

    @Test func emailMFAAccountWithTOTPAsksForBothCodes() async throws {
        let (flow, step) = try await start("alice+mfa+2fa@example.com")
        #expect(step == .emailCode)
        #expect(try await flow.submitCode(FakeEnteServer.code) == .secondFactor(totp: true, passkey: false))
        #expect(try await flow.submitCode(FakeEnteServer.code) == .complete)
        #expect(flow.keys != nil)
    }

    @Test func accountWithoutSRPVerifiesTheEmailCode() async throws {
        let (flow, step) = try await start("alice+nosrp@example.com")
        #expect(step == .emailCode)
        #expect(try await flow.submitCode(FakeEnteServer.code) == .complete)
        #expect(flow.keys != nil)
    }

    @Test func wrongPasswordAfterTheEmailCodeCanBeRetried() async throws {
        let (flow, step) = try await start("alice+mfa@example.com", password: "wrong")
        #expect(step == .emailCode)
        await #expect(throws: EnteLoginError.incorrectPassword) {
            try await flow.submitCode(FakeEnteServer.code)
        }
        #expect(flow.needsPassword)
        #expect(try await flow.submitPassword(FakeEnteServer.password) == .complete)
        #expect(!flow.needsPassword)
        #expect(flow.keys != nil)
    }
}

#endif
