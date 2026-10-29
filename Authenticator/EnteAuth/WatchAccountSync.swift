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

/// Sends the Ente Auth accounts to the Apple Watch app, which keeps them and calculates the codes itself.
///
/// Opt in: nothing is sent until the user turns on **Show Ente Auth accounts on Apple Watch**. The accounts are sent
/// whenever they are synced from Ente with the saved session. Turning it off or signing out of Ente sends an empty
/// list, which makes the watch delete everything.
///
/// The Mac has no Apple Watch connection, so there a watch is never available and nothing is sent.
@Observable final class WatchAccountSync: NSObject {

    static let shared = WatchAccountSync()

    private static let enabledKey = "Watch.ShowEnteAccounts"
    private static let pendingClearKey = "Watch.PendingClear"

    /// A watch is paired and has the app installed.
    private(set) var isWatchAvailable = false
    private(set) var isEnabled: Bool

    #if os(iOS)
        @ObservationIgnored private let session: WCSession?
    #endif
    @ObservationIgnored private let defaults: UserDefaults

    #if os(iOS)
        init(session: WCSession? = WCSession.isSupported() ? .default : nil, defaults: UserDefaults = .standard) {
            self.session = session
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
        update(Self.accounts(from: codes, favorites: FavoritesStorage().readFavorites()))
    }

    /// The accounts for the watch, pinned in Ente Auth or marked as favorite in this app.
    static func accounts(from codes: [EnteCode], favorites: Set<String>) -> [OTPAccount] {
        codes.compactMap { code in
            guard var account = code.otpAccount else { return nil }
            account.isPinned = account.isPinned || code.credentialId.map(favorites.contains) == true
            return account
        }
        .sorted(by: OTPAccount.listOrder)
    }

    @discardableResult private func update(_ accounts: [OTPAccount]) -> Bool {
        #if os(iOS)
            guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return false }
            do {
                try session.updateApplicationContext(try WatchAccountsMessage.context(for: accounts))
                return true
            } catch {
                return false
            }
        #else
            return false
        #endif
    }

    #if os(iOS)
        private func sessionStateChanged() {
            guard let session else { return }
            isWatchAvailable = session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
            if !isEnabled && defaults.bool(forKey: Self.pendingClearKey) && update([]) {
                defaults.removeObject(forKey: Self.pendingClearKey)
            }
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
    }
#endif
