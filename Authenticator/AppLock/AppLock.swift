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
            let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            precondition(status == errSecSuccess, "No random bytes for the salt")
            self.salt = salt
            hash = Self.derive(secret, salt: salt, rounds: rounds)
        } else {
            salt = Data()
            hash = Data()
        }
    }

    /// Common codes that aren't a run or a repeated pattern, e.g. keypad columns and years. Codes are guessed from
    /// the most common first, so these go first.
    private static let commonCodes: Set<String> = [
        "0852", "1004", "1984", "2000", "2001", "2020", "2580", "5683", "7410", "8520", "9630",
        "112233", "123321", "147258", "159753", "258456", "520520", "654456", "789456",
    ]

    /// Whether a code is among the first ones tried when guessing: all the same digit, a run up or down like 1234 or
    /// 8765, a repeated pattern like 1212 or 123123, or another common one. Codes already set keep working, only new
    /// ones are checked.
    static func isEasyToGuess(code: String) -> Bool {
        let digits = code.compactMap(\.wholeNumberValue)
        guard digits.count == code.count, digits.count > 1 else { return false }
        let steps = Set(zip(digits, digits.dropFirst()).map { ($1 - $0 + 10) % 10 })
        // The same digit, or a run up or down, wrapping around from 9 to 0.
        if steps.count == 1, let step = steps.first, [0, 1, 9].contains(step) { return true }
        // A short pattern repeated, e.g. 1212, 6969 or 123123.
        for length in 1...(digits.count / 2) where digits.count % length == 0 {
            let pattern = Array(digits.prefix(length))
            if (0..<digits.count).allSatisfy({ digits[$0] == pattern[$0 % length] }) { return true }
        }
        return commonCodes.contains(code)
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

/// The wrong codes or passwords since the last right one.
nonisolated struct AppLockAttempts: Codable, Sendable, Equatable {
    var failures: Int
    /// The system's uptime at the last wrong attempt, see `AppLock.deviceUptime()`.
    var lastFailure: TimeInterval
}

/// Reading the lock failed because the keychain can't be read until the device is unlocked.
nonisolated struct AppLockUnavailableError: Error {}

/// Where the lock is kept: the keychain in the app, memory in the tests.
nonisolated protocol AppLockStorage: Sendable {
    /// Nil when the app isn't locked. Throws `AppLockUnavailableError` before the device was first unlocked.
    func load() throws -> AppLockConfiguration?
    func save(_ configuration: AppLockConfiguration?) throws
    /// Nil when there are no wrong attempts, or they can't be read.
    func loadAttempts() -> AppLockAttempts?
    func saveAttempts(_ attempts: AppLockAttempts?) throws
}

/// What the lock protects on the device: the files the app keeps its accounts in, and the keychain items that open
/// them or reach the accounts elsewhere (the Ente session, the saved YubiKey passwords).
nonisolated struct AppLockProtectedData: Sendable {
    /// Whether any of the files is there.
    var exists: @Sendable () -> Bool
    /// Deletes the keychain items, so that files kept aside can't be opened again once the lock is gone.
    var forget: @Sendable () -> Void

    /// The app's. Named here rather than through the types that keep them, as the AutoFill extension builds this file
    /// without those.
    static let app = AppLockProtectedData(
        exists: {
            let files = [URL.applicationSupportDirectory.appending(components: "DeviceAccounts", "Accounts"),
                         URL.applicationSupportDirectory.appending(components: "EnteAuth", "Vault"),
                         URL.applicationSupportDirectory.appending(components: "Tags", "YubiKeyTags"),
                         URL.applicationSupportDirectory.appending(components: "Favorites", "Favorites"),
                         URL.applicationSupportDirectory.appending(components: "AutoFill", "Websites")]
                + [AppGroup.containerURL?.appending(components: "AutoFill", "Accounts")].compactMap { $0 }
            return files.contains { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        },
        forget: {
            for service in ["DeviceAccounts", "EnteAuth.Vault", "Tags", "Favorites", "AutoFill.Websites", "AutoFill.Accounts",
                            "EnteAuth", "OATH"] {
                var query: [String: Any] = [String(kSecClass): kSecClassGenericPassword, String(kSecAttrService): service]
                #if os(macOS)
                query[String(kSecUseDataProtectionKeychain)] = true
                #endif
                SecItemDelete(query as CFDictionary)
            }
        })
}

/// The lock and its wrong attempts in the keychain: `WhenUnlockedThisDeviceOnly`, so they never leave the device or
/// come back from a backup, and can't be changed from outside the app like its preferences can.
nonisolated struct AppLockKeychain: AppLockStorage {

    private static let configurationAccount = "configuration"
    private static let attemptsAccount = "attempts"

    private func query(account: String) -> [String: Any] {
        var query: [String: Any] = [String(kSecClass): kSecClassGenericPassword,
                                    String(kSecAttrService): "AppLock",
                                    String(kSecAttrAccount): account]
        #if os(macOS)
        query[String(kSecUseDataProtectionKeychain)] = true
        #endif
        return query
    }

    func load() throws -> AppLockConfiguration? {
        try read(account: Self.configurationAccount).map { try JSONDecoder().decode(AppLockConfiguration.self, from: $0) }
    }

    func save(_ configuration: AppLockConfiguration?) throws {
        try write(configuration.map { try JSONEncoder().encode($0) }, account: Self.configurationAccount)
    }

    func loadAttempts() -> AppLockAttempts? {
        guard let data = try? read(account: Self.attemptsAccount) else { return nil }
        return try? JSONDecoder().decode(AppLockAttempts.self, from: data)
    }

    func saveAttempts(_ attempts: AppLockAttempts?) throws {
        try write(attempts.map { try JSONEncoder().encode($0) }, account: Self.attemptsAccount)
    }

    private func read(account: String) throws -> Data? {
        var query = query(account: account)
        query[String(kSecReturnData)] = true
        query[String(kSecMatchLimit)] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw SecureStoreError.dataCastError }
            return data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw AppLockUnavailableError()
        default:
            throw Self.error(status)
        }
    }

    /// Updates the item in place, so a change that fails leaves the old lock rather than none.
    private func write(_ data: Data?, account: String) throws {
        let query = query(account: account)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
            return
        }
        let attributes: [String: Any] = [String(kSecValueData): data,
                                         String(kSecAttrAccessible): kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            // In the group shared with the AutoFill extension, which locks with it too.
            var item = query.merging(attributes) { _, new in new }
            SharedKeychain.addAccessGroup(to: &item)
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    private static func error(_ status: OSStatus) -> Error {
        SecureStoreError.unhandledError(message: SecCopyErrorMessageString(status, nil) as String? ?? String(status))
    }
}

/// A Face ID, Touch ID or passcode check that already succeeded. Reading a protected item with it doesn't ask again,
/// as long as the check satisfies the item's access control: the device passcode doesn't satisfy `biometryCurrentSet`.
/// Keep it only as long as it's needed, as it reads protected items without the user knowing.
nonisolated struct KeychainAuthentication: @unchecked Sendable {
    // Only ever passed to the keychain, never changed after it was evaluated.
    let context: LAContext
}

/// Locks the account list behind Face ID or Touch ID, a 4 or 6 digit code, or a password.
///
/// The app locks when it starts and whenever it goes to the background, or on the Mac when the screen locks or the
/// Mac sleeps. While it's locked, nothing that would show codes or ask for something else (NFC, the Ente session's
/// Face ID) is started: it waits in `whenUnlocked`.
///
/// After 5 wrong codes or passwords, the next attempt has to wait 30 seconds, doubling with each wrong one up to a
/// day, so a code can't be guessed slowly over months, while the owner can always try again the next day. The wait
/// follows the system's uptime, which can't be set like the clock, and starts over when the device
/// restarts. There's no way around a forgotten code or password other than deleting the app: the accounts are on the
/// YubiKey and in Ente Auth, not only in the app.
///
/// The keychain keeps the lock when the app is deleted, the app's preferences don't, which is how a lock left by an
/// earlier installation shows. Preferences can be edited though, so they alone don't remove a lock. While the files the
/// lock protects are still there, the app wasn't deleted, and the lock stays. Without them, the lock is forgotten once
/// the device owner confirms it with Face ID, Touch ID or the device passcode, and the keychain items that would open
/// those files, or reach the accounts in Ente Auth, are deleted with it: files kept aside and put back can't be read.
@MainActor @Observable final class AppLock {
    static let shared = Bundle.main.bundleURL.pathExtension == "appex"
        // The AutoFill extension can't tell which installation of the app saved the lock, the app forgets an earlier
        // one's when it starts.
        ? AppLock(defaults: AppGroup.defaults, keepsSavedLock: true)
        : AppLock()

    private static let enabledKey = "AppLock.Enabled"
    private static let freeAttempts = 5
    /// The longest wait between attempts.
    static let maximumWait: TimeInterval = 24 * 3600

    /// The lock, nil when the app isn't locked or the lock can't be read yet.
    private(set) var configuration: AppLockConfiguration?
    private(set) var isLocked: Bool
    /// The lock couldn't be read, usually because the device hasn't been unlocked since it started, or because the
    /// keychain failed. The app stays locked until it can be read.
    private(set) var isUnavailable = false
    /// When the code or password can be tried again after too many wrong ones.
    private(set) var retryDate: Date?
    /// Face ID or Touch ID is being asked for.
    private(set) var isAuthenticating = false
    /// The Face ID or Touch ID that just unlocked the app, for what's waiting in `whenUnlocked` to read the keychain
    /// without asking again. Only set while those actions run, so it can't approve anything later on.
    @ObservationIgnored private(set) var unlockAuthentication: KeychainAuthentication?

    @ObservationIgnored private let storage: AppLockStorage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keepsSavedLock: Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let uptime: () -> TimeInterval
    @ObservationIgnored private let deviceOwnerIsAvailable: () -> Bool
    @ObservationIgnored private let authenticateDeviceOwner: @MainActor (String) async -> KeychainAuthentication?
    @ObservationIgnored private let protectedData: AppLockProtectedData
    @ObservationIgnored private var pendingActions: [@MainActor () -> Void] = []
    @ObservationIgnored private var didAskForDeviceOwner = false
    /// The saved lock is kept until the device owner confirms forgetting it, `configuration` is the device method
    /// until then. See `holdUnconfirmedLock()`.
    @ObservationIgnored private var isUnconfirmedLock = false
    /// Whether forgetting the unconfirmed lock deletes the keychain items of what it protected.
    @ObservationIgnored private var forgetsProtectedData = false

    var method: AppLockMethod { configuration?.method ?? .off }

    /// With `keepsSavedLock`, a lock in the keychain is used even if this installation didn't save it.
    init(storage: AppLockStorage = AppLockKeychain(),
         defaults: UserDefaults = .standard,
         keepsSavedLock: Bool = false,
         now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = AppLock.deviceUptime,
         deviceOwnerIsAvailable: @escaping () -> Bool = { AppLock.canUseDeviceOwner },
         authenticateDeviceOwner: @escaping @MainActor (String) async -> KeychainAuthentication? = { await AppLock.evaluateDeviceOwner(reason: $0) },
         protectedData: AppLockProtectedData = .app) {
        self.storage = storage
        self.protectedData = protectedData
        self.defaults = defaults
        self.keepsSavedLock = keepsSavedLock
        self.now = now
        self.uptime = uptime
        self.deviceOwnerIsAvailable = deviceOwnerIsAvailable
        self.authenticateDeviceOwner = authenticateDeviceOwner
        isLocked = true
        relock()
    }

    /// Reads the lock again and locks, if a lock is set. The AutoFill extension does this for every request, as its
    /// process can outlive one and the lock can change in the app in between.
    func relock() {
        reload()
        isLocked = isUnavailable || method != .off
        didAskForDeviceOwner = false
        pendingActions = []
        updateRetryDate()
    }

    /// Reads the lock from the keychain.
    private func reload() {
        do {
            let saved = try storage.load()
            if saved != nil, !keepsSavedLock, !defaults.bool(forKey: Self.enabledKey) {
                if protectedData.exists() {
                    // The preferences were changed: the app wasn't deleted, as what the lock protects is still there.
                    defaults.set(true, forKey: Self.enabledKey)
                    configuration = saved
                    isUnconfirmedLock = false
                } else {
                    // Left by an earlier installation of the app.
                    holdUnconfirmedLock(forgetsProtectedData: true)
                }
            } else {
                configuration = saved
                isUnconfirmedLock = false
                forgetsProtectedData = false
            }
            isUnavailable = false
        } catch is DecodingError {
            // A lock that can't be decoded can't be unlocked, so it mustn't lock the app for good. Only the app writes
            // the keychain item, so this isn't a way to get rid of a lock, and the accounts are kept.
            holdUnconfirmedLock(forgetsProtectedData: false)
            isUnavailable = false
        } catch {
            // The device is locked, or the keychain failed. The app stays locked and reads it again when it's next
            // active, rather than opening without the lock.
            isUnavailable = true
        }
    }

    /// Asks for the device owner before a saved lock that can't be used is forgotten. A device without a passcode has
    /// no owner to ask.
    private func holdUnconfirmedLock(forgetsProtectedData: Bool) {
        self.forgetsProtectedData = forgetsProtectedData
        if deviceOwnerIsAvailable() {
            configuration = AppLockConfiguration(method: .device)
            isUnconfirmedLock = true
        } else {
            forgetSavedLock()
        }
    }

    private func forgetSavedLock() {
        if forgetsProtectedData {
            protectedData.forget()
        }
        forgetsProtectedData = false
        try? storage.save(nil)
        try? storage.saveAttempts(nil)
        defaults.set(false, forKey: Self.enabledKey)
        configuration = nil
        isUnconfirmedLock = false
        retryDate = nil
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
        let authentication = await authenticateDeviceOwner(String(localized: "Unlock Oriel OTP", comment: "Face ID reason when unlocking the app"))
        isAuthenticating = false
        guard let authentication else { return }
        if isUnconfirmedLock { forgetSavedLock() }
        unlock(authentication: authentication)
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
        // Counted as wrong before it's checked, and only checked once that's saved: an attempt whose count can't be
        // saved would be a free one. Saving first, before the slow comparison, also leaves the AutoFill extension,
        // which shares the count, little time to read it in between and lose one of the two.
        let failures = (storage.loadAttempts()?.failures ?? 0) + 1
        do {
            try storage.saveAttempts(AppLockAttempts(failures: failures, lastFailure: uptime()))
        } catch {
            return false
        }
        if configuration.matches(secret) {
            try? storage.saveAttempts(nil)
            return true
        }
        updateRetryDate()
        return false
    }

    /// Asks for Face ID, Touch ID or the device passcode before the lock is changed from or to the device method.
    func verifyDeviceOwner() async -> Bool {
        await authenticateDeviceOwner(String(localized: "Change how Oriel OTP is locked", comment: "Face ID reason when changing the app lock")) != nil
    }

    /// Changes the lock. `secret` is the new code or password, for the methods that have one.
    func setMethod(_ method: AppLockMethod, secret: String? = nil) throws {
        precondition(!method.hasSecret || secret != nil, "A code or password is needed")
        let configuration = method == .off ? nil : AppLockConfiguration(method: method, secret: secret)
        // Set before the lock is saved, so a lock saved by this installation is never taken for an earlier one's,
        // even if the app stops in between.
        if configuration != nil {
            defaults.set(true, forKey: Self.enabledKey)
        }
        try storage.save(configuration)
        defaults.set(configuration != nil, forKey: Self.enabledKey)
        try? storage.saveAttempts(nil)
        self.configuration = configuration
        isUnconfirmedLock = false
        isUnavailable = false
        retryDate = nil
        if configuration == nil { unlock() }
    }

    /// Clears `retryDate` once it has passed, for the views counting down to it.
    func updateRetryDate() {
        guard var attempts = storage.loadAttempts(), attempts.failures >= Self.freeAttempts else {
            retryDate = nil
            return
        }
        let uptime = uptime()
        if attempts.lastFailure > uptime {
            // The device restarted, which says nothing about the time that passed: the wait starts over.
            attempts.lastFailure = uptime
            try? storage.saveAttempts(attempts)
        }
        let delay = min(30 * pow(2, Double(min(attempts.failures - Self.freeAttempts, 32))), Self.maximumWait)
        let remaining = delay - (uptime - attempts.lastFailure)
        retryDate = remaining > 0 ? now().addingTimeInterval(remaining) : nil
    }

    private func unlock(authentication: KeychainAuthentication? = nil) {
        isLocked = false
        let actions = pendingActions
        pendingActions = []
        unlockAuthentication = authentication
        actions.forEach { $0() }
        unlockAuthentication = nil
    }

    nonisolated static func evaluateDeviceOwner(reason: String) async -> KeychainAuthentication? {
        let context = LAContext()
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return nil }
        return KeychainAuthentication(context: context)
    }

    /// The time since the device started, including while it slept. Changing the clock doesn't affect it.
    nonisolated static func deviceUptime() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
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
