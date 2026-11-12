/*
 * Copyright (C) Yubico.
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
import YubiKit

// MARK: - Sheets, alerts and dialogs over the window

extension MainView {

    var presentations: some View {
        @Bindable var model = model
        return
            mainLayout
            .onChange(of: model.allTags) { _, tags in
                if let selectedTag, !tags.contains(selectedTag) {
                    self.selectedTag = nil
                }
            }
            .onChange(of: model.accounts.map(\.accountId)) { _, accountIDs in
                // Drop the selection when the account goes away, e.g. the YubiKey was removed or the account deleted.
                #if os(macOS)
                    selectedAccountIDs.formIntersection(accountIDs)
                    singleColumnPath.removeAll { !accountIDs.contains($0) }
                #else
                    if let selectedAccountID, !accountIDs.contains(selectedAccountID) {
                        self.selectedAccountID = nil
                    }
                #endif
            }
            .sheet(isPresented: $showAddAccount) {
                AddAccountView(
                    showAddCredential: $showAddAccount, accountSubject: addAccountSubject, oathURL: oathURL,
                    destinations: addAccountDestinations
                )
                // The view reads the link only when it is made.
                .id(addAccountLinkID)
                .scaledBodyFont()
                .appLockCover()
            }
            .sheet(isPresented: $showEnteSync) {
                EnteSyncView(
                    existingCredentialIds: Set(model.keyAccounts.map(\.accountId)),
                    capacity: model.accountsLoaded ? model.credentialCapacity : nil,
                    canAddToYubiKey: DeviceCapabilities.supportsNFC || model.isKeyPluggedIn
                ) { templates, requiresTouch in
                    model.importToYubiKey(templates, requiresTouch: requiresTouch) { toastPresenter.toast(message: $0) }
                }
                .scaledBodyFont()
                .appLockCover()
            }
            // Sheets rather than full-screen covers, so they read as a task on top of the account list and can be swiped away.
            .sheet(isPresented: $showConfiguration) {
                ConfigurationView(showConfiguration: $showConfiguration)
                    .onAppear {
                        model.stop()
                    }.onDisappear {
                        model.start()
                    }
                    .scaledBodyFont()
                    .appLockCover()
            }
            // Rename from the Mac's menu bar, or from a row's VoiceOver actions.
            .sheet(item: $accountToRename) { account in
                EditView(
                    account: account, viewModel: model,
                    showEditing: Binding(get: { accountToRename != nil }, set: { if !$0 { accountToRename = nil } })
                )
                .scaledBodyFont()
                .appLockCover()
            }
            .sheet(item: $accountToTag) { account in
                AccountTagsView(
                    account: account, isPresented: Binding(get: { accountToTag != nil }, set: { if !$0 { accountToTag = nil } })
                )
                .scaledBodyFont()
                .appLockCover()
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
                    .onAppear {
                        model.stop()
                    }.onDisappear {
                        model.start()
                    }
                    .scaledBodyFont()
                    .appLockCover()
            }
            .alert(String(localized: "Enter password", comment: "Password alert"), isPresented: $model.presentPasswordEntry) {
                SecureField(String(localized: "Password", comment: "Password alert"), text: $password)
                Button(String(localized: "Cancel", comment: "Password alert"), role: .cancel) {
                    model.cancelPasswordEntry()
                    password = ""
                }
                Button(String(localized: "OK", comment: "Password alert")) {
                    model.submitPassword(password)
                    password = ""
                }
            } message: {
                Text(model.passwordEntryMessage)
            }
            .alertOrConfirmationDialog(
                String(localized: "Save password?", comment: "Save password alert"), isPresented: $model.presentPasswordSaveType
            ) {
                Button(String(localized: "Save password", comment: "Save password alert.")) { model.selectPasswordSaveType(.save) }
                let authenticationType = PasswordPreferences.evaluatedAuthenticationType()
                if authenticationType != .none {
                    Button(String(localized: "Save and protect with \(authenticationType.title)")) { model.selectPasswordSaveType(.lock) }
                }
                Button(String(localized: "Never for this YubiKey", comment: "Save password alert.")) {
                    model.selectPasswordSaveType(.never)
                }
                Button(String(localized: "Not now", comment: "Save passsword alert"), role: .cancel) { model.selectPasswordSaveType(nil) }
            }
            .alert(
                accountsToDelete.count > 1
                    ? String(
                        localized: "Delete \(accountsToDelete.count) accounts?",
                        comment: "Delete several accounts alert. The placeholder is the number of accounts.")
                    : String(localized: "Delete account?"),
                isPresented: Binding(get: { !accountsToDelete.isEmpty }, set: { if !$0 { accountsToDelete = [] } }),
                presenting: accountsToDelete
            ) { accounts in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    model.deleteAccounts(accounts) {}
                }
            } message: { accounts in
                if accounts.contains(where: \.isOnDevice) {
                    if accounts.count > 1 {
                        Text(
                            String(
                                localized:
                                    "Accounts on this device are deleted for good, as there is no other copy. You won’t be able to generate codes for them anymore. Accounts on a YubiKey or in Ente Auth are removed from there.",
                                comment: "Delete several accounts alert when some are on this device"))
                    } else {
                        Text(
                            String(
                                localized:
                                    "This deletes the account for good, as there is no other copy. You won’t be able to generate codes for it anymore.",
                                comment: "Delete account alert for an account on this device"))
                    }
                } else if accounts.contains(where: \.isInEnte) {
                    if accounts.count > 1 {
                        Text(
                            String(
                                localized:
                                    "Accounts on the YubiKey are deleted from it. Accounts in Ente Auth are moved to its trash on all your devices, where the Ente Auth app can restore them.",
                                comment: "Delete several accounts alert when some are in Ente Auth"))
                    } else {
                        Text(
                            String(
                                localized:
                                    "This moves the account to the trash in Ente Auth on all your devices. You can restore it in the Ente Auth app.",
                                comment: "Delete account alert for an account in Ente Auth"))
                    }
                } else if accounts.count > 1 {
                    Text(
                        String(
                            localized: "This removes the accounts from the YubiKey. You won’t be able to generate codes for them anymore.",
                            comment: "Delete several accounts alert"))
                } else {
                    Text("This removes the account from the YubiKey. You won’t be able to generate codes for it anymore.")
                }
            }
            // A confirmation for an account on a YubiKey doesn't outlive the key: the next key connected may have an
            // account of the same name.
            .onChange(of: model.accounts.filter { $0.location == .yubiKey }.map(\.accountId)) { _, onYubiKey in
                let isGone = { (account: Account) in account.location == .yubiKey && !onYubiKey.contains(account.accountId) }
                if accountsToDelete.contains(where: isGone) {
                    accountsToDelete.removeAll(where: isGone)
                }
                if let accountToRename, isGone(accountToRename) {
                    self.accountToRename = nil
                }
            }
            #if os(iOS)
                // Blanks the codes, which are privacy sensitive, whenever the scene isn't active, so they don't show in the
                // app switcher or its snapshot. Only the codes, so the screen still makes sense behind the NFC and Face ID sheets.
                // The Mac has no app switcher snapshots, and codes are read from the window while another app is in front.
                .redacted(reason: scenePhase == .active ? [] : .privacy)
            #else
                // The countdowns pause while the window is covered by others or on another Space, and catch up when it's seen.
                .background {
                    WindowOcclusionObserver { isVisible in
                        model.setCountdownsVisible(isVisible, in: .mainWindow)
                    }
                    .accessibilityHidden(true)
                }
                // The lock screen only covers the window, the menu bar's commands would still copy codes and delete accounts.
                .focusedSceneValue(\.mainWindowMenuState, AppLock.shared.isLocked ? nil : menuState)
                .onChange(of: commands.pending) { _, command in
                    guard let command else { return }
                    commands.pending = nil
                    guard !AppLock.shared.isLocked else { return }
                    perform(command)
                }
                // The delete alert is shown above the lock screen, so it's closed when the app locks.
                .onChange(of: AppLock.shared.isLocked) { _, isLocked in
                    if isLocked {
                        accountsToDelete = []
                    }
                }
                .textScaledFrame(minWidth: Self.minimumWindowWidth, minHeight: 420)
            #endif
    }
}
