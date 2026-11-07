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

// Detail column of the main split view. Shown beside the account list in regular width
// (iPad, iPhone Duo inner display) and pushed on top of it in compact width.
struct AccountDetailView: View {

    @Environment(MainViewModel.self) var model
    @Environment(ToastPresenter.self) var toastPresenter
    let account: Account
    let onDelete: () -> Void

    @State private var showEditing = false
    @State private var showDeleteConfirmation = false
    @State private var showAutoFillWebsites = false

    @ScaledSize(relativeTo: .largeTitle) private var iconSize: CGFloat = 80

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(String(account.title.first ?? "?"))
                .scaledFont(.largeTitle)
                // Grows with the text, but not so much that the name and code go off screen.
                .frame(width: min(iconSize, 120), height: min(iconSize, 120))
                .background(account.iconColor)
                .clipShape(Circle())
                .accessibilityHidden(true)
            Text(account.title.leftToRightIfAddress)
                .scaledFont(.title2) { $0.weight(.medium) }
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            account.subTitle.map {
                Text($0.leftToRightIfAddress)
                    .scaledFont(.body)
                    .foregroundStyle(Color(.secondaryLabel))
                    .multilineTextAlignment(.center)
            }
            if !account.isOnYubiKey || model.showsAccountLocations {
                Label {
                    Text(account.locationDescription)
                } icon: {
                    AccountLocationIcon(account: account)
                        .accessibilityHidden(true)
                }
                .scaledFont(.footnote)
                .foregroundStyle(Color(.secondaryLabel))
            }
            if let id = autoFillID {
                let websites = AutoFillAccountSync.shared.websites(for: id, issuer: account.credential.issuer)
                Label {
                    Text(websites.isEmpty ? String(localized: "No AutoFill websites", comment: "Account details without AutoFill websites")
                         : websites.joined(separator: ", "))
                } icon: {
                    Image(systemName: "key.fill")
                        .accessibilityHidden(true)
                }
                .scaledFont(.footnote)
                .foregroundStyle(Color(.secondaryLabel))
                .accessibilityLabel(String(localized: "AutoFill websites: \(websites.joined(separator: ", "))", comment: "Account details AutoFill websites, for VoiceOver. The placeholder is a list of websites."))
            }
            if account.isOnYubiKey && model.cloud.isEnabled {
                Text(String(localized: "A YubiKey never gives its accounts back, so this account can't be copied to Ente Auth. To keep an account in both, add it again and choose YubiKey and Ente Auth.", comment: "Account details of a YubiKey account while signed in to Ente Auth"))
                    .scaledFont(.footnote)
                    .foregroundStyle(Color(.secondaryLabel))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            AccountCodeButton(account: account)
                .padding(.top, 12)
            Spacer()
            Spacer()
        }
        .padding()
        .scrollsWhenTooTall()
        .avoidingReservedRegions()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Copy is what people come here for, so it's the last to move into the overflow menu when the bar is narrow.
            if #available(iOS 27.0, macOS 27.0, *) {
                copyToolbarItem
                    .visibilityPriority(.high)
            } else {
                copyToolbarItem
            }
            ToolbarItemGroup(placement: .primaryAction) {
                // The app calculates these accounts' codes by itself, so Calculate would only ever be dimmed.
                if autoFillID != nil {
                    autoFillWebsitesButton
                        .accessibilityIdentifier("account-details.toolbar-autofill-websites")
                } else {
                    Button(action: { account.calculate() }) {
                        Label(String(localized: "Calculate", comment: "Menu"), systemImage: "arrow.clockwise")
                    }
                    .accessibilityInputLabels(VoiceControlNames.calculate)
                    .accessibilityIdentifier("account-details.calculate")
                    #if os(iOS)
                    .keyboardShortcut("r")
                    #endif
                    .help(String(localized: "Calculate a new code", comment: "Toolbar help"))
                    .disabled(!account.enableRefresh)
                }
                Button(action: { account.isPinned.toggle() }) {
                    Label(account.isPinned ? String(localized: "Unpin", comment: "Menu") : String(localized: "Pin", comment: "Menu"),
                          systemImage: account.isPinned ? "pin.slash" : "pin")
                }
                .help(account.isPinned ? String(localized: "Unpin the account", comment: "Mac row button help") : String(localized: "Pin the account to the top", comment: "Mac row button help"))
                .accessibilityIdentifier("account-details.pin")
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                if autoFillID != nil {
                    autoFillWebsitesButton
                        .accessibilityIdentifier("account-details.autofill-websites")
                }
                if account.canRename {
                    Button(action: { showEditing.toggle() }) {
                        Label(String(localized: "Rename", comment: "Menu"), systemImage: "square.and.pencil")
                    }
                    .help(String(localized: "Rename the account", comment: "Toolbar help"))
                    .accessibilityIdentifier("account-details.rename")
                }
                CopyToYubiKeyButtons(account: account)
                Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                    Label(String(localized: "Delete", comment: "Menu"), systemImage: "trash")
                }
                .help(deleteHelp)
                .accessibilityIdentifier("account-details.delete")
            }
        }
        .sheet(isPresented: $showEditing) {
            EditView(account: account, viewModel: model, showEditing: $showEditing)
        }
        .sheet(isPresented: $showAutoFillWebsites) {
            if let id = autoFillID {
                AutoFillWebsitesView(id: id, issuer: account.credential.issuer, isPresented: $showAutoFillWebsites)
            }
        }
        .alert("Delete account?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                model.deleteAccount(account) {
                    onDelete()
                }
            }
        } message: {
            if account.isOnDevice {
                Text(String(localized: "This deletes the account for good, as there is no other copy. You won’t be able to generate codes for it anymore.", comment: "Delete account alert for an account on this device"))
            } else if account.isInEnte {
                Text(String(localized: "This moves the account to the trash in Ente Auth on all your devices. You can restore it in the Ente Auth app.", comment: "Delete account alert for an account in Ente Auth"))
            } else {
                Text("This removes the account from the YubiKey. You won’t be able to generate codes for it anymore.")
            }
        }
    }

    private var deleteHelp: String {
        switch account.location {
        case .yubiKey: String(localized: "Delete the account from the YubiKey", comment: "Toolbar help")
        case .ente: String(localized: "Move the account to the trash in Ente Auth", comment: "Toolbar help")
        case .device: String(localized: "Delete the account from this device", comment: "Toolbar help")
        }
    }

    /// The id AutoFill knows a time-based Ente Auth account by, nil for the accounts it can't fill in.
    private var autoFillID: String? {
        guard case .ente(let id) = account.location, account.credential.type == .totp else { return nil }
        return id
    }

    private var autoFillWebsitesButton: some View {
        Button(action: { showAutoFillWebsites = true }) {
            Label(String(localized: "AutoFill websites", comment: "Menu"), systemImage: "globe")
        }
        .help(String(localized: "Choose the websites AutoFill suggests the code on", comment: "Toolbar help"))
    }

    private var copyToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: copyCode) {
                Label(String(localized: "Copy", comment: "Menu"), systemImage: "doc.on.doc")
            }
            .accessibilityInputLabels(VoiceControlNames.copy)
            .accessibilityIdentifier("account-details.copy")
            .help(String(localized: "Copy the code", comment: "Mac row button help"))
            .disabled(!account.canCopyCode)
        }
    }

    private func copyCode() {
        toastPresenter.copyCode(of: account)
    }
}

