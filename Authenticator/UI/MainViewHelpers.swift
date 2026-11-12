/*
 * Copyright (C) Yubico.
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

#if os(macOS)
    /// Opens an account over the list, in the main window's single column.
    struct OpenAccountAction: Equatable {
        @Binding var path: [String]

        func callAsFunction(_ accountID: String) {
            path = [accountID]
        }

        // There's only the one path, so a new action doesn't need to update the rows.
        static func == (lhs: Self, rhs: Self) -> Bool { true }
    }

    extension EnvironmentValues {
        @Entry var opensAccount: OpenAccountAction?
    }
#endif

/// A row that opens its account. A link shows it in the split view's details, but in a stack a link also opens whatever
/// the arrow keys select, so there a click opens it instead.
struct AccountRowLink<Label: View>: View {
    #if os(macOS)
        @Environment(\.opensAccount) private var opensAccount
    #endif
    let accountID: String
    @ViewBuilder let label: Label

    var body: some View {
        #if os(macOS)
            if let opensAccount {
                label
                    .tag(accountID)
                    .onTapGesture { opensAccount(accountID) }
                    // A button to VoiceOver and Voice Control, as the link is in the split view.
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { opensAccount(accountID) }
            } else {
                link
            }
        #else
            link
        #endif
    }

    private var link: some View {
        NavigationLink(value: accountID) { label }
    }
}

extension View {
    func alertOrConfirmationDialog<A>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A) -> some View
    where A: View {
        modifier(AlertOrConfirmationDialog(title: title, isPresented: isPresented, actions: actions()))
    }
}

// Shows an alert in regular width and a confirmation dialog in compact width, so the presentation follows the
// space the scene has (iPad, iPhone Duo inner display, Split View) rather than the device type.
private struct AlertOrConfirmationDialog<A: View>: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let title: String
    @Binding var isPresented: Bool
    let actions: A

    // Read by the bindings when a presentation writes back, which can happen after the size class has changed.
    private final class SizeClassBox {
        var isRegular = false
    }
    @State private var sizeClass = SizeClassBox()

    // Both presentations stay attached rather than switching between them with if/else, which would give the content
    // a new identity whenever the size class changes, e.g. when an iPhone Duo opens, and reset its state and sheets.
    func body(content: Content) -> some View {
        let isRegular = horizontalSizeClass == .regular
        sizeClass.isRegular = isRegular
        return
            content
            .alert(title, isPresented: presentation(asAlert: true, isRegular: isRegular)) { actions }
            .confirmationDialog(title, isPresented: presentation(asAlert: false, isRegular: isRegular), titleVisibility: .visible) {
                actions
            }
    }

    // When the size class changes while presented, the outgoing presentation is dismissed and the other one shown.
    // Only the presentation that matches the current size class may dismiss, so the outgoing one can't clear isPresented.
    private func presentation(asAlert: Bool, isRegular: Bool) -> Binding<Bool> {
        let sizeClass = self.sizeClass
        let isPresented = $isPresented
        return Binding(
            get: { isPresented.wrappedValue && isRegular == asAlert },
            set: { newValue in
                guard newValue || sizeClass.isRegular == asAlert else { return }
                isPresented.wrappedValue = newValue
            }
        )
    }
}

extension String {
    /// How to use a YubiKey, for the empty list, where it's one option among others.
    static func optionalYubiKey(isVoiceOverEnabled: Bool) -> String {
        guard DeviceCapabilities.supportsNFC else {
            return String(
                localized: "Have a YubiKey? Insert it to see its accounts.", comment: "Empty account list on a device without NFC")
        }
        return isVoiceOverEnabled
            ? String(
                localized: "Have a YubiKey? Insert it or scan it over NFC to see its accounts.",
                comment: "Empty account list, with VoiceOver on")
            : String(localized: "Have a YubiKey? Insert it or pull down to activate NFC.", comment: "Empty account list")
    }

    /// What to do to see the YubiKey's accounts, as one sentence so it can be translated as a whole.
    static func insertYubiKey(isVoiceOverEnabled: Bool) -> String {
        guard DeviceCapabilities.supportsNFC else { return String(localized: "Insert YubiKey") }
        // Pulling down to refresh is hard to find with VoiceOver, which has the Scan NFC YubiKey button instead.
        return isVoiceOverEnabled
            ? String(
                localized: "Insert YubiKey or scan a NFC YubiKey",
                comment: "Account list and Configuration without a YubiKey, with VoiceOver on")
            : String(localized: "Insert YubiKey or pull down to activate NFC", comment: "Account list and Configuration without a YubiKey")
    }
}
