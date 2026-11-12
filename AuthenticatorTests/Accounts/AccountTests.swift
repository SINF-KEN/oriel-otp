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

    nonisolated private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    private func account(
        validFor seconds: TimeInterval = 30, connectionType: OrielOTP.OATHSession.ConnectionType = .nfc,
        requestRefresh: @escaping (Account) -> Void = { _ in }
    ) -> Account {
        let credential = OrielOTP.OATHSession.Credential(type: .totp, issuer: "GitHub", accountName: "alice", period: 30)
        let otp = OrielOTP.OATHSession.OTP(code: "123456", validity: DateInterval(start: .now, duration: seconds))
        return Account(
            credential: credential, code: otp, keyVersion: Version("5.4.0")!, requestRefresh: requestRefresh,
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
        #expect(
            !invalidates(
                {
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
        account.update(otp: OrielOTP.OATHSession.OTP(code: "654321", validity: DateInterval(start: .now, duration: 60)))
        // Well past when the old code's refresh would have run. Waiting less can only let the test pass, not fail.
        try await Task.sleep(for: .milliseconds(500))
        #expect(!flag.isSet)
    }

    /// Waits for the refresh itself, not for a flag polled against a deadline. The test and the refresh both run on
    /// the main actor, and while other tests keep it busy past the deadline, both resume together once it frees up: a
    /// poll that ran first failed the test though the refresh was about to run. The time limit catches a missing one.
    @Test(.timeLimit(.minutes(1)))
    func aCodeIsRefreshedWhenItExpires() async {
        let (refreshes, refreshed) = AsyncStream.makeStream(of: Void.self)
        let account = account(validFor: 0.05, connectionType: .wired) { _ in refreshed.yield() }
        var iterator = refreshes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        _ = account
    }

    private func account(endingIn seconds: TimeInterval) -> Account {
        let credential = OrielOTP.OATHSession.Credential(type: .totp, issuer: "GitHub", accountName: "alice", period: 30)
        let otp = OrielOTP.OATHSession.OTP(
            code: "123456", validity: DateInterval(start: .now.addingTimeInterval(seconds - 30), duration: 30))
        return Account(
            credential: credential, code: otp, keyVersion: Version("0.0.0")!, requestRefresh: { _ in },
            connectionType: .wired, isPinned: false, location: .device(id: "a"))
    }

    @Test func theNextCodeShowsInTheLastSeconds() {
        let account = account(endingIn: 3)
        var askedFor: Date?
        account.codeAtDate = { date in
            askedFor = date
            return "654321"
        }
        #expect(account.formattedNextCode == "654 321")
        // The code of the next period, which starts when this one ends.
        #expect(askedFor == account.otp?.validity.end)
    }

    @Test func theNextCodeIsntShownEarlier() {
        let account = account(endingIn: 20)
        account.codeAtDate = { _ in "654321" }
        #expect(account.formattedNextCode == nil)
    }

    @Test func aYubiKeyAccountHasNoNextCode() {
        let account = account(endingIn: 3)
        #expect(account.codeAtDate == nil)
        #expect(account.formattedNextCode == nil)
    }
}
