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

import AppIntents
import CoreSpotlight
import Foundation
#if os(iOS)
    import UIKit
#endif

/// An account for Shortcuts, Siri and Spotlight: one in Ente Auth or on this device, whose codes the app calculates,
/// or on the Mac one on the plugged-in YubiKey.
struct AccountEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Account", comment: "Shortcuts type name"))
    static let defaultQuery = AccountQuery()

    /// `Account.accountId`: "ente/<id>", "device/<id>", or the credential id of a YubiKey account, e.g.
    /// "GitHub:alice@example.com".
    let id: String
    let issuer: String?
    let accountName: String
    var tags: [String] = []

    var title: String {
        if let issuer, !issuer.isEmpty { return issuer }
        return accountName
    }

    var displayRepresentation: DisplayRepresentation {
        if let issuer, !issuer.isEmpty {
            DisplayRepresentation(title: "\(issuer)", subtitle: "\(accountName)")
        } else {
            DisplayRepresentation(title: "\(accountName)")
        }
    }

    /// The names and tags, never the code or the secret.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.displayName = title
        attributes.contentDescription = issuer?.isEmpty == false ? accountName : nil
        attributes.keywords = [issuer, accountName].compactMap { $0 } + tags
        return attributes
    }

    var isOnYubiKey: Bool {
        !id.hasPrefix(CalculatedAccounts.entePrefix) && !id.hasPrefix(CalculatedAccounts.devicePrefix)
    }
}

/// Shortcuts and Siri get no account names while the app is locked, and Siri and Spotlight suggest accounts only with
/// **Show accounts in Spotlight** on, see `AccountSpotlight`.
struct AccountQuery: EntityStringQuery {

    /// Replaced in the tests.
    /// The app lock, or on iOS the device: with the app lock off, Siri on the Lock Screen gets no account names either.
    var isLocked: @MainActor @Sendable () -> Bool = {
        #if os(iOS)
            AppLock.shared.isLocked || !UIApplication.shared.isProtectedDataAvailable
        #else
            AppLock.shared.isLocked
        #endif
    }
    var suggestsAccounts: @MainActor @Sendable () -> Bool = { AccountSpotlight.shared.isEnabled }
    var calculatedEntities: @MainActor @Sendable () -> [AccountEntity] = { CalculatedAccounts.entities() }

    /// While the app is locked, the accounts asked for come back without their names, so a shortcut that copies a
    /// code still runs and unlocks the app first.
    @MainActor func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        if isLocked() {
            return identifiers.map(Self.unnamedEntity)
        }
        return try await allEntities(includingYubiKey: identifiers.contains { !Self.isCalculated($0) })
            .filter { identifiers.contains($0.id) }
    }

    @MainActor func entities(matching string: String) async throws -> [AccountEntity] {
        guard !isLocked() else { return [] }
        return try await allEntities(includingYubiKey: true).filter {
            $0.title.localizedStandardContains(string) || $0.accountName.localizedStandardContains(string)
                || $0.tags.contains { $0.localizedStandardContains(string) }
        }
    }

    /// Also what Siri and Spotlight suggest Copy Code for, so empty unless the accounts are shown in Spotlight.
    @MainActor func suggestedEntities() async throws -> [AccountEntity] {
        guard !isLocked(), suggestsAccounts() else { return [] }
        return try await allEntities(includingYubiKey: true)
    }

    /// An account known only by the id it was asked for. A YubiKey account's id is its name, which the caller already
    /// has.
    private static func unnamedEntity(_ id: String) -> AccountEntity {
        isCalculated(id)
            ? AccountEntity(id: id, issuer: nil, accountName: String(localized: "Account", comment: "Shortcuts type name"))
            : AccountEntity(id: id, issuer: nil, accountName: id)
    }

    private static func isCalculated(_ id: String) -> Bool {
        id.hasPrefix(CalculatedAccounts.entePrefix) || id.hasPrefix(CalculatedAccounts.devicePrefix)
    }

    @MainActor private func allEntities(includingYubiKey: Bool) async throws -> [AccountEntity] {
        var entities = calculatedEntities()
        #if os(macOS)
            if includingYubiKey {
                do {
                    entities += try await YubiKeyAccess.accounts()
                } catch {
                    // Without a YubiKey there are still the other accounts. With none at all, say why.
                    if entities.isEmpty { throw error }
                }
            }
        #endif
        return entities.sorted {
            ($0.title.lowercased(), $0.accountName.lowercased()) < ($1.title.lowercased(), $1.accountName.lowercased())
        }
    }
}

