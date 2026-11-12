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

import Foundation
import SwiftUI

/// **Most used first**: how often each account's code was copied, so the accounts used most can come first.
///
/// Only the counts are kept, never a code. They are by account ID, which names the account, so they're kept in an
/// encrypted file like the pins, only on this device and only while the option is on: turning it off deletes them.
@MainActor @Observable final class AccountUsage {

    static let shared = AccountUsage()

    static let isEnabledKey = "SortByUse"

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.isEnabledKey)
            if !isEnabled {
                counts = [:]
                hasRead = true
                file.remove()
            }
        }
    }

    /// The number of copies by account ID.
    private(set) var counts: [String: Int] = [:]

    @ObservationIgnored private let file: EncryptedFile<[String: Int]>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var hasRead = false

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(components: "Usage", "Counts")
    }

    init(
        url: URL = defaultURL, keychain: EncryptedFileKey = KeychainFileKey(service: KeychainService.usage),
        defaults: UserDefaults = .standard
    ) {
        file = EncryptedFile(url: url, keychain: keychain)
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.isEnabledKey)
    }

    func count(for accountID: String) -> Int {
        read()
        return counts[accountID, default: 0]
    }

    /// Counts a copy of the account's code, if the option is on.
    func recordUse(of accountID: String) {
        guard isEnabled else { return }
        read()
        // Not counted until the file can be read, e.g. while the device is locked, so nothing saved is replaced.
        guard hasRead else { return }
        counts[accountID, default: 0] += 1
        try? file.save(counts)
    }

    /// The accounts, the most used first while the option is on. Accounts used as often keep their order.
    func ordered<Item>(_ items: [Item], id: (Item) -> String) -> [Item] {
        guard isEnabled else { return items }
        read()
        guard !counts.isEmpty else { return items }
        return items.enumerated()
            .sorted { lhs, rhs in
                let left = counts[id(lhs.element), default: 0]
                let right = counts[id(rhs.element), default: 0]
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func read() {
        guard !hasRead, isEnabled else { return }
        do {
            counts = try file.load() ?? [:]
            hasRead = true
        } catch EncryptedFileError.unavailable {
            // Read again later, once the device is unlocked.
        } catch {
            // A file that can't be decrypted, e.g. after a restore: start counting again.
            counts = [:]
            hasRead = true
        }
    }
}

/// **Most used first**, in Configuration on iOS and the General settings on the Mac.
struct AccountOrderSection: View {

    @Bindable private var usage = AccountUsage.shared
    @State private var showsCheckup = false

    var body: some View {
        Section {
            Toggle(String(localized: "Most used first", comment: "Account list setting"), isOn: $usage.isEnabled)
                .accessibilityIdentifier("settings.most-used-first")
            Button(String(localized: "Account Check-Up…", comment: "Account list setting button")) { showsCheckup = true }
                .accessibilityIdentifier("settings.account-checkup")
                .sheet(isPresented: $showsCheckup) {
                    AccountCheckupView()
                        #if os(macOS)
                            .frame(minWidth: 480, minHeight: 420)
                        #endif
                }
        } header: {
            Text(String(localized: "Account List", comment: "Settings section"))
        } footer: {
            Text(
                String(
                    localized:
                        "Puts the accounts whose codes you copy most at the top of each section. Only how often each code is copied is kept, on this device; turning this off deletes it.",
                    comment: "Account list settings footer"))
        }
    }
}
