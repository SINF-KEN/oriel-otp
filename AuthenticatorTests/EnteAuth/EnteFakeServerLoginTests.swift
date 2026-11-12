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

        private func start(
            _ email: String, password: String = FakeEnteServer.password,
            server: URL = FakeEnteServer.server
        ) async throws -> (EnteLoginFlow, EnteLoginStep) {
            let api = try EnteAPIClient(server: server, session: URLSession.stubbed([FakeEnteServer.self]))
            return try await EnteLoginFlow.start(api: api, email: email, password: password)
        }

        @Test func srpAccountSignsInWithThePasswordAlone() async throws {
            let (flow, step) = try await start("alice@example.com")
            #expect(step == .complete)
            let keys = try #require(flow.keys)
            #expect(keys.userID == 42)
            #expect(!keys.token.isEmpty)
        }

        /// A server that doesn't know the account's verifier can't prove it, so it can't hand out keys for the account,
        /// even though the password decrypts them.
        @Test func srpSignInRefusesAWrongServerProof() async throws {
            await #expect(throws: EnteSRPError.serverProofMismatch) {
                try await start("alice@example.com", server: FakeEnteServer.serverSendingAWrongProof())
            }
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

        @Test func passkeyAccountKeepsThePasswordWhileThePasskeyIsVerified() async throws {
            let (flow, step) = try await start("alice+passkey@example.com")
            #expect(step == .emailCode)
            #expect(try await flow.submitCode(FakeEnteServer.code) == .secondFactor(totp: false, passkey: true))
            #expect(flow.passkeyURL != nil)
            // Not verified in the browser yet, the password entered at the start is still kept.
            #expect(try await flow.checkPasskey() == nil)
            #expect(try await flow.checkPasskey() == .complete)
            #expect(!flow.needsPassword)
            #expect(flow.keys?.userID == 42)
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
