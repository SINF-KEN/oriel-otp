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
#if os(iOS)
    import WatchConnectivity
#endif

#if os(iOS)
    /// The parts of `WCSession` the sync uses, a seam for the tests.
    protocol WatchSession: AnyObject {
        var delegate: (any WCSessionDelegate)? { get set }
        var activationState: WCSessionActivationState { get }
        var isPaired: Bool { get }
        var isWatchAppInstalled: Bool { get }
        var isReachable: Bool { get }
        /// The latest context sent, which the system keeps on disk.
        var applicationContext: [String: Any] { get }
        func activate()
        func updateApplicationContext(_ applicationContext: [String: Any]) throws
        func sendMessage(
            _ message: [String: Any], replyHandler: (([String: Any]) -> Void)?,
            errorHandler: ((any Error) -> Void)?)
    }

    extension WCSession: WatchSession {}
#endif

/// Sends the Ente Auth accounts to the Apple Watch app, which keeps them and calculates the codes itself.
///
/// Opt in: nothing is sent until the user turns on **Show Ente Auth accounts on Apple Watch**. The accounts are sent
/// whenever they are synced from Ente with the saved session. Turning it off or signing out of Ente sends an empty
/// list, which makes the watch delete everything.
///
/// The system keeps the latest application context on disk on both devices, so the accounts are sealed with a
/// `WatchSyncKey` kept in this device's keychain, which the watch gets with `sendMessage`. A new key is made after the
/// accounts are cleared, so a context sent before can't be opened with a later key and the other way round.
///
/// The Mac has no Apple Watch connection, so there a watch is never available and nothing is sent.
@Observable final class WatchAccountSync: NSObject {

    static let shared = WatchAccountSync()

    nonisolated private static let enabledKey = "Watch.ShowEnteAccounts"
    private static let pendingClearKey = "Watch.PendingClear"
    /// The key must be deleted before another is used, deleting it failed while the iPhone was locked.
    nonisolated private static let pendingRotationKey = "Watch.PendingKeyRotation"

    /// A watch is paired and has the app installed.
    private(set) var isWatchAvailable = false
    private(set) var isEnabled: Bool

    #if os(iOS)
        @ObservationIgnored private let session: (any WatchSession)?
        @ObservationIgnored private let keyItem: any WatchKeychainItem
    #endif
    /// Also read off the main actor to answer the watch; `UserDefaults` is thread safe.
    @ObservationIgnored nonisolated(unsafe) private let defaults: UserDefaults
    /// The accounts that couldn't be sent, e.g. before the session was activated. Sent once it is.
    @ObservationIgnored private var unsentAccounts: [OTPAccount]?

