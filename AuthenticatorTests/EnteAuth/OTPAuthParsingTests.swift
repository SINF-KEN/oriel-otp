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

nonisolated private let testSecret = "JBSWY3DPEHPK3PXP"

/// The two readers of otpauth URLs, the one for the YubiKey and the one for codes calculated on the device, and
/// writing accounts back as URLs.
struct OTPAuthParsingTests {

    /// The data of an Ente entity holding the URL.
    private func entity(_ url: String) -> String {
        String(decoding: try! JSONEncoder().encode(url), as: UTF8.self)
    }

    private func yubiKeyTemplate(_ url: String) throws -> YubiKitOATHSession.CredentialTemplate {
        try YubiKitOATHSession.CredentialTemplate(otpauthURL: try #require(URL(string: url)))
    }

    private func deviceAccount(_ url: String) throws -> OTPAccount? {
        OTPAuthURLParser.account(id: "1", components: try #require(URLComponents(string: url)))
    }

    // MARK: Period

    @Test(arguments: ["9223372036854775807", "86401"])
    func rejectsPeriodsTooLong(period: String) throws {
        let url = "otpauth://totp/A:b?secret=\(testSecret)&period=\(period)"
        #expect(throws: CredentialTemplateError.period) { try yubiKeyTemplate(url) }
        #expect(try deviceAccount(url) == nil)
        #expect(EnteCloudCode(rawData: entity(url)) == nil)
    }

    @Test func acceptsAPeriodOfADay() throws {
        let url = "otpauth://totp/A:b?secret=\(testSecret)&period=86400"
        #expect(try yubiKeyTemplate(url).type.period == 86_400)
        #expect(try deviceAccount(url)?.period == 86_400)
    }

    @Test(arguments: [TimeInterval(1e19), 30.5, .nan, .infinity])
    func templatesNeedAWholePeriodOfAtMostADay(period: TimeInterval) {
        #expect(throws: CredentialTemplateError.period) {
            try YubiKitOATHSession.CredentialTemplate(type: .totp(period: period), algorithm: .sha1, secret: Data([1, 2, 3]),
                                                      issuer: "A", accountName: "b", digits: 6)
        }
    }

    @Test func aPeriodThatIsntAnIntIsntExported() {
        let template = YubiKitOATHSession.CredentialTemplate(type: .totp(period: 1e19), algorithm: .sha1, secret: Data([1, 2, 3]),
                                                             issuer: "A", name: "b", digits: 6)
        #expect(EnteCodeExporter.otpauthURL(for: template) == nil)
        #expect(throws: (any Error).self) { try EnteCodeExporter.rawData(for: template) }
    }

    // MARK: HOTP counter

    @Test func rejectsACounterThatCantMoveOn() throws {
        #expect(EnteCloudCode(rawData: entity("otpauth://hotp/A:b?secret=\(testSecret)&counter=18446744073709551615")) == nil)
        let code = EnteCloudCode(rawData: entity("otpauth://hotp/A:b?secret=\(testSecret)&counter=18446744073709551614"))
        #expect(code?.counter == UInt64.max - 1)
    }

    @Test func readsCountersAboveInt32() throws {
        #expect(try yubiKeyTemplate("otpauth://hotp/A:b?secret=\(testSecret)&counter=3000000000").type.counter == 3_000_000_000)
    }

    @Test(arguments: ["4294967296", "-1", "abc", ""])
    func rejectsCountersTheYubiKeyCantKeep(counter: String) throws {
        #expect(throws: CredentialTemplateError.counter) {
            try yubiKeyTemplate("otpauth://hotp/A:b?secret=\(testSecret)&counter=\(counter)")
        }
    }

    @Test func movesACounterOnWhateverTheCaseOfItsName() throws {
        var editor = try #require(EnteEntryEditor(rawData: entity("otpauth://hotp/A:b?secret=\(testSecret)&Counter=5")))
        #expect(EnteCloudCode(rawData: entity("otpauth://hotp/A:b?secret=\(testSecret)&Counter=5"))?.counter == 5)
        #expect(editor.counter == 5)
        editor.counter = 6
        let rawData = try #require(editor.rawData)
        #expect(EnteCloudCode(rawData: rawData)?.counter == 6)
        #expect(rawData.lowercased().components(separatedBy: "counter=").count == 2)
    }

    // MARK: Parameters

    @Test func bothParsersReadNamesInAnyCase() throws {
        let url = "otpauth://totp/A:b?SECRET=\(testSecret)&Algorithm=sha256&DIGITS=8&Period=60"
        let template = try yubiKeyTemplate(url)
        let account = try #require(try deviceAccount(url))
        // YubiKit pads short secrets with zeros, which gives the same codes.
        #expect(account.secret == Data(base32Encoded: testSecret))
        #expect(template.secret.starts(with: account.secret))
        #expect(template.algorithm == .sha256 && account.algorithm == .sha256)
        #expect(template.digits == 8 && account.digits == 8)
        #expect(template.type.period == 60 && account.period == 60)
    }

