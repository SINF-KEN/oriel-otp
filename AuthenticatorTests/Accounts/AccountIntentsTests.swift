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

@MainActor struct AccountQueryTests {

    private static let accounts = [
        AccountEntity(id: "ente/1", issuer: "GitHub", accountName: "alice@example.com"),
        AccountEntity(id: "device/2", issuer: "Bank", accountName: "alice"),
    ]

    private func query(locked: Bool, suggests: Bool = true) -> AccountQuery {
        AccountQuery(isLocked: { locked }, suggestsAccounts: { suggests }, calculatedEntities: { Self.accounts })
    }

    @Test func listsTheAccountsWhileUnlocked() async throws {
        #expect(try await query(locked: false).suggestedEntities().map(\.id) == ["device/2", "ente/1"])
        #expect(try await query(locked: false).entities(matching: "git").map(\.id) == ["ente/1"])
        #expect(try await query(locked: false).entities(for: ["ente/1"]).map(\.title) == ["GitHub"])
    }

    @Test func namesNoAccountWhileLocked() async throws {
        let query = query(locked: true)
        #expect(try await query.suggestedEntities().isEmpty)
        #expect(try await query.entities(matching: "git").isEmpty)
        // A shortcut that copies a code still finds its account, to unlock the app and copy it.
        let entities = try await query.entities(for: ["ente/1"])
        #expect(entities.map(\.id) == ["ente/1"])
        #expect(entities.allSatisfy { $0.issuer == nil && !$0.accountName.contains("alice") })
    }

    @Test func suggestsNoAccountWithSpotlightOff() async throws {
        #expect(try await query(locked: false, suggests: false).suggestedEntities().isEmpty)
        #expect(try await query(locked: false, suggests: false).entities(matching: "bank").map(\.id) == ["device/2"])
    }
}

@MainActor struct AccountSpotlightTests {

    private let defaults = UserDefaults(suiteName: "AccountSpotlightTests-\(UUID().uuidString)")!

    private final class Counter {
        var count = 0
    }

    @Test func updatesTheSuggestionsOnlyWhileOnAndWhenTurnedOff() async {
        let counter = Counter()
        let spotlight = AccountSpotlight(defaults: defaults, indexes: false, updateShortcuts: { counter.count += 1 })
        spotlight.update()
        await spotlight.finishUpdating()
        #expect(counter.count == 0)

        spotlight.isEnabled = true
        await spotlight.finishUpdating()
        #expect(counter.count == 1)
        spotlight.update()
        await spotlight.finishUpdating()
        #expect(counter.count == 2)

        // Once more, which clears them, even if the accounts change right after.
        spotlight.isEnabled = false
        spotlight.update()
        await spotlight.finishUpdating()
        #expect(counter.count == 3)
        spotlight.update()
        await spotlight.finishUpdating()
        #expect(counter.count == 3)
    }
}
