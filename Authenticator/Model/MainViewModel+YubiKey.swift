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

// MARK: - YubiKey accounts: adding, copying, renaming and deleting

extension MainViewModel {

    enum CopyToYubiKeyResult {
        case copied, moved
        /// The YubiKey has an account with the same name. Nothing was changed, also not where the account is now.
        case alreadyOnYubiKey
    }

    /// The credential to put the account on a YubiKey with, nil if a YubiKey can't store it.
    private func yubiKeyTemplate(of account: Account) -> YubiKitOATHSession.CredentialTemplate? {
        switch account.location {
        case .yubiKey: nil
        case .ente(let id): cloud.yubiKeyTemplate(of: id)
        case .device(let id): device.yubiKeyTemplate(of: id)
        }
    }

    /// Whether the account can be copied to a YubiKey. It can't if a YubiKey can't store it. A HOTP account can only
    /// be moved, as a copy would count codes on its own and fall out of step with the original.
    func canCopyToYubiKey(_ account: Account, moving: Bool) -> Bool {
        guard moving || account.credential.type != .hotp else { return false }
        return yubiKeyTemplate(of: account) != nil
    }

    /// Puts an account in Ente Auth or on this device on the YubiKey. Moving it also moves it to Ente's trash or
    /// deletes it from this device, once it is on the YubiKey. The completion isn't called when the YubiKey couldn't
    /// be reached, which `handle(error:)` reports.
    func copyToYubiKey(_ account: Account, moving: Bool, completion: @escaping (CopyToYubiKeyResult) -> Void) {
        guard let template = yubiKeyTemplate(of: account) else { return }
        addAccounts([template], requiresTouch: false) { [weak self] result in
            if let error = result.error {
                self?.sessionError = error.isOATHStorageFull ? OATHSessionError.storageFull(notAdded: [template.displayName]) : error
                return
            } else if result.added.isEmpty {
                completion(.alreadyOnYubiKey)
                return
            }
            // The copy on the YubiKey is filed under the same tags.
            if !account.tags.isEmpty {
                let id = OATHCredentialId.key(accountName: template.name, issuer: template.issuer,
                                              period: UInt(template.type.period ?? 0), isTOTP: template.type.period != nil)
                do {
                    try self?.saveKeyTags(account.tags, for: id)
                } catch {
                    // The account is on the key; only its tags are missing, which the user is told.
                    self?.sessionError = error
                }
                self?.keyAccounts.first { $0.credential.id == id }?.tags = account.tags
                self?.sortAccounts()
            }
            if moving {
                // If the source can't be removed, the account is on both: "copied", with the error.
                completion(self?.removeAfterMove(account) == true ? .moved : .copied)
            } else {
                completion(.copied)
            }
        }
    }
    
    /// Removes the account from where it was moved from. Returns false, and shows the error, if it couldn't be.
    private func removeAfterMove(_ account: Account) -> Bool {
        do {
            switch account.location {
            case .yubiKey: break
            case .ente(let id): try cloud.delete(id)
            case .device(let id): try device.delete(id)
            }
            return true
        } catch {
            sessionError = error
            return false
        }
    }

    /// Adds an account to the YubiKey. The completion is called only if the account was added.
    func addAccount(_ template: YubiKitOATHSession.CredentialTemplate, requiresTouch: Bool, completion: (() -> Void)? = nil) {
        Task {
            do {
                let session = try await OATHSessionHandler.shared.anySession()
                try await session.addCredential(template: template, requiresTouch: requiresTouch)
                await updateAccounts(using: session)
                completion?()
            } catch {
                handle(error: error, retry: { self.addAccount(template, requiresTouch: requiresTouch, completion: completion) })
            }
        }
    }
    
    /// Adds several accounts in one YubiKey session, e.g. when importing. Accounts already on the YubiKey are skipped.
    func addAccounts(_ templates: [YubiKitOATHSession.CredentialTemplate], requiresTouch: Bool, completion: @escaping (OATHSession.AddCredentialsResult) -> Void) {
        Task {
            do {
                let session = try await OATHSessionHandler.shared.anySession()
                let result = try await session.addCredentials(templates: templates, requiresTouch: requiresTouch)
                await updateAccounts(using: session)
                completion(result)
            } catch {
                handle(error: error, retry: { self.addAccounts(templates, requiresTouch: requiresTouch, completion: completion) })
            }
        }
    }

    func renameAccount(_ account: Account, issuer: String, accountName: String, completion: @escaping () -> Void) {
        if case .ente(let id) = account.location {
            do {
                try cloud.rename(id, issuer: issuer, accountName: accountName)
                completion()
            } catch {
                sessionError = error
            }
            return
        }
        if case .device(let id) = account.location {
            do {
                try device.rename(id, issuer: issuer, accountName: accountName)
                completion()
            } catch {
                sessionError = error
            }
            return
        }
        Task {
            do {
                let wasPinned = account.isPinned
                let session = try await OATHSessionHandler.shared.anySession()
                let oldId = account.credential.id
                let credential = try await session.renameCredential(account.credential, issuer: issuer, accountName: accountName)
                // The tags are kept by the account's id, which the new name changes.
                if !account.tags.isEmpty {
                    do {
                        try saveKeyTags(account.tags, for: credential.id, movingFrom: oldId)
                    } catch {
                        // Renamed on the key; only the tags didn't follow, which the user is told.
                        sessionError = error
                    }
                }
                if wasPinned {
                    account.isPinned = false
                }
                account.credential = credential
                account.updateTitles()
                sortAccounts()
                account.isPinned = wasPinned
                await updateAccounts(using: session)
                ConnectionManager.shared.closeNFC(message: String(localized: "Account renamed", comment: "OATH NFC account renamed"))
                completion()
            } catch {
                handle(error: error, retry: { self.renameAccount(account, issuer: issuer, accountName: accountName, completion: completion) })
            }
        }
    }
    
    /// Deletes the account from the YubiKey or this device, or moves an Ente Auth account to Ente's trash.
    func deleteAccount(_ account: Account, completion: @escaping () -> Void) {
        if case .ente(let id) = account.location {
            do {
                try cloud.delete(id)
                completion()
            } catch {
                sessionError = error
            }
            return
        }
        if case .device(let id) = account.location {
            do {
                try device.delete(id)
                completion()
            } catch {
                sessionError = error
            }
            return
        }
        Task {
            do {
                let session = try await OATHSessionHandler.shared.anySession()
                try await session.deleteCredential(account.credential)
                removeKeyAccount(account)
                if !account.tags.isEmpty {
                    do {
                        try saveKeyTags([], for: account.credential.id)
                    } catch {
                        // Left behind, they'd come back on an account added later with the same name.
                        sessionError = error
                    }
                }
                session.endNFC(message: String(localized: "Account deleted", comment: "OATH NFC account deleted"))
                completion()
            } catch {
                handle(error: error, retry: { self.deleteAccount(account, completion: completion) })
            }
        }
    }
    
    /// Deletes the accounts one after the other, as the YubiKey handles one command at a time.
    func deleteAccounts(_ accounts: [Account], completion: @escaping () -> Void) {
        guard let account = accounts.first else {
            completion()
            return
        }
        deleteAccount(account) { [weak self] in
            self?.deleteAccounts(Array(accounts.dropFirst()), completion: completion)
        }
    }
}
