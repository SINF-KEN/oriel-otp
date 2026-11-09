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
import WatchConnectivity

/// The Ente Auth accounts sent by the iPhone, kept in the watch's keychain so codes work without the iPhone.
///
/// The iPhone sends them sealed in the application context. The key comes in a message: the iPhone sends it when it
/// makes a new one, and this asks for it when a context can't be opened, again whenever the iPhone becomes reachable
/// or the app becomes active, until it gets it. Until then the accounts saved before stay.
@Observable final class WatchAccountStore: NSObject {

    private(set) var accounts: [OTPAccount]

    @ObservationIgnored private let receiver: WatchAccountReceiver?
    /// The latest context couldn't be opened without the key.
    @ObservationIgnored private var needsKey = false
    @ObservationIgnored private var isRequestingKey = false

    override init() {
        if DemoMode.isEnabled {
            receiver = nil
            accounts = DemoMode.accounts.sorted(by: OTPAccount.listOrder)
        } else {
            let receiver = WatchAccountReceiver()
            self.receiver = receiver
            accounts = receiver.accounts
        }
        super.init()
    }

    func activate() {
        guard receiver != nil, WCSession.isSupported(), WCSession.default.delegate == nil else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Called when the app becomes active: saves what couldn't be saved while the watch was locked, and applies the
    /// latest context again, e.g. one that couldn't be opened then.
    func refresh() {
        guard let receiver else { return }
        receiver.retry()
        accounts = receiver.accounts
        applyLatestContext()
    }

    private func applyLatestContext() {
        guard receiver != nil, WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        apply(WCSession.default.receivedApplicationContext)
    }

    private func apply(_ context: [String: Any]) {
        guard let receiver else { return }
        needsKey = receiver.apply(context) == .needsKey
        accounts = receiver.accounts
        if needsKey { requestKey() }
    }

    /// Doesn't ask again if the key doesn't open the context: the iPhone may have a newer one, which comes with the
    /// next context.
    private func receive(_ key: WatchSyncKey) {
        guard let receiver else { return }
        let session = WCSession.default
        needsKey =
            receiver.receive(key, context: session.activationState == .activated ? session.receivedApplicationContext : [:]) == .needsKey
        accounts = receiver.accounts
    }

    private func requestKey() {
        let session = WCSession.default
        guard !isRequestingKey, session.activationState == .activated, session.isReachable else { return }
        isRequestingKey = true
        session.sendMessage(
            WatchAccountsMessage.keyRequest,
            replyHandler: { @Sendable reply in
                let key = WatchAccountsMessage.key(from: reply)
                Task { @MainActor in
                    self.isRequestingKey = false
                    if let key { self.receive(key) }
                }
            },
            errorHandler: { @Sendable _ in
                Task { @MainActor in self.isRequestingKey = false }
            })
    }
}

extension WatchAccountStore: WCSessionDelegate {

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.applyLatestContext() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        // Property list values only, never changed after this.
        nonisolated(unsafe) let context = applicationContext
        Task { @MainActor in self.apply(context) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in
            if self.needsKey { self.requestKey() }
        }
    }

    /// The iPhone sends a new key as soon as it makes it.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let key = WatchAccountsMessage.key(from: message) else { return }
        Task { @MainActor in self.receive(key) }
    }
}
