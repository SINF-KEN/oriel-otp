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

import Foundation
import YubiKit

/// An account kept only on this device, in the format Ente's apps store, so it can move to Ente Auth as it is.
nonisolated struct DeviceAccountItem: Codable, Sendable, Equatable {
    let id: String
    var rawData: String
}

/// Where the accounts are kept: an encrypted file in the app, memory in the tests.
nonisolated protocol DeviceAccountStorage: Sendable {
    func load() throws -> [DeviceAccountItem]?
    func save(_ items: [DeviceAccountItem]) throws
    /// Moves a file that couldn't be read out of the way, so saving doesn't write over it.
    func setAside() throws
    /// Hands over the accounts of each file set aside earlier that can be read now, and deletes the file unless
    /// `keep` throws.
    func recoverSetAside(_ keep: ([DeviceAccountItem]) throws -> Void)
}

nonisolated extension DeviceAccountStorage {
    func recoverSetAside(_ keep: ([DeviceAccountItem]) throws -> Void) {}
}

/// Keeps the accounts in an encrypted file with a key of its own, apart from the Ente vault, which is replaced when
/// the person signs in to another Ente account.
nonisolated struct DeviceAccountFile: DeviceAccountStorage {

    private let file: EncryptedFile<[DeviceAccountItem]>

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(components: "DeviceAccounts", "Accounts")
    }

    init(url: URL = defaultURL, keychain: EnteVaultKeychain = EnteVaultKeychainKey(service: "DeviceAccounts")) {
        file = EncryptedFile(url: url, keychain: keychain)
    }

    func load() throws -> [DeviceAccountItem]? { try file.load() }
    func save(_ items: [DeviceAccountItem]) throws { try file.save(items) }

    func setAside() throws { try file.setAside() }
    func recoverSetAside(_ keep: ([DeviceAccountItem]) throws -> Void) { file.recoverSetAside(keep) }
}

enum DeviceAccountsError: Error, LocalizedError {
    /// The accounts can't be read right now, so saving would write over them.
    case unavailable

    var errorDescription: String? {
        String(localized: "The accounts on this device can't be read right now. Unlock the device and try again.", comment: "Error when changing an account on this device")
    }
}

/// The accounts kept only on this device, for people without a YubiKey or an Ente account. The app calculates their
/// codes.
///
/// This is the only copy, unless the person makes a backup (`DeviceBackup`): the file isn't in the device's backups
/// and its key never leaves the device. So a change that can't be saved is reported rather than dropped, and nothing
/// is saved while the file couldn't be read, which would write over the accounts in it.
@Observable final class DeviceAccounts {

    static let shared = DeviceAccounts()

    enum AddResult: Equatable {
        case added
        case alreadyPresent
    }

    /// An account that can be shown in the account list.
    struct Account: Equatable {
        let id: String
        let code: EnteCloudCode
    }

    private var items: [DeviceAccountItem] = []

    /// Called after the accounts changed.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let storage: DeviceAccountStorage
    /// The file couldn't be read yet, e.g. because the app was launched in the background on a locked device.
    @ObservationIgnored private var isLocked = false
    /// The file can't be read at all, e.g. it was written by a later version of the app. It is set aside before the
    /// first save rather than written over.
    @ObservationIgnored private var isUnreadable = false

    init(storage: DeviceAccountStorage = DeviceAccountFile()) {
        self.storage = storage
        load()
    }

    private func load() {
        do {
            items = try storage.load() ?? []
            isLocked = false
        } catch EnteVaultError.unreadable {
            // Its key is gone or it is damaged, which reading it again won't change.
            items = []
            isLocked = false
            isUnreadable = true
        } catch {
            isLocked = true
        }
        recoverSetAside()
    }

    /// Brings back the accounts of files that were set aside because they couldn't be read, once they can, e.g.
    /// after the app that wrote them is installed again.
    private func recoverSetAside() {
        guard !isLocked else { return }
        storage.recoverSetAside { items in
            try keep(rawData: items.map(\.rawData))
        }
    }

    /// Reads the accounts if they couldn't be read before, e.g. when the app comes to the foreground.
    func loadIfLocked() {
        guard isLocked else { return }
        load()
        if !isLocked {
            onChange?()
        }
    }

    /// The accounts whose codes can be calculated.
    var accounts: [Account] {
        items.compactMap { item in
            EnteCloudCode(rawData: item.rawData).map { Account(id: item.id, code: $0) }
        }
    }

    /// Adds an account, unless there is one with the same name.
    func add(_ template: YubiKitOATHSession.CredentialTemplate) throws -> AddResult {
        let credentialId = OATHCredentialId.key(accountName: template.name, issuer: template.issuer,
                                                period: UInt(template.type.period ?? 0), isTOTP: template.type.period != nil)
        let isPresent = items.contains { EnteCodeParser.parse(id: $0.id, rawData: $0.rawData)?.credentialId == credentialId }
        guard !isPresent else { return .alreadyPresent }
        let rawData = String(decoding: try EnteCodeExporter.rawData(for: template), as: UTF8.self)
        // An account that can't be listed would be kept without anyone seeing it.
        guard EnteCloudCode(rawData: rawData) != nil else { throw CredentialTemplateError.type }
        try update { $0.append(DeviceAccountItem(id: UUID().uuidString.lowercased(), rawData: rawData)) }
        return .added
    }

