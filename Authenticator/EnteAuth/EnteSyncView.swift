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
import YubiKit

/// Signs in to Ente Auth and lets the user pick accounts to put on the YubiKey.
struct EnteSyncView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model: EnteSyncViewModel
    @FocusState private var focusedField: Field?

    /// Whether a YubiKey can be reached, over NFC or because one is plugged in.
    let canAddToYubiKey: Bool
    /// Called with the selected accounts after the view is dismissed.
    let onImport: ([YubiKitOATHSession.CredentialTemplate], Bool) -> Void

    private enum Field {
        case email, password, code, server
    }

    init(existingCredentialIds: Set<String>, capacity: Int?, canAddToYubiKey: Bool, onImport: @escaping ([YubiKitOATHSession.CredentialTemplate], Bool) -> Void) {
        _model = State(initialValue: EnteSyncViewModel(existingCredentialIds: existingCredentialIds, capacity: capacity))
        self.canAddToYubiKey = canAddToYubiKey
        self.onImport = onImport
    }

    var body: some View {
        NavigationStack {
            Form {
                switch model.phase {
                case .signIn:
                    signInSection
                case .savedSession(let email):
                    savedSessionSection(email: email)
                case .emailCode:
                    emailCodeSection
                case .secondFactor(let totp, let passkey):
                    secondFactorSection(totp: totp, passkey: passkey)
                case .accounts:
                    accountsSections
                }
            }
            .formStyle(.grouped)
            // Scrolling puts the keyboard away, so the footers under it can be read.
            .scrollDismissesKeyboard(.immediately)
            .disabled(model.isBusy)
            #if os(macOS)
            .frame(minWidth: 460, idealWidth: 500, minHeight: 400, idealHeight: 520)
            #endif
            .navigationTitle(String(localized: "Ente Auth", comment: "Ente sync navigation title"))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityAction(.escape) { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isBusy {
                        ProgressView()
                    } else if model.phase == .accounts {
                        ConfirmButton(addButtonTitle) { importSelection() }
                            .disabled(model.selection.isEmpty || !canAddToYubiKey)
                    }
                }
            }
            .errorAlert(error: $model.error)
        }
        .onDisappear {
            model.close()
        }
    }

    // MARK: - Sign in

    private var signInSection: some View {
        Group {
            Section {
                TextField(String(localized: "Email", comment: "Ente sign in field"), text: $model.email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .email)
                    .onSubmit { focusedField = .password }
                SecureField(String(localized: "Password", comment: "Ente sign in field"), text: $model.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { model.signIn() }
                Button(String(localized: "Sign in", comment: "Ente sign in button")) { model.signIn() }
                    .disabled(!model.canSignIn)
            } header: {
                Text(String(localized: "Sign in to Ente Auth", comment: "Ente sign in section header"))
            } footer: {
                if model.isDerivingKeys {
                    derivingKeysText
                } else {
                    Text(String(localized: "Your Ente Auth accounts are end-to-end encrypted and only decrypted on this device, and your password never leaves it. If you stay signed in, the accounts are kept on this device and listed with your YubiKey's, and accounts you add, rename, pin or delete here are changed in Ente Auth too.", comment: "Ente sign in footer"))
                }
            }

            Section {
                TextField(EnteAPIClient.defaultServer.absoluteString, text: $model.server)
                    // The placeholder is the default server's address, which isn't a name to say.
                    .accessibilityLabel(String(localized: "Server", comment: "Ente sign in server field"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .server)
                if model.canSaveSession {
                    Toggle(String(localized: "Stay signed in", comment: "Ente sign in toggle"), isOn: $model.staySignedIn)
                }
            } header: {
                Text(String(localized: "Options", comment: "Ente sign in options header"))
            } footer: {
                if model.canSaveSession {
                    #if os(macOS)
                    Text(String(localized: "Leave the server empty unless you host Ente yourself. Staying signed in keeps your session and the key that decrypts your accounts in the keychain, protected by Touch ID or your Mac's password, so you can sync again without your Ente password, which is never stored.", comment: "Mac Ente sign in options footer"))
                    #else
                    Text(String(localized: "Leave the server empty unless you host Ente yourself. Staying signed in keeps your session and the key that decrypts your accounts in the keychain, protected by Face ID or Touch ID, so you can sync again without your password, which is never stored.", comment: "Ente sign in options footer"))
                    #endif
                } else {
                    Text(String(localized: "Leave the server empty unless you host Ente yourself.", comment: "Ente sign in options footer without stay signed in"))
                }
            }
        }
        .onAppear { focusedField = model.email.isEmpty ? .email : .password }
    }

    @ViewBuilder private func savedSessionSection(email: String) -> some View {
        Section {
            LabeledContent(String(localized: "Account", comment: "Ente saved session account label"), value: email)
            Button(String(localized: "Sync accounts", comment: "Ente saved session sync button")) { model.useSavedSession() }
            Button(String(localized: "Sign out", comment: "Ente sign out button"), role: .destructive) { model.signOut() }
        } header: {
            Text(String(localized: "Signed in to Ente Auth", comment: "Ente saved session header"))
        } footer: {
            Text(String(localized: "Your Ente Auth accounts are kept on this device, encrypted, and listed with your YubiKey's, so their codes work offline. They are synced with Ente when the app opens, after each change and when you refresh the list. Choose Sync accounts to pick ones to add to your YubiKey.", comment: "Ente saved session footer"))
        }
        watchSection
    }

    /// Shown with a saved session when a watch with the app is paired, or while the switch is on so it can be turned off.
    @ViewBuilder private var watchSection: some View {
        if model.watch.isWatchAvailable || model.watch.isEnabled {
            Section {
                Toggle(String(localized: "Show Ente Auth accounts on Apple Watch", comment: "Ente sync Apple Watch toggle"),
                       isOn: Binding(get: { model.watch.isEnabled }, set: { model.setShowsAccountsOnWatch($0) }))
            } footer: {
                Text(String(localized: "A copy of your time-based Ente Auth accounts is kept on your Apple Watch, so it can show codes without your iPhone. The accounts on the watch are updated each time you sync, and deleted when you turn this off or sign out.", comment: "Ente sync Apple Watch toggle footer"))
            }
        }
    }

    private var emailCodeSection: some View {
        Section {
            codeField
            Button(String(localized: "Verify code", comment: "Ente verify code button")) { model.submitCode() }
                .disabled(model.code.isEmpty)
            Button(String(localized: "Resend code", comment: "Ente resend email code button")) { model.resendCode() }
            startOverButton
        } header: {
            Text(String(localized: "Check your email", comment: "Ente email code header"))
        } footer: {
            if model.isDerivingKeys {
                derivingKeysText
            } else {
                Text(String(localized: "Enter the verification code Ente sent to \(model.email).", comment: "Ente email code footer. The placeholder is the email address."))
            }
        }
    }

    private func secondFactorSection(totp: Bool, passkey: Bool) -> some View {
        Group {
            if totp {
                Section {
                    codeField
                    Button(String(localized: "Verify code", comment: "Ente verify code button")) { model.submitCode() }
                        .disabled(model.code.isEmpty)
                } header: {
                    Text(String(localized: "Two-factor authentication", comment: "Ente two factor header"))
                } footer: {
                    if model.isDerivingKeys {
                        derivingKeysText
                    } else {
                        Text(String(localized: "Enter the code from your authenticator app.", comment: "Ente two factor footer"))
                    }
                }
            }
            if passkey {
                Section {
                    Button(String(localized: "Verify passkey in browser", comment: "Ente passkey button")) {
                        if let url = model.passkeyURL { openURL(url) }
                    }
                    .disabled(model.passkeyURL == nil)
                    Button(String(localized: "I have verified the passkey", comment: "Ente passkey continue button")) { model.checkPasskey() }
                } header: {
                    Text(String(localized: "Passkey", comment: "Ente passkey header"))
                } footer: {
                    if model.isDerivingKeys {
                        derivingKeysText
                    } else {
                        Text(String(localized: "Verify your passkey on Ente's website, then come back here.", comment: "Ente passkey footer"))
                    }
                }
            }
            Section { startOverButton }
        }
    }

    private var codeField: some View {
        TextField(String(localized: "Code", comment: "Ente verification code field"), text: $model.code)
            .textContentType(.oneTimeCode)
            .keyboardType(.numberPad)
            .focused($focusedField, equals: .code)
            .onAppear { focusedField = .code }
    }

    /// Replaces a section's footer while the password is turned into keys, after signing in or verifying a code or passkey.
    private var derivingKeysText: some View {
        Text(String(localized: "Deriving your keys. This can take a few seconds.", comment: "Ente sign in progress"))
    }

    private var startOverButton: some View {
        Button(String(localized: "Use another account", comment: "Ente start over button")) { model.startOver() }
    }

    // MARK: - Accounts

    @ViewBuilder private var accountsSections: some View {
        if model.codes.isEmpty {
            Section {
                Text(String(localized: "There are no accounts in Ente Auth.", comment: "Ente sync no accounts"))
                    .foregroundStyle(.secondary)
            }
        } else {
            storageSection
            Section {
                ForEach(model.codes) { code in
                    EnteCodeRow(code: code,
                                isSelected: model.selection.contains(code.id),
                                isOnYubiKey: model.isOnYubiKey(code)) {
                        model.toggleSelection(code)
                    }
                }
            } header: {
                HStack {
                    Text(String(localized: "\(model.codes.count) accounts in Ente Auth", comment: "Ente sync accounts header. The placeholder is the number of accounts."))
                    Spacer()
                    if !model.canSelectMore && !model.selection.isEmpty {
                        Button(String(localized: "Select none", comment: "Ente sync deselect all")) { model.selectNone() }
                    } else {
                        Button(String(localized: "Select all", comment: "Ente sync select all")) { model.selectAll() }
                            .disabled(model.freeSpaces == 0)
                    }
                }
            } footer: {
                if !canAddToYubiKey {
                    Text(String(localized: "Insert your YubiKey to add the accounts.", comment: "Ente sync no YubiKey footer"))
                } else {
                    Text(String(localized: "The selected accounts are added to your YubiKey. Accounts with the same name as one on the YubiKey are skipped.", comment: "Ente sync accounts footer"))
                }
            }
            Section {
                Toggle(String(localized: "Require touch", comment: "Add account toggle"), isOn: $model.requiresTouch)
            }
        }
        Section {
            if let email = model.signedInEmail {
                LabeledContent(String(localized: "Account", comment: "Ente saved session account label"), value: email)
            }
            Button(String(localized: "Sign out", comment: "Ente sign out button"), role: .destructive) { model.signOut() }
        }
        if model.isSessionSaved {
            watchSection
        }
    }

    private var addButtonTitle: String {
        if model.selection.isEmpty {
            String(localized: "Add", comment: "Ente sync add selected accounts to YubiKey")
        } else {
            String(localized: "Add \(model.selection.count)", comment: "Ente sync add selected accounts to YubiKey. The placeholder is the number of selected accounts.")
        }
    }

    /// How much room is left on the YubiKey, with a warning when the selection doesn't fit.
    @ViewBuilder private var storageSection: some View {
        if let freeSpaces = model.freeSpaces, let capacity = model.capacity {
            Section {
                LabeledContent(String(localized: "Space on YubiKey", comment: "Ente sync free space label"),
                               value: String(localized: "\(freeSpaces) of \(capacity) free", comment: "Ente sync free space. The placeholders are the free and total number of accounts the YubiKey can hold."))
            } footer: {
                if freeSpaces == 0 {
                    Text(String(localized: "The YubiKey is full. Delete accounts from it to make room.", comment: "Ente sync YubiKey full footer"))
                } else if model.isSelectionTooLarge {
                    Label(String(localized: "Too many accounts selected. Deselect \(model.selection.count - freeSpaces) so they all fit on the YubiKey.", comment: "Ente sync selection too large warning. The placeholder is how many accounts to deselect."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if model.importableCodes.count > freeSpaces {
                    Text(String(localized: "Not all accounts fit on the YubiKey, so only the first ones are selected. Pick the ones you need most.", comment: "Ente sync free space footer"))
                }
            }
        }
    }

    private func importSelection() {
        let templates = model.selectedTemplates
        let requiresTouch = model.requiresTouch
        dismiss()
        onImport(templates, requiresTouch)
    }
}

private struct EnteCodeRow: View {
    let code: EnteCode
    let isSelected: Bool
    let isOnYubiKey: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color(.tertiaryLabel))
                    .accessibilityHidden(true)
                // Explicit label colors, a button in a form would otherwise tint them with the accent color. An account
                // that can't be added is lighter, but still readable.
                VStack(alignment: .leading) {
                    Text(code.title)
                        .foregroundStyle(Color(code.template == nil ? .secondaryLabel : .label))
                    if let subtitle = code.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                    if let reason = code.unsupportedReason {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if isOnYubiKey {
                        Text(String(localized: "Already on YubiKey", comment: "Ente sync account already on YubiKey"))
                            .font(.footnote)
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                }
                #if os(macOS)
                Spacer(minLength: 0)
                #endif
            }
            #if os(macOS)
            .contentShape(Rectangle())
            #endif
        }
        #if os(macOS)
        // A whole row that toggles, rather than a bordered push button.
        .buttonStyle(.plain)
        #endif
        .disabled(code.template == nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