/// The accounts whose codes the app calculates: the ones in Ente Auth and on this device.
@MainActor enum CalculatedAccounts {

    nonisolated static let entePrefix = "ente/"
    nonisolated static let devicePrefix = "device/"

    enum CodeError: LocalizedError {
        case accountNotFound
        case locked
        case yubiKeyOnly
        case protected

        var errorDescription: String? {
            switch self {
            case .accountNotFound:
                String(localized: "The account isn't in Oriel OTP any more.", comment: "Shortcuts error")
            case .locked:
                String(localized: "Unlock Oriel OTP and try again.", comment: "Mac Shortcuts error when the app is locked")
            case .yubiKeyOnly:
                String(
                    localized: "Open Oriel OTP to get the codes of accounts on a YubiKey.",
                    comment: "Shortcuts error on iOS for a YubiKey account")
            case .protected:
                String(
                    localized: "This account asks for Face ID, Touch ID or the passcode. Copy its code in Oriel OTP.",
                    comment: "Shortcuts error when checking the device owner for a protected account failed")
            }
        }
    }

    static func entities() -> [AccountEntity] {
        DeviceAccounts.shared.loadIfLocked()
        let cloud = EnteCloud.shared.accounts.map {
            AccountEntity(id: entePrefix + $0.id, issuer: $0.code.issuer, accountName: $0.code.accountName, tags: $0.code.tags)
        }
        let device = DeviceAccounts.shared.accounts.map {
            AccountEntity(id: devicePrefix + $0.id, issuer: $0.code.issuer, accountName: $0.code.accountName, tags: $0.code.tags)
        }
        return cloud + device
    }

    /// The current code, or the next one of a counter-based account, which moves its counter on.
    static func code(for id: String) throws -> String {
        if id.hasPrefix(entePrefix) {
            let vaultID = String(id.dropFirst(entePrefix.count))
            guard let code = EnteCloud.shared.accounts.first(where: { $0.id == vaultID })?.code else { throw CodeError.accountNotFound }
            if code.kind == .hotp {
                guard let otp = EnteCloud.shared.nextHOTPCode(vaultID) else { throw CodeError.accountNotFound }
                return otp
            }
            return code.code(at: AppClock.now).code
        }
        if id.hasPrefix(devicePrefix) {
            let deviceID = String(id.dropFirst(devicePrefix.count))
            DeviceAccounts.shared.loadIfLocked()
            guard let code = DeviceAccounts.shared.accounts.first(where: { $0.id == deviceID })?.code else {
                throw CodeError.accountNotFound
            }
            if code.kind == .hotp {
                guard let otp = DeviceAccounts.shared.nextHOTPCode(deviceID) else { throw DeviceAccountsError.unavailable }
                return otp
            }
            return code.code(at: AppClock.now).code
        }
        throw CodeError.yubiKeyOnly
    }
}

/// Copies an account's code, without opening the app unless it has to be unlocked.
struct CopyCodeIntent: AppIntent {
    static let title = LocalizedStringResource("Copy Code", comment: "Shortcuts action")
    // App Store Connect turns down an intent description that names the platform (ITMS-90626), so each one has its own.
    #if os(macOS)
        static let description = IntentDescription(
            LocalizedStringResource(
                "Copies the code of an account to the clipboard. Accounts on a YubiKey work while it's plugged in.",
                comment: "Shortcuts action description"))
    #else
        static let description = IntentDescription(
            LocalizedStringResource("Copies the code of an account to the clipboard.", comment: "Shortcuts action description"))
    #endif

