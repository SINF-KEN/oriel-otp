/*
 * Copyright (C) 2022 Yubico.
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


#if os(iOS)
import SwiftUI

struct TokenRequestView: View {
    
    let userInfo: [AnyHashable: Any]?
    
    @Environment(\.dismiss) private var dismiss
    @State private var model = TokenRequestViewModel()
    @State private var pin = ""
    @FocusState private var isPINFocused: Bool
    
    @State private var accessoryText = String(localized: "Insert a YubiKey and enter its PIN to access the certificate.")
    @State private var accessoryOpacity = 1.0
    @State private var nfcOpacity = DeviceCapabilities.supportsNFC ? 1.0 : 0.0
    @State private var isCompleted = false
    @State private var presentYubiOTP = false
    @State private var error: TokenRequestViewModel.TokenError? = nil

    @ScaledMetric(relativeTo: .body) private var iconColumnWidth: CGFloat = 35
    
    init(userInfo: [AnyHashable: Any]?) {
        self.userInfo = userInfo
    }
    
    var body: some View {
        NavigationStack {
            // Scrolls on short displays, such as the outer display of iPhone Duo with the keyboard up.
            ScrollView {
                if isCompleted {
                    completedView
                } else {
                    unlockForm
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Keeps the PIN field and the instructions in one half of a half-folded iPhone Duo.
            .avoidingReservedRegions()
            .navigationTitle(String(localized: "Unlock YubiKey"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isCompleted {
                    ToolbarItem(placement: .confirmationAction) {
                        ConfirmButton(String(localized: "Done", comment: "PIV extension close button")) { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        CancelButton {
                            model.cancel()
                            dismiss()
                        }
                    }
                }
            }
        }
        .alert(error?.message.title ?? "", isPresented: .constant(error != nil), presenting: error) { _ in
            Button(String(localized: "OK")) { error = nil }
        } message: { error in
            if let text = error.message.text {
                Text(text)
            }
        }
        .fullScreenCover(isPresented: $presentYubiOTP) {
            TokenRequestYubiOTPView(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            model.cancel()
            dismiss()
        }
        .task {
            isPINFocused = true
            let yubiOTPEnabled = await model.isYubiOTPEnabledOverUSBC()
            guard !Task.isCancelled else { return }
            if yubiOTPEnabled == true {
                presentYubiOTP = true
            }
            model.isWiredKeyConnected { connected in
                wiredKeyDidChange(connected: connected)
            }
        }
        .onDisappear {
            model.stop()
        }
    }

    private var unlockForm: some View {
        VStack(spacing: 20) {
            HStack(spacing: 0) {
                Image("InsertKey")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 8)
                    .padding(.leading, 3)
                    .frame(width: iconColumnWidth, alignment: .leading)
                    .accessibilityHidden(true)
                Text(accessoryText)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }
            .opacity(accessoryOpacity)

            Group {
                HStack(spacing: 0) {
                    separator
                    Text("or")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: iconColumnWidth)
                    separator
                }

                HStack(spacing: 0) {
                    Image(systemName: "dot.radiowaves.forward")
                        .frame(width: iconColumnWidth, alignment: .leading)
                        .accessibilityHidden(true)
                    Text("Enter the PIN, then tap a NFC enabled YubiKey against the iPhone to access the certificate.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .opacity(nfcOpacity)

            VStack(spacing: 8) {
                SecureField(String(localized: "Smart card (PIV) PIN"), text: $pin)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .keyboardType(.numbersAndPunctuation)
                    .textContentType(.oneTimeCode)
                    .submitLabel(.go)
                    .focused($isPINFocused)
                    .onSubmit(submitPIN)
                    .onChange(of: pin) { _, pin in
                        if pin.count > 8 { self.pin = String(pin.prefix(8)) }
                    }
                    .frame(minHeight: 44)
                separator
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        // Keeps the lines readable on wide displays.
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity)
    }

    private var separator: some View {
        Color(.separator).frame(height: 1)
    }
    
    private var completedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 64))
                .foregroundStyle(Color(.color11))
                .accessibilityHidden(true)
            Text(Self.completedMessage)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private static let completedMessage = String(localized: "Go back to the app that asked for the certificate.", comment: "PIV extension completed message")
    
    private func wiredKeyDidChange(connected: Bool) {
        if !connected && nfcOpacity == 1 { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            nfcOpacity = 0
            accessoryOpacity = 0
        } completion: {
            withAnimation(.easeInOut(duration: 0.2)) {
                accessoryOpacity = 1
                if connected {
                    accessoryText = String(localized: "Enter the PIN to access the certificate.", comment: "PIV extension enter PIN message")
                } else {
                    accessoryText = String(localized: "Insert a YubiKey and enter its PIN to access the certificate.")
                    if DeviceCapabilities.supportsNFC {
                        nfcOpacity = 1
                    }
                }
            }
        }
    }
    
    private func submitPIN() {
        guard let userInfo else { dismiss(); return }
        guard !pin.isEmpty else { return }
        let password = pin
        Task {
            do throws(TokenRequestViewModel.TokenError) {
                try await model.handleTokenRequest(userInfo, password: password)
            } catch .cancelled {
                return
            } catch {
                pin = ""
                switch error {
                case .alreadyHandled:
                    return
                default:
                    self.error = error
                }
                return
            }
            withAnimation(.easeInOut(duration: 0.5)) {
                isCompleted = true
            }
            isPINFocused = false
            AccessibilityNotification.Announcement(Self.completedMessage).post()
        }
    }
}
#endif
