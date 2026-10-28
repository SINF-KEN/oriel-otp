/*
 * Copyright (C) 2022 Yubico.
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


import SwiftUI
import OSLog

struct SmartCardConfigurationView: View {
    
    @Environment(\.dismiss) private var dismiss
    @State private var model = SmartCardViewModel()
    @State private var certificates: [SmartCardViewModel.Certificate]? = nil
    @State private var tokens = [SecCertificate]()
    @State private var presentHelpAlert = false
    @State private var presentNotificationsAlert = false
    @State private var storeError: Error? = nil
    
    var body: some View {
        List {
            Section {
                SmartCardStatusView(isEnabled: !tokens.isEmpty)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                SmartCardHeaderRow(type: .onYubiKey)
                if let certificates {
                    if certificates.isEmpty {
                        SmartCardMessageRow(message: String(localized: "No certificates on YubiKey", comment: "PIV extension no certificates message"))
                    } else {
                        ForEach(Array(certificates.enumerated()), id: \.offset) { _, certificate in
                            let name = "\(certificate.certificate.subjectSummary ?? String(localized: "No name", comment: "PIV extension certificate with no name")) (slot \(String(format: "%02X", certificate.slot.rawValue)))"
                            if tokens.contains(certificate.certificate) {
                                SmartCardCertificateRow(name: name, symbol: "checkmark.circle")
                            } else {
                                SmartCardCertificateRow(name: name, symbol: "plus.circle") {
                                    storeTokenCertificate(certificate.certificate)
                                }
                            }
                        }
                    }
                } else {
                    SmartCardMessageRow(message: String(localized: "Insert YubiKey or pull down to activate NFC"))
                }
            }
            Section {
                SmartCardHeaderRow(type: .onDevice)
                if tokens.isEmpty {
                    SmartCardMessageRow(message: String(localized: "No public key certificates in keychain", comment: "PIV extension no certs in keychain"))
                } else {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                        SmartCardCertificateRow(name: token.subjectSummary ?? "", symbol: "minus.circle") {
                            model.removeTokenCertificate(certificate: token)
                            model.update()
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("Smart card extension")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentHelpAlert.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
            }
        }
        .alert(String(localized: "Smart card extension", comment: "PIV extension info alert title"), isPresented: $presentHelpAlert, actions: {
            Button(role: .none) {
                if let url = URL(string: "https://docs.yubico.com/software/yubikey/tools/authenticator/auth-guide/smart-card-index.html") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text(String(localized: "Read more...", comment: "PIV extension read more alert title"))
            }
            Button(role: .cancel) {
                presentHelpAlert.toggle()
            } label: {
                Text("Cancel")
            }
        }, message: {
            Text("Other applications can use client certificates on your YubiKey for authentication and signing purposes.")
        })
        .alert(String(localized: "Notifications disabled", comment: "PIV extension notifications alert title"), isPresented: $presentNotificationsAlert, actions: {
            Button(String(localized: "Cancel")) {
                dismiss()
            }
            Button(String(localized: "Settings", comment: "PIV extension settings alert title")) {
                guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(settingsUrl) { success in
                    guard success else { return }
                    dismiss()
                }
            }
        }, message: {
            Text(String(localized: "The smart card extension requires notifications to be enabled for Oriel OTP. Enable it in the iOS Settings.", comment: "PIV extensions notifications alert message"))
        })
        .alert(String(localized: "Failed storing certificate", comment: "PIV extension storing error alert title"), isPresented: .constant(storeError != nil), presenting: storeError) { _ in
            Button(String(localized: "Ok")) { storeError = nil }
        } message: { error in
            Text(verbatim: "Error: \(error)")
        }
        .refreshable(enabled: DeviceCapabilities.supportsNFC) {
            model.startNFC()
        }
        .task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            if !granted {
                presentNotificationsAlert = true
            }
        }
        .onAppear {
            model.certificatesCallback = { result in
                switch result {
                case .success(let certificates):
                    self.certificates = certificates
                case .failure(let error):
                    Logger.ctk.error("SmartCardConfigurationView: failed to fetch certificates: \(error)")
                }
            }
            model.tokensCallback = { result in
                switch result {
                case .success(let tokens):
                    self.tokens = tokens
                case .failure(let error):
                    Logger.ctk.error("SmartCardConfigurationView: failed to fetch tokens: \(error)")
                }
            }
            model.start()
        }
        .onDisappear {
            model.stop()
            model.certificatesCallback = nil
            model.tokensCallback = nil
        }
    }
    
    private func storeTokenCertificate(_ certificate: SecCertificate) {
        if let error = model.storeTokenCertificate(certificate: certificate) {
            storeError = error
        }
        model.update()
    }
}

private struct SmartCardStatusView: View {
    
    let isEnabled: Bool
    
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "minus.circle.fill")
                .font(.system(size: 55))
                .foregroundStyle(isEnabled ? Color(.systemGreen) : Color(.secondaryLabel))
                .accessibilityHidden(true)
            Text(isEnabled ? String(localized: "Enabled", comment: "PIV extension enabled message") : String(localized: "Not Enabled", comment: "PIV extension not enabled message"))
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
    }
}

private struct SmartCardHeaderRow: View {
    
    enum `Type` {
        case onYubiKey
        case onDevice
    }
    
    let type: Type
    private let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    
    var body: some View {
        VStack(spacing: 10) {
            image
                .resizable()
                .scaledToFit()
                .font(Font.title.weight(.semibold))
                .padding(10)
                .frame(width: 60, height: 60)
                .foregroundStyle(.white)
                .background(Color(.systemOrange))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityHidden(true)
            Text(title).font(.title2).bold()
                .multilineTextAlignment(.center)
            Text(text)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
    
    private var image: Image {
        switch type {
        case .onYubiKey: Image("securitykey")
        case .onDevice: Image(systemName: "iphone")
        }
    }
    
    private var title: String {
        switch type {
        case .onYubiKey: String(localized: "Certificates on YubiKey", comment: "PIV extension table cell header")
        case .onDevice: String(localized: "Public key certificates on \(device)", comment: "PIV extension no certs on device")
        }
    }
    
    private var text: String {
        switch type {
        case .onYubiKey: String(localized: "Certificates on this YubiKey can be used to authenticate and sign requests from other applications if added to this \(device).", comment: "PIV extension no certs on yubikey message")
        case .onDevice: String(localized: "These certificates have been added to this \(device) and can be used by other applications.", comment: "PIV extension certs on device")
        }
    }
}

private struct SmartCardMessageRow: View {
    
    let message: String
    
    var body: some View {
        Text(message)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 45)
    }
}

private struct SmartCardCertificateRow: View {
    
    let name: String
    let symbol: String
    var action: (() -> Void)? = nil
    
    var body: some View {
        HStack {
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if let action {
                Button(action: action) {
                    symbolImage
                }
                .buttonStyle(.borderless)
            } else {
                symbolImage
                    .foregroundStyle(.tint)
            }
        }
    }
    
    private var symbolImage: some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .light))
    }
}
