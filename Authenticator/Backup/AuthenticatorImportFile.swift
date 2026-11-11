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
import UniformTypeIdentifiers

/// The files an export can come in: JSON or text, 2FAS's `.2fas` files, which have no type of their own, and images,
/// for a screenshot of Google Authenticator's export QR codes.
nonisolated enum AuthenticatorImportFile {

    static let contentTypes: [UTType] = [.json, .plainText, .text, .image, UTType(filenameExtension: "2fas") ?? .data, .data]

    /// The otpauth URLs in an export, or in the QR codes of an image.
    static func otpauthURLs(from data: Data) throws -> [String] {
        if let codes = qrCodes(inImage: data) {
            let urls = try AuthenticatorImport.otpauthURLs(fromText: codes.joined(separator: "\n"))
            guard !urls.isEmpty else { throw AuthenticatorImportError.noAccounts }
            return urls
        }
        return try AuthenticatorImport.otpauthURLs(from: data)
    }

    /// The text of every QR code in an image, nil if the data isn't an image.
    static func qrCodes(inImage data: Data) -> [String]? {
        guard let image = CIImage(data: data) else { return nil }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: image) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}
