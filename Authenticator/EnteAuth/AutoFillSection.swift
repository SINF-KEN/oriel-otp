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

/// AutoFill of verification codes in settings.
struct AutoFillSection: View {

    @Environment(\.scenePhase) private var scenePhase
    private var autoFill: AutoFillAccountSync { .shared }

    var body: some View {
        Section {
            if autoFill.isEnabled == true {
                LabeledContent(String(localized: "AutoFill codes", comment: "AutoFill setting"),
                               value: String(localized: "On", comment: "AutoFill setting value"))
                Button(String(localized: "Open AutoFill settings", comment: "AutoFill setting button")) { autoFill.openSettings() }
            } else {
                Button(String(localized: "Turn on AutoFill", comment: "AutoFill setting button")) { autoFill.turnOn() }
            }
        } header: {
            Text(String(localized: "AutoFill", comment: "AutoFill settings section header"))
        } footer: {
            #if os(macOS)
            Text(String(localized: "Fill in the codes of your time-based Ente Auth accounts in Safari and other apps. Each account is suggested on the websites in its details. Codes of accounts on your YubiKey can't be filled in. If you lock the app, it is unlocked first.", comment: "Mac AutoFill settings footer"))
            #else
            Text(String(localized: "Fill in the codes of your time-based Ente Auth accounts in Safari and other apps. Each account is suggested on the websites in its details. Codes of accounts on your YubiKey can't be filled in. If you lock the app, it is unlocked first. In Settings, choose Oriel OTP for Set Up Codes In to add accounts from setup links and QR codes.", comment: "AutoFill settings footer"))
            #endif
        }
        .task { autoFill.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { autoFill.refresh() }
        }
    }
}
