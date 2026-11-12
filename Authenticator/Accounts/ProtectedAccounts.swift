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

/// Accounts whose code is only shown or copied after Face ID, Touch ID or the device passcode, chosen one by one for
/// the accounts that matter most. Their codes show as dots, like with **Hide codes**, until checked.
///
/// Kept by account ID, which names the account, in an encrypted file like the pins.
@MainActor @Observable final class ProtectedAccounts {

    static let shared = ProtectedAccounts()

    /// The protected accounts' IDs.
    private(set) var accountIDs: Set<String> = []

    @ObservationIgnored private let file: EncryptedFile<Set<String>>
    @ObservationIgnored private var hasRead = false
    /// Replaced in the tests.
    @ObservationIgnored var authenticate: @Sendable (String) async -> Bool = { reason in
        await AppLock.evaluateDeviceOwner(reason: reason) != nil
    }

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(components: "ProtectedAccounts", "Accounts")
    }

    init(url: URL = defaultURL, keychain: EncryptedFileKey = KeychainFileKey(service: KeychainService.protectedAccounts)) {
        file = EncryptedFile(url: url, keychain: keychain)
    }

    /// Whether the device can check its owner, which protecting an account needs.
    var isAvailable: Bool {
        AppLock.canUseDeviceOwner
    }

    func isProtected(_ accountID: String) -> Bool {
        read()
        return accountIDs.contains(accountID)
    }

    /// Protecting an account, or no longer protecting it, asks for Face ID, Touch ID or the passcode first, so someone
    /// holding an unlocked device can't simply turn it off. Returns whether it changed.
    @discardableResult func setProtected(_ isProtected: Bool, _ accountID: String, title: String) async -> Bool {
        read()
        guard hasRead, isProtected != accountIDs.contains(accountID) else { return false }
        let reason =
            isProtected
            ? String(
                localized: "Ask for this before showing or copying the code for \(title).",
                comment: "Face ID or Touch ID prompt when protecting an account. The placeholder is the account's name.")
            : String(
                localized: "Stop asking for this before showing or copying the code for \(title).",
                comment: "Face ID or Touch ID prompt when no longer protecting an account. The placeholder is the account's name.")
        guard await authenticate(reason) else { return false }
        var ids = accountIDs
        if isProtected {
            ids.insert(accountID)
        } else {
            ids.remove(accountID)
        }
        do {
            if ids.isEmpty {
                file.remove()
            } else {
                try file.save(ids)
            }
        } catch {
            return false
        }
        accountIDs = ids
        return true
    }

    /// Asks for Face ID, Touch ID or the passcode before the code of a protected account is shown or copied. True
    /// right away for other accounts.
    func unlock(_ accountID: String, title: String) async -> Bool {
        guard isProtected(accountID) else { return true }
        let reason = String(
            localized: "Show and copy the code for \(title).",
            comment: "Face ID or Touch ID prompt before copying a protected account's code. The placeholder is the account's name.")
        return await authenticate(reason)
    }

    /// Unreadable while the device is locked, when no code is shown anyway. A file that can't be decrypted, e.g. after
    /// a restore, counts as none.
    private func read() {
        guard !hasRead else { return }
        do {
            accountIDs = try file.load() ?? []
            hasRead = true
        } catch EncryptedFileError.unavailable {
            return
        } catch {
            accountIDs = []
            hasRead = true
        }
    }
}

/// Protects the account's code with Face ID, Touch ID or the passcode, or stops protecting it.
struct ProtectCodeButton: View {
    let account: Account

    private var protection: ProtectedAccounts { .shared }

    var body: some View {
        if protection.isAvailable {
            let isProtected = protection.isProtected(account.accountId)
            Button {
                Task { await protection.setProtected(!isProtected, account.accountId, title: account.title) }
            } label: {
                if isProtected {
                    Label(
                        String(
                            localized: "Stop Asking for \(AppLock.deviceOwnerTitle)",
                            comment: "Menu. The placeholder is Face ID, Touch ID, Optic ID, Device passcode or Mac password."),
                        systemImage: "lock.open")
                } else {
                    Label(
                        String(
                            localized: "Ask for \(AppLock.deviceOwnerTitle) to Copy",
                            comment: "Menu. The placeholder is Face ID, Touch ID, Optic ID, Device passcode or Mac password."),
                        systemImage: "lock")
                }
            }
        }
    }
}
