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

@MainActor
struct ProtectedAccountsTests {

    private let url = URL.temporaryDirectory.appending(components: "ProtectedAccountsTests-\(UUID().uuidString)", "Accounts")
    private let keychain = InMemoryVaultKey()

    /// Face ID that succeeds or fails, and remembers what it was asked.
    private final class Owner: @unchecked Sendable {
        var accepts = true
        var reasons: [String] = []
    }

    private func protection(_ owner: Owner) -> ProtectedAccounts {
        let protection = ProtectedAccounts(url: url, keychain: keychain)
        protection.authenticate = { reason in
            await MainActor.run {
                owner.reasons.append(reason)
                return owner.accepts
            }
        }
        return protection
    }

    @Test func protectingAnAccountAsksForTheOwnerFirst() async {
        let owner = Owner()
        let protection = protection(owner)
        owner.accepts = false
        #expect(await !protection.setProtected(true, "ente/1", title: "GitHub"))
        #expect(!protection.isProtected("ente/1"))
        owner.accepts = true
        #expect(await protection.setProtected(true, "ente/1", title: "GitHub"))
        #expect(protection.isProtected("ente/1"))
        #expect(owner.reasons.count == 2)
        #expect(owner.reasons.allSatisfy { $0.contains("GitHub") })
    }

    @Test func turningItOffAsksForTheOwnerToo() async {
        let owner = Owner()
        let protection = protection(owner)
        await protection.setProtected(true, "ente/1", title: "GitHub")
        owner.accepts = false
        #expect(await !protection.setProtected(false, "ente/1", title: "GitHub"))
        #expect(protection.isProtected("ente/1"))
        owner.accepts = true
        #expect(await protection.setProtected(false, "ente/1", title: "GitHub"))
        #expect(!protection.isProtected("ente/1"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func isKeptOnThisDevice() async {
        await protection(Owner()).setProtected(true, "device/1", title: "Bank")
        #expect(protection(Owner()).isProtected("device/1"))
        #expect(!protection(Owner()).isProtected("device/2"))
    }

    @Test func onlyProtectedAccountsAskBeforeCopying() async {
        let owner = Owner()
        let protection = protection(owner)
        await protection.setProtected(true, "ente/1", title: "GitHub")
        owner.reasons = []
        #expect(await protection.unlock("ente/2", title: "Other"))
        #expect(owner.reasons.isEmpty)
        owner.accepts = false
        #expect(await !protection.unlock("ente/1", title: "GitHub"))
        owner.accepts = true
        #expect(await protection.unlock("ente/1", title: "GitHub"))
        #expect(owner.reasons.count == 2)
    }

    /// A protected account's code shows as dots, even with Hide codes off, until it's revealed after Face ID.
    @Test func hidesTheCodeOfAProtectedAccount() async {
        let protection = protection(Owner())
        await protection.setProtected(true, "ente/1", title: "GitHub")
        let defaults = UserDefaults(suiteName: "ProtectedAccountsTests-\(UUID().uuidString)")!
        let visibility = CodeVisibility(defaults: defaults, protection: protection)
        #expect(!visibility.hidesCodes)
        #expect(!visibility.isShown("ente/1"))
        #expect(visibility.isShown("ente/2"))
        visibility.reveal("ente/1")
        #expect(visibility.isShown("ente/1"))
        visibility.hideAll()
        #expect(!visibility.isShown("ente/1"))
    }
}
