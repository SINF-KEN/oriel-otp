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

import SwiftUI

/// The saved Ente account in settings, with Sign out.
struct EnteAccountSection: View {

    private let store: EnteSessionStore
    @State private var account: EnteSavedAccount?
    @State private var isConfirmingSignOut = false
    @State private var isSigningOut = false

    init(store: EnteSessionStore = EnteSessionStore()) {
        self.store = store
        _account = State(initialValue: store.savedAccount)
    }

    var body: some View {
        Section {
            if let account {
                LabeledContent(String(localized: "Account", comment: "Ente saved session account label"), value: account.email.leftToRightIfAddress)
                LabeledContent(String(localized: "Server", comment: "Ente saved account server label"),
                               value: account.server.host ?? account.server.absoluteString)
                Button(String(localized: "Sign out", comment: "Ente sign out button"), role: .destructive) {
                    isConfirmingSignOut = true
                }
                .disabled(isSigningOut)
            } else {
                Text(String(localized: "Not signed in", comment: "Ente settings without a saved account"))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(verbatim: "Ente Auth")
        } footer: {
            if let account, !account.hasSession {
                Text(String(localized: "Ente ended this session. Open Sync from Ente Auth and enter your password to sync again.", comment: "Ente settings footer when the server rejected the session"))
            } else if account != nil {
                #if os(macOS)
                Text(String(localized: "Your session and the key that decrypts your Ente Auth accounts are kept in this Mac's keychain, protected by Touch ID or your Mac's password. A copy of the accounts is kept on this Mac, encrypted with a key that never leaves it. Your Ente password is never stored.", comment: "Mac Ente settings footer"))
                #else
                Text(String(localized: "Your session and the key that decrypts your Ente Auth accounts are kept in this device's keychain, protected by Face ID or Touch ID. A copy of the accounts is kept on this device, encrypted with a key that never leaves it. Your Ente password is never stored.", comment: "Ente settings footer"))
                #endif
            } else {
                Text(String(localized: "Sign in from Sync from Ente Auth to stay signed in on this device.", comment: "Ente settings footer without a saved account"))
            }
        }
        .onAppear { account = store.savedAccount }
        .confirmationDialog(String(localized: "Sign out of Ente?", comment: "Ente sign out confirmation"), isPresented: $isConfirmingSignOut) {
            Button(String(localized: "Sign out", comment: "Ente sign out button"), role: .destructive) { signOut() }
        } message: {
            if EnteCloud.shared.hasPendingChanges {
                Text(String(localized: "The session, the key and the copy of your accounts are deleted from this device. Some changes made here haven't been synced with Ente Auth yet and will be lost.", comment: "Ente sign out confirmation message with changes that weren't uploaded"))
            } else {
                Text(String(localized: "The session, the key and the copy of your accounts are deleted from this device. Your accounts stay in Ente Auth.", comment: "Ente sign out confirmation message"))
            }
        }
    }

    private func signOut() {
        isSigningOut = true
        Task {
            await store.signOut()
            account = store.savedAccount
            isSigningOut = false
        }
    }
}
