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

import AppIntents
import Foundation

/// Opens the app's add account sheet. In place of the Home Screen quick action on iOS.
struct AddAccountIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Account"
    static let description = IntentDescription("Opens Oriel OTP to add an account to your YubiKey.")

    @MainActor func perform() async throws -> some IntentResult {
        QuickAction.addAccount.perform()
        return .result()
    }
}

/// Copies the code of an account on the plugged-in YubiKey, without opening the app.
struct CopyCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Code"
    static let description = IntentDescription("Copies the code of an account on your YubiKey to the clipboard. The YubiKey has to be plugged in.")

    @Parameter(title: "Account")
    var account: YubiKeyAccountEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Copy the code for \(\.$account)")
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let code = try await YubiKeyAccess.code(for: account.id)
        Platform.copy(code)
        return .result(value: code)
    }
}

struct OrielOTPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CopyCodeIntent(),
                    phrases: ["Copy a code with \(.applicationName)",
                              "Copy a YubiKey code with \(.applicationName)"],
                    shortTitle: "Copy Code",
                    systemImageName: "doc.on.doc")
        AppShortcut(intent: AddAccountIntent(),
                    phrases: ["Add an account to \(.applicationName)"],
                    shortTitle: "Add Account",
                    systemImageName: "plus")
    }
}

/// An account on the plugged-in YubiKey, for Shortcuts and Spotlight.
struct YubiKeyAccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "YubiKey Account"
    static let defaultQuery = YubiKeyAccountQuery()

    /// The credential id, as the YubiKey stores it, e.g. "GitHub:alice@example.com".
    let id: String
    let issuer: String?
    let accountName: String

    var displayRepresentation: DisplayRepresentation {
        if let issuer {
            DisplayRepresentation(title: "\(issuer)", subtitle: "\(accountName)")
        } else {
            DisplayRepresentation(title: "\(accountName)")
        }
    }
}

struct YubiKeyAccountQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [YubiKeyAccountEntity] {
        try await YubiKeyAccess.accounts().filter { identifiers.contains($0.id) }
    }

    @MainActor func suggestedEntities() async throws -> [YubiKeyAccountEntity] {
        try await YubiKeyAccess.accounts()
    }
}

/// Reads the plugged-in YubiKey for Shortcuts, connecting to it if the app isn't already.
@MainActor enum YubiKeyAccess {

    enum AccessError: LocalizedError {
        case noYubiKey
        case accountNotFound

        var errorDescription: String? {
            switch self {
            case .noYubiKey:
                String(localized: "Plug in your YubiKey and try again.", comment: "Mac Shortcuts error")
            case .accountNotFound:
                String(localized: "The account isn't on the plugged-in YubiKey.", comment: "Mac Shortcuts error")
            }
        }
    }

    static func accounts() async throws -> [YubiKeyAccountEntity] {
        try await withSession { session in
            try await session.calculateAll().map { credential, _ in
                YubiKeyAccountEntity(id: credential.id, issuer: credential.issuer, accountName: credential.accountName)
            }
        }
    }

    static func code(for id: String) async throws -> String {
        try await withSession { session in
            guard let credential = try await session.calculateAll().map(\.0).first(where: { $0.id == id }) else {
                throw AccessError.accountNotFound
            }
            if credential.requiresTouch {
                TouchPrompt.show(for: credential.issuer ?? credential.accountName)
            }
            defer { TouchPrompt.hide() }
            return try await session.calculate(credential: credential).code
        }
    }

    private static func withSession<T>(_ body: (OATHSession) async throws -> T) async throws -> T {
        let manager = ConnectionManager.shared
        let wasSuspended = manager.areWiredConnectionsSuspended
        manager.resumeWiredConnections()
        defer {
            // Let go of the YubiKey again if nothing else in the app is using it.
            if wasSuspended && !MainWindowState.shared.isVisible {
                Task { await manager.suspendWiredConnections() }
            }
        }
        if manager.wiredConnection == nil {
            let connection = Task { try await manager.nextWiredConnection() }
            let timeout = Task {
                try await Task.sleep(for: .seconds(5))
                connection.cancel()
            }
            defer { timeout.cancel() }
            guard (try? await connection.value) != nil else { throw AccessError.noYubiKey }
        }
        return try await body(OATHSessionHandler.shared.anySession())
    }
}

#endif
