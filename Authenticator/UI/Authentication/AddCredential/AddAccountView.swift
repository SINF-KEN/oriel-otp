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

/// Where a new account is saved: on the YubiKey, in Ente Auth, or both.
struct AccountDestinations: OptionSet, Hashable {
    let rawValue: Int
    static let yubiKey = AccountDestinations(rawValue: 1 << 0)
    /// The Ente Auth vault on this device, which uploads it to Ente.
    static let ente = AccountDestinations(rawValue: 1 << 1)
    static let both: AccountDestinations = [.yubiKey, .ente]
}

struct AddAccountView: View {

    @Binding var showAddAccount: Bool
    /// The new account, whether it requires touch and where to save it.
    var accountSubject: PassthroughSubject<(YubiKitOATHSession.CredentialTemplate?, Bool, AccountDestinations), Never>
    /// Where the account can be saved: on the YubiKey if one can be reached, in Ente Auth while an account is saved.
    private let availableDestinations: AccountDestinations

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
    /// The last choice of where to save, the default when both can be chosen.
    @AppStorage("AddAccount.Destinations") private var lastDestinations = AccountDestinations.yubiKey.rawValue
    @State private var chosenDestinations: AccountDestinations
    // Adding to Ente Auth goes through the vault of the saved account, so it is only offered when there is one.
    private let enteEmail = EnteCloud.shared.email
    @FocusState private var focusedField: Field?

    init(showAddCredential: Binding<Bool>, accountSubject: PassthroughSubject<(YubiKitOATHSession.CredentialTemplate?, Bool, AccountDestinations), Never>,
         oathURL: URL?, destinations: AccountDestinations) {
        _showAddAccount = showAddCredential
        self.accountSubject = accountSubject
        availableDestinations = destinations
        let defaults = UserDefaults.standard
        // Before the choice, a switch added accounts to Ente Auth as well as the YubiKey.
        if defaults.bool(forKey: "EnteAuth.AddNewAccounts") {
            defaults.set(AccountDestinations.both.rawValue, forKey: "AddAccount.Destinations")
            defaults.removeObject(forKey: "EnteAuth.AddNewAccounts")
        }
        let last = AccountDestinations(rawValue: defaults.object(forKey: "AddAccount.Destinations") as? Int ?? AccountDestinations.yubiKey.rawValue)
        _chosenDestinations = State(initialValue: last.isEmpty || !destinations.isSuperset(of: last) ? .yubiKey : last)
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
                    if destinations.contains(.yubiKey) {
                        Toggle(String(localized: "Require touch", comment: "Add account toggle"), isOn: $requiresTouch)
                    }
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

                destinationSection

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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // VoiceOver's escape gesture, a two-finger Z, does the same as Cancel.
            .accessibilityAction(.escape) { showAddAccount = false }
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
            accountSubject.send((nil, true, []))
        }
    }

    private var title: String {
        availableDestinations == .ente ? String(localized: "Add to Ente Auth", comment: "Add account navigation title when adding to Ente Auth only")
            : String(localized: "Add account", comment: "Add account navigation title")
    }

    private var isHOTP: Bool {
        if mode == .manual { return kind == .hotp }
        if case .hotp = template?.type { return true }
        return false
    }

    /// Where the account is saved. A HOTP account is saved in one place only, as each copy would count its codes on
    /// its own and they would fall out of step.
    private var destinations: AccountDestinations {
        guard availableDestinations == .both else { return availableDestinations }
        return isHOTP && chosenDestinations == .both ? .yubiKey : chosenDestinations
    }

    @ViewBuilder private var destinationSection: some View {
        if availableDestinations == .both, let enteEmail {
            Section {
                Picker(String(localized: "Save to", comment: "Add account picker of where the account is saved"),
                       selection: Binding(get: { destinations }, set: { chosenDestinations = $0 })) {
                    Text(String(localized: "YubiKey", comment: "Add account destination")).tag(AccountDestinations.yubiKey)
                    Text(String(localized: "Ente Auth", comment: "Add account destination")).tag(AccountDestinations.ente)
                    if !isHOTP {
                        Text(String(localized: "YubiKey and Ente Auth", comment: "Add account destination")).tag(AccountDestinations.both)
                    }
                }
            } footer: {
                switch destinations {
                case .ente:
                    Text(String(localized: "The account is saved in Ente Auth for \(enteEmail) and appears on your other devices.", comment: "Add account footer when adding to Ente Auth only. The placeholder is an email address."))
                case .both:
                    Text(String(localized: "Saves the account in Ente Auth for \(enteEmail) too. A YubiKey never gives its accounts back, so this is the only time it can be copied.", comment: "Add account Ente Auth footer. The placeholder is an email address."))
                default:
                    if isHOTP {
                        Text(String(localized: "A HOTP account is saved in one place only, as each copy would count its codes on its own.", comment: "Add account footer for a HOTP account"))
                    } else {
                        Text(String(localized: "A YubiKey never gives its accounts back, so it can't be copied to Ente Auth later. Choose YubiKey and Ente Auth to keep it in both.", comment: "Add account footer when adding to the YubiKey only"))
                    }
                }
            }
        } else if availableDestinations == .ente, let enteEmail {
            Section {
                Label(String(localized: "Stored in Ente Auth", comment: "Where an account is stored"), systemImage: "cloud")
            } footer: {
                Text(String(localized: "The account is saved in Ente Auth for \(enteEmail) and appears on your other devices.", comment: "Add account footer when adding to Ente Auth only. The placeholder is an email address."))
            }
        } else if enteEmail == nil {
            Section {
            } footer: {
                Text(String(localized: "To save accounts in Ente Auth too, choose Sync from Ente Auth in the menu and sign in with Stay signed in turned on.", comment: "Add account footer without a saved Ente session"))
            }
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
            .accessibilityAction(.escape) { showAddAccount = false }
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
        let destinations = destinations
        if availableDestinations == .both {
            lastDestinations = chosenDestinations.rawValue
        }
        accountSubject.send((credential, destinations.contains(.yubiKey) && requiresTouch, destinations))
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
