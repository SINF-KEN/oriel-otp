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

    private let codeColor = Color(.secondaryLabel)
    @ScaledMetric(relativeTo: .largeTitle) private var codeFontSize: CGFloat = 44

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(String(account.title.first ?? "?"))
                .font(.largeTitle)
                .frame(width: 80, height: 80)
                .background(account.iconColor)
                .clipShape(Circle())
                .accessibilityHidden(true)
            Text(account.title)
                .font(.title2.weight(.medium))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            account.subTitle.map {
                Text($0)
                    .font(.body)
                    .foregroundStyle(Color(.secondaryLabel))
                    .multilineTextAlignment(.center)
            }
            if account.isInEnte || !model.cloudAccounts.isEmpty {
                Label {
                    Text(account.locationDescription)
                } icon: {
                    AccountLocationIcon(account: account)
                        .accessibilityHidden(true)
                }
                .font(.footnote)
                .foregroundStyle(Color(.secondaryLabel))
            }
            if !account.isInEnte && model.cloud.isEnabled {
                Text(String(localized: "A YubiKey never gives its accounts back, so this account can't be copied to Ente Auth. To keep an account in both, add it again and choose YubiKey and Ente Auth.", comment: "Account details of a YubiKey account while signed in to Ente Auth"))
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryLabel))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Button(action: copyCode) {
                HStack(spacing: 10) {
                    statusIcon
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                    // Scales with Dynamic Type, and shrinks rather than truncating or wrapping in a narrow column such as
                    // Slide Over or half of a folded iPhone Duo.
                    Text(account.formattedCode ?? "*** ***")
                        .privacySensitive()
                        .font(.system(size: codeFontSize, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .opacity(account.state == .expired ? 0.4 : 1.0)
                }
                .foregroundStyle(codeColor)
                .padding(.vertical, 12)
                .padding(.horizontal, 24)
                .background(Color(.secondarySystemBackground), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .accessibilityLabel(account.spokenCode)
            .accessibilityValue(account.accessibilityCodeState)
            .accessibilityHint(String(localized: "Copies the code", comment: "Accessibility hint for a code in the account list or the Mac menu bar"))
            // The label is the code itself, which can't be said to Voice Control.
            .accessibilityInputLabels([String(localized: "Code", comment: "Voice Control name for the code in the account details"),
                                       String(localized: "Copy code", comment: "Voice Control name for the Copy button")])
            Spacer()
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Button(action: { account.calculate() }) {
                    Label(String(localized: "Calculate", comment: "Menu"), systemImage: "arrow.clockwise")
                }
                .accessibilityInputLabels(VoiceControlNames.calculate)
                .help(String(localized: "Calculate a new code", comment: "Toolbar help"))
                .disabled(!account.enableRefresh)
                Button(action: { account.isPinned.toggle() }) {
                    Label(account.isPinned ? String(localized: "Unpin", comment: "Menu") : String(localized: "Pin", comment: "Menu"),
                          systemImage: account.isPinned ? "pin.slash" : "pin")
                }
                .help(account.isPinned ? String(localized: "Unpin the account", comment: "Mac row button help") : String(localized: "Pin the account to the top", comment: "Mac row button help"))
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                CopyToYubiKeyButtons(account: account)
                if account.canRename {
                    Button(action: { showEditing.toggle() }) {
                        Label(String(localized: "Rename", comment: "Menu"), systemImage: "square.and.pencil")
                    }
                    .help(String(localized: "Rename the account", comment: "Toolbar help"))
                }
                Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                    Label(String(localized: "Delete", comment: "Menu"), systemImage: "trash")
                }
                .help(account.isInEnte ? String(localized: "Move the account to the trash in Ente Auth", comment: "Toolbar help")
                      : String(localized: "Delete the account from the YubiKey", comment: "Toolbar help"))
            }
        }
        .sheet(isPresented: $showEditing) {
            EditView(account: account, viewModel: model, showEditing: $showEditing)
        }
        .alert("Delete account?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                model.deleteAccount(account) {
                    onDelete()
                }
            }
        } message: {
            if account.isInEnte {
                Text(String(localized: "This moves the account to the trash in Ente Auth on all your devices. You can restore it in the Ente Auth app.", comment: "Delete account alert for an account in Ente Auth"))
            } else {
                Text("This removes the account from the YubiKey. You won’t be able to generate codes for it anymore.")
            }
        }
    }

    private var copyToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: copyCode) {
                Label(String(localized: "Copy", comment: "Menu"), systemImage: "doc.on.doc")
            }
            .accessibilityInputLabels(VoiceControlNames.copy)
            .help(String(localized: "Copy the code", comment: "Mac row button help"))
            .disabled(account.state == .expired || account.otp == nil)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch account.state {
        case .requiresCalculation, .expired:
            Image(systemName: account.requiresTouch ? "hand.tap.fill" : "arrow.clockwise.circle.fill")
                .font(.system(size: 26))
        case .countingdown(let remaining):
            PieProgressView(progress: remaining, color: codeColor)
        }
    }

    private func copyCode() {
        toastPresenter.copyCode(of: account)
    }
}

/// Copy to YubiKey and Move to YubiKey, for an account in Ente Auth. Moving puts it in Ente's trash once it is on
/// the YubiKey, so it can still be restored in Ente Auth.
struct CopyToYubiKeyButtons: View {

    @Environment(MainViewModel.self) private var model
    @Environment(ToastPresenter.self) private var toastPresenter
    let account: Account

    var body: some View {
        if account.isInEnte {
            let canReachYubiKey = DeviceCapabilities.supportsNFC || model.isKeyPluggedIn
            if model.canCopyToYubiKey(account, moving: false) {
                Button(action: { Self.copy(account, moving: false, model: model, toastPresenter: toastPresenter) }) {
                    Label(String(localized: "Copy to YubiKey", comment: "Menu"), systemImage: "plus.square.on.square")
                }
                .help(String(localized: "Put the account on the YubiKey and keep it in Ente Auth", comment: "Toolbar help"))
                .disabled(!canReachYubiKey)
            }
            if model.canCopyToYubiKey(account, moving: true) {
                Button(action: { Self.copy(account, moving: true, model: model, toastPresenter: toastPresenter) }) {
                    Label(String(localized: "Move to YubiKey", comment: "Menu"), systemImage: "arrow.right.square")
                }
                .help(String(localized: "Put the account on the YubiKey and move it to the trash in Ente Auth", comment: "Toolbar help"))
                .disabled(!canReachYubiKey)
            }
        }
    }

    static func copy(_ account: Account, moving: Bool, model: MainViewModel, toastPresenter: ToastPresenter) {
        model.copyToYubiKey(account, moving: moving) { result in
            switch result {
            case .copied:
                toastPresenter.toast(message: String(localized: "Copied to the YubiKey", comment: "Toast after copying an Ente Auth account to the YubiKey"))
            case .moved:
                toastPresenter.toast(message: String(localized: "Moved to the YubiKey. Ente Auth keeps it in the trash.", comment: "Toast after moving an Ente Auth account to the YubiKey"))
            case .alreadyOnYubiKey:
                toastPresenter.toast(message: String(localized: "The YubiKey already has an account with this name. Nothing was changed.", comment: "Toast when copying an Ente Auth account to a YubiKey that has one with the same name"))
            }
        }
    }
}
