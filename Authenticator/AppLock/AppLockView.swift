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

/// The screen shown over the app while it's locked.
struct AppLockView: View {

    private var lock: AppLock { .shared }
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 40

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            Image(systemName: "lock.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "Oriel OTP is locked", comment: "App lock screen title"))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if lock.isUnavailable {
                Text(String(localized: "Unlock your device to open Oriel OTP.", comment: "App lock screen before the device was first unlocked"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if lock.method == .device {
                Button {
                    Task { await lock.unlockWithDeviceOwner() }
                } label: {
                    Text(String(localized: "Unlock with \(AppLock.deviceOwnerTitle)", comment: "App lock screen button. The placeholder is Face ID, Touch ID or Device passcode."))
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(lock.isAuthenticating)
            } else {
                AppLockSecretEntry(method: lock.method,
                                   prompt: lock.method == .password
                                       ? String(localized: "Enter your password", comment: "App lock screen prompt")
                                       : String(localized: "Enter your code", comment: "App lock screen prompt")) {
                    lock.unlock(with: $0)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .scrollsWhenTooTall()
        .background(Color(.systemBackground))
    }
}

/// Asks for a code or password: to unlock, to check the current one before it's changed, or to choose a new one.
/// `submit` returns whether it was accepted; a wrong one shakes and clears the entry.
struct AppLockSecretEntry: View {

    let method: AppLockMethod
    let prompt: String
    var checksRetryDate = true
    let submit: (String) -> Bool

    private var lock: AppLock { .shared }

    /// Announced for VoiceOver, which can't see the dots shake.
    static let wrongCodeMessage = String(localized: "Wrong code. Try again.", comment: "VoiceOver announcement after a wrong app lock code")
    static let wrongPasswordMessage = String(localized: "Wrong password. Try again.", comment: "VoiceOver announcement after a wrong app lock password")

    var body: some View {
        VStack(spacing: 20) {
            Text(prompt)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if checksRetryDate, let retryDate = lock.retryDate {
                Text("Too many attempts. Try again in \(Text(timerInterval: Date.now...retryDate, countsDown: true)).", comment: "App lock wait after wrong codes. The placeholder counts down, e.g. 0:30.")
                    .monospacedDigit()
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .task(id: retryDate) {
                        try? await Task.sleep(for: .seconds(max(0, retryDate.timeIntervalSinceNow) + 0.2))
                        lock.updateRetryDate()
                    }
            } else if let length = method.codeLength {
                AppLockCodePad(length: length, submit: submit)
            } else {
                AppLockPasswordField(submit: submit)
            }
        }
        .frame(maxWidth: 360)
    }
}

/// Dots for the digits entered and a number pad. The digits can be typed too, e.g. on the Mac.
private struct AppLockCodePad: View {

    let length: Int
    let submit: (String) -> Bool

    @State private var code = ""
    @State private var wrongAttempts = 0
    @FocusState private var isFocused: Bool
    // The keys grow with the text, up to a size where three still fit across the smallest iPhone. Beyond that the
    // digits stop growing and show in the Large Content Viewer when held.
    @ScaledMetric(relativeTo: .title) private var scaledKeySize: CGFloat = 72
    private var keySize: CGFloat { min(scaledKeySize, 96) }

    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 32) {
            HStack(spacing: 18) {
                ForEach(0..<length, id: \.self) { index in
                    Circle()
                        .fill(index < code.count ? Color.primary : Color.clear)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: 1.5))
                        .frame(width: 14, height: 14)
                }
            }
            .modifier(Shake(animatableData: CGFloat(wrongAttempts)))
            .accessibilityElement()
            .accessibilityLabel(String(localized: "\(code.count) of \(length) digits entered", comment: "App lock code dots for VoiceOver"))

            Grid(horizontalSpacing: 24, verticalSpacing: 16) {
                ForEach(rows, id: \.self) { row in
                    GridRow {
                        ForEach(row, id: \.self) { digit in key(digit) }
                    }
                }
                GridRow {
                    Color.clear.frame(width: keySize, height: keySize)
                    key("0")
                    Button(action: deleteDigit) {
                        Image(systemName: "delete.backward")
                            .font(.title2)
                            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                            .frame(width: keySize, height: keySize)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityShowsLargeContentViewer()
                    .accessibilityLabel(String(localized: "Delete", comment: "App lock number pad delete button"))
                    .accessibilityInputLabels([String(localized: "Delete", comment: "App lock number pad delete button"),
                                               String(localized: "Backspace", comment: "Voice Control name for the app lock delete key")])
                    .opacity(code.isEmpty ? 0 : 1)
                    .disabled(code.isEmpty)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            add(press.characters)
            return .handled
        }
        .onKeyPress(.delete) {
            deleteDigit()
            return .handled
        }
    }

    private func key(_ digit: String) -> some View {
        Button {
            add(digit)
        } label: {
            Text(verbatim: digit)
                .font(.title.weight(.regular))
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .frame(width: keySize, height: keySize)
                .background(Color.secondary.opacity(0.18), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityShowsLargeContentViewer { Text(verbatim: digit) }
        // Typed as soon as the finger lifts, like the system's passcode keys.
        .accessibilityAddTraits(.isKeyboardKey)
    }

    private func add(_ digits: String) {
        guard code.count < length else { return }
        code += digits.filter(\.isASCII).filter(\.isNumber).prefix(length - code.count)
        guard code.count == length else { return }
        let entered = code
        // Shown full for a moment, so the last dot doesn't go straight back to empty.
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            if !submit(entered) {
                Platform.notify(.error)
                AccessibilityNotification.Announcement(AppLockSecretEntry.wrongCodeMessage).post()
                withAnimation(.default) { wrongAttempts += 1 }
            }
            code = ""
        }
    }

    private func deleteDigit() {
        guard !code.isEmpty else { return }
        code.removeLast()
    }
}

private struct AppLockPasswordField: View {

    let submit: (String) -> Bool

    @State private var password = ""
    @State private var wrongAttempts = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            SecureField(String(localized: "Password", comment: "App lock password field"), text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(enter)
                .modifier(Shake(animatableData: CGFloat(wrongAttempts)))
            Button(String(localized: "Continue", comment: "App lock password button"), action: enter)
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty)
        }
        .onAppear { isFocused = true }
    }

    private func enter() {
        guard !password.isEmpty else { return }
        if !submit(password) {
            Platform.notify(.error)
            AccessibilityNotification.Announcement(AppLockSecretEntry.wrongPasswordMessage).post()
            withAnimation(.default) { wrongAttempts += 1 }
        }
        password = ""
    }
}

/// Shakes sideways each time `animatableData` goes up by one.
private struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}

#if os(macOS)
extension View {
    /// Covers the view with the lock screen while the app is locked: the Mac's windows, its sheets and the menu bar.
    func appLockCover() -> some View {
        modifier(AppLockCover())
    }
}

private struct AppLockCover: ViewModifier {
    func body(content: Content) -> some View {
        let isLocked = AppLock.shared.isLocked
        content
            .disabled(isLocked)
            .accessibilityHidden(isLocked)
            .overlay {
                if isLocked {
                    AppLockView()
                }
            }
    }
}
#else
extension View {
    /// Nothing on iOS, where `AppLockWindow` covers the whole scene.
    func appLockCover() -> some View { self }
}

/// Shows the lock screen in a window of its own above the app's, so it covers the sheets and alerts too.
@MainActor final class AppLockWindow {

    private let window: UIWindow

    init(windowScene: UIWindowScene) {
        window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: AppLockView())
        // VoiceOver stays on the lock screen and can't reach the app's window behind it.
        window.rootViewController?.view.accessibilityViewIsModal = true
        update(animated: false)
        observe()
    }

    /// Shows or hides the window for the lock. Called directly when the app goes to the background, so the lock
    /// screen is there before the app switcher takes its snapshot.
    func update(animated: Bool) {
        if AppLock.shared.isLocked {
            let wasHidden = window.isHidden
            window.alpha = 1
            window.isHidden = false
            window.makeKey()
            // Moves VoiceOver to the lock screen, so it doesn't stay on the app behind it.
            if wasHidden {
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
        } else if !window.isHidden {
            let window = window
            UIView.animate(withDuration: animated ? 0.2 : 0) {
                window.alpha = 0
            } completion: { _ in
                guard !AppLock.shared.isLocked else { return }
                window.isHidden = true
                window.windowScene?.windows.first { $0 !== window && !$0.isHidden }?.makeKey()
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
        }
    }

    private func observe() {
        withObservationTracking {
            _ = AppLock.shared.isLocked
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update(animated: true)
                self?.observe()
            }
        }
    }
}
#endif
