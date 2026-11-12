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

    /// Showing the accounts on Apple Watch, in settings. Shown when a watch with the app is paired, or while the switch is
    /// on so it can be turned off.
    struct AppleWatchSection: View {

        private var watch: WatchAccountSync { .shared }

        var body: some View {
            if watch.isWatchAvailable || watch.isEnabled {
                Section {
                    Toggle(
                        String(localized: "Show accounts on Apple Watch", comment: "Apple Watch setting toggle"),
                        isOn: Binding(get: { watch.isEnabled }, set: setShowsAccounts))
                } header: {
                    Text(String(localized: "Apple Watch", comment: "Apple Watch settings section header"))
                } footer: {
                    Text(
                        String(
                            localized:
                                "A copy of your time-based accounts on this iPhone and in Ente Auth is kept on your Apple Watch, so it can show codes without your iPhone. Accounts on your YubiKey can't be shown. The copy is updated when your accounts change, and deleted when you turn this off.",
                            comment: "Apple Watch setting footer"))
                }
            }
        }

        private func setShowsAccounts(_ isOn: Bool) {
            guard isOn else {
                watch.disable()
                return
            }
            watch.enable()
            EnteCloud.shared.updateWatch()
        }
    }

#endif
