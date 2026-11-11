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

import CoreImage
import Foundation
import Testing
@testable import OrielOTP

@MainActor struct AuthenticatorImportTests {

    /// "Hello!\xde\xad\xbe\xef", JBSWY3DPEHPK3PXP in base32.
    private static let secret = Data([0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x21, 0xde, 0xad, 0xbe, 0xef])

    /// The account as this device's accounts read it, HOTP included.
    private func account(_ url: String) throws -> EnteCloudCode {
        try #require(EnteCloudCode(rawData: url))
    }

    // MARK: - Google Authenticator

    /// Encodes a protocol buffer field the way Google Authenticator does.
    private func field(_ number: Int, _ bytes: Data) -> Data {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    private func field(_ number: Int, _ value: UInt64) -> Data {
        varint(UInt64(number << 3)) + varint(value)
    }

    private func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    private func migrationLink(_ accounts: [Data]) -> String {
        var payload = Data()
        for account in accounts {
            payload += field(1, account)
        }
        payload += field(2, 1) + field(3, 1) + field(4, 0) + field(5, 12345)
        // Without padding, like Google's, and percent-encoded.
        let base64 = payload.base64EncodedString().replacingOccurrences(of: "=", with: "")
        let encoded = base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return "otpauth-migration://offline?data=\(encoded)"
    }

    private func googleAccount(name: String, issuer: String, algorithm: UInt64 = 1, digits: UInt64 = 1, type: UInt64 = 2,
                               counter: UInt64? = nil) -> Data {
        var data = field(1, Self.secret) + field(2, Data(name.utf8)) + field(3, Data(issuer.utf8))
            + field(4, algorithm) + field(5, digits) + field(6, type)
        if let counter { data += field(7, counter) }
        return data
    }

    @Test func readsAGoogleAuthenticatorExportWithSeveralAccounts() throws {
        let link = migrationLink([
            googleAccount(name: "GitHub:alice@example.com", issuer: "GitHub"),
            googleAccount(name: "bob", issuer: "Bank", algorithm: 2, digits: 2),
            googleAccount(name: "carol", issuer: "", type: 1, counter: 7),
        ])
        let urls = try AuthenticatorImport.otpauthURLs(fromText: link)
        #expect(urls.count == 3)

        let github = try account(urls[0])
        #expect(github.issuer == "GitHub")
        #expect(github.accountName == "alice@example.com")
        #expect(github.secret == Self.secret)
        #expect(github.kind == .totp)
        #expect(github.digits == 6)

        let bank = try account(urls[1])
        #expect(bank.issuer == "Bank")
        #expect(bank.algorithm == .sha256)
        #expect(bank.digits == 8)

        let carol = try account(urls[2])
        #expect(carol.kind == .hotp)
        #expect(carol.accountName == "carol")
        #expect(carol.counter == 7)
    }

    @Test func skipsGoogleAccountsTheAppCantCalculate() throws {
        let link = migrationLink([googleAccount(name: "md5", issuer: "Old", algorithm: 4), googleAccount(name: "ok", issuer: "New")])
        let urls = try AuthenticatorImport.otpauthURLs(fromText: link)
        #expect(urls.count == 1)
        #expect(try account(urls[0]).issuer == "New")
    }

    @Test func refusesAMalformedGoogleExport() {
        #expect(throws: (any Error).self) {
            try AuthenticatorImport.otpauthURLs(fromText: "otpauth-migration://offline?data=CgL%2F")
        }
    }

