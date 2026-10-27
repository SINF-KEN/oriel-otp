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
    @State private var overlayOpacity = 0.0
    @State private var checkmarkOpacity = 0.0
    @State private var arrowHintOpacity = 0.0
    @State private var arrowHintScale = 1.0
    @State private var presentYubiOTP = false
    @State private var error: TokenRequestViewModel.TokenError? = nil
    
    init(userInfo: [AnyHashable: Any]?) {
        self.userInfo = userInfo
    }
    
    var body: some View {
        GeometryReader { geometry in
            // We need to tighten the vertical spacing to make room for the keyboard on smaller screens
            let isCompact = geometry.size.width <= 320
            VStack(spacing: 0) {
                Text("Unlock YubiKey")
                    .font(.system(size: 22))
                    .padding(.top, isCompact ? 40 : 70)
                
                HStack(spacing: 0) {
                    Image("InsertKey")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 8)
                        .padding(.leading, 3)
                        .frame(width: 35, alignment: .leading)
                        .accessibilityHidden(true)
                    Text(accessoryText)
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                }
                .opacity(accessoryOpacity)
                .padding(.top, isCompact ? 35 : 40)
                .padding(.horizontal, 30)
                
                Group {
                    HStack(spacing: 0) {
                        separator
                        Text("or")
                            .font(.system(size: 16))
                            .foregroundStyle(Color(.separator))
                            .frame(minWidth: 35)
                        separator
                    }
                    .frame(height: 30)
                    .padding(.top, isCompact ? 5 : 15)
                    .padding(.horizontal, 20)
                    
                    HStack(spacing: 0) {
                        Image(systemName: "dot.radiowaves.forward")
                            .frame(width: 16)
                            .frame(width: 35, alignment: .leading)
                            .accessibilityHidden(true)
                        Text("Enter the PIN, then tap a NFC enabled YubiKey against the iPhone to access the certificate.")
                            .font(.system(size: 16))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, isCompact ? 5 : 15)
                    .padding(.horizontal, 30)
                }
                .opacity(nfcOpacity)
                
                VStack(spacing: 0) {
                    SecureField(String(localized: "Smart card (PIV) PIN"), text: $pin)
                        .font(.system(size: 18))
                        .multilineTextAlignment(.center)
                        .keyboardType(.numbersAndPunctuation)
                        .textContentType(.oneTimeCode)
                        .submitLabel(.go)
                        .focused($isPINFocused)
                        .onSubmit(submitPIN)
                        .onChange(of: pin) { _, pin in
                            if pin.count > 8 { self.pin = String(pin.prefix(8)) }
                        }
                        .frame(minWidth: 170, maxHeight: .infinity)
                    separator
                }
                .frame(height: 50)
                .padding(.top, isCompact ? 35 : 60)
                .padding(.horizontal, 20)
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
        .overlay {
            completedOverlay
        }
        .alert(error?.message.title ?? "", isPresented: .constant(error != nil), presenting: error) { _ in
            Button(String(localized: "Ok")) { error = nil }
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
    
    private var separator: some View {
        Color(.separator).frame(height: 1)
    }
    
    private var completedOverlay: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground)
            VStack(spacing: 17) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(Color(.color11))
                    .accessibilityHidden(true)
                Text("Tap the back button to continue")
                    .font(.system(size: 16))
            }
            .opacity(checkmarkOpacity)
            .frame(maxWidth: .infinity)
            .padding(.top, 240)
            Image(systemName: "arrow.turn.left.up")
                .font(.system(size: 22))
                .scaleEffect(arrowHintScale)
                .opacity(arrowHintOpacity)
                .padding(.leading, 18)
                .padding(.top, 53)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
        .opacity(overlayOpacity)
        .allowsHitTesting(overlayOpacity > 0)
    }
    
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
                overlayOpacity = 1
            }
            withAnimation(.easeInOut(duration: 2)) {
                checkmarkOpacity = 1
            }
            isPINFocused = false
            await animateHint()
        }
    }
    
    // Pulses the arrow pointing at the system back button in the status bar a few times.
    private func animateHint() async {
        try? await Task.sleep(for: .seconds(4))
        for step in 0..<7 {
            let isExpanded = step.isMultiple(of: 2)
            withAnimation(.easeInOut(duration: 1)) {
                arrowHintOpacity = isExpanded ? 1 : 0
                arrowHintScale = isExpanded ? 1.8 : 1
            }
            try? await Task.sleep(for: .seconds(1))
        }
        withAnimation(.easeInOut(duration: 0.6)) {
            arrowHintOpacity = 1
            arrowHintScale = 1
        }
    }
}
