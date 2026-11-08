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
    @Environment(\.textScale) private var textScale
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
    /// The account open over the list in the single column layout.
    @State var singleColumnPath: [String] = []
    /// The layout kept while the window is being resized, true for the single column. See `mainLayout`.
    @State private var layoutDuringResize: Bool?
    /// For the arrow keys, which only reach the list while it has the focus.
    @FocusState private var isListFocused: Bool
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
    @State var isSearchFocused = false
    @State var didEnterBackground = true
    @State var otp: String? = nil
    @State var oathURL: URL? = nil
    @State var accountsToDelete: [Account] = []
    @State var accountToRename: Account?
    /// The account whose tags are being changed, from a row's menu.
    @State var accountToTag: Account?
    /// The tag whose accounts the list shows, nil for all.
    @State var selectedTag: String?
    @State var quickActions = QuickActionCenter.shared
    @ScaledSize(relativeTo: .largeTitle) private var placeholderSize: CGFloat = 64
    
    // Computed so it follows VoiceOver being turned on or off while the app runs.
    var insertYubiKeyMessage: String {
        .insertYubiKey(isVoiceOverEnabled: isVoiceOverEnabled)
    }
    
    /// Whether a YubiKey can be reached, over NFC or because one is plugged in.
    var canAddToYubiKey: Bool {
        DeviceCapabilities.supportsNFC || model.isKeyPluggedIn
    }

    /// Where a new account can be saved. This device always works, with neither a YubiKey nor an Ente account.
    var addDestinations: AccountDestinations {
        var destinations: AccountDestinations = .device
        if canAddToYubiKey { destinations.insert(.yubiKey) }
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
                if destinations.contains(.device) {
                    addAccountToDevice(template)
                } else if destinations.contains(.yubiKey) {
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
                    let authentication = AppLock.shared.unlockAuthentication
                    Task { await model.cloud.syncAutomatically(authentication: authentication) }
                    performPendingQuickAction()
                }
            } else if phase == .active {
                performPendingQuickAction()
            } else if phase == .background {
                didEnterBackground = true
                CodeVisibility.shared.hideAll()

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
        .onChange(of: quickActions.pendingAccountID, initial: true) { _, _ in
            performPendingQuickAction()
        }
        // One that came while the app was locked. On the Mac the app locks without going to the background, so
        // becoming active doesn't do it.
        .onChange(of: AppLock.shared.isLocked) { _, isLocked in
            if !isLocked {
                performPendingQuickAction()
            }
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
    
    #if os(macOS)
    /// The narrowest the list and the details get beside each other, in points at 100% text size.
    private static let minimumColumnWidth: CGFloat = 320
    /// The narrowest the window gets, in points at 100% text size, where the codes go below the names.
    private static let minimumWindowWidth: CGFloat = 280
    /// Until a view that comes back to the single column can take the focus, after going back to it.
    private static let navigationDelay = Duration.milliseconds(400)

    /// Two columns while both fit, otherwise one, as on an iPhone, which also happens as the text gets bigger. A split
    /// view doesn't do this itself on the Mac, and when its columns don't fit, it's centered in the window and cut off
    /// on both sides.
    ///
    /// The layout only changes once a resize ends. Replacing the list during one crashes the app: AppKit ends the
    /// table's live resize as it's removed, which adds rows to a table SwiftUI is already destroying.
    private var mainLayout: some View {
        GeometryReader { reader in
            let minimumWidth = Self.minimumColumnWidth * textScale
            let isSingleColumn = layoutDuringResize ?? (reader.size.width < 2 * minimumWidth)
            ZStack {
                LiveResizeObserver { isResizing in
                    layoutDuringResize = isResizing ? isSingleColumn : nil
                }
                if isSingleColumn {
                    singleColumnView
                } else {
                    // The window can be too narrow for two columns during a resize. They share it until it ends.
                    let sidebarMinimum = min(minimumWidth, reader.size.width / 2)
                    splitView(sidebarWidth: sidebarMinimum...(reader.size.width - sidebarMinimum))
                }
            }
        }
    }

    private var singleColumnView: some View {
        NavigationStack(path: $singleColumnPath) {
            accountColumn()
                // Below the toolbar, whose search field gets wider than a narrow window and is cut off.
                .safeAreaInset(edge: .top, spacing: 0) {
                    SingleColumnSearchField(text: $searchText, isFocused: $isSearchFocused)
                }
                .environment(\.opensAccount, OpenAccountAction(path: $singleColumnPath))
                // The arrow keys only move the selection here, so they can get past an account.
                .onKeyPress(.rightArrow) {
                    guard let selectedAccountID else { return .ignored }
                    singleColumnPath = [selectedAccountID]
                    return .handled
                }
                .navigationDestination(for: String.self) { accountID in
                    if let account = model.accounts.first(where: { $0.accountId == accountID }) {
                        accountDetail(account)
                            // Back to the list with Escape, wherever the focus is.
                            .background {
                                Button(action: { singleColumnPath = [] }) { EmptyView() }
                                    .keyboardShortcut(.cancelAction)
                                    .opacity(0)
                                    .accessibilityHidden(true)
                            }
                    }
                }
        }
        // AppKit gives the search field the first focus, mostly with larger text, which would keep the arrow keys from
        // the list. With something typed in it, it came from the two columns, so it keeps the focus.
        .onAppear { focusList(overSearch: searchText.isEmpty) }
        // Leaving the search field with Escape goes back to the list.
        .onChange(of: isSearchFocused) { _, isFocused in
            if !isFocused {
                focusList()
            }
        }
        // The menu bar's commands work on the selection, which the two columns also show when the window gets wider.
        .onChange(of: singleColumnPath) { _, path in
            if let accountID = path.last {
                selectedAccountID = accountID
            } else {
                focusList()
            }
        }
    }

    /// Gives the list the focus once it's on screen, unless the search field is about to take it.
    private func focusList(overSearch: Bool = false) {
        Task {
            try? await Task.sleep(for: Self.navigationDelay)
            if overSearch || !isSearchFocused {
                isListFocused = true
            }
        }
    }

    private func splitView(sidebarWidth: ClosedRange<CGFloat>) -> some View {
        NavigationSplitView {
            accountColumn()
                .searchable(text: $searchText, placement: .sidebar, prompt: String(localized: "Search"))
                .searchFocusedBinding($isSearchFocused)
                .autocorrectionDisabled(true)
                .navigationSplitViewColumnWidth(min: sidebarWidth.lowerBound,
                                                ideal: min(360 * textScale, sidebarWidth.upperBound),
                                                max: sidebarWidth.upperBound)
        } detail: {
            detailColumn
        }
    }
    #else
    private var mainLayout: some View {
        FoldedColumnWidthReader { foldedColumnWidth in
            NavigationSplitView {
                accountColumn()
                    .searchable(text: $searchText, prompt: String(localized: "Search"))
                    .searchFocusedBinding($isSearchFocused)
                    .autocorrectionDisabled(true)
                    // Wide enough on an iPad for a 6 digit code beside the name at the default text size.
                    .navigationSplitViewColumnWidth(min: 320, ideal: foldedColumnWidth ?? 420, max: foldedColumnWidth)
                    // ⌘F with a hardware keyboard. Search Accounts in the menu bar on the Mac.
                    .background {
                        // Without a label, which the accessibility audit would still see at this opacity.
                        Button(action: focusSearch) { EmptyView() }
                            .keyboardShortcut("f")
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                    .environment(\.isInFoldedColumn, foldedColumnWidth != nil)
                    .background {
                        FoldedSplitViewAdapter(isOnFold: foldedColumnWidth != nil)
                            .accessibilityHidden(true)
                    }
            } detail: {
                detailColumn
            }
        }
    }
    #endif

    @ViewBuilder private var detailColumn: some View {
        if let selectedAccount {
            accountDetail(selectedAccount)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: placeholderSize))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
                if model.hasAccounts {
                    Text(String(localized: "Select an account to see its code and details", comment: "Details column before an account is selected"))
                        .scaledFont(.body)
                        .foregroundStyle(Color(.secondaryLabel))
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // In one half of an iPhone Duo, rather than across the fold.
            .avoidingReservedRegions()
        }
    }

    private func accountDetail(_ account: Account) -> some View {
        AccountDetailView(account: account) {
            selectedAccountID = nil
        }
        .id(account.accountId)
        .scaledBodyFont()
    }

    /// The account list with its toolbar and title.
    private func accountColumn() -> some View {
        accountList
            #if os(macOS)
            .focused($isListFocused)
            // Here rather than for the whole window, so the search field keeps the system's size.
            .scaledBodyFont()
            // Return copies the selected account's code, Delete deletes the selected accounts.
            .onKeyPress(.return) {
                guard !AppLock.shared.isLocked, let selectedAccount else { return .ignored }
                toastPresenter.copyCode(of: selectedAccount)
                return .handled
            }
            .onDeleteCommand {
                guard !AppLock.shared.isLocked else { return }
                accountsToDelete = selectedAccounts
            }
            #endif
            .listStyle(.inset)
            .refreshable(enabled: DeviceCapabilities.supportsNFC || model.cloud.isEnabled) {
                otp = nil
                // Synced first, so Face ID for the Ente session isn't asked for while the NFC sheet is up.
                await model.cloud.sync(reportsErrors: true)
                if DeviceCapabilities.supportsNFC {
                    model.updateAccountsOverNFC()
                }
            }
            #if os(macOS)
            // Customizable from the View menu or by Control-clicking the toolbar.
            .toolbar(id: "accounts") { macToolbar }
            .navigationTitle(Text(verbatim: "Oriel OTP"))
            #else
            .toolbar { mainToolbar }
            .navigationTitle(model.hasAccounts ? String(localized: "Accounts", comment: "Navigation title in main view.") : "")
            #endif
    }

    private var presentations: some View {
        @Bindable var model = model
        return mainLayout
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
            AddAccountView(showAddCredential: $showAddAccount, accountSubject: addAccountSubject, oathURL: oathURL, destinations: addAccountDestinations)
                .scaledBodyFont()
                .appLockCover()
        }
        .sheet(isPresented: $showEnteSync) {
            EnteSyncView(existingCredentialIds: Set(model.keyAccounts.map(\.accountId)),
                         capacity: model.accountsLoaded ? model.credentialCapacity : nil,
                         canAddToYubiKey: DeviceCapabilities.supportsNFC || model.isKeyPluggedIn) { templates, requiresTouch in
                importAccounts(templates, requiresTouch: requiresTouch)
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
            EditView(account: account, viewModel: model, showEditing: Binding(get: { accountToRename != nil }, set: { if !$0 { accountToRename = nil } }))
                .scaledBodyFont()
                .appLockCover()
        }
        .sheet(item: $accountToTag) { account in
            AccountTagsView(account: account, isPresented: Binding(get: { accountToTag != nil }, set: { if !$0 { accountToTag = nil } }))
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
            if accounts.contains(where: \.isOnDevice) {
                if accounts.count > 1 {
                    Text(String(localized: "Accounts on this device are deleted for good, as there is no other copy. You won’t be able to generate codes for them anymore. Accounts on a YubiKey or in Ente Auth are removed from there.", comment: "Delete several accounts alert when some are on this device"))
                } else {
                    Text(String(localized: "This deletes the account for good, as there is no other copy. You won’t be able to generate codes for it anymore.", comment: "Delete account alert for an account on this device"))
                }
            } else if accounts.contains(where: \.isInEnte) {
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
            if showsTagFilter {
                TagFilterBar(tags: model.allTags, selection: $selectedTag)
                    .listRowSeparator(.hidden)
            }
            if !model.hasAccounts {
                ListStatusView(image: Image(systemName: "person.crop.circle.badge.plus"), message: String(localized: "No accounts yet", comment: "Account list without accounts"), height: reader.size.height) {
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
                                   message: model.cloudAccounts.isEmpty && model.deviceAccounts.isEmpty ? String(localized: "No matching accounts on YubiKey") : String(localized: "No matching accounts", comment: "Search without results when Ente Auth accounts are listed too"),
                                   height: reader.size.height)
                }
            } else if selectedTag != nil && taggedAccounts.isEmpty {
                ListStatusView(image: Image(systemName: "tag"), message: String(localized: "No accounts with this tag", comment: "Account list filtered by a tag that no account has any more"),
                               height: reader.size.height)
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
                ListStatusView(image: Image(systemName: "person.crop.circle"), message: String(localized: "No accounts on YubiKey"), height: reader.size.height) {
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
    }

    /// The tags show above the list once an account has one.
    private var showsTagFilter: Bool {
        model.hasAccounts && !model.allTags.isEmpty
    }

    /// The accounts with the selected tag, or all of them.
    private var taggedAccounts: [Account] {
        selectedTag == nil ? model.accounts : model.accounts.filter { $0.isTagged(selectedTag) }
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

    @ToolbarContentBuilder private var macToolbar: some CustomizableToolbarContent {
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
    @ToolbarContentBuilder private var mainToolbar: some ToolbarContent {
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

    private func performPendingQuickAction() {
        guard scenePhase == .active, !AppLock.shared.isLocked else { return }
        showPendingAccount()
        guard let action = quickActions.pending else { return }
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

    /// Shows an account opened from Spotlight or Shortcuts, with nothing in front of it.
    private func showPendingAccount() {
        guard let accountID = quickActions.pendingAccountID else { return }
        quickActions.pendingAccountID = nil
        guard model.accounts.contains(where: { $0.accountId == accountID }),
              !notificationsViewModel.showPIVTokenView && !notificationsViewModel.presentDisableOTP else { return }
        showConfiguration = false
        showAbout = false
        showEnteSync = false
        showAddAccount = false
        searchText = ""
        selectedTag = nil
        selectedAccountID = accountID
    }

    private func addAccount() {
        oathURL = nil
        addAccountDestinations = addDestinations
        showAddAccount = true
    }

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
            tagsButton(account)
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
            tagsButton(account)
            #if os(macOS)
            deleteButton(account)
            #endif
        }
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

    #if os(macOS)
    private var selectedAccounts: [Account] {
        model.accounts.filter { selectedAccountIDs.contains($0.accountId) }
    }

    private var menuState: MainWindowMenuState {
        let selection = selectedAccounts
        return MainWindowMenuState(canAddAccount: true,
                                   canRefresh: model.canRefresh,
                                   canSearch: true,
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
            addAccount()
        case .syncFromEnte:
            showEnteSync = true
        case .refresh:
            model.refresh()
        case .search:
            // The search field is on the list, so an account open over it closes first. Set again each time, as the
            // field doesn't report back when it wasn't there to take the focus.
            let delay = singleColumnPath.isEmpty ? Duration.zero : Self.navigationDelay
            singleColumnPath = []
            focusSearch(after: delay)
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
    #endif

    private func focusSearch() {
        focusSearch(after: .zero)
    }

    private func focusSearch(after delay: Duration) {
        isSearchFocused = false
        Task {
            try? await Task.sleep(for: delay)
            isSearchFocused = true
        }
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
            // One sentence each, so translators can word and order them as their language needs.
            let message = result.alreadyPresent.isEmpty
                ? String(localized: "Added \(result.added.count) accounts.", comment: "Import result. The placeholder is the number of accounts.")
                : String(localized: "Added \(result.added.count) accounts. \(result.alreadyPresent.count) were already on the YubiKey.", comment: "Import result. The placeholders are the number of accounts added and the number that were already on the YubiKey.")
            toastPresenter.toast(message: message)
        }
    }

    /// Adds an account to the Ente Auth vault, which uploads it. For an account that was just put on the YubiKey,
    /// this is the only time it can be copied, as the YubiKey can't give the secret back later.
    private func addAccountToDevice(_ template: YubiKitOATHSession.CredentialTemplate) {
        do {
            switch try model.addDeviceAccount(template) {
            case .added:
                toastPresenter.toast(message: String(localized: "Added to this device", comment: "Toast after adding an account to this device"))
            case .alreadyPresent:
                toastPresenter.toast(message: String(localized: "Already on this device", comment: "Toast when this device already has the account"))
            }
        } catch {
            model.sessionError = error
        }
    }

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
            // Ignores case, accents and Arabic and Hebrew vowel marks, so "gerard" finds "Gérard".
            // Tags are found too, e.g. "work".
            return taggedAccounts.filter { $0.title.localizedStandardContains(searchText) ||
                $0.subTitle?.localizedStandardContains(searchText) == true ||
                $0.tags.contains { $0.localizedStandardContains(searchText) } }
        }
    }
}

#if os(macOS)
/// Opens an account over the list, in the main window's single column.
struct OpenAccountAction: Equatable {
    @Binding var path: [String]

    func callAsFunction(_ accountID: String) {
        path = [accountID]
    }

    // There's only the one path, so a new action doesn't need to update the rows.
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var opensAccount: OpenAccountAction?
}
#endif

/// A row that opens its account. A link shows it in the split view's details, but in a stack a link also opens whatever
/// the arrow keys select, so there a click opens it instead.
private struct AccountRowLink<Label: View>: View {
    #if os(macOS)
    @Environment(\.opensAccount) private var opensAccount
    #endif
    let accountID: String
    @ViewBuilder let label: Label

    var body: some View {
        #if os(macOS)
        if let opensAccount {
            label
                .tag(accountID)
                .onTapGesture { opensAccount(accountID) }
                // A button to VoiceOver and Voice Control, as the link is in the split view.
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { opensAccount(accountID) }
        } else {
            link
        }
        #else
        link
        #endif
    }

    private var link: some View {
        NavigationLink(value: accountID) { label }
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

extension String {
    /// How to use a YubiKey, for the empty list, where it's one option among others.
    static func optionalYubiKey(isVoiceOverEnabled: Bool) -> String {
        guard DeviceCapabilities.supportsNFC else {
            return String(localized: "Have a YubiKey? Insert it to see its accounts.", comment: "Empty account list on a device without NFC")
        }
        return isVoiceOverEnabled
            ? String(localized: "Have a YubiKey? Insert it or scan it over NFC to see its accounts.", comment: "Empty account list, with VoiceOver on")
            : String(localized: "Have a YubiKey? Insert it or pull down to activate NFC.", comment: "Empty account list")
    }

    /// What to do to see the YubiKey's accounts, as one sentence so it can be translated as a whole.
    static func insertYubiKey(isVoiceOverEnabled: Bool) -> String {
        guard DeviceCapabilities.supportsNFC else { return String(localized: "Insert YubiKey") }
        // Pulling down to refresh is hard to find with VoiceOver, which has the Scan NFC YubiKey button instead.
        return isVoiceOverEnabled
            ? String(localized: "Insert YubiKey or scan a NFC YubiKey", comment: "Account list and Configuration without a YubiKey, with VoiceOver on")
            : String(localized: "Insert YubiKey or pull down to activate NFC", comment: "Account list and Configuration without a YubiKey")
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
