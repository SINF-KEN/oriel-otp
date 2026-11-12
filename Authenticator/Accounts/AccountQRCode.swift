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
import CoreImage.CIFilterBuiltins
import SwiftUI

extension EnteCloudCode {
    /// The otpauth link of the account, as other authenticator apps read it from a QR code: the secret and how codes
    /// are made, without Ente's display settings. A HOTP account carries its next counter.
    var otpauthURL: URL? {
        var components = URLComponents()
        components.scheme = "otpauth"
        switch kind {
        case .totp: components.host = "totp"
        case .steam: components.host = "steam"
        case .hotp: components.host = "hotp"
        }
        let issuer = issuer.flatMap { $0.isEmpty ? nil : $0 }
        components.path = OTPAuthURLParser.labelPath(issuer: issuer, accountName: accountName)
        var items = [URLQueryItem(name: "secret", value: secret.base32EncodedString)]
        if let issuer {
            items.append(URLQueryItem(name: "issuer", value: issuer))
        }
        items.append(URLQueryItem(name: "algorithm", value: algorithm.rawValue.uppercased()))
        items.append(URLQueryItem(name: "digits", value: String(digits)))
        if kind == .hotp {
            items.append(URLQueryItem(name: "counter", value: String(counter)))
        } else {
            items.append(URLQueryItem(name: "period", value: String(period)))
        }
        components.queryItems = items
        return components.url
    }
}

/// A QR code, drawn with sharp edges at any size.
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    /// One pixel per module, with the quiet zone around it that readers need.
    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let padded = output.transformed(by: CGAffineTransform(translationX: 4, y: 4))
            .composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -4, dy: -4).offsetBy(dx: 4, dy: 4)))
        return CIContext().createCGImage(padded, from: padded.extent)
    }
}

/// Shows an account's QR code, to add it to another device or app. Anyone who sees the code can make the account's
/// codes, so it's only shown after the app lock's code or password, Face ID or Touch ID (asked before the sheet opens),
/// and closes when the app leaves the foreground, before the system takes its snapshot for the app switcher.
struct AccountQRCodeView: View {
    /// What the sheet is presented for.
    struct Link: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    let account: Account
    let url: URL
    let close: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var isVerified = !AppLock.shared.method.hasSecret
    private var lock: AppLock { .shared }

    var body: some View {
        NavigationStack {
            Group {
                if isVerified {
                    AccountQRCodeContent(account: account, url: url)
                        .padding(24)
                        .scrollsWhenTooTall()
                } else {
                    VStack {
                        Spacer(minLength: 0)
                        AppLockSecretEntry(method: lock.method, prompt: unlockPrompt) { secret in
                            guard lock.verify(secret) else { return false }
                            isVerified = true
                            return true
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(24)
                    .scrollsWhenTooTall()
                }
            }
            #if os(macOS)
            .textScaledFrame(minWidth: 420, idealWidth: 460, minHeight: 520, idealHeight: 560)
            #endif
            .navigationTitle(String(localized: "QR code", comment: "Title of the sheet that shows an account's QR code"))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityAction(.escape, close)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Button that closes the QR code sheet"), action: close)
                        .accessibilityIdentifier("account-qr-code.done")
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { close() }
        }
    }

    private var unlockPrompt: String {
        lock.method == .password
            ? String(localized: "Enter your app lock password to show the QR code", comment: "Prompt for the app lock password before an account's QR code is shown")
            : String(localized: "Enter your app lock code to show the QR code", comment: "Prompt for the app lock code before an account's QR code is shown")
    }
}

/// The account's name, its QR code and what it's for.
struct AccountQRCodeContent: View {
    let account: Account
    let url: URL

    var body: some View {
        VStack(spacing: 16) {
            Text(account.title.leftToRightIfAddress)
                .scaledFont(.title3) { $0.weight(.semibold) }
                .multilineTextAlignment(.center)
            account.subTitle.map {
                Text($0.leftToRightIfAddress)
                    .scaledFont(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            QRCodeImage(text: url.absoluteString)
                .frame(maxWidth: 280, maxHeight: 280)
                .privacySensitive()
                .accessibilityLabel(String(localized: "QR code of the account", comment: "VoiceOver label of an account's QR code"))
                .accessibilityIdentifier("account-qr-code.image")
            Text(String(localized: "Scan it with another device or authenticator app to add the account there. Anyone who sees this code can make the account's codes, so don't share it or take a screenshot of it.", comment: "Under an account's QR code"))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
    }
}
