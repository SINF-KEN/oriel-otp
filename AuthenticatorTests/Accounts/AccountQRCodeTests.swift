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

/// An account's QR code holds its otpauth link, which reads back as the same account.
struct AccountQRCodeTests {

    /// The entry as Ente's apps store it: the link as a JSON string.
    private func code(_ uri: String) throws -> EnteCloudCode {
        try #require(EnteCloudCode(rawData: String(decoding: try JSONEncoder().encode(uri), as: UTF8.self)))
    }

    private func readBack(_ code: EnteCloudCode) throws -> EnteCloudCode {
        let url = try #require(code.otpauthURL)
        return try self.code(url.absoluteString)
    }

    private func expectSameAccount(_ a: EnteCloudCode, _ b: EnteCloudCode) {
        #expect(a.issuer == b.issuer)
        #expect(a.accountName == b.accountName)
        #expect(a.kind == b.kind)
        #expect(a.secret == b.secret)
        #expect(a.algorithm == b.algorithm)
        #expect(a.digits == b.digits)
        #expect(a.period == b.period)
        #expect(a.counter == b.counter)
    }

    @Test(arguments: [
        "otpauth://totp/GitHub:alice%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub",
        "otpauth://totp/Bank:alice?secret=JBSWY3DPEHPK3PXP&issuer=Bank&algorithm=SHA256&digits=8&period=60",
        "otpauth://hotp/Example:bob?secret=JBSWY3DPEHPK3PXP&issuer=Example&counter=7",
        "otpauth://steam/Steam:gamer?secret=JBSWY3DPEHPK3PXP&issuer=Steam",
        "otpauth://totp/alice?secret=JBSWY3DPEHPK3PXP",
        "otpauth://totp/A%26B%20Co:alice?secret=JBSWY3DPEHPK3PXP&issuer=A%26B%20Co"
    ])
    func theLinkReadsBackAsTheSameAccount(uri: String) throws {
        let code = try code(uri)
        expectSameAccount(code, try readBack(code))
    }

    /// Ente's display settings, such as pinned and tags, belong to this app, not to the account's link.
    @Test func leavesOutEntesDisplaySettings() throws {
        let code = try code(
            #"otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&codeDisplay=%7B%22pinned%22%3Atrue%2C%22tags%22%3A%5B%22work%22%5D%7D"#
        )
        #expect(code.isPinned)
        let url = try #require(code.otpauthURL)
        #expect(!url.absoluteString.contains("codeDisplay"))
    }

    @Test func theQRCodeHoldsTheLink() throws {
        let link = "otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&algorithm=SHA1&digits=6&period=30"
        let image = try #require(QRCodeImage.image(for: link))
        let scaled = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let png = try #require(CIContext().pngRepresentation(of: scaled, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        #expect(AuthenticatorImportFile.qrCodes(inImage: png) == [link])
    }
}
