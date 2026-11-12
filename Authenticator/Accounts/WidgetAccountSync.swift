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

#if os(iOS)
    import SwiftUI
    import WidgetKit

    /// **Show codes in widgets**: writes the pinned accounts whose codes the app calculates for the widgets and the Copy Code
    /// control. Off by default, as widgets show codes outside the app lock. YubiKey accounts are left out, as their
    /// secrets never leave the key, and so are accounts that ask for Face ID before copying.
    @MainActor @Observable final class WidgetAccountSync {

        static let shared = WidgetAccountSync()

        static let isEnabledKey = "Widgets.ShowCodes"

        var isEnabled: Bool {
            didSet {
                guard isEnabled != oldValue else { return }
                UserDefaults.standard.set(isEnabled, forKey: Self.isEnabledKey)
                written = nil
                write()
            }
        }

        @ObservationIgnored private let storage: WidgetAccountsFile
        @ObservationIgnored private var accounts: [OTPAccount] = []
        @ObservationIgnored private var written: [OTPAccount]?

        init(storage: WidgetAccountsFile = WidgetAccountsFile(), defaults: UserDefaults = .standard) {
            self.storage = storage
            isEnabled = defaults.bool(forKey: Self.isEnabledKey)
        }

        /// The accounts to show, in the list's order.
        func update(_ accounts: [OTPAccount]) {
            self.accounts = accounts
            write()
        }

        private func write() {
            let accounts = isEnabled ? accounts : []
            guard accounts != written else { return }
            do {
                try storage.save(accounts)
                written = accounts
            } catch {
                // Tried again with the next update, e.g. once the device is unlocked.
                written = nil
                return
            }
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetAccountsFile.widgetKind)
            ControlCenter.shared.reloadControls(ofKind: WidgetAccountsFile.controlKind)
        }
    }

    extension MainViewModel {
        /// The pinned accounts in Ente Auth or on this device, for the widgets. Counter-based accounts are left out: a widget
        /// can't move a counter on.
        func widgetAccounts() -> [OTPAccount] {
            accounts.compactMap { account in
                guard account.isPinned, !account.isOnYubiKey, !ProtectedAccounts.shared.isProtected(account.accountId),
                    let code = calculatedCode(of: account), code.kind != .hotp
                else { return nil }
                return OTPAccount(
                    id: account.accountId, kind: code.kind == .steam ? .steam : .totp, issuer: code.issuer,
                    accountName: code.accountName, secret: code.secret, algorithm: code.algorithm, digits: code.digits,
                    period: max(1, code.period), isPinned: true)
            }
        }
    }

    /// **Show codes in widgets**, in Configuration.
    struct WidgetsSection: View {
        @Bindable private var sync = WidgetAccountSync.shared

        var body: some View {
            Section {
                Toggle(String(localized: "Show codes in widgets", comment: "Widgets setting"), isOn: $sync.isEnabled)
                    .accessibilityIdentifier("settings.widgets")
            } header: {
                Text(String(localized: "Widgets", comment: "Settings section"))
            } footer: {
                Text(
                    String(
                        localized:
                            "Widgets and the Copy Code control show your pinned accounts in Ente Auth and on this device. They don't ask for the app lock, so anyone holding your unlocked iPhone can see these codes. On the Lock Screen the codes stay hidden until you unlock. Accounts on a YubiKey or that ask for Face ID aren't shown.",
                        comment: "Widgets settings footer"))
            }
        }
    }
#endif
