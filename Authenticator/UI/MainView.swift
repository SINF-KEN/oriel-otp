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
    @Environment(\.textScale) var textScale
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
    @State var layoutDuringResize: Bool?
    /// Whether the window is wide enough for the list and the details beside each other.
    @State var fitsTwoColumns = true
    /// For the arrow keys, which only reach the list while it has the focus.
    @FocusState var isListFocused: Bool
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
    /// Changed for each otpauth link, so a link opened while the add account sheet is open shows its account there.
    @State var addAccountLinkID = UUID()
    @State var accountsToDelete: [Account] = []
    @State var accountToRename: Account?
    /// The account whose tags are being changed, from a row's menu.
    @State var accountToTag: Account?
    /// The tag whose accounts the list shows, nil for all.
    @State var selectedTag: String?
    @State var quickActions = QuickActionCenter.shared
    @ScaledSize(relativeTo: .largeTitle) var placeholderSize: CGFloat = 64
    
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
                model.saveNewAccount(template, requiresTouch: requiresTouch, to: destinations) { toastPresenter.toast(message: $0) }
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
            guard OTPAuthURLParser.isOTPAuth(url) else { return }
            if showConfiguration { showConfiguration.toggle() }
            if showAbout { showAbout.toggle() }
            oathURL = url
            addAccountDestinations = addDestinations
            addAccountLinkID = UUID()
            showAddAccount = true
        })
        #if DEBUG && (targetEnvironment(simulator) || os(macOS))
        .onReceive(NotificationCenter.default.publisher(for: .simulatedYubicoOTP)) { notification in
            otp = notification.object as? String
        }
        #endif
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

    func addAccount() {
        oathURL = nil
        addAccountDestinations = addDestinations
        showAddAccount = true
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
