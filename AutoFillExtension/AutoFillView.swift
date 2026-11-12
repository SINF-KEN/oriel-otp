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

/// The lock while the app is locked, then the list of codes. For a suggestion chosen while the app is locked, its
/// code is filled in as soon as the app is unlocked.
struct AutoFillView: View {

    let model: AutoFillModel
    private var lock: AppLock { .shared }

    var body: some View {
        NavigationStack {
            Group {
                if lock.isLocked {
                    AutoFillLockView()
                } else if model.pending != nil {
                    ProgressView()
                } else {
                    AutoFillListView(model: model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", comment: "AutoFill cancel button"), action: model.cancel)
                }
            }
        }
        .onChange(of: lock.isLocked, initial: true) { _, isLocked in
            if !isLocked, let pending = model.pending {
                model.fill(pending)
            }
        }
    }
}

/// The codes to choose from, the ones suggested for the website or app first.
private struct AutoFillListView: View {

    let model: AutoFillModel
    @State private var searchText = ""

    var body: some View {
        let matching = model.filter(model.matching, by: searchText)
        let others = model.filter(model.others, by: searchText)
        List {
            if let problem = model.problem {
                problemView(problem)
            } else if matching.isEmpty && others.isEmpty {
                Text(String(localized: "No accounts match your search.", comment: "AutoFill search without results"))
                    .foregroundStyle(.secondary)
            }
            if !matching.isEmpty {
                Section(String(localized: "Suggested", comment: "AutoFill section of the accounts for the website or app")) {
                    rows(matching)
                }
            }
            if !others.isEmpty {
                Section(matching.isEmpty ? String(localized: "Accounts", comment: "AutoFill section of all accounts")
                        : String(localized: "Other Accounts", comment: "AutoFill section of the accounts not suggested for the website or app")) {
                    rows(others)
                }
            }
        }
        .navigationTitle(String(localized: "Verification Codes", comment: "AutoFill list title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText)
    }

    private func rows(_ accounts: [AutoFillAccount]) -> some View {
        ForEach(accounts) { account in
            Button {
                model.fill(account)
            } label: {
                AutoFillAccountRow(account: account.account)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func problemView(_ problem: AutoFillModel.Problem) -> some View {
        switch problem {
        case .unavailable:
            Text(String(localized: "Unlock your device to use your accounts.", comment: "AutoFill before the device was first unlocked"))
                .foregroundStyle(.secondary)
        case .noAccounts:
            Text(String(localized: "Oriel OTP fills in the codes of its time-based accounts in Ente Auth and on this device. Add one in the app, or sign in to Ente Auth there, to use it here. The accounts on your YubiKey can't be used for AutoFill.", comment: "AutoFill without accounts"))
                .foregroundStyle(.secondary)
        case .unreadable:
            Text(String(localized: "Open Oriel OTP to use your accounts here again.", comment: "AutoFill when its copy of the accounts can't be read"))
                .foregroundStyle(.secondary)
        }
    }
}

/// An account with its current code and the seconds until it changes.
private struct AutoFillAccountRow: View {

    let account: OTPAccount

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let code = OTPGenerator.grouped(OTPGenerator.code(for: account, at: context.date))
            let secondsLeft = OTPGenerator.secondsLeft(for: account, at: context.date)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.title.leftToRightIfAddress)
                        .font(.body.weight(.medium))
                    if let subtitle = account.subtitle {
                        Text(subtitle.leftToRightIfAddress)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(code)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .privacySensitive()
                Text(verbatim: "\(secondsLeft)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityHint(String(localized: "Fills in the code", comment: "AutoFill account accessibility hint"))
        }
    }
}

/// Asks for the app's lock: Face ID, Touch ID or the device passcode, or the app's code or password.
private struct AutoFillLockView: View {

    private var lock: AppLock { .shared }
    @State private var secret = ""
    @State private var isWrong = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "Oriel OTP is locked", comment: "App lock screen title"))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if lock.isUnavailable {
                Text(String(localized: "Unlock your device to use your accounts.", comment: "AutoFill before the device was first unlocked"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if lock.method == .device {
                Button(String(localized: "Unlock with \(AppLock.deviceOwnerTitle)", comment: "App lock screen button. The placeholder is Face ID, Touch ID or Device passcode.")) {
                    Task { await lock.unlockWithDeviceOwner() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(lock.isAuthenticating)
            } else if let retryDate = lock.retryDate {
                Text("Too many attempts. Try again in \(Text(timerInterval: Date.now...retryDate, countsDown: true)).", comment: "App lock wait after wrong codes. The placeholder counts down, e.g. 0:30.")
                    .monospacedDigit()
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .task(id: retryDate) {
                        try? await Task.sleep(for: .seconds(max(0, retryDate.timeIntervalSinceNow) + 0.2))
                        lock.updateRetryDate()
                    }
            } else {
                secretField
            }
        }
        .padding(24)
        .frame(maxWidth: 400)
        .task {
            if lock.method == .device {
                await lock.unlockWithDeviceOwner()
            }
        }
    }

    private var secretField: some View {
        VStack(spacing: 12) {
            SecureField(lock.method == .password ? String(localized: "Enter your password", comment: "App lock screen prompt")
                        : String(localized: "Enter your code", comment: "App lock screen prompt"), text: $secret)
                #if os(iOS)
                .keyboardType(lock.method.codeLength == nil ? .default : .numberPad)
                #endif
                .textContentType(.password)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(submit)
                .onChange(of: secret) { _, secret in
                    if let length = lock.method.codeLength, secret.count >= length {
                        submit()
                    }
                }
            if isWrong {
                Text(lock.method == .password ? String(localized: "Wrong password. Try again.", comment: "VoiceOver announcement after a wrong app lock password")
                     : String(localized: "Wrong code. Try again.", comment: "VoiceOver announcement after a wrong app lock code"))
                    .foregroundStyle(.red)
            }
            if lock.method == .password {
                Button(String(localized: "Unlock", comment: "AutoFill unlock button"), action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(secret.isEmpty)
            }
        }
        .onAppear { isFocused = true }
    }

    private func submit() {
        guard !secret.isEmpty else { return }
        isWrong = !lock.unlock(with: secret)
        secret = ""
    }
}
