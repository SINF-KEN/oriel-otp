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
import Combine
import YubiKit

struct MainView: View {
    
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) var isVoiceOverEnabled
    @Environment(ToastPresenter.self) var toastPresenter
    @Environment(NotificationsViewModel.self) var notificationsViewModel
    
    @Environment(MainViewModel.self) var model
    #if os(macOS)
    // Several accounts can be selected on the Mac, to pin or delete them together. The details show for one.
    @State var selectedAccountIDs: Set<String> = []
    var selectedAccountID: String? {
        get { selectedAccountIDs.count == 1 ? selectedAccountIDs.first : nil }
        nonmutating set { selectedAccountIDs = newValue.map { [$0] } ?? [] }
    }
    @State var commands = MainWindowCommands.shared
    @State var isSearchFocused = false
    #else
    @State var selectedAccountID: String? = nil
    #endif
    @State var showAddAccount: Bool = false
    /// Where the add account sheet can save, set when it opens.
    @State var addAccountDestinations: AccountDestinations = .yubiKey
    @State var addAccountCancellable: AnyCancellable?
    @State var addAccountSubject = PassthroughSubject<(YubiKitOATHSession.CredentialTemplate?, Bool, AccountDestinations), Never>()
    @State var showConfiguration: Bool = false
    @State var showAbout: Bool = false
    @State var showEnteSync: Bool = false
    @State var password: String = ""
    @State var searchText: String = ""
    @State var didEnterBackground = true
    @State var otp: String? = nil
    @State var oathURL: URL? = nil
    @State var accountsToDelete: [Account] = []
    @State var accountToRename: Account?
    @State var quickActions = QuickActionCenter.shared
    @ScaledMetric(relativeTo: .largeTitle) private var placeholderSize: CGFloat = 64
    
    // Computed so it follows VoiceOver being turned on or off while the app runs.
    var insertYubiKeyMessage: String {
        if DeviceCapabilities.supportsNFC {
            String(localized: "Insert YubiKey") + " " + "\(!isVoiceOverEnabled ? String(localized: "or pull down to activate NFC") : String(localized: "or scan a NFC YubiKey"))"
        } else {
            String(localized: "Insert YubiKey")
        }
    }
    
    /// Whether a YubiKey can be reached, over NFC or because one is plugged in.
    var canAddToYubiKey: Bool {
        DeviceCapabilities.supportsNFC || model.isKeyPluggedIn
    }

    /// Where a new account can be saved. Without a YubiKey to reach, accounts can still be added to Ente Auth.
    var addDestinations: AccountDestinations {
        var destinations: AccountDestinations = []
        if canAddToYubiKey || !model.cloud.isEnabled { destinations.insert(.yubiKey) }
        if model.cloud.isEnabled { destinations.insert(.ente) }
        return destinations
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var cloud = model.cloud
        presentations
        .errorAlert(error: $model.sessionError)
        .errorAlert(error: $model.connectionError) { model.start() }
        .errorAlert(error: $cloud.error)
        .onAppear {
            if ApplicationSettingsViewModel().isNFCOnAppLaunchEnabled {
                AppLock.shared.whenUnlocked { model.updateAccountsOverNFC() }
            }
            addAccountCancellable = addAccountSubject.sink { (template, requiresTouch, destinations) in
                oathURL = nil
                guard let template else { return }
                if destinations.contains(.yubiKey) {
                    model.addAccount(template, requiresTouch: requiresTouch) {
                        if destinations.contains(.ente) {
                            addAccountToEnte(template)
                        }
                    }
                } else if destinations.contains(.ente) {
                    addAccountToEnte(template)
                }
            }
        }
        .onOpenURL(perform: { url in
            #if os(macOS)
            // The Dock menu and Shortcuts ask for actions with a URL, which also opens the window when it was closed.
            if let action = QuickAction(url: url) {
                quickActions.pending = action
                return
            }
            #endif
            guard url.scheme == "otpauth" else { return }
            if showConfiguration { showConfiguration.toggle() }
            if showAbout { showAbout.toggle() }
            oathURL = url
            addAccountDestinations = addDestinations
            showAddAccount.toggle()
        })
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb, perform: { userActivity in
            guard let otp = userActivity.webpageURL?.yubiOTP else { return }
            if showConfiguration { showConfiguration.toggle() }
            if showAbout { showAbout.toggle() }
            self.otp = otp
            if ApplicationSettingsViewModel().isNFCOnOTPLaunchEnabled {
                AppLock.shared.whenUnlocked { model.updateAccountsOverNFC() }
            }
        })
        #if DEBUG && (targetEnvironment(simulator) || os(macOS))
        .onReceive(NotificationCenter.default.publisher(for: .simulatedYubicoOTP)) { notification in
            otp = notification.object as? String
        }
        #endif
        .onChange(of: otp) { _, otp in
            if let otp, SettingsConfig.isCopyOTPEnabled {
                toastPresenter.copyToClipboard(otp)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            #if os(macOS)
            MainWindowState.shared.isVisible = phase != .background
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // Both the NFC and the Face ID scanning alerts make the app enter the `.inactive` state
            // and in that situation we don't want to call model.stop() nor model.closeConnections()
            if phase == .active && didEnterBackground {
                didEnterBackground = false
                ConnectionManager.shared.resumeWiredConnections()

                guard !notificationsViewModel.showPIVTokenView else { return }
                // Nothing is read or asked for behind the lock screen: the YubiKey's password, NFC or the Ente
                // session's Face ID would come up over it or compete with it.
                AppLock.shared.whenUnlocked {
                    model.start() // This is called when app becomes active
                    Task { await model.cloud.syncAutomatically() }
                    performPendingQuickAction()
                }
            } else if phase == .active {
                performPendingQuickAction()
            } else if phase == .background {
                didEnterBackground = true

                #if os(iOS)
                // Keep running until the YubiKey connection is closed.
                let backgroundTask = UIApplication.shared.beginBackgroundTask()
                model.stop()
                Task {
                    await model.closeConnections()
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
                #else
                model.stop()
                Task {
                    await model.closeConnections()
                }
                #endif
            }
        }
        // Quick actions and the Scan NFC YubiKey intent wait for the scene to be active, as NFC can't start before that.
        .onChange(of: quickActions.pending, initial: true) { _, _ in
            performPendingQuickAction()
        }
        .onChange(of: model.showTouchToast) { _, showToast in
            let message = String(localized: "Touch the button on the YubiKey now.", comment: "Prompt to touch the YubiKey")
            if showToast {
                toastPresenter.toast(message: message, duration: nil)
            } else {
                toastPresenter.dismiss(message: message)
            }
        }
        .onChange(of: notificationsViewModel.showPIVTokenView) { _, showPIVTokenview in
            if showPIVTokenview {
                showAddAccount = false
                showEnteSync = false
                showConfiguration = false
                showAbout = false
                selectedAccountID = nil
            } else if scenePhase == .active {
                // Closed with Cancel or Done. Becoming active skipped starting while the PIV view was up.
                model.start()
            }
        }
        .onChange(of: model.presentDisableOTP) { _, presentDisableOTP in
            if presentDisableOTP {
                showAddAccount = false
                showEnteSync = false
                showConfiguration = false
                showAbout = false
                selectedAccountID = nil
                notificationsViewModel.presentDisableOTP = true
            }
        }
        .onChange(of: notificationsViewModel.presentDisableOTP) { _, presentDisableOTP in
            if !presentDisableOTP {
                model.presentDisableOTP = false
                model.start()
            }
        }
        .onChange(of: model.isKeyPluggedIn) { _, isKeyPluggedIn in
            if isKeyPluggedIn {
                performPendingQuickAction()
            }
            // If the user removes the YubiKey while adding a new account we dismiss the add account modal.
            if showAddAccount && addAccountDestinations.contains(.yubiKey) && !isKeyPluggedIn {
                showAddAccount = false
            }
        }
    }
    
    private var splitView: some View {
        @Bindable var model = model
        return NavigationSplitView {
            accountList
            #if os(macOS)
            .searchable(text: $searchText, placement: .sidebar, prompt: String(localized: "Search"))
            .searchFocusedIfAvailable($isSearchFocused)
            // Return copies the selected account's code, Delete deletes the selected accounts.
            .onKeyPress(.return) {
                guard let selectedAccount else { return .ignored }
                toastPresenter.copyCode(of: selectedAccount)
                return .handled
            }
            .onDeleteCommand {
                accountsToDelete = selectedAccounts
            }
            #else
            .searchable(text: $searchText, prompt: String(localized: "Search"))
            #endif
            .autocorrectionDisabled(true)
            .keyboardType(.asciiCapable)
            .listStyle(.inset)
            .refreshable(enabled: DeviceCapabilities.supportsNFC || model.cloud.isEnabled) {
                otp = nil
                // Synced first, so Face ID for the Ente session isn't asked for while the NFC sheet is up.
                await model.cloud.sync(reportsErrors: true)
                if DeviceCapabilities.supportsNFC {
                    model.updateAccountsOverNFC()
                }
            }
            .toolbar { mainToolbar }
            #if os(macOS)
            .navigationTitle(Text(verbatim: "Oriel OTP"))
            #else
            .navigationTitle(model.hasAccounts ? String(localized: "Accounts", comment: "Navigation title in main view.") : "")
            #endif
            .navigationSplitViewColumnWidth(min: 320, ideal: 360)
        } detail: {
            if let selectedAccount {
                AccountDetailView(account: selectedAccount) {
                    selectedAccountID = nil
                }
                .id(selectedAccount.accountId)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: placeholderSize))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
        }
    }

    private var presentations: some View {
        @Bindable var model = model
        return splitView
        .onChange(of: model.accounts.map(\.accountId)) { _, accountIDs in
            // Drop the selection when the account goes away, e.g. the YubiKey was removed or the account deleted.
            #if os(macOS)
            selectedAccountIDs.formIntersection(accountIDs)
            #else
            if let selectedAccountID, !accountIDs.contains(selectedAccountID) {
                self.selectedAccountID = nil
            }
            #endif
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountView(showAddCredential: $showAddAccount, accountSubject: addAccountSubject, oathURL: oathURL, destinations: addAccountDestinations)
                .appLockCover()
        }
        .sheet(isPresented: $showEnteSync) {
            EnteSyncView(existingCredentialIds: Set(model.keyAccounts.map(\.accountId)),
                         capacity: model.accountsLoaded ? model.credentialCapacity : nil,
                         canAddToYubiKey: DeviceCapabilities.supportsNFC || model.isKeyPluggedIn) { templates, requiresTouch in
                importAccounts(templates, requiresTouch: requiresTouch)
            }
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
                .appLockCover()
        }
        // Rename from the Mac's menu bar, or from a row's VoiceOver actions.
        .sheet(item: $accountToRename) { account in
            EditView(account: account, viewModel: model, showEditing: Binding(get: { accountToRename != nil }, set: { if !$0 { accountToRename = nil } }))
                .appLockCover()
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
                .onAppear {
                    model.stop()
                }.onDisappear {
                    model.start()
                }
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
        .alertOrConfirmationDialog(String(localized: "Save password?", comment: "Save password alert"), isPresented: $model.presentPasswordSaveType) {
            Button(String(localized: "Save password", comment: "Save password alert.")) { model.selectPasswordSaveType(.save) }
            let authenticationType = PasswordPreferences.evaluatedAuthenticationType()
            if authenticationType != .none {
                Button(String(localized: "Save and protect with \(authenticationType.title)")) { model.selectPasswordSaveType(.lock) }
            }
            Button(String(localized: "Never for this YubiKey", comment: "Save password alert.")) { model.selectPasswordSaveType(.never) }
            Button(String(localized: "Not now", comment: "Save passsword alert"), role: .cancel) { model.selectPasswordSaveType(nil) }
        }
        .alert(accountsToDelete.count > 1 ? String(localized: "Delete \(accountsToDelete.count) accounts?", comment: "Delete several accounts alert. The placeholder is the number of accounts.") : String(localized: "Delete account?"),
               isPresented: Binding(get: { !accountsToDelete.isEmpty }, set: { if !$0 { accountsToDelete = [] } }), presenting: accountsToDelete) { accounts in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                model.deleteAccounts(accounts) {}
            }
        } message: { accounts in
            if accounts.contains(where: \.isInEnte) {
                if accounts.count > 1 {
                    Text(String(localized: "Accounts on the YubiKey are deleted from it. Accounts in Ente Auth are moved to its trash on all your devices, where the Ente Auth app can restore them.", comment: "Delete several accounts alert when some are in Ente Auth"))
                } else {
                    Text(String(localized: "This moves the account to the trash in Ente Auth on all your devices. You can restore it in the Ente Auth app.", comment: "Delete account alert for an account in Ente Auth"))
                }
            } else if accounts.count > 1 {
                Text(String(localized: "This removes the accounts from the YubiKey. You won’t be able to generate codes for them anymore.", comment: "Delete several accounts alert"))
            } else {
                Text("This removes the account from the YubiKey. You won’t be able to generate codes for it anymore.")
            }
        }
        #if os(iOS)
        // Blanks the codes, which are privacy sensitive, whenever the scene isn't active, so they don't show in the
        // app switcher or its snapshot. Only the codes, so the screen still makes sense behind the NFC and Face ID sheets.
        // The Mac has no app switcher snapshots, and codes are read from the window while another app is in front.
        .redacted(reason: scenePhase == .active ? [] : .privacy)
        #else
        .focusedSceneValue(\.mainWindowMenuState, menuState)
        .onChange(of: commands.pending) { _, command in
            guard let command else { return }
            commands.pending = nil
            perform(command)
        }
        .frame(minWidth: 640, minHeight: 420)
        #endif
    }

    private var accountList: some View {
    GeometryReader { reader in
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
            if !model.hasAccounts {
                ListStatusView(image: Image("securitykey"), message: insertYubiKeyMessage, height: reader.size.height) {
                    enteSyncButton
                }
            } else if !searchText.isEmpty {
                if searchResults.count > 0 {
                    ForEach(searchResults, id: \.id) { account in
                        accountRow(account)
                    }
                } else {
                    ListStatusView(image: Image(systemName: "person.crop.circle.badge.questionmark"),
                                   message: model.cloudAccounts.isEmpty ? String(localized: "No matching accounts on YubiKey") : String(localized: "No matching accounts", comment: "Search without results when Ente Auth accounts are listed too"),
                                   height: reader.size.height)
                }
            } else if model.pinnedAccounts.count > 0 {
                Section("Pinned") {
                    ForEach(model.pinnedAccounts, id: \.id) { account in
                        accountRow(account)
                    }
                }
                if model.otherAccounts.count > 0 {
                    Section("Other") {
                        ForEach(model.otherAccounts, id: \.id) { account in
                            accountRow(account)
                        }
                    }
                }
            } else if model.accounts.count > 0 && otp != nil {
                Section("Accounts") {
                    ForEach(model.otherAccounts, id: \.id) { account in
                        accountRow(account)
                    }
                }
            } else if model.accounts.count > 0 {
                ForEach(model.accounts, id: \.id) { account in
                    accountRow(account)
                }
            } else {
                ListStatusView(image: Image(systemName: "person.crop.circle"), message: String(localized: "No accounts on YubiKey"), height: reader.size.height) {
                    Button(action: { addAccount() }) {
                        Label("Add account", systemImage: "plus")
                    }
                    .accessibilityInputLabels(VoiceControlNames.addAccount)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddToYubiKey)
                    enteSyncButton
                }
            }
            if !model.accountsLoaded && !model.cloudAccounts.isEmpty && searchText.isEmpty {
                // The Ente Auth accounts are listed, the YubiKey's join them once it has been read.
                Label(insertYubiKeyMessage, image: "securitykey")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        }
    }
    }

    @ToolbarContentBuilder private var mainToolbar: some ToolbarContent {
        #if os(iOS)
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
            }
        }
        #endif

        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
            Button(action: { model.refresh() }) {
                Label(String(localized: "Refresh", comment: "Mac toolbar"), systemImage: "arrow.clockwise")
            }
            .accessibilityInputLabels(VoiceControlNames.refresh)
            .help(String(localized: "Read the codes from the YubiKey again", comment: "Mac toolbar help"))
            .disabled(!model.canRefresh)
        }
        #else
        if !model.hasAccounts {
            ToolbarItem(placement: .principal) {
                // Shrinks rather than crowding out the bar items when the bar is narrow or laid out vertically.
                Text(verbatim: "Oriel OTP")
                    .font(.headline)
                    .foregroundStyle(Color("YubiGreen"))
                    .accessibilityHidden(true)
            }
        }
        #endif

        if #available(iOS 27.0, macOS 27.0, *) {
            addAccountToolbarItem
                .visibilityPriority(.high)
        } else {
            addAccountToolbarItem
        }

        // Secondary actions collapse into the system overflow menu.
        ToolbarItemGroup(placement: .secondaryAction) {
            enteSyncButton
                .help(String(localized: "Sync from Ente Auth", comment: "Main view menu item"))
            #if os(iOS)
            // In the Settings window and the app menu on the Mac.
            Button(action: { showConfiguration.toggle() }) {
                Label("Configuration", systemImage: "switch.2")
            }
            .accessibilityInputLabels(VoiceControlNames.configuration)
            .disabled(!DeviceCapabilities.supportsNFC && !model.isKeyPluggedIn)
            #endif
            // In the Debug menu on the Mac, so it isn't in the screenshots.
            #if DEBUG && targetEnvironment(simulator)
            if SimulatedYubiKey.isEnabled {
                SimulatedYubiKeyMenu()
                SimulatedYubicoOTPButton()
            }
            #endif
            #if os(iOS)
            Button(action: { showAbout.toggle() }) {
                Label("About", systemImage: "questionmark.circle")
            }
            .accessibilityInputLabels(VoiceControlNames.about)
            #endif
        }
    }

    private func performPendingQuickAction() {
        guard scenePhase == .active, !AppLock.shared.isLocked, let action = quickActions.pending else { return }
        quickActions.pending = nil
        guard !notificationsViewModel.showPIVTokenView && !notificationsViewModel.presentDisableOTP else { return }
        switch action {
        case .scanNFC:
            guard DeviceCapabilities.supportsNFC else { return }
            showConfiguration = false
            showAbout = false
            otp = nil
            model.updateAccountsOverNFC()
        case .addAccount:
            guard DeviceCapabilities.supportsNFC || model.isKeyPluggedIn else {
                // Done once the YubiKey is connected, e.g. right after the window opened for it.
                quickActions.pending = action
                return
            }
            showConfiguration = false
            showAbout = false
            showEnteSync = false
            addAccount()
        }
    }

    private func addAccount() {
        oathURL = nil
        addAccountDestinations = addDestinations
        showAddAccount = true
    }

    private func accountRow(_ account: Account) -> some View {
        NavigationLink(value: account.accountId) {
            #if os(macOS)
            // Copy and pin appear when the pointer is over the row, as there are no swipe actions on the Mac.
            HoverReader { isHovering in
                AccountRowView(account: account, showsLocation: showsLocation, copyCode: { toastPresenter.copyCode(of: account) }) {
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
            AccountRowView(account: account, showsLocation: showsLocation, copyCode: { toastPresenter.copyCode(of: account) })
            #endif
        }
        .listRowSeparator(.hidden)
        // The same actions as the detail view, without having to open it. VoiceOver lists them as the row's actions.
        // Swipe actions have white labels, so their colors are dark enough for 4.5:1 in both appearances, which the
        // system red and blue aren't.
        .swipeActions(edge: .leading) {
            pinButton(account)
                .tint(Color(.favorite))
        }
        .swipeActions(edge: .trailing) {
            // Not a destructive role, which would remove the row before the deletion is confirmed.
            deleteButton(account)
                .tint(Color(.deleteAction))
            copyButton(account)
                .tint(Color(.copyAction))
        }
        .contextMenu {
            copyButton(account)
            pinButton(account)
            CopyToYubiKeyButtons(account: account)
            Divider()
            deleteButton(account)
        }
        // VoiceOver lists the swipe actions on iOS. These are the rest of the context menu's and the details' actions,
        // so every one can be done from the list.
        .accessibilityActions {
            #if os(macOS)
            copyButton(account)
            pinButton(account)
            #endif
            CopyToYubiKeyButtons(account: account)
            if account.canRename {
                Button(String(localized: "Rename", comment: "Menu")) { accountToRename = account }
            }
            #if os(macOS)
            deleteButton(account)
            #endif
        }
    }

    /// Each row shows where its account is stored once there are Ente Auth accounts in the list.
    private var showsLocation: Bool {
        !model.cloudAccounts.isEmpty
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

    private func deleteButton(_ account: Account) -> some View {
        Button(action: { accountsToDelete = [account] }) {
            Label(String(localized: "Delete", comment: "Menu"), systemImage: "trash")
        }
    }

    private var enteSyncButton: some View {
        Button(action: { showEnteSync.toggle() }) {
            Label(String(localized: "Sync from Ente Auth", comment: "Main view menu item"), systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
        }
        .accessibilityInputLabels(VoiceControlNames.syncFromEnte)
    }

    #if os(macOS)
    private var selectedAccounts: [Account] {
        model.accounts.filter { selectedAccountIDs.contains($0.accountId) }
    }

    private var menuState: MainWindowMenuState {
        let selection = selectedAccounts
        return MainWindowMenuState(canAddAccount: model.isKeyPluggedIn || model.cloud.isEnabled,
                                   canRefresh: model.canRefresh,
                                   canSearch: canFocusSearch,
                                   selectionCount: selection.count,
                                   isSelectionPinned: !selection.isEmpty && selection.allSatisfy(\.isPinned),
                                   canRename: selection.count == 1 && selection[0].canRename,
                                   canCopyToYubiKey: model.isKeyPluggedIn && selection.count == 1 && model.canCopyToYubiKey(selection[0], moving: false),
                                   canMoveToYubiKey: model.isKeyPluggedIn && selection.count == 1 && model.canCopyToYubiKey(selection[0], moving: true))
    }

    /// Does what was chosen in the menu bar.
    private func perform(_ command: MainWindowCommands.Command) {
        let selection = selectedAccounts
        switch command {
        case .addAccount:
            guard model.isKeyPluggedIn || model.cloud.isEnabled else { return }
            addAccount()
        case .syncFromEnte:
            showEnteSync = true
        case .refresh:
            model.refresh()
        case .search:
            isSearchFocused = true
        case .copyCode:
            if let selectedAccount { toastPresenter.copyCode(of: selectedAccount) }
        case .togglePin:
            let pin = !selection.allSatisfy(\.isPinned)
            selection.forEach { $0.isPinned = pin }
        case .rename:
            accountToRename = selectedAccount
        case .copyToYubiKey, .moveToYubiKey:
            if let selectedAccount {
                CopyToYubiKeyButtons.copy(selectedAccount, moving: command == .moveToYubiKey, model: model, toastPresenter: toastPresenter)
            }
        case .delete:
            accountsToDelete = selection
        }
    }

    private var canFocusSearch: Bool {
        if #available(macOS 15.0, *) { true } else { false }
    }
    #endif

    private var addAccountToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // Without a YubiKey to reach, accounts can still be added to Ente Auth.
            Button(action: { addAccount() }) {
                Label("Add account", systemImage: "plus")
            }
            .accessibilityInputLabels(VoiceControlNames.addAccount)
            .help(canAddToYubiKey || !model.cloud.isEnabled ? String(localized: "Add an account to the YubiKey", comment: "Toolbar help")
                  : String(localized: "Add an account to Ente Auth", comment: "Toolbar help"))
            .disabled(!canAddToYubiKey && !model.cloud.isEnabled)
        }
    }

    private func importAccounts(_ templates: [YubiKitOATHSession.CredentialTemplate], requiresTouch: Bool) {
        guard !templates.isEmpty else { return }
        model.addAccounts(templates, requiresTouch: requiresTouch) { result in
            if let error = result.error {
                if error.isOATHStorageFull {
                    model.sessionError = OATHSessionError.storageFull(notAdded: result.notAdded.map(\.displayName))
                } else {
                    model.sessionError = error
                }
            }
            var message = String(localized: "Added \(result.added.count) accounts.", comment: "Import result. The placeholder is the number of accounts.")
            if !result.alreadyPresent.isEmpty {
                message += " " + String(localized: "\(result.alreadyPresent.count) were already on the YubiKey.", comment: "Import result. The placeholder is the number of accounts.")
            }
            toastPresenter.toast(message: message)
        }
    }

    /// Adds an account to the Ente Auth vault, which uploads it. For an account that was just put on the YubiKey,
    /// this is the only time it can be copied, as the YubiKey can't give the secret back later.
    private func addAccountToEnte(_ template: YubiKitOATHSession.CredentialTemplate) {
        do {
            switch try model.addCloudAccount(template) {
            case .added:
                toastPresenter.toast(message: String(localized: "Added to Ente Auth", comment: "Toast after adding an account to Ente Auth"))
            case .alreadyPresent:
                toastPresenter.toast(message: String(localized: "Already in Ente Auth", comment: "Toast when Ente Auth already has the account"))
            }
        } catch {
            model.sessionError = EnteSyncError(error)
        }
    }

    var selectedAccount: Account? {
        guard let selectedAccountID else { return nil }
        return model.accounts.first { $0.accountId == selectedAccountID }
    }

    var searchResults: [Account] {
        if searchText.isEmpty {
            return [Account]()
        } else {
            return model.accounts.filter { $0.title.lowercased().contains(searchText.lowercased()) ||
                $0.subTitle?.lowercased().contains(searchText.lowercased()) == true }
        }
    }
}

extension View {
    func alertOrConfirmationDialog<A>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A) -> some View where A : View {
        modifier(AlertOrConfirmationDialog(title: title, isPresented: isPresented, actions: actions()))
    }
}

