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
import Testing
import YubiKit

@testable import OrielOTP

struct OTPGeneratorTests {

    private static let sha1Secret = Data("12345678901234567890".utf8)
    private static let sha256Secret = Data("12345678901234567890123456789012".utf8)
    private static let sha512Secret = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    private static func account(_ algorithm: OTPAccount.Algorithm, secret: Data, digits: Int = 8, kind: OTPAccount.Kind = .totp)
        -> OTPAccount
    {
        OTPAccount(
            id: "1", kind: kind, issuer: "Example", accountName: "alice", secret: secret, algorithm: algorithm,
            digits: digits, period: 30, isPinned: false)
    }

    @Test func hotpMatchesRFC4226() {
        let expected = ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]
        for (counter, code) in expected.enumerated() {
            #expect(OTPGenerator.hotp(secret: Self.sha1Secret, counter: UInt64(counter)) == code)
        }
    }

    struct TOTPVector: Sendable, CustomTestStringConvertible {
        let time: TimeInterval
        let sha1: String
        let sha256: String
        let sha512: String
        var testDescription: String { String(Int(time)) }
    }

    @Test(arguments: [
        TOTPVector(time: 59, sha1: "94287082", sha256: "46119246", sha512: "90693936"),
        TOTPVector(time: 1111111109, sha1: "07081804", sha256: "68084774", sha512: "25091201"),
        TOTPVector(time: 1111111111, sha1: "14050471", sha256: "67062674", sha512: "99943326"),
        TOTPVector(time: 1234567890, sha1: "89005924", sha256: "91819424", sha512: "93441116"),
        TOTPVector(time: 2000000000, sha1: "69279037", sha256: "90698825", sha512: "38618901"),
        TOTPVector(time: 20000000000, sha1: "65353130", sha256: "77737706", sha512: "47863826")
    ])
    func totpMatchesRFC6238(_ vector: TOTPVector) {
        let date = Date(timeIntervalSince1970: vector.time)
        #expect(OTPGenerator.code(for: Self.account(.sha1, secret: Self.sha1Secret), at: date) == vector.sha1)
        #expect(OTPGenerator.code(for: Self.account(.sha256, secret: Self.sha256Secret), at: date) == vector.sha256)
        #expect(OTPGenerator.code(for: Self.account(.sha512, secret: Self.sha512Secret), at: date) == vector.sha512)
    }

    @Test func sixDigitCodesKeepLeadingZeros() {
        let code = OTPGenerator.code(
            for: Self.account(.sha1, secret: Self.sha1Secret, digits: 6), at: Date(timeIntervalSince1970: 1111111109))
        #expect(code == "081804")
    }

    @Test(arguments: [0, 59, 1111111109, 1234567890, 2000000000] as [TimeInterval])
    func steamCodesMatchTheYubiKeyPath(_ time: TimeInterval) {
        // The YubiKey path turns the HMAC the key calculates into a Steam code, the watch must give the same code.
        let steam = Self.account(.sha1, secret: Self.sha1Secret, digits: 5, kind: .steam)
        let counter = UInt64(time / 30)
        let message = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let hmac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: Self.sha1Secret)))
        #expect(OTPGenerator.code(for: steam, at: Date(timeIntervalSince1970: time)) == YubiKitOATHSession.steamCode(fromResponse: hmac))
    }

    @Test func secondsLeftCountsDownWithinThePeriod() {
        let account = Self.account(.sha1, secret: Self.sha1Secret)
        #expect(OTPGenerator.secondsLeft(for: account, at: Date(timeIntervalSince1970: 0)) == 30)
        #expect(OTPGenerator.secondsLeft(for: account, at: Date(timeIntervalSince1970: 29.5)) == 1)
        #expect(OTPGenerator.secondsLeft(for: account, at: Date(timeIntervalSince1970: 31)) == 29)
    }

    @Test func groupsNumericCodes() {
        #expect(OTPGenerator.grouped("123456") == "123 456")
        #expect(OTPGenerator.grouped("1234567") == "1234 567")
        #expect(OTPGenerator.grouped("12345678") == "1234 5678")
        #expect(OTPGenerator.grouped("KQ7F9") == "KQ7F9")
    }
}

struct OTPAuthURLParserTests {

