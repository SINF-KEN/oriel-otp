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

import CommonCrypto
import Foundation
import LocalAuthentication
import Observation
import Security

/// What unlocks the app.
nonisolated enum AppLockMethod: String, Codable, Sendable, CaseIterable {
    case off
    /// Face ID or Touch ID with the device passcode as a fallback, or Touch ID or the password on the Mac.
    case device
    case code4
    case code6
    case password

    /// The number of digits of a code, nil for the other methods.
    var codeLength: Int? {
        switch self {
        case .code4: 4
        case .code6: 6
        default: nil
        }
    }

    /// Whether the app keeps a code or password of its own for this method.
    var hasSecret: Bool { codeLength != nil || self == .password }
}

/// The lock kept in the keychain: the method and, for a code or password, a salted PBKDF2 hash of it. The code or
/// password itself is never stored.
nonisolated struct AppLockConfiguration: Codable, Sendable, Equatable {
    static let defaultRounds = 210_000

    let method: AppLockMethod
    let salt: Data
    let hash: Data
    let rounds: Int

    init(method: AppLockMethod, secret: String? = nil, rounds: Int = defaultRounds) {
        self.method = method
        self.rounds = rounds
        if method.hasSecret, let secret {
            var salt = Data(count: 16)
            _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            self.salt = salt
            hash = Self.derive(secret, salt: salt, rounds: rounds)
        } else {
            salt = Data()
            hash = Data()
        }
    }

    /// Whether `secret` is the code or password, compared in constant time.
    func matches(_ secret: String) -> Bool {
        guard method.hasSecret, !hash.isEmpty else { return false }
        let candidate = Self.derive(secret, salt: salt, rounds: rounds)
        guard candidate.count == hash.count else { return false }
        return zip(candidate, hash).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func derive(_ secret: String, salt: Data, rounds: Int) -> Data {
        let password = Array(secret.precomposedStringWithCanonicalMapping.utf8).map { CChar(bitPattern: $0) }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { salt in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                                 salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                 &derived, derived.count)
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return Data(derived)
    }
}

/// Reading the lock failed because the keychain can't be read until the device is unlocked.
nonisolated struct AppLockUnavailableError: Error {}

/// Where the lock is kept: the keychain in the app, memory in the tests.
nonisolated protocol AppLockStorage: Sendable {
    /// Nil when the app isn't locked. Throws `AppLockUnavailableError` before the device was first unlocked.
    func load() throws -> AppLockConfiguration?
    func save(_ configuration: AppLockConfiguration?) throws
}

/// The lock in the keychain: `WhenUnlockedThisDeviceOnly`, so it never leaves the device or comes back from a backup.
nonisolated struct AppLockKeychain: AppLockStorage {

    private var query: [String: Any] {
        var query: [String: Any] = [String(kSecClass): kSecClassGenericPassword,
                                    String(kSecAttrService): "AppLock",
                                    String(kSecAttrAccount): "configuration"]
        #if os(macOS)
        query[String(kSecUseDataProtectionKeychain)] = true
        #endif
        return query
    }

    func load() throws -> AppLockConfiguration? {
        var query = query
        query[String(kSecReturnData)] = true
        query[String(kSecMatchLimit)] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw SecureStoreError.dataCastError }
            return try JSONDecoder().decode(AppLockConfiguration.self, from: data)
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw AppLockUnavailableError()
        default:
            throw SecureStoreError.unhandledError(message: SecCopyErrorMessageString(status, nil) as String? ?? String(status))
        }
    }

    func save(_ configuration: AppLockConfiguration?) throws {
        SecItemDelete(query as CFDictionary)
        guard let configuration else { return }
        var query = query
        query[String(kSecValueData)] = try JSONEncoder().encode(configuration)
        query[String(kSecAttrAccessible)] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStoreError.unhandledError(message: SecCopyErrorMessageString(status, nil) as String? ?? String(status))
        }
    }
}

/// Locks the account list behind Face ID or Touch ID, a 4 or 6 digit code, or a password.
///
/// The app locks when it starts and whenever it goes to the background, or on the Mac when the screen locks or the
/// Mac sleeps. While it's locked, nothing that would show codes or ask for something else (NFC, the Ente session's
/// Face ID) is started: it waits in `whenUnlocked`.
///
/// After 5 wrong codes or passwords, the next attempt has to wait 30 seconds, doubling with each wrong one up to an
/// hour. There's no way around a forgotten code or password other than deleting the app, which forgets the lock: the
/// accounts are on the YubiKey and in Ente Auth, not only in the app.
@MainActor @Observable final class AppLock {
    static let shared = AppLock()

    private static let enabledKey = "AppLock.Enabled"
    private static let failedAttemptsKey = "AppLock.FailedAttempts"
    private static let lastFailureKey = "AppLock.LastFailure"
    private static let freeAttempts = 5

    /// The lock, nil when the app isn't locked or the lock can't be read yet.
    private(set) var configuration: AppLockConfiguration?
    private(set) var isLocked: Bool
    /// The lock couldn't be read because the device hasn't been unlocked since it started. The app stays locked
    /// until it can be read.
    private(set) var isUnavailable = false
    /// When the code or password can be tried again after too many wrong ones.
    private(set) var retryDate: Date?
    /// Face ID or Touch ID is being asked for.
    private(set) var isAuthenticating = false

    @ObservationIgnored private let storage: AppLockStorage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let authenticateDeviceOwner: @MainActor (String) async -> Bool
    @ObservationIgnored private var pendingActions: [@MainActor () -> Void] = []
    @ObservationIgnored private var didAskForDeviceOwner = false

    var method: AppLockMethod { configuration?.method ?? .off }

