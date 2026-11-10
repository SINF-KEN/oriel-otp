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
import Testing
import YubiKit

@testable import OrielOTP

/// YubiKit reads leading digits and a slash in an account's id as its period, but writes no such prefix for the default
/// 30 seconds. An account whose id would start that way must not reach a YubiKey.
@Suite struct CredentialIdPeriodTests {

    /// The period YubiKit's id parser reads from an id: the digits before the first slash, or the default of 30.
    private static func periodYubiKitReads(_ id: String) -> Double {
        guard let match = id.firstMatch(of: #/^(?<period>\d+)\/.+$/#) else { return 30 }
        return Double(String(match.period)) ?? .infinity
    }

    @Test(arguments: [
        "otpauth://totp/0/alice?secret=JBSWY3DPEHPK3PXP",
        "otpauth://totp/0%2FAcme:alice?secret=JBSWY3DPEHPK3PXP",
        "otpauth://totp/99999999999999999999/alice?secret=JBSWY3DPEHPK3PXP",
        "otpauth://totp/24%2F7%20Fitness:alice?secret=JBSWY3DPEHPK3PXP",
        "otpauth://totp/alice?secret=JBSWY3DPEHPK3PXP&issuer=24/7%20Fitness",
        "otpauth://hotp/24%2F7%20Fitness:alice?secret=JBSWY3DPEHPK3PXP&counter=0",
    ])
    func anIdThatReadsBackWithAnotherPeriodIsRefused(_ link: String) throws {
        let url = try #require(URL(string: link))
        #expect(throws: CredentialTemplateError.periodLikeName) {
            try YubiKitOATHSession.CredentialTemplate(otpauthURL: url)
        }
    }

    @Test(arguments: [
        "otpauth://totp/60%2FBank:alice?secret=JBSWY3DPEHPK3PXP&period=60",
        "otpauth://totp/Bank:24%2F7?secret=JBSWY3DPEHPK3PXP",
        "otpauth://totp/24%2F7%20Fitness:alice?secret=JBSWY3DPEHPK3PXP&period=60",
        "otpauth://totp/1Password:alice?secret=JBSWY3DPEHPK3PXP",
    ])
    func anIdThatReadsBackWithItsOwnPeriodIsKept(_ link: String) throws {
        let url = try #require(URL(string: link))
        let template = try YubiKitOATHSession.CredentialTemplate(otpauthURL: url)
        #expect(Self.periodYubiKitReads(template.identifier) == template.type.period)
    }

    @Test func onlyPeriodsACodeCanBeCalculatedWithAreUsable() {
        #expect(OATHSession.Credential.isUsable(period: 30))
        #expect(OATHSession.Credential.isUsable(period: 86_400))
        #expect(!OATHSession.Credential.isUsable(period: 0))
        #expect(!OATHSession.Credential.isUsable(period: 1e20))
        #expect(!OATHSession.Credential.isUsable(period: .infinity))
        #expect(!OATHSession.Credential.isUsable(period: 0.5))
    }
}
