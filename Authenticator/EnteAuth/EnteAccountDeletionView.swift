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

/// Deletes an account on a self-hosted server, after the password and any email code or second factor.
struct EnteAccountDeletionView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model: EnteAccountDeletionViewModel
    @State private var isConfirming = false

    /// Called after the account was deleted and the view dismissed.
    let onDeleted: () -> Void

    init(server: URL, email: String, onDeleted: @escaping () -> Void = {}) {
        _model = State(initialValue: EnteAccountDeletionViewModel(server: server, email: email))
        self.onDeleted = onDeleted
    }

    private var host: String { (model.server.host ?? model.server.absoluteString).isolated }

    var body: some View {
        NavigationStack {
            Form {
                switch model.phase {
                case .password:
                    passwordSection
                case .emailCode:
                    emailCodeSection
                case .secondFactor(let totp, let passkey):
                    secondFactorSections(totp: totp, passkey: passkey)
                case .deleted:
                    deletedSection
                }
            }
            .formStyle(.grouped)
            .scaledButtonLabels()
            .scrollDismissesKeyboard(.immediately)
            .disabled(model.isBusy)
            #if os(macOS)
                .textScaledFrame(minWidth: 460, idealWidth: 500, minHeight: 400, idealHeight: 520)
            #endif
            .navigationTitle(String(localized: "Delete account", comment: "Ente account deletion navigation title"))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityAction(.escape) { close() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.phase != .deleted {
                        CancelButton { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isBusy {
                        ProgressView()
                    } else if model.phase == .deleted {
                        ConfirmButton(String(localized: "Done", comment: "PIV extension close button")) { close() }
                            .accessibilityIdentifier("ente.delete-account.done")
                    }
                }
            }
            .errorAlert(error: $model.error)
            .confirmationDialog(
                String(
                    localized: "Delete your account on \(host)?",
                    comment: "Ente account deletion confirmation. The placeholder is the server."),
                isPresented: $isConfirming, titleVisibility: .visible
            ) {
                Button(String(localized: "Delete account", comment: "Ente account deletion button"), role: .destructive) { model.delete() }
                    .accessibilityIdentifier("ente.delete-account.confirm")
            } message: {
                Text(
                    String(
                        localized:
                            "The account and every Ente Auth account in it are deleted from the server for good. This can't be undone.",
                        comment: "Ente account deletion confirmation message"))
            }
        }
        .interactiveDismissDisabled(model.phase == .deleted)
        .onDisappear {
            model.close()
        }
    }

    private func close() {
        let deleted = model.phase == .deleted
        dismiss()
        if deleted { onDeleted() }
    }

    private var passwordSection: some View {
        Section {
            TextField(String(localized: "Email", comment: "Ente sign in field"), text: $model.email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("ente.delete-account.email")
            SecureField(String(localized: "Password", comment: "Ente sign in field"), text: $model.password)
                .textContentType(.password)
                .accessibilityIdentifier("ente.delete-account.password")
                .onSubmit { if model.canDelete { isConfirming = true } }
            Button(String(localized: "Delete account", comment: "Ente account deletion button"), role: .destructive) { isConfirming = true }
                .disabled(!model.canDelete)
                .accessibilityIdentifier("ente.delete-account.delete")
        } header: {
            Text(String(localized: "Account on \(host)", comment: "Ente account deletion header. The placeholder is the server."))
        } footer: {
            if model.isDerivingKeys {
                derivingKeysText
            } else {
                Text(
                    String(
                        localized:
                            "Deleting the account removes it and all its Ente Auth accounts from your server. Enter its password to confirm it's yours. Your password never leaves this device.",
                        comment: "Ente account deletion footer"))
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
                Text(
                    String(
                        localized:
                            "Enter the verification code sent to \(model.email.isolated). Without email on your server, it's in the server's log.",
                        comment: "Ente account creation email code footer. The placeholder is the email address."))
            }
        }
    }

    @ViewBuilder private func secondFactorSections(totp: Bool, passkey: Bool) -> some View {
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
            }
        }
        Section { startOverButton }
    }

    private var deletedSection: some View {
        Section {
            LabeledContent(
                String(localized: "Account", comment: "Ente saved session account label"), value: model.email.leftToRightIfAddress)
            LabeledContent(
                String(localized: "Server", comment: "Ente saved account server label"),
                value: model.server.host ?? model.server.absoluteString)
        } header: {
            Text(String(localized: "Account deleted", comment: "Ente account deletion finished header"))
        } footer: {
            Text(
                String(
                    localized: "The account and its data were deleted from your server. Codes on your YubiKey aren't affected.",
                    comment: "Ente account deletion finished footer"))
        }
    }

    private var codeField: some View {
        TextField(String(localized: "Code", comment: "Ente verification code field"), text: $model.code)
            .textContentType(.oneTimeCode)
            // The number pad types Arabic-Indic digits where those are the region's, the ASCII one always 0 to 9.
            .keyboardType(.asciiCapableNumberPad)
            .accessibilityIdentifier("ente.delete-account.code")
    }

    private var derivingKeysText: some View {
        Text(String(localized: "Deriving your keys. This can take a few seconds.", comment: "Ente sign in progress"))
    }

    private var startOverButton: some View {
        Button(String(localized: "Use another account", comment: "Ente start over button")) { model.startOver() }
    }
}