    @Test(arguments: [
        "otpauth://totp/A:b?secret=\(testSecret)&SECRET=GEZDGNBVGY3TQOJQ",
        "otpauth://totp/A:b?secret=\(testSecret)&period=30&Period=60",
        "otpauth://totp/A:b?secret=\(testSecret)&digits=6&digits=8",
        "otpauth://totp/A:b?secret=\(testSecret)&algorithm=SHA1&ALGORITHM=SHA512",
        "otpauth://totp/b?secret=\(testSecret)&issuer=A&Issuer=B",
    ])
    func rejectsASettingGivenTwice(url: String) throws {
        #expect(throws: CredentialTemplateError.repeatedParameter) { try yubiKeyTemplate(url) }
        #expect(try deviceAccount(url) == nil)
        #expect(EnteCloudCode(rawData: entity(url)) == nil)
        #expect(EnteCodeParser.parse(id: "1", rawData: entity(url))?.template == nil)
    }

    @Test func rejectsACounterGivenTwice() throws {
        let url = "otpauth://hotp/A:b?secret=\(testSecret)&counter=1&COUNTER=2"
        #expect(throws: CredentialTemplateError.repeatedParameter) { try yubiKeyTemplate(url) }
        #expect(EnteCloudCode(rawData: entity(url)) == nil)
    }

    @Test func keepsOtherParametersGivenTwice() throws {
        let url = "otpauth://totp/A:b?secret=\(testSecret)&image=a&image=b"
        #expect(try yubiKeyTemplate(url).name == "b")
        #expect(try deviceAccount(url) != nil)
    }

    // MARK: Base32

    @Test(arguments: ["JBSWY3DPEHPK3PX\u{0301}P", "JBSWY3DPEHPK3PXß", "JBSWY3DPEHPK3PXı", "JBSWY3DPEHPK3PXſ", "JBSWY3DPEHPK3PXＡ"])
    func rejectsSecretsWithLettersOutsideBase32(secret: String) {
        #expect(Data(base32Encoded: secret) == nil)
        #expect(OTPAuthURLParser.base32Decode(secret) == nil)
    }

    @Test func decodesBase32InAnyCase() {
        #expect(OTPAuthURLParser.base32Decode("mzxw-6ytb oi==") == Data("foobar".utf8))
        #expect(Data(base32Encoded: "mzxw6ytboi") == Data("foobar".utf8))
    }

    // MARK: Names

    @Test func removesInvisibleCharactersFromNames() throws {
        // A zero-width space, a right-to-left override, a direction isolate, a line break and a tab.
        let url = "otpauth://totp/Goo%E2%80%8Bgle:al%E2%80%AEice%E2%81%A6%0A%09?secret=\(testSecret)"
        let template = try yubiKeyTemplate(url)
        let account = try #require(try deviceAccount(url))
        #expect(template.issuer == "Google" && account.issuer == "Google")
        #expect(template.name == "alice" && account.accountName == "alice")
        let code = try #require(EnteCloudCode(rawData: entity(url)))
        #expect(code.issuer == "Google" && code.accountName == "alice")
    }

    @Test func removesInvisibleCharactersFromTheIssuerParameter() throws {
        let url = "otpauth://totp/alice?secret=\(testSecret)&issuer=%E2%80%8FBank%E2%80%8E"
        #expect(try yubiKeyTemplate(url).issuer == "Bank")
        #expect(try deviceAccount(url)?.issuer == "Bank")
    }

    @Test(arguments: [
        "otpauth://totp/%20Example%20:%20alice%20?secret=\(testSecret)",
        "otpauth://totp/alice%20?secret=\(testSecret)&issuer=%20Example",
    ])
    func bothParsersTrimNames(url: String) throws {
        let template = try yubiKeyTemplate(url)
        let account = try #require(try deviceAccount(url))
        #expect(template.issuer == "Example" && account.issuer == "Example")
        #expect(template.name == "alice" && account.accountName == "alice")
    }

    @Test func aNameWithOnlySpacesIsMissing() throws {
        #expect(throws: CredentialTemplateError.label) { try yubiKeyTemplate("otpauth://totp/A:%20?secret=\(testSecret)") }
    }

    // MARK: Export

    @Test(arguments: [(nil, "Issuer:alice"), ("", "Issuer:alice"), ("Example", "alice:work"), (nil, "alice")] as [(String?, String)])
    func exportedNamesWithAColonReadBackTheSame(issuer: String?, name: String) throws {
        let template = try YubiKitOATHSession.CredentialTemplate(type: .totp(period: 30), algorithm: .sha1,
                                                                 secret: try #require(Data(base32Encoded: testSecret)),
                                                                 issuer: issuer, accountName: name, digits: 6)
        let rawData = String(decoding: try EnteCodeExporter.rawData(for: template), as: UTF8.self)
        let parsed = try #require(EnteCodeParser.parse(id: "1", rawData: rawData)?.template)
        #expect(parsed.issuer == template.issuer)
        #expect(parsed.name == name)
        let code = try #require(EnteCloudCode(rawData: rawData))
        #expect(code.issuer == template.issuer)
        #expect(code.accountName == name)
    }

    @Test func renamingToANameWithAColonReadsBackTheSame() throws {
        var editor = try #require(EnteEntryEditor(rawData: entity("otpauth://totp/A:b?secret=\(testSecret)&issuer=A")))
        editor.rename(issuer: nil, accountName: "Issuer:alice")
        let rawData = try #require(editor.rawData)
        let code = try #require(EnteCloudCode(rawData: rawData))
        #expect(code.issuer == nil)
        #expect(code.accountName == "Issuer:alice")
    }
}
