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
struct SafariCodesTests {

    private static let now = Date(timeIntervalSince1970: 1_798_761_612)

    private func storage(_ accounts: [AutoFillAccount]) throws -> InMemoryAutoFillStorage {
        let storage = InMemoryAutoFillStorage()
        try storage.save(accounts)
        return storage
    }

    @Test func givesTheCodesOfTheWebsite() throws {
        let storage = try storage([
            AutoFillWebsitesTests.account("1", issuer: "GitHub", websites: ["github.com"]),
            AutoFillWebsitesTests.account("2", issuer: "Example", websites: ["example.com"])
        ])
        let response = SafariCodes.response(for: "Login.GitHub.com", storage: storage, isLocked: { false }, now: Self.now)
        let accounts = try #require(response["accounts"] as? [[String: String]])
        #expect(accounts.map { $0["title"] } == ["GitHub"])
        #expect(accounts.first?["code"]?.count == 6)
    }

    /// A site whose name only ends like the account's isn't its website.
    @Test func givesNothingForAnotherWebsite() throws {
        let storage = try storage([AutoFillWebsitesTests.account("1", issuer: "GitHub", websites: ["github.com"])])
        let response = SafariCodes.response(for: "notgithub.com", storage: storage, isLocked: { false }, now: Self.now)
        #expect((response["accounts"] as? [[String: String]])?.isEmpty == true)
    }

    @Test func givesNothingWhileTheAppIsLocked() throws {
        let storage = try storage([AutoFillWebsitesTests.account("1", issuer: "GitHub", websites: ["github.com"])])
        let response = SafariCodes.response(for: "github.com", storage: storage, isLocked: { true }, now: Self.now)
        #expect(response["error"] as? String == "locked")
        #expect(response["accounts"] == nil)
    }

    @Test func saysWhenThereAreNoAccounts() {
        let response = SafariCodes.response(for: "github.com", storage: InMemoryAutoFillStorage(), isLocked: { false }, now: Self.now)
        #expect(response["error"] as? String == "noAccounts")
        #expect(SafariCodes.response(for: nil, storage: InMemoryAutoFillStorage(), isLocked: { false })["error"] as? String == "noWebsite")
    }
}
