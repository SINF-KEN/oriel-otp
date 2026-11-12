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

// MARK: - The account list, its rows and its toolbar

extension MainView {

    var accountList: some View {
    Group {
        #if os(macOS)
        let selection = $selectedAccountIDs
        #else
        let selection = $selectedAccountID
        #endif
        List(selection: selection) {
            if let otp {
                Section("Yubico OTP") {
                    YubiOtpRowView(otp: otp)
                }
            }
            if let skew = model.cloud.clockSkew {
                ClockWarningRow(skew: skew)
                    .listRowSeparator(.hidden)
            }
            if showsTagFilter {
                TagFilterBar(tags: model.allTags, selection: $selectedTag)
                    .listRowSeparator(.hidden)
            }
            if !model.hasAccounts {
                ListStatusView(image: Image(systemName: "person.crop.circle.badge.plus"), message: String(localized: "No accounts yet", comment: "Account list without accounts")) {
                    addAccountButton
                    enteSyncButton
                    // The accounts of a YubiKey join the list once it has been read.
                    Text(String.optionalYubiKey(isVoiceOverEnabled: isVoiceOverEnabled))
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if !searchText.isEmpty {
                if searchResults.count > 0 {
                    ForEach(searchResults, id: \.id) { account in
                        accountRow(account)
                    }
                } else {
                    ListStatusView(image: Image(systemName: "person.crop.circle.badge.questionmark"),
                                   message: model.cloudAccounts.isEmpty && model.deviceAccounts.isEmpty ? String(localized: "No matching accounts on YubiKey") : String(localized: "No matching accounts", comment: "Search without results when Ente Auth accounts are listed too"))
                }
            } else if selectedTag != nil && taggedAccounts.isEmpty {
                ListStatusView(image: Image(systemName: "tag"), message: String(localized: "No accounts with this tag", comment: "Account list filtered by a tag that no account has any more"))
            } else if pinnedAccounts.count > 0 {
                Section("Pinned") {
                    ForEach(pinnedAccounts, id: \.id) { account in
                        accountRow(account)
                    }
                }
                if otherAccounts.count > 0 {
                    Section("Other") {
                        ForEach(otherAccounts, id: \.id) { account in
                            accountRow(account)
                        }
                    }
                }
            } else if taggedAccounts.count > 0 && otp != nil {
                Section("Accounts") {
                    ForEach(otherAccounts, id: \.id) { account in
                        accountRow(account)
                    }
                }
            } else if taggedAccounts.count > 0 {
                ForEach(taggedAccounts, id: \.id) { account in
                    accountRow(account)
                }
            } else {
                ListStatusView(image: Image(systemName: "person.crop.circle"), message: String(localized: "No accounts on YubiKey")) {
                    addAccountButton
                    enteSyncButton
                }
            }
            if !model.accountsLoaded && model.hasAccounts && model.hasReadYubiKey && searchText.isEmpty {
                // The other accounts are listed, the YubiKey's join them once it has been read. Not asked of people
                // who don't use one.
                Label {
                    Text(insertYubiKeyMessage)
                } icon: {
                    InsertKeyIcon()
                }
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
            }
        }
        #if os(macOS)
        .background { ListScrollerInset(hasSectionHeader: showsSectionHeader) }
        #endif
    }
    // For the status views' height. Only they are drawn again as it changes, not the rows.
    .providesContainerSize()
    }

    /// The tags show above the list once an account has one.
    private var showsTagFilter: Bool {
        model.hasAccounts && !model.allTags.isEmpty
    }

    /// The accounts with the selected tag, or all of them.
    var taggedAccounts: [Account] {
        let accounts = selectedTag == nil ? model.accounts : model.accounts.filter { $0.isTagged(selectedTag) }
        return AccountUsage.shared.ordered(accounts, id: \.accountId)
    }

    private var pinnedAccounts: [Account] {
        taggedAccounts.filter(\.isPinned)
    }

    private var otherAccounts: [Account] {
        taggedAccounts.filter { !$0.isPinned }
    }

    #if os(macOS)
    /// Whether the list starts with a section's header, as search results and an unsorted list don't have any.
    private var showsSectionHeader: Bool {
        guard !showsTagFilter else { return false }
        return otp != nil || (model.hasAccounts && searchText.isEmpty && pinnedAccounts.count > 0)
    }

    @ToolbarContentBuilder var macToolbar: some CustomizableToolbarContent {
        // Together, not on their own: a secondary action floats in the middle of the Mac sidebar's toolbar.
        ToolbarItem(id: "sync-from-ente", placement: .primaryAction) {
            enteSyncButton
                .help(String(localized: "Sync from Ente Auth", comment: "Main view menu item"))
        }
        ToolbarItem(id: "refresh", placement: .primaryAction) {
            Button(action: { model.refresh() }) {
                Label(String(localized: "Refresh", comment: "Mac toolbar"), systemImage: "arrow.clockwise")
            }
            .accessibilityInputLabels(VoiceControlNames.refresh)
            .accessibilityIdentifier("accounts.refresh")
            .help(String(localized: "Read the codes from the YubiKey again", comment: "Mac toolbar help"))
            .disabled(!model.canRefresh)
        }
        // Not in the toolbar until added from Customize Toolbar, for people who'd rather click than use the menus.
        ToolbarItem(id: "copy-code", placement: .primaryAction) {
            Button(action: { perform(.copyCode) }) {
                Label(String(localized: "Copy Code", comment: "Mac Account menu"), systemImage: "doc.on.doc")
            }
            .help(String(localized: "Copy the code", comment: "Mac row button help"))
            .disabled(selectedAccount == nil)
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "pin", placement: .primaryAction) {
            let unpins = !selectedAccounts.isEmpty && selectedAccounts.allSatisfy(\.isPinned)
            Button(action: { perform(.togglePin) }) {
                Label(unpins ? String(localized: "Unpin", comment: "Mac Account menu") : String(localized: "Pin", comment: "Mac Account menu"),
                      systemImage: unpins ? "pin.slash" : "pin")
            }
            .help(unpins ? String(localized: "Unpin the account", comment: "Mac row button help") : String(localized: "Pin the account to the top", comment: "Mac row button help"))
            .disabled(selectedAccounts.isEmpty)
        }
        .defaultCustomization(.hidden)
        if #available(macOS 27.0, *) {
            addAccountToolbarItem
                .visibilityPriority(.high)
        } else {
            addAccountToolbarItem
        }
    }
    #else
    @ToolbarContentBuilder var mainToolbar: some ToolbarContent {
        // Always there, so scanning doesn't depend on discovering pull to refresh.
        if DeviceCapabilities.supportsNFC {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    otp = nil
                    model.updateAccountsOverNFC()
                } label: {
                    Label(String(localized: "Scan NFC YubiKey"), systemImage: "wave.3.right")
                }
                .accessibilityInputLabels(VoiceControlNames.scanNFC)
                .accessibilityIdentifier("accounts.scan-nfc")
            }
        }

