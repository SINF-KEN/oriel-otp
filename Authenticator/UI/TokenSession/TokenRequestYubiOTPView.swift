//
//  TokenRequestYubiOTPView.swift
//  Authenticator
//
//  Created by Jens Utbult on 2023-12-11.
//  Copyright © 2023 Yubico. All rights reserved.
//  Copyright © 2026 Kenzi Voyer.
//

import SwiftUI

// Shown over the token request when the inserted USB-C YubiKey has Yubico OTP enabled, since it then appears
// as an external keyboard and hides the on-screen keyboard needed to enter the PIN.
struct TokenRequestYubiOTPView: View {
    
    let model: TokenRequestViewModel
    
    @Environment(\.dismiss) private var dismiss
    @State private var isOTPDisabled = false
    @State private var error: Error? = nil
    
    var body: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Yubico OTP enabled").font(.title).bold()
                    Text("This YubiKey has Yubico OTP enabled which makes it appear as an external keyboard to the iPhone. Unfortunately this causes problem with the normal on-screen keyboard.")
                    Spacer().frame(height: 15)
                    Button {
                        disableOTP()
                    } label: {
                        // YubiBlue is a light green in dark mode, so the label takes the background color to keep its contrast.
                        Text("Disable Yubico OTP (recommended)")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(Color(.systemBackground))
                    }
                    .prominentActionButtonStyle()
                    Text("Disabling Yubico OTP will prevent the YubiKey from appearing as a keyboard. If you don’t use Yubico OTP this is the recommended solution. This can be re-enabled from the settings page.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer().frame(height: 25)
                    Button {
                        ignoreThisKey()
                    } label: {
                        Text("Continue with limited usability")
                            .frame(maxWidth: .infinity)
                    }
                    .secondaryActionButtonStyle()
                    Text("While the YubiKey is inserted the on-screen keyboard will not appear. To show the keyboard you will have to remove the YubiKey and then re-insert it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .opacity(isOTPDisabled ? 0 : 1)
                VStack(alignment: .leading, spacing: 15) {
                    Text("Yubico OTP has been disabled").font(.title).bold()
                    Text("Remove and re-insert your YubiKey")
                }
                .opacity(isOTPDisabled ? 1 : 0)
            }
            .padding(30)
            .accentColor(Color(UIColor.yubiBlue))
        }
        .alert(String(localized: "Error reading YubiKey", comment: "PIV extension error title"), isPresented: .constant(error != nil), presenting: error) { _ in
            Button(String(localized: "OK")) {
                error = nil
                dismiss()
            }
        } message: { error in
            Text("\(LocalizedErrorWrapper(error: error).localizedDescription)\n\n\(String(localized: "Remove and reinsert your YubiKey", comment: "PIV extension error reinsert key")).")
        }
        .task {
            await model.waitForKeyRemoval()
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
    
    private func disableOTP() {
        Task {
            do {
                try await model.disableOTP()
                withAnimation(.easeInOut(duration: 0.5)) {
                    isOTPDisabled = true
                }
            } catch {
                self.error = error
            }
        }
    }
    
    private func ignoreThisKey() {
        Task {
            do {
                try await model.ignoreThisKey()
                dismiss()
            } catch {
                self.error = error
            }
        }
    }
}
