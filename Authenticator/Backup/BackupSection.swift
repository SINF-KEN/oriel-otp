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

import SwiftUI
import UniformTypeIdentifiers

/// Backing up and restoring the accounts kept only on this device, in settings.
///
/// Making a backup asks for the app lock, or the device's owner, first: the file holds the accounts' secrets under a
/// password its maker chooses, so someone handed the unlocked app could otherwise take them along.
struct BackupSection: View {

    private var device: DeviceAccounts { .shared }
    private var lock: AppLock { .shared }

    @State private var isBackingUp = false
    @State private var isPickingFile = false
    @State private var isPickingImport = false
    @State private var picked: PickedBackup?
    @State private var notice: String?
    @State private var error: Error?

    var body: some View {
        Section {
            Button(String(localized: "Back up accounts…", comment: "Backup settings button")) {
                Task { await requestBackup() }
            }
            .disabled(device.accounts.isEmpty)
            .accessibilityIdentifier("backup.create")
            // On the button: on the section each row would present it, and the sheets would close each other.
            .sheet(isPresented: $isBackingUp) {
                BackupView(rawData: device.backupData) { saved in
                    isBackingUp = false
                    if saved {
                        notice = String(localized: "Backup saved. Keep the file and its password somewhere safe, away from this device.", comment: "Message after a backup was saved")
                    }
                }
                .appLockCover()
            }
            Button(String(localized: "Restore from backup…", comment: "Backup settings button")) {
                isPickingFile = true
            }
            .accessibilityIdentifier("backup.restore")
            .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.json, .plainText]) { result in
                switch result {
                case .success(let url): open(url)
                case .failure(let error): self.error = error
                }
            }
            .sheet(item: $picked) { picked in
                RestoreView(data: picked.data) { result in
                    self.picked = nil
                    if let result { notice = Self.summary(of: result) }
                }
                .appLockCover()
            }
            Button(String(localized: "Import from another app…", comment: "Backup settings button that imports accounts exported by another authenticator app")) {
                isPickingImport = true
            }
            .accessibilityIdentifier("backup.import")
            .fileImporter(isPresented: $isPickingImport, allowedContentTypes: AuthenticatorImportFile.contentTypes) { result in
                switch result {
                case .success(let url): importAccounts(from: url)
                case .failure(let error): self.error = error
                }
            }
        } header: {
            Text(String(localized: "Backup", comment: "Backup settings section header"))
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if device.accounts.isEmpty {
                    Text(String(localized: "Accounts saved on this device can be backed up to a file encrypted with a password you choose. There are none yet. A backup, or an encrypted export from Ente Auth, can be restored here.", comment: "Backup settings footer without accounts on this device"))
                } else {
                    Text(String(localized: "Saves the accounts kept only on this device to a file encrypted with a password you choose, which Ente Auth can open too. Without a backup they're lost with the device. Accounts on a YubiKey or in Ente Auth aren't included.", comment: "Backup settings footer"))
                }
                Text(String(localized: "Import reads exports from Google Authenticator (a screenshot of its QR code), Aegis, 2FAS and Raivo without encryption, and text files of otpauth links. The accounts are saved on this device. Delete the export afterwards: anyone with it has the accounts.", comment: "Backup settings footer about importing from another authenticator app"))
            }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(String(localized: "OK", comment: "OK button in error alert."), role: .cancel) {}
        }
        .errorAlert(error: $error)
    }

    /// Checks who is asking, then opens the sheet, which asks for the app lock's code or password itself.
    private func requestBackup() async {
        if !lock.method.hasSecret, AppLock.canUseDeviceOwner {
            guard await lock.verifyDeviceOwnerForBackup() else { return }
        }
        isBackingUp = true
    }

    private func open(_ url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= DeviceBackup.maximumFileSize,
              let data = try? Data(contentsOf: url), DeviceBackup.isBackup(data) else {
            error = DeviceBackupError.notABackup
            return
        }
        picked = PickedBackup(data: data)
    }

    /// Adds the accounts of another app's export to this device. A backup made by this app, or by Ente Auth, is
    /// restored with its password instead.
    private func importAccounts(from url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= AuthenticatorImport.maximumFileSize,
              let data = try? Data(contentsOf: url) else {
            error = AuthenticatorImportError.unknownFormat
            return
        }
        if DeviceBackup.isBackup(data) {
            picked = PickedBackup(data: data)
            return
        }
        do {
            let urls = try AuthenticatorImportFile.otpauthURLs(from: data)
            notice = Self.summary(of: try device.restore(backupLines: urls), imported: true)
        } catch {
            self.error = error
        }
    }

    /// Counts after a colon rather than in a sentence, which reads right for any number in every language.
    static func summary(of result: DeviceAccounts.RestoreResult, imported: Bool = false) -> String {
        var lines = [imported
            ? String(localized: "Accounts imported: \(result.added)", comment: "Import result. The placeholder is a number.")
            : String(localized: "Accounts restored: \(result.added)", comment: "Backup restore result. The placeholder is a number.")]
        if result.alreadyPresent > 0 {
            lines.append(String(localized: "Already on this device: \(result.alreadyPresent)", comment: "Backup restore result. The placeholder is a number of accounts."))
        }
        if result.skipped > 0 {
            lines.append(String(localized: "Couldn't be read: \(result.skipped)", comment: "Backup restore result. The placeholder is a number of accounts."))
        }
        return lines.joined(separator: "\n")
    }
}