        if !model.hasAccounts {
            ToolbarItem(placement: .principal) {
                // Shrinks rather than crowding out the bar items when the bar is narrow or laid out vertically.
                Text(verbatim: "Oriel OTP")
                    .scaledFont(.headline)
                    .foregroundStyle(Color("YubiGreen"))
                    .accessibilityHidden(true)
            }
        }

        if #available(iOS 27.0, *) {
            addAccountToolbarItem
                .visibilityPriority(.high)
        } else {
            addAccountToolbarItem
        }

        // Secondary actions collapse into the system overflow menu.
        ToolbarItemGroup(placement: .secondaryAction) {
            enteSyncButton
                .help(String(localized: "Sync from Ente Auth", comment: "Main view menu item"))
            // In the Settings window and the app menu on the Mac.
            Button(action: { showConfiguration.toggle() }) {
                Label("Configuration", systemImage: "switch.2")
            }
            .accessibilityInputLabels(VoiceControlNames.configuration)
            .accessibilityIdentifier("accounts.configuration")
            // In the Debug menu on the Mac, so it isn't in the screenshots.
            #if DEBUG && targetEnvironment(simulator)
            if SimulatedYubiKey.isEnabled {
                SimulatedYubiKeyMenu()
                SimulatedYubicoOTPButton()
            }
            #endif
            Button(action: { showAbout.toggle() }) {
                Label("About", systemImage: "questionmark.circle")
            }
            .accessibilityInputLabels(VoiceControlNames.about)
            .accessibilityIdentifier("accounts.about")
        }
    }
    #endif

    private func accountRow(_ account: Account) -> some View {
        AccountRowLink(accountID: account.accountId) {
            #if os(macOS)
            // Copy and pin appear when the pointer is over the row, as there are no swipe actions on the Mac.
            HoverReader { isHovering in
                AccountRowView(account: account, showsLocation: showsLocation, copyCode: { toastPresenter.copyCode(of: account) },
                               isCopied: toastPresenter.copiedAccountID == account.accountId,
                               isSelected: selectedAccountIDs.contains(account.accountId)) {
                    if isHovering {
                        HStack(spacing: 2) {
                            copyButton(account)
                                .help(String(localized: "Copy the code", comment: "Mac row button help"))
                            pinButton(account)
                                .help(account.isPinned ? String(localized: "Unpin the account", comment: "Mac row button help") : String(localized: "Pin the account to the top", comment: "Mac row button help"))
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            }
            #else
            AccountRowView(account: account, showsLocation: showsLocation, copyCode: { toastPresenter.copyCode(of: account) },
                           isCopied: toastPresenter.copiedAccountID == account.accountId,
                           isSelected: selectedAccountID == account.accountId)
            #endif
        }
        .listRowSeparator(.hidden)
        // The same actions as the detail view, without having to open it. VoiceOver lists them as the row's actions.
        // Swipe actions have white labels, so their colors are dark enough for 4.5:1 in both appearances, which the
        // system red and blue aren't.
        // With VoiceOver on, the swipe actions are left out and the same buttons are the row's actions below, so Copy
        // comes first rather than after Pin and Delete.
        .swipeActions(edge: .leading) {
            if !isVoiceOverEnabled {
                pinButton(account)
                    .tint(Color(.favorite))
            }
        }
        .swipeActions(edge: .trailing) {
            if !isVoiceOverEnabled {
                // Not a destructive role, which would remove the row before the deletion is confirmed.
                deleteButton(account)
                    .tint(Color(.deleteAction))
                copyButton(account)
                    .tint(Color(.copyAction))
            }
        }
        .contextMenu {
            copyButton(account)
            pinButton(account)
            tagsButton(account)
            ProtectCodeButton(account: account)
            CopyToYubiKeyButtons(account: account)
            Divider()
            deleteButton(account)
        }
        // The context menu's and the details' actions, so every one can be done from the list, with Copy first. On
        // iOS without VoiceOver, Copy, Pin and Delete are the swipe actions, which the system lists for Switch Control
        // and Full Keyboard Access.
        .accessibilityActions {
            if showsRowActions {
                copyButton(account)
                pinButton(account)
            }
            CopyToYubiKeyButtons(account: account)
            if account.canRename {
                Button(String(localized: "Rename", comment: "Menu")) { accountToRename = account }
            }
            tagsButton(account)
            ProtectCodeButton(account: account)
            if showsRowActions {
                deleteButton(account)
            }
        }
    }

    /// Copy, Pin and Delete are the row's own actions: always on the Mac, which has no swipe actions, and on iOS with
    /// VoiceOver, which then lists them in this order.
    private var showsRowActions: Bool {
        #if os(macOS)
        true
        #else
        isVoiceOverEnabled
        #endif
    }

    /// Each row shows where its account is stored once the list has accounts from different places.
    private var showsLocation: Bool {
        model.showsAccountLocations
    }

    private func copyButton(_ account: Account) -> some View {
        Button(action: { toastPresenter.copyCode(of: account) }) {
            Label(String(localized: "Copy", comment: "Menu"), systemImage: "doc.on.doc")
        }
        .accessibilityInputLabels(VoiceControlNames.copy)
    }

    private func pinButton(_ account: Account) -> some View {
        Button(action: { account.isPinned.toggle() }) {
            Label(account.isPinned ? String(localized: "Unpin", comment: "Menu") : String(localized: "Pin", comment: "Menu"),
                  systemImage: account.isPinned ? "pin.slash" : "pin")
        }
    }

    private func tagsButton(_ account: Account) -> some View {
        Button(action: { accountToTag = account }) {
            Label(String(localized: "Tags", comment: "Menu"), systemImage: "tag")
        }
    }

    private func deleteButton(_ account: Account) -> some View {
        Button(action: { accountsToDelete = [account] }) {
            Label(String(localized: "Delete", comment: "Menu"), systemImage: "trash")
        }
    }

    private var addAccountButton: some View {
        Button(action: { addAccount() }) {
            Label("Add account", systemImage: "plus")
        }
        .accessibilityInputLabels(VoiceControlNames.addAccount)
        .accessibilityIdentifier("accounts.empty-add-account")
    }

    private var enteSyncButton: some View {
        Button(action: { showEnteSync.toggle() }) {
            Label(String(localized: "Sync from Ente Auth", comment: "Main view menu item"), systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
        }
        .accessibilityInputLabels(VoiceControlNames.syncFromEnte)
        .accessibilityIdentifier("accounts.sync-from-ente")
    }

    private var addAccountToolbarItem: some CustomizableToolbarContent {
        ToolbarItem(id: "add-account", placement: .primaryAction) {
            Button(action: { addAccount() }) {
                Label("Add account", systemImage: "plus")
            }
            .accessibilityInputLabels(VoiceControlNames.addAccount)
            .accessibilityIdentifier("accounts.add-account")
            #if os(iOS)
            // With a hardware keyboard. In the menu bar on the Mac.
            .keyboardShortcut("n")
            #endif
            .help(String(localized: "Add an account", comment: "Toolbar help"))
        }
    }
}
