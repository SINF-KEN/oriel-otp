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
import LocalAuthentication
import Testing

@testable import OrielOTP

/// Stands in for the keychain, which can be made unreadable like before the device is first unlocked.
nonisolated final class InMemoryAppLockStorage: AppLockStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var _configuration: AppLockConfiguration?
    private var _attempts: AppLockAttempts?
    private var _isUnavailable = false
    private var _loadError: Error?
    private var _saveError: Error?

    var configuration: AppLockConfiguration? {
        get { lock.withLock { _configuration } }
        set { lock.withLock { _configuration = newValue } }
    }

    var isUnavailable: Bool {
        get { lock.withLock { _isUnavailable } }
        set { lock.withLock { _isUnavailable = newValue } }
    }

    /// Thrown by `load()`, e.g. a keychain error or data that can't be decoded.
    var loadError: Error? {
        get { lock.withLock { _loadError } }
        set { lock.withLock { _loadError = newValue } }
    }

    /// Thrown by `save(_:)`, which then keeps the lock it had, like the keychain does.
    var saveError: Error? {
        get { lock.withLock { _saveError } }
        set { lock.withLock { _saveError = newValue } }
    }

    var attempts: AppLockAttempts? {
        get { lock.withLock { _attempts } }
        set { lock.withLock { _attempts = newValue } }
    }

    func loadAttempts() -> AppLockAttempts? { attempts }

    func saveAttempts(_ attempts: AppLockAttempts?) throws { self.attempts = attempts }

    func load() throws -> AppLockConfiguration? {
        if isUnavailable { throw AppLockUnavailableError() }
        if let loadError { throw loadError }
        return configuration
    }

    func save(_ configuration: AppLockConfiguration?) throws {
        if let saveError { throw saveError }
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
                  uptime: @escaping () -> TimeInterval = { 1000 },
                  keepsSavedLock: Bool = false,
                  hasDeviceOwner: Bool = true,
                  deviceOwner: Bool = true) -> AppLock {
        AppLock(storage: storage, defaults: defaults, keepsSavedLock: keepsSavedLock, now: now, uptime: uptime, deviceOwnerIsAvailable: { hasDeviceOwner },
                authenticateDeviceOwner: { _ in deviceOwner ? KeychainAuthentication(context: LAContext()) : nil })
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
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var uptime: TimeInterval = 1000
        let lock = makeLock(now: { now }, uptime: { uptime })
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

        uptime += 31
        #expect(!lock.unlock(with: "0000"))
        #expect(lock.retryDate == now.addingTimeInterval(60))

        // The wait survives the app being restarted.
        let restarted = makeLock(now: { now }, uptime: { uptime })
        #expect(restarted.retryDate == now.addingTimeInterval(60))

        uptime += 61
        #expect(restarted.unlock(with: "1234"))
        #expect(restarted.retryDate == nil)
        restarted.lock()
        #expect(!restarted.unlock(with: "0000"))
        #expect(restarted.retryDate == nil)
    }

    // With the wait stopping at an hour, every 4-digit code could be tried in about 14 months.
    @Test func theWaitKeepsGrowingPastAnHourUpToADay() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var uptime: TimeInterval = 1000
        let lock = makeLock(now: { now }, uptime: { uptime })
        try lock.setMethod(.code4, secret: "1234")
        lock.lock()
        var waits: [TimeInterval] = []
        for _ in 0..<20 {
            #expect(!lock.unlock(with: "0000"))
            let wait = lock.retryDate.map { $0.timeIntervalSince(now) } ?? 0
            waits.append(wait)
            uptime += wait + 1
        }
        #expect(waits[4] == 30)
        #expect(waits[11] == 30 * 128)
        #expect(waits[16] == 24 * 3600)
        #expect(waits[19] == 24 * 3600)
        // The owner can still get in once the wait is over.
        #expect(lock.unlock(with: "1234"))
    }

    @Test(arguments: ["0000", "1111", "999999", "1234", "4321", "123456", "654321", "7890", "0987", "1212", "6969", "123123",
                      "121212", "2580", "1004", "147258"])
    func easyCodesAreTurnedDown(code: String) {
        #expect(AppLockConfiguration.isEasyToGuess(code: code))
    }

    @Test(arguments: ["2749", "8316", "502817", "1357", "135790", "120034"])
    func otherCodesAreAccepted(code: String) {
        #expect(!AppLockConfiguration.isEasyToGuess(code: code))
    }

    @Test func movingTheClockForwardDoesNotShortenTheWait() throws {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let lock = makeLock(now: { now })
        try lock.setMethod(.code4, secret: "1234")
        lock.lock()
        for _ in 0..<5 {
            #expect(!lock.unlock(with: "0000"))
        }

        now = now.addingTimeInterval(86_400)
        lock.updateRetryDate()
        #expect(lock.retryDate == now.addingTimeInterval(30))
        #expect(!lock.unlock(with: "1234"))
    }

    @Test func theWaitStartsOverWhenTheDeviceRestarts() throws {
        var uptime: TimeInterval = 5000
        let lock = makeLock(uptime: { uptime })
        try lock.setMethod(.code4, secret: "1234")
        lock.lock()
        for _ in 0..<5 {
            #expect(!lock.unlock(with: "0000"))
        }

        uptime = 10
        lock.updateRetryDate()
        #expect(lock.retryDate != nil)
        #expect(storage.attempts?.lastFailure == 10)
        uptime = 39
        lock.updateRetryDate()
        #expect(lock.retryDate != nil)
        uptime = 41
        #expect(lock.unlock(with: "1234"))
    }

    @Test func wrongAttemptsAreKeptWithTheLockNotInThePreferences() throws {
        let lock = makeLock()
        try lock.setMethod(.code4, secret: "1234")
        lock.lock()
        #expect(!lock.unlock(with: "0000"))
        #expect(storage.attempts?.failures == 1)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("AppLock.") } == ["AppLock.Enabled"])

        #expect(lock.unlock(with: "1234"))
        #expect(storage.attempts == nil)
    }

    @Test func relockingLocksAgainWithTheCurrentLock() throws {
        let lock = makeLock(keepsSavedLock: true)
        #expect(!lock.isLocked)

        // Turned on in the app after the extension started.
        storage.configuration = AppLockConfiguration(method: .code4, secret: "1234", rounds: 1)
        lock.relock()
        #expect(lock.isLocked)
        #expect(lock.method == .code4)
        #expect(lock.unlock(with: "1234"))

        // The next request has to unlock again.
        lock.relock()
        #expect(lock.isLocked)

        // Turned off in the app.
        storage.configuration = nil
        lock.relock()
        #expect(!lock.isLocked)
    }

    @Test func relockingDropsWaitingActions() throws {
        let lock = makeLock()
        try lock.setMethod(.code4, secret: "1234")
        lock.lock()
        var ran = 0
        lock.whenUnlocked { ran += 1 }
        lock.relock()
        lock.unlock(with: "1234")
        #expect(ran == 0)
    }

    @Test func relockingStaysLockedWhenTheKeychainCantBeRead() throws {
        let lock = makeLock()
        try lock.setMethod(.code4, secret: "1234")
        lock.lock()
        lock.unlock(with: "1234")
        storage.isUnavailable = true
        lock.relock()
        #expect(lock.isLocked)
        #expect(lock.isUnavailable)
    }

    /// A lock with 5 wrong attempts made, so it waits 30 seconds.
    private func waitingLock(now: @escaping () -> Date, uptime: @escaping () -> TimeInterval) throws -> AppLock {
        let lock = makeLock(now: now, uptime: uptime, deviceOwner: false)
        try lock.setMethod(.code4, secret: "1234")
        lock.lock()
        for _ in 0..<5 {
            lock.unlock(with: "0000")
        }
        return lock
    }

    @Test func changingTheClockDoesNotEndTheWait() throws {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let lock = try waitingLock(now: { now }, uptime: { 1000 })

        now = now.addingTimeInterval(365 * 24 * 3600)
        #expect(!lock.unlock(with: "1234"))
        #expect(lock.retryDate == now.addingTimeInterval(30))

        // Setting it back doesn't make the wait longer either.
        now = now.addingTimeInterval(-2 * 365 * 24 * 3600)
        #expect(!lock.unlock(with: "1234"))
        #expect(lock.retryDate == now.addingTimeInterval(30))
    }

    @Test func restartingTheDeviceStartsTheWaitOver() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var uptime: TimeInterval = 100_000
        let lock = try waitingLock(now: { now }, uptime: { uptime })

        uptime = 5
        #expect(!lock.unlock(with: "1234"))
        #expect(lock.retryDate == now.addingTimeInterval(30))

        uptime = 34
        lock.updateRetryDate()
        #expect(lock.retryDate == now.addingTimeInterval(1))

        uptime = 36
        #expect(lock.unlock(with: "1234"))
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

    @Test func lockMissingFromThePreferencesIsForgottenOnceTheDeviceOwnerConfirms() async throws {
        // The keychain keeps items when the app is deleted, its preferences don't. They can also be edited, so they
        // alone don't open the app.
        storage.configuration = AppLockConfiguration(method: .code4, secret: "1234", rounds: 1)
        storage.attempts = AppLockAttempts(failures: 9, lastFailure: 1000)

        let refused = makeLock(deviceOwner: false)
        #expect(refused.isLocked)
        #expect(refused.method == .device)
        await refused.unlockWithDeviceOwner()
        #expect(refused.isLocked)
        #expect(storage.configuration != nil)

        let lock = makeLock()
        #expect(lock.isLocked)
        #expect(!lock.unlock(with: "1234"))
        await lock.unlockWithDeviceOwner()
        #expect(!lock.isLocked)
        #expect(lock.method == .off)
        #expect(storage.configuration == nil)
        #expect(storage.attempts == nil)
        #expect(!makeLock().isLocked)
    }

    @Test func lockMissingFromThePreferencesIsForgottenWithoutADeviceOwner() throws {
        storage.configuration = AppLockConfiguration(method: .code4, secret: "1234", rounds: 1)
        let lock = makeLock(hasDeviceOwner: false)
        #expect(!lock.isLocked)
        #expect(lock.method == .off)
        #expect(storage.configuration == nil)
    }

    @Test func settingALockReplacesOneWaitingForTheDeviceOwner() async throws {
        storage.configuration = AppLockConfiguration(method: .code4, secret: "1234", rounds: 1)
        let lock = makeLock()
        try lock.setMethod(.code6, secret: "123456")
        lock.lock()
        await lock.unlockWithDeviceOwner()
        #expect(lock.isLocked)
        #expect(storage.configuration?.method == .code6)
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

    @Test func staysLockedWhenTheKeychainFails() throws {
        try makeLock().setMethod(.code4, secret: "1234")
        storage.loadError = SecureStoreError.unhandledError(message: "keychain failed")
        let lock = makeLock()
        #expect(lock.isLocked)
        #expect(lock.isUnavailable)
        #expect(storage.configuration != nil)

        storage.loadError = nil
        lock.didBecomeActive()
        #expect(lock.isLocked)
        #expect(lock.unlock(with: "1234"))
    }

    @Test func lockThatCantBeDecodedIsForgottenOnceTheDeviceOwnerConfirms() async throws {
        try makeLock().setMethod(.code4, secret: "1234")
        storage.loadError = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "corrupt"))
        let lock = makeLock()
        #expect(lock.isLocked)
        #expect(lock.method == .device)
        #expect(storage.configuration != nil)

        await lock.unlockWithDeviceOwner()
        #expect(!lock.isLocked)
        #expect(lock.method == .off)
        #expect(storage.configuration == nil)
    }

    @Test func failedChangeKeepsTheOldLock() throws {
        let lock = makeLock()
        try lock.setMethod(.code4, secret: "1234")
        storage.saveError = SecureStoreError.unhandledError(message: "keychain failed")
        #expect(throws: SecureStoreError.self) { try lock.setMethod(.password, secret: "secret") }
        #expect(lock.method == .code4)

        storage.saveError = nil
        let restarted = makeLock()
        #expect(restarted.isLocked)
        #expect(restarted.method == .code4)
        #expect(restarted.unlock(with: "1234"))
    }

    @Test func waitingActionsGetTheFaceIDThatUnlockedTheApp() async throws {
        let context = LAContext()
        let lock = AppLock(storage: storage, defaults: defaults, authenticateDeviceOwner: { _ in KeychainAuthentication(context: context) })
        try lock.setMethod(.device)
        lock.lock()

        var authentication: KeychainAuthentication?
        lock.whenUnlocked { authentication = lock.unlockAuthentication }
        await lock.unlockWithDeviceOwner()

        #expect(authentication?.context === context)
        // Nothing later can use it.
        #expect(lock.unlockAuthentication == nil)
    }

    @Test func aCodeLeavesNoFaceIDForTheWaitingActions() throws {
        let lock = makeLock()
        try lock.setMethod(.code4, secret: "1234")
        lock.lock()

        var didRun = false
        lock.whenUnlocked {
            didRun = true
            #expect(lock.unlockAuthentication == nil)
        }
        #expect(lock.unlock(with: "1234"))
        #expect(didRun)
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
