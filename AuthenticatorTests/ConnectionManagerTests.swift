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
import YubiKit
@testable import OrielOTP

@MainActor
struct ConnectionManagerTests {

    private let yubiKeys = FakeWiredYubiKeys()
    private let manager: ConnectionManager

    init() {
        let yubiKeys = yubiKeys
        manager = ConnectionManager(makeWiredConnection: { await yubiKeys.next() })
    }

    @Test func nextWiredConnectionWaitsForYubiKey() async throws {
        let waiter = Task { try await manager.nextWiredConnection() }
        let yubiKey = try await FakeConnection()
        await yubiKeys.insert(yubiKey)
        let connection = try await waiter.value
        #expect(connection as? FakeConnection === yubiKey)
    }

    @Test func cancellingNextWiredConnectionThrows() async {
        let waiter = Task { try await manager.nextWiredConnection() }
        await Task.yield()
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }

    @Test func subscriberIsToldAboutInsertionAndRemoval() async throws {
        var updates = manager.wiredConnections().makeAsyncIterator()
        let yubiKey = try await FakeConnection()
        await yubiKeys.insert(yubiKey)
        #expect(await updates.next() as? FakeConnection === yubiKey)
        await yubiKey.close(error: nil)
        let removed = try #require(await updates.next())
        #expect(removed == nil)
    }

    @Test func previousSubscriberIsToldWhatItMissed() async throws {
        var first = manager.wiredConnections().makeAsyncIterator()
        let yubiKeyA = try await FakeConnection()
        await yubiKeys.insert(yubiKeyA)
        #expect(await first.next() as? FakeConnection === yubiKeyA)

        let yubiKeyB = try await FakeConnection()
        do {
            var second = manager.wiredConnections().makeAsyncIterator()
            // A new subscriber is handed the current connection.
            #expect(await second.next() as? FakeConnection === yubiKeyA)
            await yubiKeyA.close(error: nil)
            let removed = try #require(await second.next())
            #expect(removed == nil)
            await yubiKeys.insert(yubiKeyB)
            #expect(await second.next() as? FakeConnection === yubiKeyB)
        }

        // The second subscriber has gone away, so the first one is handed the connection it missed.
        #expect(await first.next() as? FakeConnection === yubiKeyB)
    }

    @Test func suspendClosesAndResumeReconnects() async throws {
        var updates = manager.wiredConnections().makeAsyncIterator()
        let yubiKeyA = try await FakeConnection()
        await yubiKeys.insert(yubiKeyA)
        #expect(await updates.next() as? FakeConnection === yubiKeyA)

        await manager.suspendWiredConnections()
        #expect(await yubiKeyA.isClosed)
        let removed = try #require(await updates.next())
        #expect(removed == nil)

        let yubiKeyB = try await FakeConnection()
        await yubiKeys.insert(yubiKeyB)
        manager.resumeWiredConnections()
        #expect(await updates.next() as? FakeConnection === yubiKeyB)
    }
}

/// Hands out the YubiKeys a test inserts, in order, to the connection manager's wired loop.
private actor FakeWiredYubiKeys {
    private var inserted: [FakeConnection] = []
    private var waiter: CheckedContinuation<SmartCardConnection, Never>?

    func insert(_ yubiKey: FakeConnection) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: yubiKey)
        } else {
            inserted.append(yubiKey)
        }
    }

    func next() async -> SmartCardConnection {
        if !inserted.isEmpty { return inserted.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }
}

private actor FakeConnection: SmartCardConnection {
    private(set) var isClosed = false
    private var closeError: Error?
    private var closeWaiters: [CheckedContinuation<Error?, Never>] = []

    init() async throws(SmartCardConnectionError) {}

    static func makeConnection() async throws(SmartCardConnectionError) -> FakeConnection {
        try await FakeConnection()
    }

    func send(data: Data) async throws(SmartCardConnectionError) -> Data {
        Data([0x90, 0x00])
    }

    func close(error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        closeError = error
        closeWaiters.forEach { $0.resume(returning: error) }
        closeWaiters.removeAll()
    }

    func waitUntilClosed() async -> Error? {
        if isClosed { return closeError }
        return await withCheckedContinuation { closeWaiters.append($0) }
    }
}
