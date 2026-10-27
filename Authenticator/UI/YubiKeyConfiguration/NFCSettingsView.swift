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

struct NFCSettingsView: View {
    
    @State private var model = ApplicationSettingsViewModel()
    
    var body: some View {
        Form {
            Section {
                Toggle("Initiate NFC at application start", isOn: $model.isNFCOnAppLaunchEnabled)
            } footer: {
                Text("Initiate NFC at application start will automatically read your YubiKey as soon as the app becomes active.")
            }
            Section {
                Toggle("Bypass touch requirement", isOn: $model.isBypassTouchEnabled)
            } footer: {
                Text("Accounts that require touch will need an extra NFC tap to calculate its code. Bypassing it minimizes the number of NFC taps needed.")
            }
            Section {
                Toggle("Activate NFC on OTP tag read", isOn: $model.isNFCOnOTPLaunchEnabled)
            } footer: {
                Text("Start NFC and read OATH accounts when the application has been opened by reading the OTP tag on a YubiKey.")
            }
            Section {
                Toggle("Copy Yubico OTP to clipboard", isOn: $model.isCopyOTPEnabled)
            } footer: {
                Text("Copy Yubico OTP automatically to clipboard when a YubiKey has been passively scanned using the NFC NDEF tag functionality.")
            }
        }
        .formStyle(.grouped)
        .tint(Color(.yubiBlue))
    }
}