    @Test func readsAGoogleExportFromAScreenshotOfItsQRCode() throws {
        let link = migrationLink([googleAccount(name: "alice", issuer: "GitHub")])
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(link.utf8), forKey: "inputMessage")
        let image = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        let png = try #require(context.pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        let urls = try AuthenticatorImportFile.otpauthURLs(from: png)
        #expect(urls.count == 1)
        #expect(try account(urls[0]).issuer == "GitHub")
    }

    // MARK: - Other apps

    @Test func readsAnAegisExport() throws {
        let json = """
            {"version": 1, "header": {"slots": null, "params": null}, "db": {"version": 3, "entries": [
              {"type": "totp", "uuid": "1", "name": "alice", "issuer": "GitHub", "info": {"secret": "JBSWY3DPEHPK3PXP", "algo": "SHA1", "digits": 6, "period": 30}},
              {"type": "hotp", "uuid": "2", "name": "bob", "issuer": "Bank", "info": {"secret": "JBSWY3DPEHPK3PXP", "algo": "SHA512", "digits": 8, "counter": 3}},
              {"type": "steam", "uuid": "3", "name": "gamer", "issuer": "Steam", "info": {"secret": "JBSWY3DPEHPK3PXP", "algo": "SHA1", "digits": 5, "period": 30}},
              {"type": "yandex", "uuid": "4", "name": "x", "issuer": "Yandex", "info": {"secret": "JBSWY3DPEHPK3PXP", "pin": "1234"}}
            ]}}
            """
        let urls = try AuthenticatorImport.otpauthURLs(from: Data(json.utf8))
        #expect(urls.count == 3)
        #expect(try account(urls[0]).issuer == "GitHub")
        let bank = try account(urls[1])
        #expect(bank.kind == .hotp)
        #expect(bank.algorithm == .sha512)
        #expect(bank.digits == 8)
        #expect(try account(urls[2]).issuer == "Steam")
    }

    @Test func turnsDownAnEncryptedAegisExport() {
        let json = #"{"version": 1, "header": {"slots": [{"type": 1}], "params": {"nonce": "x", "tag": "y"}}, "db": "c2VjcmV0"}"#
        #expect(throws: AuthenticatorImportError.encrypted(app: "Aegis")) {
            try AuthenticatorImport.otpauthURLs(from: Data(json.utf8))
        }
    }

    @Test func readsA2FASExport() throws {
        let json = """
            {"schemaVersion": 4, "appVersionCode": 5000000, "services": [
              {"name": "GitHub", "secret": "JBSWY3DPEHPK3PXP", "otp": {"account": "alice", "digits": 6, "period": 30, "algorithm": "SHA1", "tokenType": "TOTP"}},
              {"name": "Bank", "secret": "JBSWY3DPEHPK3PXP", "otp": {"label": "bob", "issuer": "My Bank", "digits": 8, "period": 60, "algorithm": "SHA256", "tokenType": "TOTP"}}
            ]}
            """
        let urls = try AuthenticatorImport.otpauthURLs(from: Data(json.utf8))
        #expect(urls.count == 2)
        #expect(try account(urls[0]).accountName == "alice")
        let bank = try account(urls[1])
        #expect(bank.issuer == "My Bank")
        #expect(bank.accountName == "bob")
        #expect(bank.period == 60)
    }

    @Test func turnsDownAnEncrypted2FASExport() {
        let json = #"{"schemaVersion": 4, "services": [], "servicesEncrypted": "abc:def:ghi"}"#
        #expect(throws: AuthenticatorImportError.encrypted(app: "2FAS")) {
            try AuthenticatorImport.otpauthURLs(from: Data(json.utf8))
        }
    }

    @Test func readsARaivoExport() throws {
        let json = """
            [{"issuer": "GitHub", "account": "alice", "secret": "JBSWY3DPEHPK3PXP", "algorithm": "SHA1", "digits": "6", "kind": "TOTP", "timer": "30", "counter": "0"},
             {"issuer": "Bank", "account": "bob", "secret": "JBSWY3DPEHPK3PXP", "algorithm": "SHA1", "digits": "6", "kind": "HOTP", "timer": "30", "counter": "12"}]
            """
        let urls = try AuthenticatorImport.otpauthURLs(from: Data(json.utf8))
        #expect(urls.count == 2)
        #expect(try account(urls[1]).kind == .hotp)
        #expect(try account(urls[1]).counter == 12)
    }

    @Test func readsATextFileOfLinks() throws {
        let text = """
            otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub
            not a link

            OTPAUTH://TOTP/Bank:bob?secret=JBSWY3DPEHPK3PXP&issuer=Bank
            """
        #expect(try AuthenticatorImport.otpauthURLs(from: Data(text.utf8)).count == 2)
    }

    @Test func turnsDownFilesWithoutAccounts() {
        #expect(throws: AuthenticatorImportError.noAccounts) {
            try AuthenticatorImport.otpauthURLs(from: Data("just some notes".utf8))
        }
        #expect(throws: AuthenticatorImportError.unknownFormat) {
            try AuthenticatorImport.otpauthURLs(from: Data(#"{"some": "json"}"#.utf8))
        }
    }

    @Test func leavesOutSecretsThatArentBase32() throws {
        let json = #"[{"issuer": "Bad", "account": "x", "secret": "not base32!", "kind": "TOTP"}]"#
        #expect(throws: AuthenticatorImportError.noAccounts) {
            try AuthenticatorImport.otpauthURLs(from: Data(json.utf8))
        }
    }

    @Test func aColonInANameDoesNotMoveTheIssuer() throws {
        let url = try #require(AuthenticatorImport.otpauthURL(type: "totp", issuer: "Work: Mail", name: "alice", secret: "JBSWY3DPEHPK3PXP",
                                                              algorithm: nil, digits: nil, period: nil, counter: nil))
        #expect(try account(url).accountName == "alice")
    }

    // MARK: - Into this device

    @Test func importedAccountsAreAddedOnceToThisDevice() throws {
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        let urls = try AuthenticatorImport.otpauthURLs(fromText: migrationLink([
            googleAccount(name: "alice", issuer: "GitHub"), googleAccount(name: "bob", issuer: "Bank"),
        ]))
        #expect(try device.restore(backupLines: urls) == DeviceAccounts.RestoreResult(added: 2))
        #expect(try device.restore(backupLines: urls) == DeviceAccounts.RestoreResult(alreadyPresent: 2))
        #expect(device.accounts.count == 2)
    }
}
