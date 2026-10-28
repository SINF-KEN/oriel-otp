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

    init(existingCredentialIds: Set<String>, canAddToYubiKey: Bool, onImport: @escaping ([YubiKitOATHSession.CredentialTemplate], Bool) -> Void) {
        _model = State(initialValue: EnteSyncViewModel(existingCredentialIds: existingCredentialIds))
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
                case .password:
                    passwordSection
                case .secondFactor(let totp, let passkey):
                    secondFactorSection(totp: totp, passkey: passkey)
                case .accounts:
                    accountsSections
                }
            }
            .formStyle(.grouped)
            .disabled(model.isBusy)
            .navigationTitle(String(localized: "Ente Auth", comment: "Ente sync navigation title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isBusy {
                        ProgressView()
                    } else if model.phase == .accounts {
                        ConfirmButton(String(localized: "Add", comment: "Ente sync add selected accounts to YubiKey")) { importSelection() }
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
                    .submitLabel(.continue)
                    .focused($focusedField, equals: .email)
                    .onSubmit { model.signIn() }
                Button(String(localized: "Continue", comment: "Ente sign in button")) { model.signIn() }
                    .disabled(model.email.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text(String(localized: "Sign in to Ente Auth", comment: "Ente sign in section header"))
            } footer: {
                Text(String(localized: "Your Ente Auth accounts are end-to-end encrypted. They are downloaded and decrypted on this device and only stored on your YubiKey. Your password never leaves this device and nothing is changed in Ente Auth.", comment: "Ente sign in footer"))
            }

            Section {
                TextField(EnteAPIClient.defaultServer.absoluteString, text: $model.server)
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
                    Text(String(localized: "Leave the server empty unless you host Ente yourself. Staying signed in keeps a session in the keychain, protected by Face ID, Touch ID or your passcode, so you can sync again without your password.", comment: "Ente sign in options footer"))
                } else {
                    Text(String(localized: "Leave the server empty unless you host Ente yourself.", comment: "Ente sign in options footer without stay signed in"))
                }
            }
        }
        .onAppear { focusedField = .email }
    }

    private func savedSessionSection(email: String) -> some View {
        Section {
            LabeledContent(String(localized: "Account", comment: "Ente saved session account label"), value: email)
            Button(String(localized: "Sync accounts", comment: "Ente saved session sync button")) { model.useSavedSession() }
            Button(String(localized: "Sign out", comment: "Ente sign out button"), role: .destructive) { model.signOut() }
        } header: {
            Text(String(localized: "Signed in to Ente Auth", comment: "Ente saved session header"))
        }
    }

    private var emailCodeSection: some View {
        Section {
            codeField
            Button(String(localized: "Verify", comment: "Ente verify code button")) { model.submitCode() }
                .disabled(model.code.isEmpty)
            Button(String(localized: "Resend code", comment: "Ente resend email code button")) { model.resendCode() }
            startOverButton
        } header: {
            Text(String(localized: "Check your email", comment: "Ente email code header"))
        } footer: {
            Text(String(localized: "Enter the verification code Ente sent to \(model.email).", comment: "Ente email code footer. The placeholder is the email address."))
        }
    }

    private var passwordSection: some View {
        Section {
            SecureField(String(localized: "Password", comment: "Ente sign in field"), text: $model.password)
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focusedField, equals: .password)
                .onSubmit { model.submitPassword() }
            Button(String(localized: "Sign in", comment: "Ente sign in button")) { model.submitPassword() }
                .disabled(model.password.isEmpty)
            startOverButton
        } header: {
            Text(model.email)
        } footer: {
            if model.isBusy {
                Text(String(localized: "Deriving your keys. This can take a few seconds.", comment: "Ente sign in progress"))
            }
        }
        .onAppear { focusedField = .password }
    }

    private func secondFactorSection(totp: Bool, passkey: Bool) -> some View {
        Group {
            if totp {
                Section {
                    codeField
                    Button(String(localized: "Verify", comment: "Ente verify code button")) { model.submitCode() }
                        .disabled(model.code.isEmpty)
                } header: {
                    Text(String(localized: "Two-factor authentication", comment: "Ente two factor header"))
                } footer: {
                    Text(String(localized: "Enter the code from your authenticator app.", comment: "Ente two factor footer"))
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
                    Text(String(localized: "Verify your passkey on Ente's website, then come back here.", comment: "Ente passkey footer"))
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
                    if model.selection.count == model.importableCodes.count && !model.selection.isEmpty {
                        Button(String(localized: "Select none", comment: "Ente sync deselect all")) { model.selectNone() }
                    } else {
                        Button(String(localized: "Select all", comment: "Ente sync select all")) { model.selectAll() }
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
                // Explicit label colors, a button in a form would otherwise tint them with the accent color.
                VStack(alignment: .leading) {
                    Text(code.title)
                        .foregroundStyle(Color(code.template == nil ? .tertiaryLabel : .label))
                    if let subtitle = code.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Color(code.template == nil ? .tertiaryLabel : .secondaryLabel))
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
            }
        }
        .disabled(code.template == nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
