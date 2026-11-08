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

/// Creates an account on a self-hosted server. Ente's own servers don't offer this.
struct EnteSignUpView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var model: EnteSignUpViewModel

    /// Called with the email of the new account, to sign in with.
    let onCreated: (String) -> Void

    init(server: URL, email: String, onCreated: @escaping (String) -> Void) {
        _model = State(initialValue: EnteSignUpViewModel(server: server, email: email))
        self.onCreated = onCreated
    }

    private var host: String { (model.server.host ?? model.server.absoluteString).isolated }

    var body: some View {
        NavigationStack {
            Form {
                switch model.phase {
                case .details:
                    detailsSection
                case .emailCode:
                    emailCodeSection
                case .recoveryKey:
                    recoveryKeySections
                case .finished:
                    finishedSection
                }
            }
            .formStyle(.grouped)
            .scaledButtonLabels()
            .scrollDismissesKeyboard(.immediately)
            .disabled(model.isBusy)
            #if os(macOS)
            .textScaledFrame(minWidth: 460, idealWidth: 500, minHeight: 400, idealHeight: 520)
            #endif
            .navigationTitle(String(localized: "Create account", comment: "Ente account creation navigation title"))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityAction(.escape) {
                if model.phase != .finished { dismiss() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.phase != .finished {
                        CancelButton { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isBusy {
                        ProgressView()
                    } else if model.phase == .finished {
                        ConfirmButton(String(localized: "Done", comment: "PIV extension close button")) {
                            onCreated(model.email)
                            dismiss()
                        }
                        .accessibilityIdentifier("ente.sign-up.done")
                    }
                }
            }
            .errorAlert(error: $model.error)
        }
        // A swipe would lose the recovery key while it's being written down.
        .interactiveDismissDisabled(model.phase == .recoveryKey)
        .onDisappear {
            model.close()
        }
    }

    private var detailsSection: some View {
        Section {
            TextField(String(localized: "Email", comment: "Ente sign in field"), text: $model.email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("ente.sign-up.email")
            SecureField(String(localized: "Password", comment: "Ente sign in field"), text: $model.password)
                .textContentType(.newPassword)
                .accessibilityIdentifier("ente.sign-up.password")
            SecureField(String(localized: "Confirm password", comment: "Ente account creation field"), text: $model.confirmation)
                .textContentType(.newPassword)
                .accessibilityIdentifier("ente.sign-up.confirm")
                .onSubmit { model.sendCode() }
            Button(String(localized: "Continue", comment: "PIV extension notifications explanation button")) { model.sendCode() }
                .disabled(!model.canSendCode)
                .accessibilityIdentifier("ente.sign-up.continue")
        } header: {
            Text(String(localized: "New account on \(host)", comment: "Ente account creation header. The placeholder is the server."))
        } footer: {
            Text(String(localized: "Your password never leaves this device, and your server can't reset it. A code is sent to this email, or written to your server's log if it can't send email.", comment: "Ente account creation footer"))
        }
    }

    private var emailCodeSection: some View {
        Section {
            TextField(String(localized: "Code", comment: "Ente verification code field"), text: $model.code)
                .textContentType(.oneTimeCode)
                // The number pad types Arabic-Indic digits where those are the region's, the ASCII one always 0 to 9.
                .keyboardType(.asciiCapableNumberPad)
                .accessibilityIdentifier("ente.sign-up.code")
            Button(String(localized: "Verify code", comment: "Ente verify code button")) { model.submitCode() }
                .disabled(model.code.isEmpty)
                .accessibilityIdentifier("ente.sign-up.verify")
            Button(String(localized: "Resend code", comment: "Ente resend email code button")) { model.resendCode() }
        } header: {
            Text(String(localized: "Check your email", comment: "Ente email code header"))
        } footer: {
            if model.isDerivingKeys {
                Text(String(localized: "Deriving your keys. This can take a few seconds.", comment: "Ente sign in progress"))
            } else {
                Text(String(localized: "Enter the verification code sent to \(model.email.isolated). Without email on your server, it's in the server's log.", comment: "Ente account creation email code footer. The placeholder is the email address."))
            }
        }
    }

    @ViewBuilder private var recoveryKeySections: some View {
        if let recoveryKey = model.recoveryKey {
            Section {
                // Fixed lines: wrapped text gets hyphens, which aren't part of the key and would break a copy made by hand.
                VStack(alignment: .leading) {
                    ForEach(Array(stride(from: 0, to: recoveryKey.count, by: 16)), id: \.self) { offset in
                        Text(verbatim: String(recoveryKey.dropFirst(offset).prefix(16)))
                            .lineLimit(1)
                            .minimumScaleFactor(0.3)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("ente.sign-up.recovery-key")
                Button(String(localized: "Copy recovery key", comment: "Ente account creation button")) {
                    Platform.copy(recoveryKey)
                }
            } header: {
                Text(String(localized: "Your recovery key", comment: "Ente account creation header"))
            } footer: {
                Text(String(localized: "If you forget your password, this key is the only way to get your accounts back. Your server can't reset the password, and this key is shown only now. Keep it somewhere safe, away from this device.", comment: "Ente account creation recovery key footer"))
            }
            Section {
                Toggle(String(localized: "I saved my recovery key", comment: "Ente account creation toggle"), isOn: $model.hasSavedRecoveryKey)
                    .accessibilityIdentifier("ente.sign-up.saved")
                Button(String(localized: "Create account", comment: "Ente account creation navigation title")) { model.finish() }
                    .disabled(!model.hasSavedRecoveryKey)
                    .accessibilityIdentifier("ente.sign-up.create")
            }
        }
    }

    private var finishedSection: some View {
        Section {
            LabeledContent(String(localized: "Account", comment: "Ente saved session account label"), value: model.email.leftToRightIfAddress)
            LabeledContent(String(localized: "Server", comment: "Ente saved account server label"), value: model.server.host ?? model.server.absoluteString)
        } header: {
            Text(String(localized: "Account created", comment: "Ente account creation finished header"))
        } footer: {
            Text(String(localized: "Sign in with your new password to start using it.", comment: "Ente account creation finished footer"))
        }
    }
}
