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

import AuthenticationServices
import Foundation
import Testing

@testable import OrielOTP

/// What the AutoFill extension shows, from the accounts the app wrote for it.
@MainActor
struct AutoFillModelTests {

    /// A storage whose file can't be read.
    private nonisolated struct FailingStorage: AutoFillStorage {
        let error: Error
        func load() throws -> [AutoFillAccount]? { throw error }
        func save(_ accounts: [AutoFillAccount]) throws {}
        func remove() {}
    }

    private static func website(_ host: String) -> ASCredentialServiceIdentifier {
        ASCredentialServiceIdentifier(identifier: host, type: .domain)
    }

    @Test func suggestsTheAccountsOfTheWebsiteFirst() throws {
        let storage = InMemoryAutoFillStorage()
        try storage.save([
            AutoFillWebsitesTests.account("1", issuer: "GitHub", websites: ["github.com"]),
            AutoFillWebsitesTests.account("2", issuer: "Example", websites: ["example.com"]),
            AutoFillWebsitesTests.account("3", issuer: "Another", websites: [])
        ])
        let model = AutoFillModel(storage: storage)
        model.load(for: [Self.website("login.example.com")])
        #expect(model.problem == nil)
        #expect(model.matching.map(\.id) == ["2"])
        #expect(model.others.map(\.id) == ["3", "1"])
    }

    @Test func saysWhenThereAreNoAccounts() {
        let model = AutoFillModel(storage: InMemoryAutoFillStorage())
        model.load(for: [Self.website("example.com")])
        #expect(model.problem == .noAccounts)
        #expect(model.matching.isEmpty && model.others.isEmpty)
    }

    @Test func saysWhenTheDeviceIsLocked() {
        let model = AutoFillModel(storage: FailingStorage(error: EncryptedFileError.unavailable))
        model.load(for: [])
        #expect(model.problem == .unavailable)
    }

    @Test func saysWhenTheFileCantBeRead() {
        let model = AutoFillModel(storage: FailingStorage(error: CocoaError(.fileReadCorruptFile)))
        model.load(for: [])
        #expect(model.problem == .unreadable)
        #expect(model.others.isEmpty)
    }

    /// A file that can't be read later doesn't leave the accounts read before.
    @Test func forgetsTheAccountsWhenTheFileCantBeReadAnyMore() throws {
        let storage = InMemoryAutoFillStorage()
        try storage.save([AutoFillWebsitesTests.account("1", issuer: "GitHub", websites: ["github.com"])])
        let model = AutoFillModel(storage: storage)
        model.load(for: [])
        #expect(model.others.count == 1)
        storage.failsToLoad = true
        model.load(for: [])
        #expect(model.problem == .unavailable)
        #expect(model.others.isEmpty)
    }

    @Test func filtersByNameAccountAndWebsite() throws {
        let accounts = [
            AutoFillWebsitesTests.account("1", issuer: "GitHub", websites: ["github.com"]),
            AutoFillWebsitesTests.account("2", issuer: "Example", websites: ["example.org"])
        ]
        let model = AutoFillModel(storage: InMemoryAutoFillStorage())
        #expect(model.filter(accounts, by: "  ").map(\.id) == ["1", "2"])
        #expect(model.filter(accounts, by: "git").map(\.id) == ["1"])
        #expect(model.filter(accounts, by: "ALICE").map(\.id) == ["1", "2"])
        #expect(model.filter(accounts, by: ".org").map(\.id) == ["2"])
        #expect(model.filter(accounts, by: "nothing").isEmpty)
    }
}