    /// With the app lock off, Siri could otherwise copy a code, and name the accounts, on a locked device.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: LocalizedStringResource("Account", comment: "Shortcuts parameter"))
    var account: AccountEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Copy the code for \(\.$account)")
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try await unlockApp()
        // Asked for while the app was locked, the account came without its name.
        let title = CalculatedAccounts.entities().first { $0.id == account.id }?.title ?? account.title
        guard await ProtectedAccounts.shared.unlock(account.id, title: title) else { throw CalculatedAccounts.CodeError.protected }
        let code: String
        #if os(macOS)
            if account.isOnYubiKey {
                code = try await YubiKeyAccess.code(for: account.id)
            } else {
                code = try CalculatedAccounts.code(for: account.id)
            }
        #else
            code = try CalculatedAccounts.code(for: account.id)
        #endif
        Platform.copy(code)
        AccountUsage.shared.recordUse(of: account.id)
        // The code isn't said, so it isn't read out or shown with Hide codes on. It is the result, for the next action.
        return .result(
            value: code,
            dialog: IntentDialog(
                LocalizedStringResource(
                    "Copied the code for \(title).", comment: "Shortcuts result. The placeholder is the account's name.")))
    }

    /// Shortcuts don't get past the app lock. On iOS, where the app locks in the background, Shortcuts opens it to be
    /// unlocked. On the Mac, Touch ID or the Mac's password is asked for when it unlocks the app, a code or password
    /// has to be entered in the app.
    @MainActor private func unlockApp() async throws {
        let lock = AppLock.shared
        #if os(iOS)
            guard lock.isLocked else { return }
            let dialog = IntentDialog(
                LocalizedStringResource("Unlock Oriel OTP to copy the code.", comment: "Shortcuts prompt when the app is locked"))
            if #available(iOS 26.0, *) {
                try await continueInForeground(dialog, alwaysConfirm: false)
            } else {
                try await requestToContinueInForeground(dialog)
            }
            // The app asks for Face ID or its code once it's in front.
            let deadline = ContinuousClock.now + .seconds(120)
            while lock.isLocked {
                guard ContinuousClock.now < deadline else { throw CalculatedAccounts.CodeError.locked }
                try await Task.sleep(for: .milliseconds(250))
            }
        #else
            if lock.isLocked && lock.method == .device {
                await lock.unlockWithDeviceOwner()
            }
            guard !lock.isLocked else { throw CalculatedAccounts.CodeError.locked }
        #endif
    }
}

#if os(iOS)
    extension CopyCodeIntent: ForegroundContinuableIntent {
        @available(iOS 26.0, *)
        static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    }
#endif

/// Opens the app on an account, e.g. from a Spotlight result.
struct OpenAccountIntent: OpenIntent {
    static let title = LocalizedStringResource("Open Account", comment: "Shortcuts action")
    static let description = IntentDescription(
        LocalizedStringResource("Opens Oriel OTP on an account.", comment: "Shortcuts action description"))

    @Parameter(title: LocalizedStringResource("Account", comment: "Shortcuts parameter"))
    var target: AccountEntity

    @MainActor func perform() async throws -> some IntentResult {
        QuickActionCenter.shared.pendingAccountID = target.id
        #if os(macOS)
            QuickAction.openMainWindow()
        #endif
        return .result()
    }
}

struct OrielOTPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CopyCodeIntent(),
            phrases: [
                "Copy a code with \(.applicationName)",
                "Copy the \(\.$account) code with \(.applicationName)",
                "Copy my \(\.$account) code in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("Copy Code", comment: "Shortcuts action"),
            systemImageName: "doc.on.doc")
        #if os(iOS)
            AppShortcut(
                intent: ScanNFCYubiKeyIntent(),
                phrases: [
                    "Scan a YubiKey with \(.applicationName)",
                    "Show my codes in \(.applicationName)"
                ],
                shortTitle: "Scan NFC YubiKey",
                systemImageName: "wave.3.right")
            AppShortcut(
                intent: AddAccountIntent(),
                phrases: [
                    "Add an account to \(.applicationName)",
                    "Add a YubiKey account with \(.applicationName)"
                ],
                shortTitle: "Add Account",
                systemImageName: "plus")
        #else
            AppShortcut(
                intent: AddAccountIntent(),
                phrases: ["Add an account to \(.applicationName)"],
                shortTitle: "Add Account",
                systemImageName: "plus")
        #endif
    }
}
