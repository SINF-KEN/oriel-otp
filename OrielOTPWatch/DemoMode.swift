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

/// Made-up accounts and a frozen clock for the screenshots in the README, only in debug builds in the simulator.
///
/// Launch arguments:
/// - `-DemoAccounts YES` shows the demo accounts instead of the ones in the keychain, and doesn't talk to the iPhone.
/// - `-DemoDate <seconds since 1970>` freezes the clock, so the codes and rings are the same on every run.
/// - `-DemoLuminanceReduced YES` shows the rows as they look wrist down and in Always On.
enum DemoMode {

    #if DEBUG && targetEnvironment(simulator)
        static let isEnabled = UserDefaults.standard.bool(forKey: "DemoAccounts")
        static let isLuminanceReduced = UserDefaults.standard.bool(forKey: "DemoLuminanceReduced")

        static let date: Date? = {
            let seconds = UserDefaults.standard.double(forKey: "DemoDate")
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }()

        /// The time-based accounts of the fake Ente server's demo account, with their own made-up secrets.
        static let accounts: [OTPAccount] = [
            ("e4", "otpauth://totp/Dropbox:alice@example.com?secret=MFRGGZDFMZTWQ2LK&issuer=Dropbox", true),
            ("e1", "otpauth://totp/GitHub:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub", false),
            ("e2", "otpauth://totp/Proton:alice@proton.me?secret=KRUGKIDROVUWG2ZA&issuer=Proton", false),
            ("e3", "otpauth://totp/Discord:alice%231234?secret=GEZDGNBVGY3TQOJQ&issuer=Discord", false),
            ("e5", "otpauth://totp/Bitwarden:alice?secret=ONSWG4TFOQQGC3TE&issuer=Bitwarden", false),
            ("e6", "otpauth://totp/Cloudflare:ops@example.com?secret=NBSWY3DPEB3W64TM&issuer=Cloudflare&algorithm=SHA256&digits=8", false),
            ("e7", "otpauth://totp/Tailscale:alice@github?secret=OBQXG43XN5ZGIMJS&issuer=Tailscale", false),
            ("e8", "otpauth://steam/Steam:gamer?secret=MNXW2ZLUNBUW4ZZA", false),
            ("e9", "otpauth://totp/Nintendo:alice?secret=MJQW4YLOMFZWC3DB&issuer=Nintendo&period=60", false)
        ].compactMap { id, url, isPinned in
            URLComponents(string: url).flatMap { OTPAuthURLParser.account(id: id, components: $0, isPinned: isPinned) }
        }
    #else
        static let isEnabled = false
        static let isLuminanceReduced = false
        static let date: Date? = nil
        static let accounts: [OTPAccount] = []
    #endif
}