private struct PickedBackup: Identifiable {
    let id = UUID()
    let data: Data
}

/// The backup as a file for the system's save dialog.
nonisolated struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Asks for the app lock's code or password if there is one, then for the backup's password twice, and saves the file.
private struct BackupView: View {

    let rawData: [String]
    /// Called with whether a backup was saved.
    let done: (Bool) -> Void

    private var lock: AppLock { .shared }

    @State private var isVerified: Bool
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isEncrypting = false
    @State private var document: BackupDocument?
    @State private var isExporting = false
    @State private var error: Error?

    init(rawData: [String], done: @escaping (Bool) -> Void) {
        self.rawData = rawData
        self.done = done
        _isVerified = State(initialValue: !AppLock.shared.method.hasSecret)
    }

    private var isLongEnough: Bool { password.count >= DeviceBackup.minimumPasswordLength }
    private var canSave: Bool { isLongEnough && password == confirmation && !isEncrypting }

    var body: some View {
        NavigationStack {
            Group {
                if isVerified {
                    form
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
            .textScaledFrame(minWidth: 460, idealWidth: 500, minHeight: 400, idealHeight: 460)
            #endif
            .navigationTitle(String(localized: "Back up accounts", comment: "Backup navigation title"))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityAction(.escape) { done(false) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { done(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isEncrypting { ProgressView() }
                }
            }
            .errorAlert(error: $error)
            .fileExporter(isPresented: $isExporting, document: document, contentType: .json, defaultFilename: DeviceBackup.fileName()) { result in
                switch result {
                case .success: done(true)
                case .failure(let error): self.error = error
                }
            }
        }
        .interactiveDismissDisabled(isEncrypting)
    }

    private var unlockPrompt: String {
        lock.method == .password
            ? String(localized: "Enter your app lock password to back up your accounts", comment: "Backup prompt for the app lock password")
            : String(localized: "Enter your app lock code to back up your accounts", comment: "Backup prompt for the app lock code")
    }

    private var form: some View {
        Form {
            Section {
                SecureField(String(localized: "Password", comment: "Ente sign in field"), text: $password)
                    .accessibilityIdentifier("backup.password")
                SecureField(String(localized: "Confirm password", comment: "Ente account creation field"), text: $confirmation)
                    .accessibilityIdentifier("backup.confirmation")
                    .onSubmit { if canSave { save() } }
                Button(String(localized: "Save backup…", comment: "Backup button that encrypts the accounts and opens the save dialog")) { save() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("backup.save")
            } header: {
                Text(String(localized: "Backup password", comment: "Backup password section header"))
            } footer: {
                if isEncrypting {
                    Text(String(localized: "Encrypting your accounts. This can take a few seconds.", comment: "Backup progress"))
                } else if isLongEnough, !confirmation.isEmpty, password != confirmation {
                    Text(String(localized: "The passwords don't match.", comment: "Backup password footer when the two entries differ"))
                } else {
                    Text(String(localized: "Choose a password of at least \(DeviceBackup.minimumPasswordLength) characters. Anyone with the file can try passwords as often as they like, so pick a long one. You need it to restore the backup: it can't be reset, and it isn't stored in the app.", comment: "Backup password footer. The placeholder is the minimum length, 8."))
                }
            }
        }
        .formStyle(.grouped)
        .scaledButtonLabels()
        .scrollDismissesKeyboard(.immediately)
        .disabled(isEncrypting)
    }

    private func save() {
        guard canSave else { return }
        isEncrypting = true
        let rawData = rawData
        let password = password
        Task {
            do {
                // Off the main actor: deriving the key takes seconds.
                let data = try await Task.detached(priority: .userInitiated) {
                    try DeviceBackup.encrypt(rawData: rawData, password: password)
                }.value
                document = BackupDocument(data: data)
                isExporting = true
            } catch {
                self.error = error
            }
            isEncrypting = false
        }
    }
}

/// Asks for the password of a backup and adds its accounts to this device.
private struct RestoreView: View {

    let data: Data
    /// Called with what was restored, nil if nothing was.
    let done: (DeviceAccounts.RestoreResult?) -> Void

    private var device: DeviceAccounts { .shared }

    @State private var password = ""
    @State private var isDecrypting = false
    @State private var error: Error?

    private var canRestore: Bool { !password.isEmpty && !isDecrypting }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(String(localized: "Password", comment: "Ente sign in field"), text: $password)
                        .accessibilityIdentifier("restore.password")
                        .onSubmit { if canRestore { restore() } }
                    Button(String(localized: "Restore accounts", comment: "Backup restore button")) { restore() }
                        .disabled(!canRestore)
                        .accessibilityIdentifier("restore.restore")
                } header: {
                    Text(String(localized: "Backup password", comment: "Backup password section header"))
                } footer: {
                    if isDecrypting {
                        Text(String(localized: "Decrypting the backup. This can take a few seconds.", comment: "Backup restore progress"))
                    } else {
                        Text(String(localized: "Enter the password the backup was made with. Its accounts are added to this device. Accounts that are here already are left as they are.", comment: "Backup restore footer"))
                    }
                }
            }
            .formStyle(.grouped)
            .scaledButtonLabels()
            .scrollDismissesKeyboard(.immediately)
            .disabled(isDecrypting)
            #if os(macOS)
            .textScaledFrame(minWidth: 460, idealWidth: 500, minHeight: 320, idealHeight: 360)
            #endif
            .navigationTitle(String(localized: "Restore from backup", comment: "Backup restore navigation title"))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityAction(.escape) { done(nil) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { done(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isDecrypting { ProgressView() }
                }
            }
            .errorAlert(error: $error)
        }
        .interactiveDismissDisabled(isDecrypting)
    }

    private func restore() {
        guard canRestore else { return }
        isDecrypting = true
        let data = data
        let password = password
        Task {
            do {
                // Off the main actor: deriving the key takes seconds.
                let lines = try await Task.detached(priority: .userInitiated) {
                    try DeviceBackup.decrypt(data, password: password)
                }.value
                done(try device.restore(backupLines: lines))
            } catch {
                self.error = error
                isDecrypting = false
            }
        }
    }
}