// Shows an alert in regular width and a confirmation dialog in compact width, so the presentation follows the
// space the scene has (iPad, iPhone Duo inner display, Split View) rather than the device type.
private struct AlertOrConfirmationDialog<A: View>: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let title: String
    @Binding var isPresented: Bool
    let actions: A

    // Read by the bindings when a presentation writes back, which can happen after the size class has changed.
    private final class SizeClassBox {
        var isRegular = false
    }
    @State private var sizeClass = SizeClassBox()

    // Both presentations stay attached rather than switching between them with if/else, which would give the content
    // a new identity whenever the size class changes, e.g. when an iPhone Duo opens, and reset its state and sheets.
    func body(content: Content) -> some View {
        let isRegular = horizontalSizeClass == .regular
        sizeClass.isRegular = isRegular
        return content
            .alert(title, isPresented: presentation(asAlert: true, isRegular: isRegular)) { actions }
            .confirmationDialog(title, isPresented: presentation(asAlert: false, isRegular: isRegular), titleVisibility: .visible) { actions }
    }

    // When the size class changes while presented, the outgoing presentation is dismissed and the other one shown.
    // Only the presentation that matches the current size class may dismiss, so the outgoing one can't clear isPresented.
    private func presentation(asAlert: Bool, isRegular: Bool) -> Binding<Bool> {
        let sizeClass = self.sizeClass
        let isPresented = $isPresented
        return Binding(
            get: { isPresented.wrappedValue && isRegular == asAlert },
            set: { newValue in
                guard newValue || sizeClass.isRegular == asAlert else { return }
                isPresented.wrappedValue = newValue
            }
        )
    }
}

extension URL {
    
    var yubiOTP: String? {
        if self.scheme == "https" && self.host == "my.yubico.com" {
            var otp: String
            let components = URLComponents(url: self, resolvingAgainstBaseURL: false)
            if let fragment = components?.fragment {
                otp = fragment
            } else {
                otp = self.lastPathComponent
            }
            return otp
        } else {
            return nil
        }
    }
}
