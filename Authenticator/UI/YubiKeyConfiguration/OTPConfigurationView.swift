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
import OSLog
import YubiKit

/* Shows whether OTP is enabled on the YubiKey over the transport it is connected with, and lets the user toggle it.
 For YubiKey NFC it is showing website NFC tag notification on YubiKey tap against the device.
 For YubiKey 5Ci it is printing key string in text fields on YubiKey touch.
 */
struct OTPConfigurationView: View {
    
    @Environment(\.dismiss) private var dismiss
    @State private var model = ManagementViewModel()
    @State private var isEnabled = true
    @State private var isToggleDisabled = false
    @State private var description = String(localized: "If enabled, scanning the YubiKey will display a notification. Tapping the notification will reveal the One-Time Password.")
    @State private var alert: AlertMessage? = nil
    
    struct AlertMessage {
        let title: String
        let message: String?
    }
    
    var body: some View {
        SettingsView(image: Image(systemName: "ellipsis.rectangle"), imageColor: Color(.systemBlue)) {
            Text("One-Time Password").font(.title2).bold()
                .accessibilityAddTraits(.isHeader)
            Text(description)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        } buttons: {
            Toggle("One-Time Password", isOn: Binding(get: { isEnabled }, set: { enabled in
                isEnabled = enabled
                setOTPEnabled(enabled)
            }))
            .tint(Color(.yubiBlue))
            .disabled(isToggleDisabled)
        }
        .alert(alert?.title ?? "", isPresented: .constant(alert != nil), presenting: alert) { _ in
            Button(String(localized: "OK")) {
                alert = nil
                dismiss()
            }
        } message: { alert in
            if let message = alert.message {
                Text(message)
            }
        }
        .task {
            model.didDisconnect { isNFC, error in
                if error == nil && isNFC { return }

                // Handle disconnect caused by key being removed, or by the user cancelling NFC, NFC timing out
                // or the NFC sheet being closed with an error message
                if error == nil || isNFC {
                    dismiss()
                    return
                }
                alert = AlertMessage(title: error.map { LocalizedErrorWrapper(error: $0).localizedDescription } ?? String(localized: "Unknown error"), message: nil)
            }
            do {
                let configuration = try await model.isOTPEnabled()
                isEnabled = configuration.isEnabled
                isToggleDisabled = !configuration.isSupported || configuration.isConfigurationLocked
                if isToggleDisabled {
                    description = String(localized: "This setting is not supported on your YubiKey.")
                } else if configuration.transport == .usb {
                    description = String(localized: "If enabled, the YubiKey will output a One-Time Password when touched. Since the YubiKey is detected as a keyboard the built in keyboard in iOS will be disabled.")
                } else if configuration.transport == .nfc {
                    description = String(localized: "If enabled, scanning the YubiKey will display a notification. Tapping the notification will reveal the One-Time Password.")
                }
            } catch is CancellationError {
                return
            } catch {
                alert = AlertMessage(title: String(localized: "Error", comment: "OTP settings read error alert title"), message: LocalizedErrorWrapper(error: error).localizedDescription)
            }
        }
    }
    
    private func setOTPEnabled(_ enabled: Bool) {
        Task {
            do {
                try await model.setOTPEnabled(enabled: enabled)
            } catch {
                alert = AlertMessage(title: String(localized: "Error writing configuration", comment: "OTP settings error alert title"), message: LocalizedErrorWrapper(error: error).localizedDescription)
            }
        }
    }
}
