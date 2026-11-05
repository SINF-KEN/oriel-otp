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
import CoreMedia
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Finds otpauth QR codes without a camera: in a window, in images and on the pasteboard.
enum QRCodeReader {

    enum ReadError: LocalizedError {
        case windowNotCaptured
        case noQRCode

        var errorDescription: String? {
            switch self {
            case .windowNotCaptured:
                String(localized: "That window couldn't be read. Copy the QR code or drop a picture of it here instead.", comment: "Mac QR scan error")
            case .noQRCode:
                String(localized: "No QR code for an account was found. Make sure the whole QR code can be seen.", comment: "Mac QR scan error")
            }
        }
    }

    /// Looks for QR codes in a window the person picks in the system's picker. The picker gives access to that one
    /// window, which is why this needs no Screen Recording permission. Throws `CancellationError` if they cancel it.
    @MainActor
    static func scanWindow() async throws -> URL {
        let picker = WindowPicker()
        defer { picker.close() }
        let filter = try await picker.pick()
        let image = try await WindowCapture().firstFrame(of: filter)
        guard let url = otpauthURLs(in: image).first else { throw ReadError.noQRCode }
        return url
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

/// A continuation fed by system callbacks: the first result counts and the later ones are ignored.
private nonisolated final class FirstResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    func wait(starting start: () -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            start()
        }
    }

    func resume(with result: Result<Value, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        // Handed over once, and the sender doesn't touch it afterwards.
        nonisolated(unsafe) let result = result
        continuation?.resume(with: result)
    }
}

/// Shows the system's window picker, without the app's own windows, as those can't hold the QR code.
private nonisolated final class WindowPicker: NSObject, SCContentSharingPickerObserver {
    private let result = FirstResult<SCContentFilter>()

    @MainActor
    func pick() async throws -> SCContentFilter {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = .singleWindow
        configuration.allowsChangingSelectedContent = false
        configuration.excludedBundleIDs = Bundle.main.bundleIdentifier.map { [$0] } ?? []
        picker.configuration = configuration
        // Without this the system offers to share with the app from its video menu too.
        picker.maximumStreamCount = 0
        picker.add(self)
        picker.isActive = true
        return try await result.wait { picker.present(using: .window) }
    }

    /// Call this after the capture, as the filter comes from the active picker.
    @MainActor
    func close() {
        let picker = SCContentSharingPicker.shared
        picker.isActive = false
        picker.remove(self)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        result.resume(with: .success(filter))
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        result.resume(with: .failure(CancellationError()))
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        result.resume(with: .failure(QRCodeReader.ReadError.windowNotCaptured))
    }
}

/// Takes one frame of a picked window. It has to be a stream: `SCScreenshotManager` is refused a picker's filter
/// without the Screen Recording permission.
private nonisolated final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// So that the capture can't stay on when no frame comes, e.g. because the window was closed.
    private static let timeout: DispatchTimeInterval = .seconds(5)

    private let result = FirstResult<CIImage>()

    func firstFrame(of filter: SCContentFilter) async throws -> CIImage {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        } catch {
            throw QRCodeReader.ReadError.windowNotCaptured
        }
        do {
            let image = try await result.wait { start(stream) }
            try? await stream.stopCapture()
            return image
        } catch {
            try? await stream.stopCapture()
            throw error
        }
    }

    private func start(_ stream: SCStream) {
        stream.startCapture { [result] error in
            if error != nil {
                result.resume(with: .failure(QRCodeReader.ReadError.windowNotCaptured))
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) { [result] in
            result.resume(with: .failure(QRCodeReader.ReadError.windowNotCaptured))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isCompleteFrame, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        result.resume(with: .success(CIImage(cvPixelBuffer: pixelBuffer)))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        result.resume(with: .failure(QRCodeReader.ReadError.windowNotCaptured))
    }
}

private nonisolated extension CMSampleBuffer {
    /// Whether this is a new picture, rather than a notice that nothing changed.
    var isCompleteFrame: Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        guard let status = attachments?.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: status) == .complete
    }
}

#endif
