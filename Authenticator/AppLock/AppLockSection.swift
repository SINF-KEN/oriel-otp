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

/// The app lock in settings: what unlocks the app, and changing the code or password.
///
/// Changing it asks for the current lock first, so someone handed the unlocked app can't turn it off.
struct AppLockSection: View {

    private var lock: AppLock { .shared }
    @State private var change: AppLockChange?
    @State private var error: Error?

    var body: some View {
        Section {
            Picker(String(localized: "Lock with", comment: "App lock setting"),
                   selection: Binding(get: { lock.method }, set: { method in Task { await requestChange(to: method) } })) {
                Text(String(localized: "Off", comment: "App lock method")).tag(AppLockMethod.off)
                if AppLock.canUseDeviceOwner || lock.method == .device {
                    Text(verbatim: AppLock.deviceOwnerTitle).tag(AppLockMethod.device)
                }
                Text(String(localized: "4-digit code", comment: "App lock method")).tag(AppLockMethod.code4)
                Text(String(localized: "6-digit code", comment: "App lock method")).tag(AppLockMethod.code6)
                Text(String(localized: "Password", comment: "App lock method")).tag(AppLockMethod.password)
            }
            if lock.method.hasSecret {
                Button(lock.method == .password
                       ? String(localized: "Change password", comment: "App lock setting button")
                       : String(localized: "Change code", comment: "App lock setting button")) {
                    Task { await requestChange(to: lock.method) }
                }
            }
        } header: {
            Text(String(localized: "App lock", comment: "App lock settings section header"))
        } footer: {
            #if os(macOS)
            Text(String(localized: "Asked for when the app opens, the screen locks or the Mac sleeps. A forgotten code or password can't be recovered: delete the app, then your accounts are on your YubiKey and in Ente Auth.", comment: "Mac app lock settings footer"))
            #else
            Text(String(localized: "Asked for when the app opens or comes back from the background. A forgotten code or password can't be recovered: delete the app, then your accounts are on your YubiKey and in Ente Auth.", comment: "App lock settings footer"))
            #endif
        }
        .sheet(item: $change) { change in
            AppLockChangeView(change: change) { result in
                self.change = nil
                if case .failure(let error) = result { self.error = error }
            }
        }
        .errorAlert(error: $error)
    }

    /// Checks the current lock and asks for the new code or password, or changes it right away when neither needs to
    /// be typed.
    private func requestChange(to method: AppLockMethod) async {
        let current = lock.method
        guard method != current || method.hasSecret else { return }
        if current.hasSecret || method.hasSecret {
            // Face ID for the current lock first, the sheet then only asks for codes and passwords.
            if current == .device, !(await lock.verifyDeviceOwner()) { return }
            change = AppLockChange(from: current, to: method)
            return
        }
        // Between off and Face ID: Face ID is asked for either way, to turn it off or to check that it works.
        guard await lock.verifyDeviceOwner() else { return }
        do {
            try lock.setMethod(method)
        } catch {
            self.error = error
        }
    }
}

struct AppLockChange: Identifiable {
    let id = UUID()
    let from: AppLockMethod
    let to: AppLockMethod
}

/// Asks for the current code or password, then the new one twice.
private struct AppLockChangeView: View {

    let change: AppLockChange
    let done: (Result<Void, Error>?) -> Void

    private enum Step: Hashable {
        case current
        case new
        case confirm(String)
        case mismatch
    }

    @State private var step: Step

    private var lock: AppLock { .shared }

    init(change: AppLockChange, done: @escaping (Result<Void, Error>?) -> Void) {
        self.change = change
        self.done = done
        _step = State(initialValue: change.from.hasSecret ? .current : .new)
    }

    var body: some View {
        NavigationStack {
            VStack {
                Spacer(minLength: 0)
                switch step {
                case .current:
                    AppLockSecretEntry(method: change.from, prompt: currentPrompt) { secret in
                        guard lock.verify(secret) else { return false }
                        Task { await currentVerified() }
                        return true
                    }
                case .new, .mismatch:
                    AppLockSecretEntry(method: change.to, prompt: step == .mismatch ? mismatchPrompt : newPrompt, checksRetryDate: false) { secret in
                        guard change.to != .password || secret.count >= 4 else { return false }
                        step = .confirm(secret)
                        return true
                    }
                    .id(step)
                case .confirm(let first):
                    AppLockSecretEntry(method: change.to, prompt: confirmPrompt, checksRetryDate: false) { secret in
                        guard secret == first else {
                            step = .mismatch
                            return false
                        }
                        save(secret)
                        return true
                    }
                    .id(step)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .scrollsWhenTooTall()
            .navigationTitle(String(localized: "App lock", comment: "App lock settings section header"))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityAction(.escape) { done(nil) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { done(nil) }
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 560)
        #endif
        .interactiveDismissDisabled()
    }

    private var currentPrompt: String {
        change.from == .password
            ? String(localized: "Enter your current password", comment: "App lock change prompt")
            : String(localized: "Enter your current code", comment: "App lock change prompt")
    }

    private var newPrompt: String {
        change.to == .password
            ? String(localized: "Choose a password of at least 4 characters", comment: "App lock change prompt")
            : String(localized: "Choose a \(change.to.codeLength ?? 0)-digit code", comment: "App lock change prompt. The placeholder is 4 or 6.")
    }

    private var confirmPrompt: String {
        change.to == .password
            ? String(localized: "Enter the password again", comment: "App lock change prompt")
            : String(localized: "Enter the code again", comment: "App lock change prompt")
    }

    private var mismatchPrompt: String {
        change.to == .password
            ? String(localized: "The passwords didn't match. Choose a password.", comment: "App lock change prompt")
            : String(localized: "The codes didn't match. Choose a code.", comment: "App lock change prompt")
    }

    private func currentVerified() async {
        if change.to.hasSecret {
            step = .new
        } else if change.to == .device, !(await lock.verifyDeviceOwner()) {
            done(nil)
        } else {
            done(Result { try lock.setMethod(change.to) })
        }
    }

    private func save(_ secret: String) {
        done(Result { try lock.setMethod(change.to, secret: secret) })
    }
}
