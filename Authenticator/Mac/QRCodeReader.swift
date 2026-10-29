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
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Finds otpauth QR codes without a camera: on the screen, in images and on the pasteboard.
enum QRCodeReader {

    enum ReadError: LocalizedError {
        case noScreenRecordingPermission
        case noQRCode

        var errorDescription: String? {
            switch self {
            case .noScreenRecordingPermission:
                String(localized: "Allow Oriel OTP to record the screen in System Settings, under Privacy & Security > Screen & System Audio Recording. It only looks for a QR code and doesn't keep the picture.", comment: "Mac QR scan error")
            case .noQRCode:
                String(localized: "No QR code for an account was found. Make sure the whole QR code can be seen.", comment: "Mac QR scan error")
            }
        }
    }

    /// The System Settings pane where screen recording is allowed.
    static let screenRecordingSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// Looks for QR codes on every display, leaving out the app's own windows so the add account sheet can't hide one.
    static func scanScreen() async throws -> URL {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ReadError.noScreenRecordingPermission
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ReadError.noScreenRecordingPermission
        }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            if let url = otpauthURLs(in: CIImage(cgImage: image)).first {
                return url
            }
        }
        throw ReadError.noQRCode
    }

    /// An otpauth URL from the pasteboard, as text or as a picture of a QR code.
    static func readPasteboard() throws -> URL {
        let pasteboard = NSPasteboard.general
        if let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: string), url.scheme == "otpauth" {
            return url
        }
        if let image = NSImage(pasteboard: pasteboard), let url = otpauthURLs(in: image).first {
            return url
        }
        throw ReadError.noQRCode
    }

    /// An otpauth URL from dropped or imported items: images, image files or the URL itself.
    static func read(_ providers: [NSItemProvider]) async throws -> URL {
        for provider in providers {
            if let data = try? await provider.data(of: .image), let image = NSImage(data: data),
               let url = otpauthURLs(in: image).first {
                return url
            }
            if let data = try? await provider.data(of: .url), let url = URL(dataRepresentation: data, relativeTo: nil) {
                if url.scheme == "otpauth" {
                    return url
                }
                if url.isFileURL, let image = NSImage(contentsOf: url), let otpauthURL = otpauthURLs(in: image).first {
                    return otpauthURL
                }
            }
        }
        throw ReadError.noQRCode
    }

    static func otpauthURLs(in image: NSImage) -> [URL] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return otpauthURLs(in: CIImage(cgImage: cgImage))
    }

    static func otpauthURLs(in image: CIImage) -> [URL] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: image) ?? []
        return features
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .compactMap { URL(string: $0) }
            .filter { $0.scheme == "otpauth" }
    }
}

private extension NSItemProvider {
    func data(of type: UTType) async throws -> Data? {
        guard hasItemConformingToTypeIdentifier(type.identifier) else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(for: type) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

#endif
