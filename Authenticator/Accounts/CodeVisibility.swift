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

/// Whether codes are shown, for sharing the screen or using the app in public. With **Hide codes** on, a code shows
/// as dots until it's tapped, which also copies it, and for a few seconds after.
@MainActor @Observable final class CodeVisibility {

    static let shared = CodeVisibility()

    static let hidesCodesKey = "HideCodes"
    /// How long a tapped code stays shown.
    static let revealDuration = Duration.seconds(10)

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let protection: ProtectedAccounts

    var hidesCodes: Bool {
        didSet {
            guard hidesCodes != oldValue else { return }
            defaults.set(hidesCodes, forKey: Self.hidesCodesKey)
            revealed = []
        }
    }

    /// The accounts whose code was tapped, by account id.
    private(set) var revealed: Set<String> = []
    @ObservationIgnored private var hideTasks: [String: Task<Void, Never>] = [:]

    init(defaults: UserDefaults = .standard, protection: ProtectedAccounts = .shared) {
        self.defaults = defaults
        self.protection = protection
        hidesCodes = defaults.bool(forKey: Self.hidesCodesKey)
    }

    /// A protected account's code only shows for a few seconds after Face ID or Touch ID, see `ProtectedAccounts`.
    func isShown(_ accountID: String) -> Bool {
        revealed.contains(accountID) || (!hidesCodes && !protection.isProtected(accountID))
    }

    /// Shows the code for a few seconds, if codes are hidden or the account is protected.
    func reveal(_ accountID: String) {
        guard hidesCodes || protection.isProtected(accountID) else { return }
        revealed.insert(accountID)
        hideTasks[accountID]?.cancel()
        hideTasks[accountID] = Task { [weak self] in
            try? await Task.sleep(for: Self.revealDuration)
            guard !Task.isCancelled else { return }
            self?.revealed.remove(accountID)
            self?.hideTasks[accountID] = nil
        }
    }

    /// Hides the codes that were tapped, e.g. when the app goes to the background.
    func hideAll() {
        hideTasks.values.forEach { $0.cancel() }
        hideTasks = [:]
        if !revealed.isEmpty {
            revealed = []
        }
    }

    /// What a hidden code shows: a dot for each digit, in the code's two halves.
    static func placeholder(digits: Int) -> String {
        let digits = max(digits, 5)
        let dots = String(repeating: "•", count: digits)
        guard digits > 5 else { return dots }
        var placeholder = dots
        placeholder.insert(" ", at: placeholder.index(placeholder.startIndex, offsetBy: digits / 2))
        return placeholder
    }
}

extension Account {
    /// Whether the code may be shown, rather than dots. Codes the app hasn't got yet show as stars either way.
    @MainActor var isCodeShown: Bool {
        CodeVisibility.shared.isShown(accountId)
    }

    /// The next code, while the current one is about to change, unless codes are hidden. See `formattedNextCode`.
    @MainActor var displayedNextCode: String? {
        isCodeShown ? formattedNextCode : nil
    }

    /// The code as the list and the details show it: the code, dots while codes are hidden, or nil while there's none.
    @MainActor var displayedCode: String? {
        guard let formattedCode else { return nil }
        guard isCodeShown else {
            return CodeVisibility.placeholder(digits: formattedCode.filter { !$0.isWhitespace }.count)
        }
        return formattedCode
    }
}

/// **Hide codes** and **Show in Spotlight**, in Configuration on iOS and the General settings on the Mac.
struct PrivacySection: View {

    @Bindable private var visibility = CodeVisibility.shared
    @Bindable private var spotlight = AccountSpotlight.shared

    var body: some View {
        Section {
            Toggle(String(localized: "Hide codes", comment: "Privacy setting"), isOn: $visibility.hidesCodes)
                .accessibilityIdentifier("settings.hide-codes")
            Toggle(String(localized: "Show accounts in Spotlight", comment: "Privacy setting"), isOn: $spotlight.isEnabled)
                .accessibilityIdentifier("settings.spotlight")
        } header: {
            Text(String(localized: "Privacy", comment: "Settings section"))
        } footer: {
            Text(
                String(
                    localized:
                        "Hidden codes show as dots until you tap one, which also copies it. In Spotlight, the names of your Ente Auth accounts and the accounts on this device can be searched for; their codes and secrets are never added.",
                    comment: "Privacy settings footer"))
        }
    }
}