    #if os(iOS)
        init(
            session: (any WatchSession)? = WCSession.isSupported() ? WCSession.default : nil,
            keyItem: any WatchKeychainItem = SystemKeychainItem(service: "OrielOTP.WatchSyncKey", account: "key"),
            defaults: UserDefaults = .standard
        ) {
            self.session = session
            self.keyItem = keyItem
            self.defaults = defaults
            self.isEnabled = defaults.bool(forKey: Self.enabledKey)
            super.init()
        }
    #else
        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
            self.isEnabled = defaults.bool(forKey: Self.enabledKey)
            super.init()
        }
    #endif

    func activate() {
        #if os(iOS)
            guard let session, session.delegate == nil else { return }
            session.delegate = self
            session.activate()
        #endif
    }

    func enable() {
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
    }

    /// Turns the switch off and tells the watch to delete the accounts.
    func disable() {
        guard isEnabled || defaults.bool(forKey: Self.pendingClearKey) else { return }
        isEnabled = false
        defaults.removeObject(forKey: Self.enabledKey)
        unsentAccounts = nil
        if update([]) {
            defaults.removeObject(forKey: Self.pendingClearKey)
        } else {
            // Not activated yet or no watch right now, try again when the session is active.
            defaults.set(true, forKey: Self.pendingClearKey)
        }
    }

    /// Sends the time-based accounts when the switch is on. HOTP accounts are skipped, the watch couldn't keep the
    /// counter in step with Ente.
    func send(_ codes: [EnteCode]) {
        guard isEnabled else { return }
        let accounts = Self.accounts(from: codes, favorites: FavoritesStorage().readFavorites())
        unsentAccounts = update(accounts) ? nil : accounts
    }

    /// The accounts for the watch, pinned in Ente Auth or marked as favorite in this app.
    nonisolated static func accounts(from codes: [EnteCode], favorites: Set<String>) -> [OTPAccount] {
        codes.compactMap { code in
            guard var account = code.otpAccount else { return nil }
            account.isPinned = account.isPinned || code.credentialId.map(favorites.contains) == true
            return account
        }
        .sorted(by: OTPAccount.listOrder)
    }

    /// Sends the accounts sealed, or for an empty list the mark that there are none. False when it couldn't be sent
    /// now, e.g. without a watch or while the keychain is locked.
    @discardableResult private func update(_ accounts: [OTPAccount]) -> Bool {
        #if os(iOS)
            if accounts.isEmpty {
                // Even without a watch: the next accounts are sealed with a new key.
                rotateKey()
            }
            guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return false }
            if accounts.isEmpty {
                return (try? session.updateApplicationContext(WatchAccountsMessage.clearedContext)) != nil
            }
            guard let (key, isNew) = currentKey() else { return false }
            do {
                try session.updateApplicationContext(try WatchAccountsMessage.context(for: accounts, key: key))
            } catch {
                return false
            }
            if isNew {
                // Saves the watch asking for it. If it isn't reachable now, it asks when it gets the context.
                sendKey(key)
            }
            return true
        #else
            return false
        #endif
    }

    #if os(iOS)
        /// The key to seal the accounts with, made if there is none. Nil while the keychain is locked.
        private func currentKey() -> (key: WatchSyncKey, isNew: Bool)? {
            if defaults.bool(forKey: Self.pendingRotationKey) {
                guard rotateKey() else { return nil }
            }
            switch keyItem.read() {
            case .found(let data):
                if let key = WatchSyncKey(data: data) { return (key, false) }
            case .notFound:
                break
            case .unavailable:
                return nil
            }
            let key = WatchSyncKey.generate()
            return keyItem.write(key.data) ? (key, true) : nil
        }

        /// Deletes the key, so the next accounts are sealed with a new one.
        @discardableResult private func rotateKey() -> Bool {
            if keyItem.write(nil) {
                defaults.removeObject(forKey: Self.pendingRotationKey)
                return true
            }
            defaults.set(true, forKey: Self.pendingRotationKey)
            return false
        }

        private func sendKey(_ key: WatchSyncKey) {
            guard let session, session.activationState == .activated, session.isReachable else { return }
            session.sendMessage(WatchAccountsMessage.keyMessage(key), replyHandler: nil, errorHandler: { @Sendable _ in })
        }

        /// The reply to the watch asking for the key: none while the switch is off, the key is to be replaced or the
        /// keychain is locked. The watch asks again later.
        nonisolated static func keyReply(keyItem: any WatchKeychainItem, defaults: UserDefaults) -> [String: Any] {
            guard defaults.bool(forKey: enabledKey), !defaults.bool(forKey: pendingRotationKey),
                case .found(let data) = keyItem.read(), let key = WatchSyncKey(data: data)
            else { return [:] }
            return WatchAccountsMessage.keyMessage(key)
        }

        func sessionStateChanged() {
            guard let session else { return }
            isWatchAvailable = session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
            if !isEnabled && defaults.bool(forKey: Self.pendingClearKey) && update([]) {
                defaults.removeObject(forKey: Self.pendingClearKey)
            }
            if isEnabled, let unsentAccounts, update(unsentAccounts) {
                self.unsentAccounts = nil
            }
            replaceLegacyContext()
        }

        /// Replaces a context from a version that sent the accounts unencrypted, which the system keeps on disk until
        /// another context is sent. Its accounts are read this once, to send them sealed.
        private func replaceLegacyContext() {
            guard let session, isWatchAvailable, !WatchAccountsMessage.isCurrent(session.applicationContext) else { return }
            let accounts = isEnabled ? WatchAccountsMessage.legacyAccounts(from: session.applicationContext) ?? [] : []
            update(accounts)
        }
    #endif
}

#if os(iOS)
    extension WatchAccountSync: WCSessionDelegate {

        nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
            Task { @MainActor in self.sessionStateChanged() }
        }

        nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
            Task { @MainActor in self.sessionStateChanged() }
        }

        nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
            Task { @MainActor in self.sessionStateChanged() }
        }

        /// Called when the user switches to another watch, activate again to talk to the new one.
        nonisolated func sessionDidDeactivate(_ session: WCSession) {
            session.activate()
        }

        /// The watch asks for the key when it has a context it can't open. Answered right away: this may run in the
        /// background, and the reply handler can't be passed to the main actor.
        nonisolated func session(
            _ session: WCSession, didReceiveMessage message: [String: Any],
            replyHandler: @escaping ([String: Any]) -> Void
        ) {
            guard WatchAccountsMessage.isKeyRequest(message) else { return replyHandler([:]) }
            replyHandler(Self.keyReply(keyItem: keyItem, defaults: defaults))
        }
    }
#endif
