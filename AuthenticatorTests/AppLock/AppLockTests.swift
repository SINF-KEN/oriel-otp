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

/// Stands in for the keychain, which can be made unreadable like before the device is first unlocked.
nonisolated final class InMemoryAppLockStorage: AppLockStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var _configuration: AppLockConfiguration?
    private var _isUnavailable = false

    var configuration: AppLockConfiguration? {
        get { lock.withLock { _configuration } }
        set { lock.withLock { _configuration = newValue } }
    }

    var isUnavailable: Bool {
        get { lock.withLock { _isUnavailable } }
        set { lock.withLock { _isUnavailable = newValue } }
    }

    func load() throws -> AppLockConfiguration? {
        if isUnavailable { throw AppLockUnavailableError() }
        return configuration
    }

    func save(_ configuration: AppLockConfiguration?) throws {
        self.configuration = configuration
    }
}

@MainActor struct AppLockTests {

    let storage = InMemoryAppLockStorage()
    let defaults: UserDefaults

    init() {
        let suite = "AppLockTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func makeLock(now: @escaping () -> Date = { Date(timeIntervalSinceReferenceDate: 800_000_000) },
                  deviceOwner: Bool = true) -> AppLock {
        AppLock(storage: storage, defaults: defaults, now: now, authenticateDeviceOwner: { _ in deviceOwner })
    }

    @Test func notLockedWithoutALock() {
        let lock = makeLock()
        #expect(lock.method == .off)
        #expect(!lock.isLocked)
        lock.lock()
        #expect(!lock.isLocked)
    }

    @Test func codeIsHashedAndUnlocks() throws {
        try makeLock().setMethod(.code6, secret: "123456")
        let configuration = try #require(storage.configuration)
        #expect(!configuration.hash.isEmpty)
        #expect(!String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self).contains("123456"))

        let lock = makeLock()
        #expect(lock.isLocked)
        #expect(lock.method == .code6)
        #expect(!lock.unlock(with: "654321"))
        #expect(lock.isLocked)
        #expect(lock.unlock(with: "123456"))
        #expect(!lock.isLocked)
    }

    @Test func passwordIsComparedAfterNormalization() throws {
        let lock = makeLock()
        try lock.setMethod(.password, secret: "caf\u{E9}")
        lock.lock()
        #expect(lock.unlock(with: "cafe\u{301}"))
    }

    @Test func actionsWaitUntilUnlocked() throws {
        let lock = makeLock()
        try lock.setMethod(.code4, secret: "1234")
        lock.lock()
        var ran = 0
        lock.whenUnlocked { ran += 1 }
        #expect(ran == 0)
        lock.unlock(with: "1234")
        #expect(ran == 1)
        lock.whenUnlocked { ran += 1 }
        #expect(ran == 2)
    }

    @Test func lockingAgainDropsWaitingActions() throws {
        let lock = makeLock()
        try lock.setMethod(.code4, secret: "1234")
        lock.lock()
        var ran = 0
        lock.whenUnlocked { ran += 1 }
        lock.lock()
        lock.unlock(with: "1234")
        #expect(ran == 0)
    }

    @Test func waitsAfterTooManyWrongAttempts() throws {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let lock = AppLock(storage: storage, defaults: defaults, now: { now }, authenticateDeviceOwner: { _ in true })
        try lock.setMethod(.code4, secret: "1234")
        lock.lock()
        for _ in 0..<4 {
            #expect(!lock.unlock(with: "0000"))
        }
        #expect(lock.retryDate == nil)
        #expect(!lock.unlock(with: "0000"))
        #expect(lock.retryDate == now.addingTimeInterval(30))
        // The right code isn't accepted while waiting.
        #expect(!lock.unlock(with: "1234"))

        now = now.addingTimeInterval(31)
        #expect(!lock.unlock(with: "0000"))
        #expect(lock.retryDate == now.addingTimeInterval(60))

        // The wait survives the app being restarted.
        let restarted = AppLock(storage: storage, defaults: defaults, now: { now }, authenticateDeviceOwner: { _ in true })
        #expect(restarted.retryDate == now.addingTimeInterval(60))

        now = now.addingTimeInterval(61)
        #expect(restarted.unlock(with: "1234"))
        #expect(restarted.retryDate == nil)
        restarted.lock()
        #expect(!restarted.unlock(with: "0000"))
        #expect(restarted.retryDate == nil)
    }

    @Test func deviceOwnerUnlocks() async throws {
        let lock = makeLock()
        try lock.setMethod(.device)
        lock.lock()
        await lock.unlockWithDeviceOwner()
        #expect(!lock.isLocked)

        let failing = makeLock(deviceOwner: false)
        #expect(failing.isLocked)
        await failing.unlockWithDeviceOwner()
        #expect(failing.isLocked)
    }

    @Test func turningOffUnlocks() throws {
        let lock = makeLock()
        try lock.setMethod(.password, secret: "secret")
        lock.lock()
        try lock.setMethod(.off)
        #expect(!lock.isLocked)
        #expect(storage.configuration == nil)
        #expect(!makeLock().isLocked)
    }

    @Test func lockLeftByAnEarlierInstallationIsForgotten() throws {
        // The keychain keeps items when the app is deleted, its preferences don't.
        storage.configuration = AppLockConfiguration(method: .code4, secret: "1234", rounds: 1)
        let lock = makeLock()
        #expect(!lock.isLocked)
        #expect(lock.method == .off)
        #expect(storage.configuration == nil)
    }

    @Test func staysLockedUntilTheKeychainCanBeRead() throws {
        try makeLock().setMethod(.code4, secret: "1234")
        storage.isUnavailable = true
        let lock = makeLock()
        #expect(lock.isLocked)
        #expect(lock.isUnavailable)
        #expect(!lock.unlock(with: "1234"))

        storage.isUnavailable = false
        lock.didBecomeActive()
        #expect(!lock.isUnavailable)
        #expect(lock.isLocked)
        #expect(lock.unlock(with: "1234"))
    }

    @Test func unlocksOnceTheKeychainShowsThereIsNoLock() {
        storage.isUnavailable = true
        let lock = makeLock()
        #expect(lock.isLocked)
        storage.isUnavailable = false
        lock.didBecomeActive()
        #expect(!lock.isLocked)
    }
}
