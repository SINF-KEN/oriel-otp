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

// MARK: - This device

extension MainViewModel {

    func deviceAccount(id: String, code: EnteCloudCode) -> Account {
        let credential = OATHSession.Credential(type: code.kind == .hotp ? .hotp : .totp, issuer: code.issuer, accountName: code.accountName,
                                                period: UInt(code.period))
        let otp = code.kind == .hotp ? nil : code.code(at: AppClock.now)
        let account = calculatedAccount(credential: credential, otp: otp, code: code, location: .device(id: id))
        account.onPinnedChange = { [weak self] account in
            do {
                try self?.device.setPinned(id, account.isPinned)
            } catch {
                // Otherwise the pin would look saved, and be gone at the next launch.
                self?.sessionError = error
            }
        }
        return account
    }

    /// Adds an account to this device.
    func addDeviceAccount(_ template: YubiKitOATHSession.CredentialTemplate) throws -> DeviceAccounts.AddResult {
        try device.add(template)
    }

    enum MoveToEnteResult {
        case moved
        /// Ente Auth has an account with the same name. Nothing was changed, also not on this device.
        case alreadyInEnte
    }

    /// Whether the account on this device can be moved to Ente Auth, which also backs it up.
    func canMoveToEnte(_ account: Account) -> Bool {
        account.isOnDevice && cloud.isEnabled
    }

    /// Puts an account on this device in Ente Auth, and deletes it here once it is saved in the vault. Until it has
    /// been uploaded the vault is its only copy, so if the vault is discarded before then, e.g. by signing out, the
    /// account is put back on this device (see `EnteCloud`).
    func moveToEnte(_ account: Account) throws -> MoveToEnteResult {
        guard case .device(let id) = account.location, let rawData = device.rawData(of: id) else { return .alreadyInEnte }
        guard try cloud.add(rawData: rawData) == .added else { return .alreadyInEnte }
        try device.delete(id)
        return .moved
    }
}
