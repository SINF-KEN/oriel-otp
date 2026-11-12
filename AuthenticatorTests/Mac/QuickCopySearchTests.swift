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

#if os(macOS)
    import Foundation
    import Testing
    import YubiKit

    @testable import OrielOTP

    @MainActor
    struct QuickCopySearchTests {

        private func account(_ issuer: String, _ name: String = "alice", id: String) -> Account {
            let credential = OrielOTP.OATHSession.Credential(type: .totp, issuer: issuer, accountName: name, period: 30)
            let otp = OrielOTP.OATHSession.OTP(code: "123456", validity: DateInterval(start: .now, duration: 30))
            return Account(
                credential: credential, code: otp, keyVersion: Version("5.4.0")!, requestRefresh: { _ in },
                connectionType: .wired, isPinned: false, location: .device(id: id))
        }

        @Test func listsEveryAccountBeforeTyping() {
            let accounts = [account("GitHub", id: "1"), account("Bank", id: "2")]
            #expect(QuickCopySearch.results(in: accounts, for: " ").map(\.title) == ["GitHub", "Bank"])
        }

        /// The names that start with what's typed come first, so Return copies the account most likely meant.
        @Test func putsNamesStartingWithTheTextFirst() {
            let accounts = [account("My Bank", id: "1"), account("Bank", id: "2"), account("GitHub", id: "3")]
            #expect(QuickCopySearch.results(in: accounts, for: "bank").map(\.title) == ["Bank", "My Bank"])
        }

        @Test func ignoresCaseAndAccentsAndFindsAccountNames() {
            let accounts = [account("Société Générale", "gérard", id: "1"), account("GitHub", id: "2")]
            #expect(QuickCopySearch.results(in: accounts, for: "societe").map(\.title) == ["Société Générale"])
            #expect(QuickCopySearch.results(in: accounts, for: "GERARD").map(\.title) == ["Société Générale"])
            #expect(QuickCopySearch.results(in: accounts, for: "nothing").isEmpty)
        }
    }
#endif
