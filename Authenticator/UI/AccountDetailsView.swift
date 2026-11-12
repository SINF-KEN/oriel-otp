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
    @State private var showTags = false
    /// The account's otpauth link while its QR code shows.
    @State private var qrCode: AccountQRCodeView.Link?

    @ScaledSize(relativeTo: .largeTitle) private var iconSize: CGFloat = 80

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            // Grows with the text, but not so much that the name and code go off screen.
            AccountIconView(account: account, size: min(iconSize, 120), letterStyle: .largeTitle)
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
            if !account.tags.isEmpty {
                Label {
                    Text(account.tags.joined(separator: ", "))
                } icon: {
                    Image(systemName: "tag")
                        .accessibilityHidden(true)
                }
                .scaledFont(.footnote)
                .foregroundStyle(Color(.secondaryLabel))
                .accessibilityLabel(String(localized: "Tags: \(account.tags.joined(separator: ", "))", comment: "Account details tags, for VoiceOver. The placeholder is a list of tags."))
                .accessibilityIdentifier("account-details.tag-list")
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
            if account.codeAtDate != nil {
                NextCodeLabel(account: account)
            }
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
                Button(action: { showTags = true }) {
                    Label(String(localized: "Tags", comment: "Menu"), systemImage: "tag")
                }
                .help(String(localized: "File the account under tags", comment: "Toolbar help"))
                .accessibilityIdentifier("account-details.tags")
                ProtectCodeButton(account: account)
                    .accessibilityIdentifier("account-details.protect")
                CopyToYubiKeyButtons(account: account)
                if !account.isOnYubiKey {
                    Button(action: showQRCode) {
                        Label(String(localized: "Show QR Code", comment: "Menu item that shows an account's QR code, to add it to another device"), systemImage: "qrcode")
                    }
                    .help(String(localized: "Show the account's QR code, to add it to another device or app", comment: "Toolbar help"))
                    .accessibilityIdentifier("account-details.qr-code")
                }
                if model.knownCopy(of: account) != nil {
                    let requiresTouch = account.requiresTouch
                    Button(action: { model.setRequiresTouch(!requiresTouch, of: account) {
                        toastPresenter.toast(message: requiresTouch
                                             ? String(localized: "Touch is no longer required", comment: "OATH NFC after turning off Require touch")
                                             : String(localized: "Touch is now required", comment: "OATH NFC after turning on Require touch"))
                    } }) {
                        Label(requiresTouch ? String(localized: "Don't Require Touch", comment: "Menu for a YubiKey account")
                                            : String(localized: "Require Touch", comment: "Menu for a YubiKey account"),
                              systemImage: "hand.tap")
                    }
                    .help(String(localized: "Write the account to the YubiKey again from its copy in Ente Auth or on this device, with the new setting", comment: "Toolbar help"))
                    .accessibilityIdentifier("account-details.require-touch")
                }
                Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                    Label(String(localized: "Delete", comment: "Menu"), systemImage: "trash")
                }
                .help(deleteHelp)
                .accessibilityIdentifier("account-details.delete")
            }
        }
        .sheet(isPresented: $showEditing) {
            EditView(account: account, viewModel: model, showEditing: $showEditing)
                .appLockCover()
        }
        .sheet(item: $qrCode) { link in
            AccountQRCodeView(account: account, url: link.url) { qrCode = nil }
                .appLockCover()
        }
        .sheet(isPresented: $showTags) {
            AccountTagsView(account: account, isPresented: $showTags)
                .appLockCover()
        }
        .sheet(isPresented: $showAutoFillWebsites) {
            if let id = autoFillID {
                AutoFillWebsitesView(id: id, issuer: account.credential.issuer, isPresented: $showAutoFillWebsites)
                    .appLockCover()
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

    /// Asks who's there, then shows the QR code. A code or password is asked for in the sheet, Face ID or Touch ID before.
    private func showQRCode() {
        Task {
            let lock = AppLock.shared
            if !lock.method.hasSecret, AppLock.canUseDeviceOwner {
                guard await lock.verifyDeviceOwnerForQRCode() else { return }
            }
            qrCode = model.otpauthURL(for: account).map(AccountQRCodeView.Link.init)
        }
    }

    private var deleteHelp: String {
        switch account.location {
        case .yubiKey: String(localized: "Delete the account from the YubiKey", comment: "Toolbar help")
        case .ente: String(localized: "Move the account to the trash in Ente Auth", comment: "Toolbar help")
        case .device: String(localized: "Delete the account from this device", comment: "Toolbar help")
        }
    }

    /// The id AutoFill knows the account by: a time-based one in Ente Auth or on this device. Nil for the accounts it
    /// can't fill in.
    private var autoFillID: String? {
        guard account.credential.type == .totp else { return nil }
        switch account.location {
        case .ente(let id), .device(let id): return id
        case .yubiKey: return nil
        }
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
/// The next code, in the last seconds of the current one, so the one about to expire isn't the one typed. Its own
/// view, as it reads the countdown every second. Its height is kept while it's empty, so the screen doesn't move.
private struct NextCodeLabel: View {
    let account: Account

    var body: some View {
        let next = account.remaining > 0 ? account.displayedNextCode : nil
        let label = Text(String(localized: "Next code: \(next ?? "888 888")", comment: "Account details, in the last seconds of a code. The placeholder is the next code, e.g. 123 456."))
            .scaledFont(.callout) { $0.monospacedDigit() }
            .foregroundStyle(Color(.secondaryLabel))
        // Hidden rather than clear, which the accessibility audit would measure as text without contrast.
        if next == nil {
            label.hidden()
        } else {
            label
                .privacySensitive()
                .accessibilityIdentifier("account-details.next-code")
        }
    }
}

private struct AccountCodeButton: View {

    @Environment(ToastPresenter.self) private var toastPresenter
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let account: Account

    // The code is what the screen is for, so it's the largest thing on it and in the accent color, like the codes in the
    // list. The asset has darker and lighter variants for Increase Contrast, so it stays readable on the gray capsule.
    private let codeColor = Color.accentColor
    @ScaledSize(relativeTo: .largeTitle) private var codeFontSize: CGFloat = 56
    @ScaledSize(relativeTo: .largeTitle) private var statusSize: CGFloat = 34

    var body: some View {
        Button(action: { toastPresenter.copyCode(of: account) }) {
            HStack(spacing: 10) {
                statusIcon
                    .frame(width: statusSize, height: statusSize)
                    .accessibilityHidden(true)
                // Scales with Dynamic Type, and shrinks rather than truncating or wrapping in a narrow column such as
                // Slide Over or half of a folded iPhone Duo.
                Text(account.displayedCode ?? "*** ***")
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