    func rename(_ id: String, issuer: String, accountName: String) throws {
        guard let code = code(of: id), (code.issuer ?? "", code.accountName) != (issuer, accountName) else { return }
        try edit(id) { $0.rename(issuer: issuer, accountName: accountName) }
    }

    /// A pin that can't be saved is simply gone at the next launch, so it isn't reported.
    func setPinned(_ id: String, _ isPinned: Bool) {
        guard let code = code(of: id), code.isPinned != isPinned else { return }
        try? edit(id) { $0.isPinned = isPinned }
    }

    /// In the format Ente Auth keeps them, so they go along when the account moves there.
    func setTags(_ id: String, _ tags: [String]) throws {
        guard let code = code(of: id), code.tags != EnteEntry.cleaned(tags) else { return }
        try edit(id) { $0.tags = tags }
    }

    func delete(_ id: String) throws {
        try update { $0.removeAll { $0.id == id } }
    }

    /// Keeps accounts whose only copy was in the Ente vault, which is being discarded, e.g. ones moved to Ente Auth
    /// that never reached it. One that is here already isn't added again.
    func keep(rawData: [String]) throws {
        try update { items in
            for rawData in rawData {
                let code = EnteCloudCode(rawData: rawData)
                let isPresent = items.contains { item in
                    item.rawData == rawData || code.map { code in EnteCloudCode(rawData: item.rawData)?.isSameAccount(as: code) == true } == true
                }
                if !isPresent {
                    items.append(DeviceAccountItem(id: UUID().uuidString.lowercased(), rawData: rawData))
                }
            }
        }
    }

    /// What restoring a backup did.
    struct RestoreResult: Equatable {
        var added = 0
        /// The same account, with the same secret, is on this device already.
        var alreadyPresent = 0
        /// Not an account whose codes the app can calculate, e.g. one in Ente Auth's trash.
        var skipped = 0
    }

    /// The accounts as they are stored, for `DeviceBackup` to encrypt.
    var backupData: [String] { items.map(\.rawData) }

    /// Adds the accounts of a backup, given as its lines. One that is here already is left as it is, with its own
    /// HOTP counter, which may have moved on since the backup. Nothing is added if they can't all be saved.
    @discardableResult func restore(backupLines: [String]) throws -> RestoreResult {
        var result = RestoreResult()
        try update { items in
            var codes = items.compactMap { EnteCloudCode(rawData: $0.rawData) }
            for line in backupLines {
                guard let rawData = DeviceBackup.rawData(forLine: line), let code = EnteCloudCode(rawData: rawData) else {
                    result.skipped += 1
                    continue
                }
                if codes.contains(where: { $0.isSameAccount(as: code) }) {
                    result.alreadyPresent += 1
                } else {
                    items.append(DeviceAccountItem(id: UUID().uuidString.lowercased(), rawData: rawData))
                    codes.append(code)
                    result.added += 1
                }
            }
        }
        return result
    }

    /// Returns the next HOTP code and moves the counter on. Nil if that can't be saved, as the code would be given
    /// out again, or if the counter is at its end.
    func nextHOTPCode(_ id: String) -> String? {
        guard let code = code(of: id), code.kind == .hotp else { return nil }
        let (next, overflow) = code.counter.addingReportingOverflow(1)
        guard !overflow else { return nil }
        do {
            try edit(id) { $0.counter = next }
        } catch {
            return nil
        }
        return code.hotpCode()
    }

    private func code(of id: String) -> EnteCloudCode? {
        rawData(of: id).flatMap(EnteCloudCode.init(rawData:))
    }

    func rawData(of id: String) -> String? {
        items.first { $0.id == id }?.rawData
    }

    /// The credential to put the account on a YubiKey with, nil if a YubiKey can't store it.
    func yubiKeyTemplate(of id: String) -> YubiKitOATHSession.CredentialTemplate? {
        rawData(of: id).flatMap { EnteCodeParser.parse(id: id, rawData: $0)?.template }
    }

    private func edit(_ id: String, _ change: (inout EnteEntryEditor) -> Void) throws {
        guard let index = items.firstIndex(where: { $0.id == id }), var editor = EnteEntryEditor(rawData: items[index].rawData) else { return }
        change(&editor)
        guard let rawData = editor.rawData, rawData != items[index].rawData else { return }
        try update { $0[index].rawData = rawData }
    }

    /// Changes the accounts and saves them. Every change goes through here, and is undone if it can't be saved.
    private func update(_ change: (inout [DeviceAccountItem]) -> Void) throws {
        guard !isLocked else { throw DeviceAccountsError.unavailable }
        var changed = items
        change(&changed)
        guard changed != items else { return }
        if isUnreadable {
            try storage.setAside()
            isUnreadable = false
        }
        try storage.save(changed)
        items = changed
        onChange?()
    }
}
