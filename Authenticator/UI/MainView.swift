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
    @State var selectedAccountID: String? = nil
    @State var showAddAccount: Bool = false
    @State var addAccountCancellable: AnyCancellable?
    @State var addAccountSubject = PassthroughSubject<(YubiKitOATHSession.CredentialTemplate?, Bool, Bool), Never>()
    @State var showConfiguration: Bool = false
    @State var showAbout: Bool = false
    @State var showEnteSync: Bool = false
    @State var password: String = ""
    @State var searchText: String = ""
    @State var didEnterBackground = true
    @State var otp: String? = nil
    @State var oathURL: URL? = nil
    @State var accountToDelete: Account? = nil
    @State var quickActions = QuickActionCenter.shared
    
    // Computed so it follows VoiceOver being turned on or off while the app runs.
    var insertYubiKeyMessage: String {
        if DeviceCapabilities.supportsNFC {
            String(localized: "Insert YubiKey") + " " + "\(!isVoiceOverEnabled ? String(localized: "or pull down to activate NFC") : String(localized: "or scan a NFC YubiKey"))"
        } else {
            String(localized: "Insert YubiKey")
        }
    }
    
    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            GeometryReader { reader in
                List(selection: $selectedAccountID) {
                    if let otp {
                        Section("Yubico OTP") {
                            YubiOtpRowView(otp: otp)
                        }
                    }
                    if !model.accountsLoaded {
                        ListStatusView(image: Image("securitykey"), message: insertYubiKeyMessage, height: reader.size.height)
                    } else if !searchText.isEmpty {
                        if searchResults.count > 0 {
                            ForEach(searchResults, id: \.id) { account in
                                accountRow(account)
                            }
                        } else {
                            ListStatusView(image: Image(systemName: "person.crop.circle.badge.questionmark"), message: String(localized: "No matching accounts on YubiKey"), height: reader.size.height)
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
                        ListStatusView(image: Image(systemName: "person.crop.circle"), message: String(localized: "No accounts on YubiKey"), height: reader.size.height)
                    }
                }
            }
            .searchable(text: $searchText, prompt: String(localized: "Search"))
            .autocorrectionDisabled(true)
            .keyboardType(.asciiCapable)
            .listStyle(.inset)
            .refreshable(enabled: DeviceCapabilities.supportsNFC) {
                otp = nil
                model.updateAccountsOverNFC()
            }
            .toolbar {
                // Always there, so scanning doesn't depend on discovering pull to refresh.
                if DeviceCapabilities.supportsNFC {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            otp = nil
                            model.updateAccountsOverNFC()
                        } label: {
                            Label(String(localized: "Scan NFC YubiKey"), systemImage: "wave.3.right")
                        }
                    }
                }

                if !model.accountsLoaded {
                    ToolbarItem(placement: .principal) {
                        // Shrinks rather than crowding out the bar items when the bar is narrow or laid out vertically.
                        Text(verbatim: "Oriel OTP")
                            .font(.headline)
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
                    Button(action: { showEnteSync.toggle() }) {
                        Label(String(localized: "Sync from Ente Auth", comment: "Main view menu item"), systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    }
                    Button(action: { showConfiguration.toggle() }) {
                        Label("Configuration", systemImage: "switch.2")
                    }
                    .disabled(!DeviceCapabilities.supportsNFC && !model.isKeyPluggedIn)
                    Button(action: { showAbout.toggle() }) {
                        Label("About", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle(model.accountsLoaded ? String(localized: "Accounts", comment: "Navigation title in main view.") : "")
            .navigationSplitViewColumnWidth(min: 320, ideal: 360)
        } detail: {
            if let selectedAccount {
                AccountDetailView(account: selectedAccount) {
                    selectedAccountID = nil
                }
                .id(selectedAccount.accountId)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: model.accounts.map(\.accountId)) { _, accountIDs in
            // Drop the selection when the account goes away, e.g. the YubiKey was removed or the account deleted.
            if let selectedAccountID, !accountIDs.contains(selectedAccountID) {
                self.selectedAccountID = nil
            }
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountView(showAddCredential: $showAddAccount, accountSubject: addAccountSubject, oathURL: oathURL)
        }
        .sheet(isPresented: $showEnteSync) {
            EnteSyncView(existingCredentialIds: Set(model.accounts.map(\.accountId)),
                         canAddToYubiKey: DeviceCapabilities.supportsNFC || model.isKeyPluggedIn) { templates, requiresTouch in
                importAccounts(templates, requiresTouch: requiresTouch)
            }
        }
        // Sheets rather than full-screen covers, so they read as a task on top of the account list and can be swiped away.
        .sheet(isPresented: $showConfiguration) {
            ConfigurationView(showConfiguration: $showConfiguration)
                .onAppear {
                    model.stop()
                }.onDisappear {
                    model.start()
                }
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
                .onAppear {
                    model.stop()
                }.onDisappear {
                    model.start()
                }
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
        .alert("Delete account?", isPresented: Binding(get: { accountToDelete != nil }, set: { if !$0 { accountToDelete = nil } }), presenting: accountToDelete) { account in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                model.deleteAccount(account) {}
            }
        } message: { _ in
            Text("This removes the account from the YubiKey. You won’t be able to generate codes for it anymore.")
        }
        // Blanks the codes, which are privacy sensitive, whenever the scene isn't active, so they don't show in the
        // app switcher or its snapshot. Only the codes, so the screen still makes sense behind the NFC and Face ID sheets.
        .redacted(reason: scenePhase == .active ? [] : .privacy)
        .errorAlert(error: $model.sessionError)
        .errorAlert(error: $model.connectionError) { model.start() }
        .onAppear {
            if ApplicationSettingsViewModel().isNFCOnAppLaunchEnabled {
                model.updateAccountsOverNFC()
            }
            addAccountCancellable = addAccountSubject.sink { (template, requiresTouch, addToEnte) in
                oathURL = nil
                if let template {
                    model.addAccount(template, requiresTouch: requiresTouch) {
                        if addToEnte {
                            addAccountToEnte(template)
                        }
                    }
                }
            }
        }
        .onOpenURL(perform: { url in
            guard url.scheme == "otpauth" else { return }
            if showConfiguration { showConfiguration.toggle() }
            if showAbout { showAbout.toggle() }
            oathURL = url
            showAddAccount.toggle()
        })
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb, perform: { userActivity in
            guard let otp = userActivity.webpageURL?.yubiOTP else { return }
            if showConfiguration { showConfiguration.toggle() }
            if showAbout { showAbout.toggle() }
            self.otp = otp
            if ApplicationSettingsViewModel().isNFCOnOTPLaunchEnabled {
                model.updateAccountsOverNFC()
            }
        })
        .onChange(of: otp) { _, otp in
            if let otp, SettingsConfig.isCopyOTPEnabled {
                toastPresenter.copyToClipboard(otp)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Both the NFC and the Face ID scanning alerts make the app enter the `.inactive` state
            // and in that situation we don't want to call model.stop() nor model.closeConnections()
            if phase == .active && didEnterBackground {
                didEnterBackground = false
                ConnectionManager.shared.resumeWiredConnections()

                guard !notificationsViewModel.showPIVTokenView else { return }
                model.start() // This is called when app becomes active
                performPendingQuickAction()
            } else if phase == .active {
                performPendingQuickAction()
            } else if phase == .background {
                didEnterBackground = true

                // Keep running until the YubiKey connection is closed.
                let backgroundTask = UIApplication.shared.beginBackgroundTask()
                model.stop()
                Task {
                    await model.closeConnections()
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
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
            // If the user removes the YubiKey while adding a new account we dismiss the add account modal.
            if showAddAccount && !isKeyPluggedIn {
                showAddAccount = false
            }
        }
    }
    
    private func performPendingQuickAction() {
        guard scenePhase == .active, let action = quickActions.pending else { return }
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
            guard DeviceCapabilities.supportsNFC || model.isKeyPluggedIn else { return }
            showConfiguration = false
            showAbout = false
            showEnteSync = false
            oathURL = nil
            showAddAccount = true
        }
    }

    private func accountRow(_ account: Account) -> some View {
        NavigationLink(value: account.accountId) {
            AccountRowView(account: account)
        }
        .listRowSeparator(.hidden)
        // The same actions as the detail view, without having to open it. VoiceOver lists them as the row's actions.
        .swipeActions(edge: .leading) {
            pinButton(account)
                .tint(Color("Favorite"))
        }
        .swipeActions(edge: .trailing) {
            // Not a destructive role, which would remove the row before the deletion is confirmed.
            deleteButton(account)
                .tint(.red)
            copyButton(account)
                .tint(.blue)
        }
        .contextMenu {
            copyButton(account)
            pinButton(account)
            Divider()
            deleteButton(account)
        }
    }

    private func copyButton(_ account: Account) -> some View {
        Button(action: { toastPresenter.copyCode(of: account) }) {
            Label(String(localized: "Copy", comment: "Menu"), systemImage: "doc.on.doc")
        }
    }

    private func pinButton(_ account: Account) -> some View {
        Button(action: { account.isPinned.toggle() }) {
            Label(account.isPinned ? String(localized: "Unpin", comment: "Menu") : String(localized: "Pin", comment: "Menu"),
                  systemImage: account.isPinned ? "pin.slash" : "pin")
        }
    }

    private func deleteButton(_ account: Account) -> some View {
        Button(action: { accountToDelete = account }) {
            Label(String(localized: "Delete", comment: "Menu"), systemImage: "trash")
        }
    }

    private var addAccountToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: { showAddAccount.toggle() }) {
                Label("Add account", systemImage: "plus")
            }
            .disabled(!DeviceCapabilities.supportsNFC && !model.isKeyPluggedIn)
        }
    }

    private func importAccounts(_ templates: [YubiKitOATHSession.CredentialTemplate], requiresTouch: Bool) {
        guard !templates.isEmpty else { return }
        model.addAccounts(templates, requiresTouch: requiresTouch) { result in
            if let error = result.error {
                model.sessionError = error
            }
            var message = String(localized: "Added \(result.added.count) accounts.", comment: "Import result. The placeholder is the number of accounts.")
            if !result.alreadyPresent.isEmpty {
                message += " " + String(localized: "\(result.alreadyPresent.count) were already on the YubiKey.", comment: "Import result. The placeholder is the number of accounts.")
            }
            toastPresenter.toast(message: message)
        }
    }

    /// Adds an account that was just put on the YubiKey to Ente Auth too. The YubiKey can't give the secret back
    /// later, so this is the only time it can be copied.
    private func addAccountToEnte(_ template: YubiKitOATHSession.CredentialTemplate) {
        Task {
            do {
                switch try await EnteSessionStore().add(template) {
                case .added:
                    toastPresenter.toast(message: String(localized: "Added to Ente Auth", comment: "Toast after adding an account to Ente Auth"))
                case .alreadyPresent:
                    toastPresenter.toast(message: String(localized: "Already in Ente Auth", comment: "Toast when Ente Auth already has the account"))
                }
            } catch {
                model.sessionError = EnteSyncError(error)
            }
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