/// The code with its countdown. A view of its own so the countdown only redraws this: redrawing the details would
/// rebuild their toolbar every second, and on the Mac that makes the tooltip of the button under the pointer blink.
private struct AccountCodeButton: View {

    @Environment(ToastPresenter.self) private var toastPresenter
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let account: Account

    private let codeColor = Color(.secondaryLabel)
    @ScaledSize(relativeTo: .largeTitle) private var codeFontSize: CGFloat = 44
    @ScaledSize(relativeTo: .largeTitle) private var statusSize: CGFloat = 28

    var body: some View {
        Button(action: { toastPresenter.copyCode(of: account) }) {
            HStack(spacing: 10) {
                statusIcon
                    .frame(width: statusSize, height: statusSize)
                    .accessibilityHidden(true)
                // Scales with Dynamic Type, and shrinks rather than truncating or wrapping in a narrow column such as
                // Slide Over or half of a folded iPhone Duo.
                Text(account.formattedCode ?? "*** ***")
                    .privacySensitive()
                    .font(.system(size: codeFontSize, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    // Not dimmed with Increase Contrast; the symbol before it still says it's expired.
                    .opacity(account.state == .expired && colorSchemeContrast != .increased ? 0.4 : 1.0)
            }
            .foregroundStyle(codeColor)
            .padding(.vertical, 12)
            .padding(.horizontal, 24)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(account.spokenCode)
        .accessibilityValue(account.accessibilityCodeState)
        .accessibilityHint(String(localized: "Copies the code", comment: "Accessibility hint for a code in the account list or the Mac menu bar"))
        .accessibilityIdentifier("account-details.code")
        #if os(iOS)
        // With a hardware keyboard, which the Mac has in its menu bar. Also for a pointer on an iPad.
        .keyboardShortcut("c")
        .hoverEffect(.highlight)
        #endif
        // The label is the code itself, which can't be said to Voice Control.
        .accessibilityInputLabels([String(localized: "Code", comment: "Voice Control name for the code in the account details"),
                                   String(localized: "Copy code", comment: "Voice Control name for the Copy button")])
    }

    @ViewBuilder private var statusIcon: some View {
        switch account.state {
        case .requiresCalculation, .expired:
            Image(systemName: account.requiresTouch ? "hand.tap.fill" : "arrow.clockwise.circle.fill")
                .font(.system(size: statusSize * 26 / 28))
        case .countingdown(let remaining):
            PieProgressView(progress: remaining, color: codeColor)
        }
    }
}

/// Copy to YubiKey and Move to YubiKey, for an account in Ente Auth or on this device, and Move to Ente Auth for one on
/// this device. Moving puts an Ente Auth account in Ente's trash once it is on the YubiKey, so it can still be restored
/// in Ente Auth, and deletes an account on this device once it is in its new place.
struct CopyToYubiKeyButtons: View {

    @Environment(MainViewModel.self) private var model
    @Environment(ToastPresenter.self) private var toastPresenter
    let account: Account

    var body: some View {
        if !account.isOnYubiKey {
            let canReachYubiKey = DeviceCapabilities.supportsNFC || model.isKeyPluggedIn
            if model.canCopyToYubiKey(account, moving: false) {
                Button(action: { Self.copy(account, moving: false, model: model, toastPresenter: toastPresenter) }) {
                    Label(String(localized: "Copy to YubiKey", comment: "Menu"), systemImage: "plus.square.on.square")
                }
                .help(account.isOnDevice ? String(localized: "Put the account on the YubiKey and keep it on this device", comment: "Toolbar help")
                      : String(localized: "Put the account on the YubiKey and keep it in Ente Auth", comment: "Toolbar help"))
                .disabled(!canReachYubiKey)
            }
            if model.canCopyToYubiKey(account, moving: true) {
                Button(action: { Self.copy(account, moving: true, model: model, toastPresenter: toastPresenter) }) {
                    Label(String(localized: "Move to YubiKey", comment: "Menu"), systemImage: "arrow.forward.square")
                }
                .help(account.isOnDevice ? String(localized: "Put the account on the YubiKey and delete it from this device", comment: "Toolbar help")
                      : String(localized: "Put the account on the YubiKey and move it to the trash in Ente Auth", comment: "Toolbar help"))
                .disabled(!canReachYubiKey)
            }
            if model.canMoveToEnte(account) {
                Button(action: { Self.moveToEnte(account, model: model, toastPresenter: toastPresenter) }) {
                    Label(String(localized: "Move to Ente Auth", comment: "Menu"), systemImage: "cloud")
                }
                .help(String(localized: "Save the account in Ente Auth and delete it from this device", comment: "Toolbar help"))
            }
        }
    }

    static func moveToEnte(_ account: Account, model: MainViewModel, toastPresenter: ToastPresenter) {
        do {
            switch try model.moveToEnte(account) {
            case .moved:
                toastPresenter.toast(message: String(localized: "Moved to Ente Auth", comment: "Toast after moving an account from this device to Ente Auth"))
            case .alreadyInEnte:
                toastPresenter.toast(message: String(localized: "Already in Ente Auth", comment: "Toast when Ente Auth already has the account"))
            }
        } catch {
            model.sessionError = EnteSyncError(error)
        }
    }

    static func copy(_ account: Account, moving: Bool, model: MainViewModel, toastPresenter: ToastPresenter) {
        let wasOnDevice = account.isOnDevice
        model.copyToYubiKey(account, moving: moving) { result in
            switch result {
            case .copied:
                toastPresenter.toast(message: String(localized: "Copied to the YubiKey", comment: "Toast after copying an Ente Auth account to the YubiKey"))
            case .moved:
                toastPresenter.toast(message: wasOnDevice ? String(localized: "Moved to the YubiKey", comment: "Toast after moving an account from this device to the YubiKey")
                                     : String(localized: "Moved to the YubiKey. Ente Auth keeps it in the trash.", comment: "Toast after moving an Ente Auth account to the YubiKey"))
            case .alreadyOnYubiKey:
                toastPresenter.toast(message: String(localized: "The YubiKey already has an account with this name. Nothing was changed.", comment: "Toast when copying an Ente Auth account to a YubiKey that has one with the same name"))
            }
        }
    }
}
