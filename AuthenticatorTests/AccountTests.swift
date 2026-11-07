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
import Observation
import Testing
import YubiKit

@testable import OrielOTP

struct AccountTests {

    private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    private func account(validFor seconds: TimeInterval = 30, connectionType: OATHSession.ConnectionType = .nfc,
                         requestRefresh: @escaping (Account) -> Void = { _ in }) -> Account {
        let credential = OATHSession.Credential(type: .totp, issuer: "GitHub", accountName: "alice", period: 30)
        let otp = OATHSession.OTP(code: "123456", validity: DateInterval(start: .now, duration: seconds))
        return Account(credential: credential, code: otp, keyVersion: Version("5.4.0")!, requestRefresh: requestRefresh,
                       connectionType: connectionType, isPinned: false)
    }

    /// Whether changing the account in `change` tells a view that read it in `read` to update.
    private func invalidates(_ read: () -> Void, by change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking(read) { flag.isSet = true }
        change()
        return flag.isSet
    }

    @Test func iconColorIsTheSameOnEveryLaunch() {
        // Calculated apart from the app, as `String.hash` would pass within one launch.
        #expect(Account.colorIndex(for: "ente/abc", count: 8) == 2)
        #expect(Account.colorIndex(for: "ente/abc", count: 5) == 4)
    }

    @Test func theCountdownOnlyUpdatesViewsThatShowIt() {
        let account = account()
        #expect(!invalidates({
            _ = account.formattedCode
            _ = account.spokenCode
            _ = account.isCountingDown
            _ = account.canCopyCode
        }, by: { account.updateState() }))
        #expect(invalidates({ _ = account.remaining }, by: { account.updateState() }))
    }

    @Test func aCodeThatExpiresUpdatesTheRow() {
        let account = account()
        #expect(account.isCountingDown)
        #expect(account.canCopyCode)
        #expect(invalidates({ _ = account.formattedCode }, by: { account.state = .expired }))
        #expect(!account.isCountingDown)
        #expect(!account.canCopyCode)
        #expect(account.formattedCode == nil)
    }

    @Test func aNewCodeReplacesTheRefreshOfTheOldOne() async throws {
        let flag = Flag()
        let account = account(validFor: 0.05, connectionType: .wired) { _ in flag.isSet = true }
        account.update(otp: OATHSession.OTP(code: "654321", validity: DateInterval(start: .now, duration: 60)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!flag.isSet)
    }

    @Test func aCodeIsRefreshedWhenItExpires() async throws {
        let flag = Flag()
        let account = account(validFor: 0.05, connectionType: .wired) { _ in flag.isSet = true }
        try await Task.sleep(for: .milliseconds(300))
        #expect(flag.isSet)
        _ = account
    }
}
