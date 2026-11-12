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

// MARK: - Ente Auth

extension MainViewModel {

    func cloudAccount(id: String, code: EnteCloudCode, isPending: Bool) -> Account {
        let credential = OATHSession.Credential(type: code.kind == .hotp ? .hotp : .totp, issuer: code.issuer, accountName: code.accountName,
                                                period: UInt(code.period))
        let otp = code.kind == .hotp ? nil : code.code(at: AppClock.now)
        // Calculated like on a YubiKey that is plugged in: a new code is calculated when one expires.
        let account = calculatedAccount(credential: credential, otp: otp, code: code, location: .ente(id: id))
        account.isPendingSync = isPending
        account.onPinnedChange = { [weak self] account in
            do {
                try self?.cloud.setPinned(id, account.isPinned)
            } catch {
                // Otherwise the pin would look saved, and be gone at the next launch.
                self?.sessionError = error
            }
        }
        return account
    }

    func calculatedAccount(credential: OATHSession.Credential, otp: (code: String, validity: DateInterval)?, code: EnteCloudCode,
                                   location: Account.Location) -> Account {
        let account = Account(credential: credential, code: otp.map { OATHSession.OTP(code: $0.code, validity: $0.validity) },
                              keyVersion: Version("0.0.0")!, requestRefresh: { [weak self] in self?.calculateCode(for: $0) },
                              connectionType: .wired, isPinned: code.isPinned, location: location)
        Self.updateDisplay(of: account, from: code)
        if code.kind != .hotp {
            // Looked up each time, as the account can be kept when its entry changes.
            account.codeAtDate = { [weak self, weak account] date in
                guard let self, let account else { return nil }
                return self.calculatedCode(of: account)?.code(at: date).code
            }
        }
        return account
    }

    /// The otpauth link of an account in Ente Auth or on this device, for its QR code. Nil for a YubiKey's, which the
    /// YubiKey never gives the secret of.
    func otpauthURL(for account: Account) -> URL? {
        calculatedCode(of: account)?.otpauthURL
    }

    /// The entry the app calculates an account's codes from.
    private func calculatedCode(of account: Account) -> EnteCloudCode? {
        switch account.location {
        case .yubiKey: nil
        case .ente: cloudCodes[account.accountId]
        case .device: deviceCodes[account.accountId]
        }
    }

    /// The tags and icon, which can change without the account being made again.
    static func updateDisplay(of account: Account, from code: EnteCloudCode) {
        if account.tags != code.tags {
            account.tags = code.tags
        }
        if account.iconID != code.iconID {
            account.iconID = code.iconID
        }
    }

    /// Calculates the code of an account in Ente Auth or on this device.
    private func calculateCode(for account: Account) {
        let nextHOTPCode: () -> String?
        let code: EnteCloudCode?
        switch account.location {
        case .yubiKey:
            return
        case .ente(let id):
            code = cloudCodes[account.accountId]
            nextHOTPCode = { [cloud] in cloud.nextHOTPCode(id) }
        case .device(let id):
            code = deviceCodes[account.accountId]
            nextHOTPCode = { [device] in device.nextHOTPCode(id) }
        }
        guard let code else { return }
        if code.kind == .hotp {
            guard let otp = nextHOTPCode() else { return }
            account.update(otp: OATHSession.OTP(code: otp, validity: DateInterval(start: AppClock.now, end: .distantFuture)))
        } else {
            // A refresh scheduled for when the code expires can fire a moment early. It still gets the next code.
            var date = AppClock.now
            if let end = account.otp?.validity.end, end > date, end.timeIntervalSince(date) < 1 {
                date = end
            }
            let (otp, validity) = code.code(at: date)
            account.update(otp: OATHSession.OTP(code: otp, validity: validity))
        }
    }

    /// Calculates the codes of the time-based accounts the app calculates again, e.g. after it was in the background.
    func refreshCalculatedCodes() {
        for account in cloudAccounts + deviceAccounts where account.credential.type == .totp {
            calculateCode(for: account)
        }
    }

    /// Adds an account to the Ente Auth vault and uploads it.
    func addCloudAccount(_ template: YubiKitOATHSession.CredentialTemplate) throws -> EnteCloud.AddResult {
        try cloud.add(template)
    }
}
