/*
 * Copyright (C) Yubico.
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
import YubiKit
import Combine

struct AddAccountView: View {

    @Binding var showAddAccount: Bool
    /// The new account, whether it requires touch and whether to add it to Ente Auth too.
    var accountSubject: PassthroughSubject<(YubiKitOATHSession.CredentialTemplate?, Bool, Bool), Never>

    private enum EntryMode {
        case scanning, manual, prefilled
    }

    private enum Field {
        case issuer, accountName, secret
    }

    private enum CredentialKind: String, CaseIterable, Identifiable {
        case totp = "TOTP", hotp = "HOTP"
        var id: Self { self }
    }

    private static let algorithms = ["SHA1", "SHA256", "SHA512"]
    private static let digitOptions = [6, 8]
    private static let periods: [TimeInterval] = [15, 30, 60]

    // A template from an otpauth URL or a scanned QR code.
    @State private var template: YubiKitOATHSession.CredentialTemplate?
    @State private var mode: EntryMode
    @State private var issuer = ""
    @State private var accountName = ""
    @State private var secret = ""
    @State private var requiresTouch = false
    @State private var kind = CredentialKind.totp
    @State private var algorithm = "SHA1"
    @State private var digits = 6
    @State private var period: TimeInterval = 30
    @State private var errorMessage: String?
    #if os(macOS)
    @State private var qrCodeError: QRCodeReader.ReadError?
    #endif
    @AppStorage("EnteAuth.AddNewAccounts") private var addToEnte = false
    // Adding to Ente Auth uses the saved session, so it is only offered when there is one.
    private let enteEmail = EnteSessionStore().savedEmail
    @FocusState private var focusedField: Field?

    init(showAddCredential: Binding<Bool>, accountSubject: PassthroughSubject<(YubiKitOATHSession.CredentialTemplate?, Bool, Bool), Never>, oathURL: URL?) {
        _showAddAccount = showAddCredential
        self.accountSubject = accountSubject
        let template = oathURL.flatMap { try? YubiKitOATHSession.CredentialTemplate(otpauthURL: $0) }
        _template = State(initialValue: template)
        #if os(iOS)
        _mode = State(initialValue: template == nil ? .scanning : .prefilled)
        #else
        // The Mac has no camera scanner. QR codes are read from the screen or an image in the form instead.
        _mode = State(initialValue: template == nil ? .manual : .prefilled)
        #endif
        _issuer = State(initialValue: template?.issuer ?? "")
        _accountName = State(initialValue: template?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                if template == nil {
                    qrCodeSection
                }
                #endif
                Section {
                    LabeledContent(String(localized: "Issuer", comment: "Add account field")) {
                        TextField(String(localized: "Optional", comment: "Add account issuer placeholder"), text: $issuer)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .issuer)
                    }
                    LabeledContent(String(localized: "Account name", comment: "Add account field")) {
                        TextField(String("john@doe.com"), text: $accountName)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .submitLabel(mode == .manual ? .next : .done)
                            .focused($focusedField, equals: .accountName)
                    }
                    if mode == .manual {
                        LabeledContent(String(localized: "Secret", comment: "Add account field")) {
                            TextField(String(localized: "Secret", comment: "Add account field"), text: $secret)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .focused($focusedField, equals: .secret)
                        }
                    }
                    Toggle(String(localized: "Require touch", comment: "Add account toggle"), isOn: $requiresTouch)
                } header: {
                    Text(String(localized: "Account details", comment: "Add account section header"))
                }
                .multilineTextAlignment(.trailing)
                .onSubmit {
                    switch focusedField {
                    case .issuer: focusedField = .accountName
                    case .accountName where mode == .manual: focusedField = .secret
                    default: focusedField = nil
                    }
                }

                Section {
                    Toggle(String(localized: "Also add to Ente Auth", comment: "Add account toggle"),
                           isOn: enteEmail == nil ? .constant(false) : $addToEnte)
                        .disabled(enteEmail == nil)
                } footer: {
                    if let enteEmail {
                        Text(String(localized: "Saves the account in Ente Auth for \(enteEmail) too. A YubiKey never gives its accounts back, so this is the only time it can be copied.", comment: "Add account Ente Auth footer. The placeholder is an email address."))
                    } else {
                        Text(String(localized: "To use this, choose Sync from Ente Auth in the menu and sign in with Stay signed in turned on.", comment: "Add account Ente Auth footer without a saved Ente session"))
                    }
                }

                if mode == .manual {
                    Section {
                        Picker(String(localized: "Type", comment: "Add account select type"), selection: $kind) {
                            ForEach(CredentialKind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker(String(localized: "Algorithm", comment: "Add account select algorithm"), selection: $algorithm) {
                            ForEach(Self.algorithms, id: \.self) { Text($0).tag($0) }
                        }
                        Picker(String(localized: "Digits", comment: "Add account select number of digits"), selection: $digits) {
                            ForEach(Self.digitOptions, id: \.self) { Text(String($0)).tag($0) }
                        }
                        if kind == .totp {
                            Picker(String(localized: "Period", comment: "Add account select period"), selection: $period) {
                                ForEach(Self.periods, id: \.self) { Text(String(Int($0))).tag($0) }
                            }
                        }
                    } header: {
                        Text(String(localized: "Advanced settings", comment: "Add account section header"))
                    } footer: {
                        Text(String(localized: "Normally these settings should not be changed, doing so may result in the code not working as expected", comment: "Add account advanced settings footer"))
                    }
                    #if os(iOS)
                    .pickerStyle(.navigationLink)
                    #endif
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Add account", comment: "Add account navigation title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { showAddAccount = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(String(localized: "Save")) { save() }
                }
            }
            #if os(macOS)
            .onDrop(of: [.image, .fileURL, .url], isTargeted: nil) { providers in
                readQRCode { try await QRCodeReader.read(providers) }
                return true
            }
            // File > Import from iPhone or iPad, to take a picture of a QR code with Continuity Camera.
            .importsItemProviders([.image]) { providers in
                readQRCode { try await QRCodeReader.read(providers) }
                return true
            }
            .frame(minWidth: 460, idealWidth: 500, minHeight: 400, idealHeight: 520)
            #endif
            .alert(String(localized: "Not valid credential information", comment: "Add account error message"),
                   isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
            #if os(macOS)
            .alert(String(localized: "Couldn't read a QR code", comment: "Mac add account QR code error title"),
                   isPresented: Binding(get: { qrCodeError != nil }, set: { if !$0 { qrCodeError = nil } }), presenting: qrCodeError) { error in
                if case .noScreenRecordingPermission = error {
                    Button(String(localized: "Open System Settings", comment: "Mac add account QR code error")) {
                        Platform.open(QRCodeReader.screenRecordingSettings)
                    }
                }
                Button("OK", role: .cancel) { }
            } message: { error in
                Text(error.localizedDescription)
            }
            #endif
        }
        // Covered by the scanner, so VoiceOver shouldn't reach it either.
        .accessibilityHidden(mode == .scanning)
        #if os(iOS)
        .overlay {
            if mode == .scanning {
                scanner
            }
        }
        #endif
        .onDisappear {
            accountSubject.send((nil, true, false))
        }
    }

    #if os(iOS)
    private var scanner: some View {
        NavigationStack {
            ScanAccountRepresentable { account in
                template = account
                issuer = account.issuer ?? ""
                accountName = account.name
                mode = .prefilled
            }
            .ignoresSafeArea()
            .navigationTitle(String(localized: "Add account", comment: "Add account navigation title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { showAddAccount = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { mode = .manual } label: {
                        Label(String(localized: "Enter manually", comment: "Scan QR code add manually button"), systemImage: "keyboard")
                    }
                }
            }
        }
        // The camera preview is dark in both appearances.
        .environment(\.colorScheme, .dark)
    }
    #endif

    #if os(macOS)
    private var qrCodeSection: some View {
        Section {
            Button {
                readQRCode { try await QRCodeReader.scanScreen() }
            } label: {
                Label(String(localized: "Scan QR Code on Screen", comment: "Mac add account button"), systemImage: "qrcode.viewfinder")
            }
            Button {
                readQRCode { try QRCodeReader.readPasteboard() }
            } label: {
                Label(String(localized: "Paste QR Code or Link", comment: "Mac add account button"), systemImage: "doc.on.clipboard")
            }
        } header: {
            Text(String(localized: "QR code", comment: "Mac add account section header"))
        } footer: {
            Text(String(localized: "Show the QR code on screen, copy it, or drop a picture of it here. To take a picture with your iPhone or iPad, use the File menu. Or enter the details below.", comment: "Mac add account QR code footer"))
        }
    }

    private func readQRCode(_ read: @escaping () async throws -> URL) {
        Task {
            do {
                let url = try await read()
                let template = try YubiKitOATHSession.CredentialTemplate(otpauthURL: url)
                self.template = template
                issuer = template.issuer ?? ""
                accountName = template.name
                mode = .prefilled
            } catch let error as QRCodeReader.ReadError {
                qrCodeError = error
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    #endif

    private func save() {
        let credential: YubiKitOATHSession.CredentialTemplate
        do {
            switch mode {
            case .manual:
                let secret = Data(base32Encoded: secret.replacingOccurrences(of: " ", with: "")) ?? Data()
                let type: YubiKitOATHSession.CredentialType = kind == .hotp ? .hotp(counter: 0) : .totp(period: period)
                credential = try YubiKitOATHSession.CredentialTemplate(type: type,
                                                                       algorithm: .algorithmFromString(algorithm),
                                                                       secret: secret,
                                                                       issuer: issuer,
                                                                       accountName: accountName,
                                                                       digits: digits)
            case .prefilled, .scanning:
                guard let template else { return }
                credential = try YubiKitOATHSession.CredentialTemplate(type: template.type,
                                                                       algorithm: template.algorithm,
                                                                       secret: template.secret,
                                                                       issuer: issuer,
                                                                       accountName: accountName,
                                                                       digits: Int(template.digits))
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        accountSubject.send((credential, requiresTouch, addToEnte && enteEmail != nil))
        showAddAccount = false
    }
}

#if os(iOS)
// Hosts the QR scanner. It sits in a container because it removes itself from its superview when it finishes.
private struct ScanAccountRepresentable: UIViewRepresentable {

    let completion: (YubiKitOATHSession.CredentialTemplate) -> Void

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let scanView = ScanAccountView(frame: container.bounds, completionHandler: completion)
        scanView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(scanView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
    }
}
#endif

extension YubiKitOATHSession.HashAlgorithm {

    static func algorithmFromString(_ string: String) -> YubiKitOATHSession.HashAlgorithm {
        switch string {
        case "SHA256":
            return .sha256
        case "SHA512":
            return .sha512
        default:
            return .sha1
        }
    }
}