    init(storage: AppLockStorage = AppLockKeychain(),
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         authenticateDeviceOwner: @escaping @MainActor (String) async -> Bool = { await AppLock.evaluateDeviceOwner(reason: $0) }) {
        self.storage = storage
        self.defaults = defaults
        self.now = now
        self.authenticateDeviceOwner = authenticateDeviceOwner
        isLocked = true
        reload()
        isLocked = isUnavailable || method != .off
        updateRetryDate()
    }

    /// Reads the lock from the keychain. A lock left in the keychain by an earlier installation of the app, which the
    /// keychain keeps when the app is deleted, is forgotten.
    private func reload() {
        do {
            var configuration = try storage.load()
            if configuration != nil, !defaults.bool(forKey: Self.enabledKey) {
                try? storage.save(nil)
                configuration = nil
            }
            self.configuration = configuration
            isUnavailable = false
        } catch is AppLockUnavailableError {
            isUnavailable = true
        } catch {
            // A lock that can't be read can't be unlocked, so it's forgotten rather than locking the app for good.
            try? storage.save(nil)
            configuration = nil
            isUnavailable = false
        }
    }

    /// Locks the app, if a lock is set.
    func lock() {
        guard method != .off || isUnavailable else { return }
        isLocked = true
        didAskForDeviceOwner = false
        // What was waiting is done again when the app comes back, e.g. syncing.
        pendingActions = []
    }

    /// For when the app becomes active: reads the lock if it couldn't be read before, and asks for Face ID or
    /// Touch ID the first time after the app locked.
    func didBecomeActive() {
        if isUnavailable {
            reload()
            if !isUnavailable && method == .off {
                unlock()
                return
            }
        }
        guard isLocked, method == .device, !didAskForDeviceOwner else { return }
        didAskForDeviceOwner = true
        Task { await unlockWithDeviceOwner() }
    }

    /// Runs `action` now, or once the app is unlocked.
    func whenUnlocked(_ action: @escaping @MainActor () -> Void) {
        if isLocked {
            pendingActions.append(action)
        } else {
            action()
        }
    }

    /// Unlocks with Face ID, Touch ID or the device passcode.
    func unlockWithDeviceOwner() async {
        guard isLocked, method == .device, !isAuthenticating else { return }
        isAuthenticating = true
        let success = await authenticateDeviceOwner(String(localized: "Unlock Oriel OTP", comment: "Face ID reason when unlocking the app"))
        isAuthenticating = false
        if success { unlock() }
    }

    /// Unlocks if `secret` is the code or password. Returns false when it isn't, or it's too early to try again.
    @discardableResult func unlock(with secret: String) -> Bool {
        guard isLocked, verify(secret) else { return false }
        unlock()
        return true
    }

    /// Whether `secret` is the code or password, counting a wrong one towards the wait before the next attempt.
    func verify(_ secret: String) -> Bool {
        guard let configuration, configuration.method.hasSecret else { return false }
        updateRetryDate()
        guard retryDate == nil else { return false }
        if configuration.matches(secret) {
            defaults.removeObject(forKey: Self.failedAttemptsKey)
            defaults.removeObject(forKey: Self.lastFailureKey)
            return true
        }
        defaults.set(defaults.integer(forKey: Self.failedAttemptsKey) + 1, forKey: Self.failedAttemptsKey)
        defaults.set(now().timeIntervalSinceReferenceDate, forKey: Self.lastFailureKey)
        updateRetryDate()
        return false
    }

    /// Asks for Face ID, Touch ID or the device passcode before the lock is changed from or to the device method.
    func verifyDeviceOwner() async -> Bool {
        await authenticateDeviceOwner(String(localized: "Change how Oriel OTP is locked", comment: "Face ID reason when changing the app lock"))
    }

    /// Changes the lock. `secret` is the new code or password, for the methods that have one.
    func setMethod(_ method: AppLockMethod, secret: String? = nil) throws {
        precondition(!method.hasSecret || secret != nil, "A code or password is needed")
        let configuration = method == .off ? nil : AppLockConfiguration(method: method, secret: secret)
        try storage.save(configuration)
        defaults.set(configuration != nil, forKey: Self.enabledKey)
        defaults.removeObject(forKey: Self.failedAttemptsKey)
        defaults.removeObject(forKey: Self.lastFailureKey)
        self.configuration = configuration
        isUnavailable = false
        retryDate = nil
        if configuration == nil { unlock() }
    }

    /// Clears `retryDate` once it has passed, for the views counting down to it.
    func updateRetryDate() {
        let failures = defaults.integer(forKey: Self.failedAttemptsKey)
        guard failures >= Self.freeAttempts else {
            retryDate = nil
            return
        }
        let delay = min(30 * pow(2, Double(failures - Self.freeAttempts)), 3600)
        let lastFailure = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: Self.lastFailureKey))
        let retryDate = lastFailure.addingTimeInterval(delay)
        self.retryDate = retryDate > now() ? retryDate : nil
    }

    private func unlock() {
        isLocked = false
        let actions = pendingActions
        pendingActions = []
        actions.forEach { $0() }
    }

    nonisolated static func evaluateDeviceOwner(reason: String) async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// Whether the device can check its owner, i.e. a passcode or password is set.
    nonisolated static var canUseDeviceOwner: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// The name of the device method: Face ID, Touch ID, Optic ID, or the passcode when there's no biometry.
    nonisolated static var deviceOwnerTitle: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default:
            #if os(macOS)
            return String(localized: "Mac password", comment: "App lock method on a Mac without Touch ID")
            #else
            return String(localized: "Device passcode", comment: "App lock method on a device without Face ID or Touch ID")
            #endif
        }
    }
}
