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

/// Moves the Ente Auth accounts from one server to another: choose the servers, sign in to both, check what will
/// happen, confirm.
struct EnteMigrationView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model: EnteMigrationViewModel
    @State private var isConfirming = false
    @State private var isCreatingAccount = false

    init() {
        _model = State(initialValue: EnteMigrationViewModel())
    }

    var body: some View {
        NavigationStack {
            Form {
                switch model.phase {
                case .servers:
                    serversSections
                case .signIn(let side):
                    signInSection(side)
                case .emailCode:
                    emailCodeSection
                case .secondFactor(_, let totp, let passkey):
                    secondFactorSections(totp: totp, passkey: passkey)
                case .review:
                    reviewSections
                case .moving:
                    movingSection
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
            .navigationTitle(String(localized: "Move to another server", comment: "Ente migration navigation title"))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityAction(.escape) {
                if model.phase != .moving { dismiss() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.phase != .finished {
                        CancelButton { dismiss() }
                            .disabled(model.phase == .moving)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isBusy {
                        ProgressView()
                    } else if model.phase == .finished {
                        ConfirmButton(String(localized: "Done", comment: "PIV extension close button")) { dismiss() }
                            .accessibilityIdentifier("ente.migrate.done")
                    }
                }
            }
            .errorAlert(error: $model.error)
            .alert(String(localized: "Move your accounts to \(model.toHost.isolated)?", comment: "Ente migration confirmation. The placeholder is the new server."),
                   isPresented: $isConfirming) {
                Button(String(localized: "Move accounts", comment: "Ente migration button"), role: .destructive) { model.move() }
                    .accessibilityIdentifier("ente.migrate.confirm")
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                if model.willSwitch {
                    Text(String(localized: "Your accounts are copied, then this device syncs with the new server instead of \(model.fromHost.isolated). The accounts stay on the old server, and your other devices keep using it until you sign in to the new server there.", comment: "Ente migration confirmation message. The placeholder is the old server."))
                } else {
                    Text(String(localized: "Your accounts are copied to the new server and stay on the old one. Nothing else changes on this device.", comment: "Ente migration confirmation message when the device doesn't switch to the new server"))
                }
            }
        }
        // Halfway through, the accounts are on both servers and this device hasn't switched yet.
        .interactiveDismissDisabled(model.phase == .moving)
        .onDisappear {
            model.close()
        }
    }

    // MARK: - Servers

    @ViewBuilder private var serversSections: some View {
        Section {
            serverField(String(localized: "Migrate from", comment: "Ente migration old server field"), text: $model.from,
                        prompt: EnteAPIClient.defaultServer.absoluteString, identifier: "ente.migrate.from")
        } header: {
            Text(String(localized: "Migrate from", comment: "Ente migration old server field"))
        }
        Section {
            serverField(String(localized: "Migrate to", comment: "Ente migration new server field"), text: $model.to,
                        prompt: "https://ente.example.com", identifier: "ente.migrate.to")
        } header: {
            Text(String(localized: "Migrate to", comment: "Ente migration new server field"))
        } footer: {
            Text(String(localized: "Your accounts are copied from the old server to the new one, end-to-end encrypted. Nothing is deleted from the old server. If you host the new server yourself, you can create an account on it in the next step.", comment: "Ente migration servers footer"))
        }
        Section {
            Button(String(localized: "Continue", comment: "PIV extension notifications explanation button")) { model.start() }
                .disabled(!model.canStart)
                .accessibilityIdentifier("ente.migrate.continue")
        }
    }

    private func serverField(_ title: String, text: Binding<String>, prompt: String, identifier: String) -> some View {
        TextField(title, text: text, prompt: Text(verbatim: prompt))
            .labelsHidden()
            .accessibilityIdentifier(identifier)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    // MARK: - Sign in

    private func host(of side: EnteMigrationViewModel.Side) -> String {
        side == .source ? model.fromHost : model.toHost
    }

    private func signInSection(_ side: EnteMigrationViewModel.Side) -> some View {
        Section {
            TextField(String(localized: "Email", comment: "Ente sign in field"), text: $model.email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("ente.migrate.email")
            SecureField(String(localized: "Password", comment: "Ente sign in field"), text: $model.password)
                .textContentType(.password)
                .submitLabel(.go)
                .accessibilityIdentifier("ente.migrate.password")
                .onSubmit { model.signIn() }
            Button(String(localized: "Sign in", comment: "Ente sign in button")) { model.signIn() }
                .disabled(!model.canSignIn)
                .accessibilityIdentifier("ente.migrate.sign-in")
            if side == .target, let server = model.signUpServer {
                Button(String(localized: "Create an account on this server", comment: "Ente button that opens account creation on a self-hosted server")) {
                    isCreatingAccount = true
                }
                .accessibilityIdentifier("ente.create-account")
                // On the button: on the section each row would present it, and the sheets would close each other.
                .sheet(isPresented: $isCreatingAccount) {
                    EnteSignUpView(server: server, email: model.email) { model.email = $0 }
                        .appLockCover()
                }
            }
            startOverButton
        } header: {
            Text(String(localized: "Sign in to \(host(of: side).isolated)", comment: "Ente migration sign in header. The placeholder is the server."))
        } footer: {
            if model.isDerivingKeys {
                derivingKeysText
            } else if side == .source {
                Text(String(localized: "The Ente account your codes are in now. Your password never leaves this device.", comment: "Ente migration old server sign in footer"))
            } else {
                Text(String(localized: "The account on the new server, which may have another email and password. Your password never leaves this device.", comment: "Ente migration new server sign in footer"))
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
                Text(String(localized: "Enter the verification code Ente sent to \(model.email.isolated).", comment: "Ente email code footer. The placeholder is the email address."))
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

    private var codeField: some View {
        TextField(String(localized: "Code", comment: "Ente verification code field"), text: $model.code)
            .textContentType(.oneTimeCode)
            // The number pad types Arabic-Indic digits where those are the region's, the ASCII one always 0 to 9.
            .keyboardType(.asciiCapableNumberPad)
    }

    private var derivingKeysText: some View {
        Text(String(localized: "Deriving your keys. This can take a few seconds.", comment: "Ente sign in progress"))
    }

    private var startOverButton: some View {
        Button(String(localized: "Start over", comment: "Ente migration button that goes back to the servers")) { model.startOver() }
    }

    // MARK: - Review

    @ViewBuilder private var reviewSections: some View {
        Section {
            LabeledContent(String(localized: "From", comment: "Ente migration review label"), value: model.fromHost)
            if let email = model.sourceEmail {
                LabeledContent(String(localized: "Account", comment: "Ente saved session account label"), value: email.leftToRightIfAddress)
            }
        }
        Section {
            LabeledContent(String(localized: "To", comment: "Ente migration review label"), value: model.toHost)
            if let email = model.targetEmail {
                LabeledContent(String(localized: "Account", comment: "Ente saved session account label"), value: email.leftToRightIfAddress)
            }
        }
        if let plan = model.plan {
            Section {
                LabeledContent(String(localized: "Accounts to copy", comment: "Ente migration review label"), value: plan.toCopy.count.formatted())
                if plan.alreadyOnTarget > 0 {
                    LabeledContent(String(localized: "Already on the new server", comment: "Ente migration review label"), value: plan.alreadyOnTarget.formatted())
                }
                if plan.trashed > 0 {
                    LabeledContent(String(localized: "In the trash, kept there", comment: "Ente migration review label"), value: plan.trashed.formatted())
                }
            } footer: {
                if plan.unreadable > 0 {
                    Label(String(localized: "\(plan.unreadable.formatted()) accounts can't be decrypted and won't be copied. They stay on the old server.", comment: "Ente migration review warning. The placeholder is the number of accounts."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text(String(localized: "Accounts already on the new server stay as they are.", comment: "Ente migration review footer"))
                }
            }
        }
        Section {
            Button(String(localized: "Move accounts", comment: "Ente migration button")) { isConfirming = true }
                .accessibilityIdentifier("ente.migrate.move")
            startOverButton
        }
    }

    private var movingSection: some View {
        Section {
            ProgressView(value: Double(model.copied), total: Double(max(model.plan?.toCopy.count ?? 0, 1)))
        } footer: {
            Text(String(localized: "Copying your accounts. Keep the app open until this is done.", comment: "Ente migration progress"))
        }
    }

    private var finishedSection: some View {
        Section {
            LabeledContent(String(localized: "Accounts copied", comment: "Ente migration finished label"), value: model.copied.formatted())
        } header: {
            Text(String(localized: "Moved to \(model.toHost.isolated)", comment: "Ente migration finished header. The placeholder is the new server."))
        } footer: {
            if model.didSwitch {
                Text(String(localized: "All accounts are on the new server, and this device now syncs with it. They are still on \(model.fromHost.isolated). Check that your codes work before you delete them there, and sign in to the new server on your other devices.", comment: "Ente migration finished footer. The placeholder is the old server."))
            } else {
                Text(String(localized: "All accounts are on the new server. They are still on \(model.fromHost.isolated). Nothing else changed on this device.", comment: "Ente migration finished footer when the device didn't switch. The placeholder is the old server."))
            }
        }
    }
}
