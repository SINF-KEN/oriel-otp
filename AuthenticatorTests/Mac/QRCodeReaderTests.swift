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

#if os(macOS)
    import AppKit
    import CoreImage
    import CoreImage.CIFilterBuiltins
    import Foundation
    import Testing

    @testable import OrielOTP

    /// Reading otpauth QR codes on the Mac, from pictures, image files and dropped URLs. The window picker needs a person
    /// to pick a window, so it isn't tested here.
    @MainActor
    struct QRCodeReaderTests {

        private static let url = URL(string: "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&issuer=Example")!

        /// A QR code of `message`, large enough to be read, on a white margin.
        private static func qrCode(_ message: String) -> NSImage {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(message.utf8)
            filter.correctionLevel = "M"
            let code = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
            let margin = code.extent.insetBy(dx: -40, dy: -40)
            let image = code.composited(over: CIImage(color: .white).cropped(to: margin))
            let cgImage = CIContext().createCGImage(image, from: margin)!
            return NSImage(cgImage: cgImage, size: margin.size)
        }

        private static func png(_ image: NSImage) -> Data {
            let representation = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            return representation.representation(using: .png, properties: [:])!
        }

        @Test func findsTheAccountInAPicture() {
            #expect(QRCodeReader.otpauthURLs(in: Self.qrCode(Self.url.absoluteString)) == [Self.url])
        }

        @Test func ignoresQRCodesThatArentForAnAccount() {
            #expect(QRCodeReader.otpauthURLs(in: Self.qrCode("https://example.com")).isEmpty)
            #expect(QRCodeReader.otpauthURLs(in: NSImage(size: NSSize(width: 10, height: 10))).isEmpty)
        }

        @Test func readsADroppedPicture() async throws {
            let provider = NSItemProvider(item: Self.png(Self.qrCode(Self.url.absoluteString)) as NSData, typeIdentifier: "public.png")
            #expect(try await QRCodeReader.read([provider]) == Self.url)
        }

        @Test func readsADroppedURL() async throws {
            #expect(try await QRCodeReader.read([NSItemProvider(object: Self.url as NSURL)]) == Self.url)
        }

        @Test func readsADroppedImageFile() async throws {
            let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
            try Self.png(Self.qrCode(Self.url.absoluteString)).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(try await QRCodeReader.read([NSItemProvider(object: file as NSURL)]) == Self.url)
        }

        @Test func saysWhenThereIsNoAccount() async {
            let provider = NSItemProvider(object: URL(string: "https://example.com")! as NSURL)
            await #expect(throws: QRCodeReader.ReadError.self) { try await QRCodeReader.read([provider]) }
            await #expect(throws: QRCodeReader.ReadError.self) { try await QRCodeReader.read([]) }
        }
    }
#endif
