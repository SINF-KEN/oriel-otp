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

struct AccountCheckupTests {

    private func item(
        _ id: String, _ issuer: String?, _ name: String, yubiKey: Bool = false, secret: String? = nil,
        fits: Bool = true
    ) -> AccountCheckup.Item {
        AccountCheckup.Item(
            id: id, issuer: issuer, accountName: name, isOnYubiKey: yubiKey,
            secret: yubiKey ? nil : Data((secret ?? id).utf8), fitsOnYubiKey: fits)
    }

    @Test func findsTheSameNameInSeveralPlaces() {
        let result = AccountCheckup.check([
            item("key/GitHub:alice", "GitHub", "alice", yubiKey: true),
            item("ente/1", "github ", "Alice"),
            item("device/2", "Bank", "alice")
        ])
        #expect(result.duplicates == [["key/GitHub:alice", "ente/1"]])
    }

    @Test func findsTheSameSecretUnderAnotherName() {
        let result = AccountCheckup.check([
            item("ente/1", "GitHub", "alice", secret: "s"),
            item("device/2", "Work GitHub", "alice@example.com", secret: "s"),
            item("device/3", "Other", "bob", secret: "t")
        ])
        #expect(result.duplicates == [["ente/1", "device/2"]])
    }

    /// One account linked to two others, by its name to one and by its secret to the other, is one group.
    @Test func joinsGroupsThroughEachLink() {
        let result = AccountCheckup.check([
            item("ente/1", "GitHub", "alice", secret: "a"),
            item("device/2", "GitHub", "alice", secret: "b"),
            item("device/3", "Old GitHub", "alice", secret: "b")
        ])
        #expect(result.duplicates == [["ente/1", "device/2", "device/3"]])
    }

    @Test func ignoresAccentsAndCase() {
        let result = AccountCheckup.check([item("ente/1", "Société", "Gérard"), item("device/2", "societe", "GERARD")])
        #expect(result.duplicates.count == 1)
    }

    @Test func suggestsTheAccountsThatFitOnTheYubiKey() {
        let result = AccountCheckup.check([
            item("key/Bank:alice", "Bank", "alice", yubiKey: true),
            item("ente/1", "Bank", "alice"),
            item("ente/2", "GitHub", "alice"),
            item("device/3", "Steam", "alice", fits: false)
        ])
        // Bank is on the key already, and Steam's codes can't be made by a YubiKey.
        #expect(result.fitOnYubiKey == ["ente/2"])
    }

    @Test func findsNothingInATidyList() {
        let result = AccountCheckup.check([
            item("key/GitHub:alice", "GitHub", "alice", yubiKey: true), item("key/Bank:bob", "Bank", "bob", yubiKey: true)
        ])
        #expect(result == AccountCheckup.Result(duplicates: [], fitOnYubiKey: []))
    }
}
