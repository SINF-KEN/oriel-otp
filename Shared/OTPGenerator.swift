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

import CryptoKit
import Foundation

/// Calculates HOTP (RFC 4226) and TOTP (RFC 6238) codes, and Steam's 5 character codes.
nonisolated enum OTPGenerator {

    private static let steamAlphabet = Array("23456789BCDFGHJKMNPQRTVWXY")

    /// The code for the account at the given time.
    static func code(for account: OTPAccount, at date: Date) -> String {
        let counter = UInt64(max(0, date.timeIntervalSince1970) / Double(max(1, account.period)))
        let value = truncatedHMAC(secret: account.secret, counter: counter, algorithm: account.algorithm)
        switch account.kind {
        case .totp:
            return decimal(value, digits: account.digits)
        case .steam:
            return steam(value)
        }
    }

    /// Seconds until the code changes, between 1 and the period.
    static func secondsLeft(for account: OTPAccount, at date: Date) -> Int {
        let period = max(1, account.period)
        return period - Int(max(0, date.timeIntervalSince1970)) % period
    }

    static func hotp(secret: Data, counter: UInt64, algorithm: OTPAccount.Algorithm = .sha1, digits: Int = 6) -> String {
        decimal(truncatedHMAC(secret: secret, counter: counter, algorithm: algorithm), digits: digits)
    }

    /// The 31 bit number from the dynamic truncation of RFC 4226 section 5.3.
    static func truncatedHMAC(secret: Data, counter: UInt64, algorithm: OTPAccount.Algorithm) -> UInt32 {
        let key = SymmetricKey(data: secret)
        let message = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        return (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
    }

    private static func decimal(_ value: UInt32, digits: Int) -> String {
        let digits = min(max(digits, 1), 10)
        var modulus: UInt64 = 1
        for _ in 0..<digits { modulus *= 10 }
        let code = String(UInt64(value) % modulus)
        return String(repeating: "0", count: max(0, digits - code.count)) + code
    }

    private static func steam(_ value: UInt32) -> String {
        var value = Int(value)
        var code = ""
        for _ in 0..<5 {
            code.append(steamAlphabet[value % steamAlphabet.count])
            value /= steamAlphabet.count
        }
        return code
    }

    /// Splits a numeric code in two groups so it's easier to read, e.g. `123 456`.
    static func grouped(_ code: String) -> String {
        guard code.count >= 6, code.allSatisfy(\.isNumber) else { return code }
        let split = code.index(code.startIndex, offsetBy: (code.count + 1) / 2)
        return code[..<split] + " " + code[split...]
    }
}
