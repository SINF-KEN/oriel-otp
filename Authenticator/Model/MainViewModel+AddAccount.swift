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

import Foundation
import YubiKit

// MARK: - Saving the accounts added in the add account sheet

extension MainViewModel {

    /// Saves an account where the add account sheet was asked to put it: on this device, on the YubiKey and then
    /// possibly in Ente Auth too, or only in Ente Auth. `toast` shows what happened; errors go to `sessionError`.
    func saveNewAccount(_ template: YubiKitOATHSession.CredentialTemplate, requiresTouch: Bool,
                        to destinations: AccountDestinations, toast: @escaping (String) -> Void) {
        if destinations.contains(.device) {
            saveToDevice(template, toast: toast)
        } else if destinations.contains(.yubiKey) {
            addAccount(template, requiresTouch: requiresTouch) { [weak self] in
                if destinations.contains(.ente) {
                    // For an account that was just put on the YubiKey, this is the only time it can be copied, as the
                    // YubiKey can't give the secret back later.
                    self?.saveToEnte(template, toast: toast)
                }
            }
        } else if destinations.contains(.ente) {
            saveToEnte(template, toast: toast)
        }
    }

    /// Puts several accounts on the YubiKey, e.g. from a Google Authenticator export scanned in the add account sheet.
    func importToYubiKey(_ templates: [YubiKitOATHSession.CredentialTemplate], requiresTouch: Bool,
                         toast: @escaping (String) -> Void) {
        guard !templates.isEmpty else { return }
        addAccounts(templates, requiresTouch: requiresTouch) { [weak self] result in
            if let error = result.error {
                if error.isOATHStorageFull {
                    self?.sessionError = OATHSessionError.storageFull(notAdded: result.notAdded.map(\.displayName))
                } else {
                    self?.sessionError = error
                }
            }
            // One sentence each, so translators can word and order them as their language needs.
            let message = result.alreadyPresent.isEmpty
                ? String(localized: "Added \(result.added.count) accounts.", comment: "Import result. The placeholder is the number of accounts.")
                : String(localized: "Added \(result.added.count) accounts. \(result.alreadyPresent.count) were already on the YubiKey.", comment: "Import result. The placeholders are the number of accounts added and the number that were already on the YubiKey.")
            toast(message)
        }
    }

    private func saveToDevice(_ template: YubiKitOATHSession.CredentialTemplate, toast: (String) -> Void) {
        do {
            switch try addDeviceAccount(template) {
            case .added:
                toast(String(localized: "Added to this device", comment: "Toast after adding an account to this device"))
            case .alreadyPresent:
                toast(String(localized: "Already on this device", comment: "Toast when this device already has the account"))
            }
        } catch {
            sessionError = error
        }
    }

    /// Adds an account to the Ente Auth vault, which uploads it.
    private func saveToEnte(_ template: YubiKitOATHSession.CredentialTemplate, toast: (String) -> Void) {
        do {
            switch try addCloudAccount(template) {
            case .added:
                toast(String(localized: "Added to Ente Auth", comment: "Toast after adding an account to Ente Auth"))
            case .alreadyPresent:
                toast(String(localized: "Already in Ente Auth", comment: "Toast when Ente Auth already has the account"))
            }
        } catch {
            sessionError = EnteSyncError(error)
        }
    }
}