    @Test func decodesBase32() {
        #expect(OTPAuthURLParser.base32Decode("MZXW6YTBOI") == Data("foobar".utf8))
        #expect(OTPAuthURLParser.base32Decode("mzxw 6ytb-oi======") == Data("foobar".utf8))
        #expect(OTPAuthURLParser.base32Decode("MZXW1") == nil)
    }

    @Test func readsTOTPAccounts() throws {
        let components = try #require(
            URLComponents(string: "otpauth://TOTP/GitHub:alice?secret=JBSWY3DPEHPK3PXP&algorithm=SHA256&digits=8&period=60"))
        let account = try #require(OTPAuthURLParser.account(id: "1", components: components))
        #expect(account.kind == .totp)
        #expect(account.issuer == "GitHub")
        #expect(account.accountName == "alice")
        #expect(account.algorithm == .sha256)
        #expect(account.digits == 8)
        #expect(account.period == 60)
        #expect(account.secret == OTPAuthURLParser.base32Decode("JBSWY3DPEHPK3PXP"))
    }

    @Test func skipsHOTPAndBrokenAccounts() throws {
        for url in [
            "otpauth://hotp/Example:alice?secret=JBSWY3DPEHPK3PXP&counter=1",
            "otpauth://totp/Example:alice",
            "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&algorithm=MD5"
        ] {
            let components = try #require(URLComponents(string: url))
            #expect(OTPAuthURLParser.account(id: "1", components: components) == nil)
        }
    }

    @Test func enteCodesCarryTheWatchAccount() throws {
        let raw = #""otpauth://totp/GitHub:alice%40example.com?secret=JBSWY3DPEHPK3PXP&codeDisplay=%7B%22pinned%22%3Atrue%7D""#
        let account = try #require(EnteCodeParser.parse(id: "1", rawData: raw)?.otpAccount)
        #expect(account.id == "1")
        #expect(account.title == "GitHub")
        #expect(account.subtitle == "alice@example.com")
        #expect(account.isPinned)

        let steam = try #require(
            EnteCodeParser.parse(id: "2", rawData: #""otpauth://steam/Steam:gamer?secret=JBSWY3DPEHPK3PXP""#)?.otpAccount)
        #expect(steam.kind == .steam)
        #expect(steam.digits == 5)

        let hotp = try #require(EnteCodeParser.parse(id: "3", rawData: #""otpauth://hotp/Example:bob?secret=JBSWY3DPEHPK3PXP&counter=0""#))
        #expect(hotp.template != nil)
        #expect(hotp.otpAccount == nil)
    }

    @Test func pinnedFromTheExportObject() throws {
        let raw = #"{"rawData":"otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP","display":{"pinned":true}}"#
        #expect(try #require(EnteCodeParser.parse(id: "1", rawData: raw)?.otpAccount).isPinned)
    }
}

struct WatchAccountsTests {

    private static func code(_ id: String, issuer: String, name: String, pinned: Bool = false) -> EnteCode {
        let raw = #""otpauth://totp/\#(issuer):\#(name)?secret=JBSWY3DPEHPK3PXP&codeDisplay=%7B%22pinned%22%3A\#(pinned)%7D""#
        return EnteCodeParser.parse(id: id, rawData: raw)!
    }

    @Test func pinnedAndFavoritesComeFirstThenByName() {
        let codes = [
            Self.code("1", issuer: "Zoom", name: "a"), Self.code("2", issuer: "apple", name: "b"),
            Self.code("3", issuer: "Mail", name: "c", pinned: true), Self.code("4", issuer: "Bank", name: "d")
        ]
        let accounts = WatchAccountSync.accounts(from: codes, favorites: ["Zoom:a"])
        #expect(accounts.map(\.id) == ["3", "1", "2", "4"])
    }

    @Test func messageRoundTrips() throws {
        let accounts = WatchAccountSync.accounts(from: [Self.code("1", issuer: "GitHub", name: "alice")], favorites: [])
        let context = try WatchAccountsMessage.context(for: accounts)
        #expect(WatchAccountsMessage.accounts(from: context) == accounts)
        #expect(WatchAccountsMessage.accounts(from: try WatchAccountsMessage.context(for: [])) == [])
        #expect(WatchAccountsMessage.accounts(from: [:]) == nil)
        #expect(WatchAccountsMessage.accounts(from: ["version": 2, "accounts": Data()]) == nil)
    }
}
