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

/// Answers the diff from `entities`, like Ente's server: changed after sinceTime, oldest first. With `endless` set it
/// answers every request with one new entity, until `endlessLimit` requests, then fails.
nonisolated private final class HostileDiffStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var entities: [(id: String, updatedAt: Int64)] = []
    nonisolated(unsafe) static var endless = false
    nonisolated(unsafe) static var requestCount = 0
    static let endlessLimit = 2_500

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let since = components?.queryItems?.first { $0.name == "sinceTime" }?.value.flatMap { Int64($0) } ?? 0
        var status = 200
        var diff: [[String: Any]] = []
        if components?.path != "/authenticator/entity/diff" {
            status = 500
        } else if Self.endless {
            if Self.requestCount > Self.endlessLimit {
                status = 500
            } else {
                diff = [["id": "endless-\(Self.requestCount)", "isDeleted": false, "updatedAt": NSNumber(value: since + 1)]]
            }
        } else {
            diff = Self.entities.filter { $0.updatedAt > since }.sorted { $0.updatedAt < $1.updatedAt }
                .map { ["id": $0.id, "isDeleted": false, "updatedAt": NSNumber(value: $0.updatedAt)] }
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["diff": diff])) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Suite(.serialized)
struct HostileServerPagingTests {

    private let server = URL(string: "https://api.example.com")!

    private func signedIn(lastSyncTime: Int64 = 0) throws -> EnteCloud {
        let defaults = makeTestDefaults()
        let store = EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true)
        let session = EnteSavedSession(server: server, email: "alice@example.com", token: "t", authenticatorKey: EnteCrypto.randomBytes(32))
        try store.save(session)
        let storage = InMemoryVaultStorage()
        var vault = EnteVault(email: "alice@example.com", server: server)
        vault.lastSyncTime = lastSyncTime
        try storage.save(vault)
        let cloud = EnteCloud(store: store, storage: storage, session: URLSession.stubbed([HostileDiffStub.self]),
                              watch: WatchAccountSync(defaults: defaults))
        cloud.use(session)
        return cloud
    }

    /// once the server sent one entity dated at the end of time, nothing changed later is ever pulled again.
    @Test func aFarFutureUpdateDoesntStopLaterPulls() async throws {
        HostileDiffStub.endless = false
        HostileDiffStub.requestCount = 0
        HostileDiffStub.entities = [("a", 5), ("evil", .max)]
        defer { HostileDiffStub.entities = [] }
        let cloud = try signedIn()
        // Whether a fixed client keeps or refuses this page doesn't matter, only what follows.
        await cloud.sync(unlock: false)

        // The server is fixed, and another device adds an account.
        HostileDiffStub.entities = [("a", 5), ("b", 7)]
        await cloud.sync(unlock: false)
        #expect(cloud.vault?.items.contains { $0.entityID == "b" } == true)
        #expect((cloud.vault?.lastSyncTime ?? 0) < .max)
    }

    /// A server that always has one more new entity must not keep the sync paging until the server gives up.
    @Test func anEndlessDiffIsCutShortByTheClient() async throws {
        HostileDiffStub.endless = true
        HostileDiffStub.requestCount = 0
        defer { HostileDiffStub.endless = false }
        let cloud = try signedIn()
        await cloud.sync(unlock: false)
        #expect(HostileDiffStub.requestCount < HostileDiffStub.endlessLimit)
        #expect(!cloud.isSyncing)
    }

    /// A far-future time saved before such times were refused is replaced by a full pull.
    @Test func aFarFutureTimeSavedEarlierIsReplaced() async throws {
        HostileDiffStub.endless = false
        HostileDiffStub.requestCount = 0
        HostileDiffStub.entities = [("a", 5), ("b", 7)]
        defer { HostileDiffStub.entities = [] }
        let cloud = try signedIn(lastSyncTime: .max)
        await cloud.sync(unlock: false)
        #expect(cloud.vault?.items.compactMap(\.entityID).sorted() == ["a", "b"])
        #expect(cloud.vault?.lastSyncTime == 7)
    }
}
