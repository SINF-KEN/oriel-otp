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

/// Reads the plugged-in YubiKey for Shortcuts, connecting to it if the app isn't already.
@MainActor enum YubiKeyAccess {

    enum AccessError: LocalizedError {
        case noYubiKey
        case accountNotFound
        case locked

        var errorDescription: String? {
            switch self {
            case .noYubiKey:
                String(localized: "Plug in your YubiKey and try again.", comment: "Mac Shortcuts error")
            case .accountNotFound:
                String(localized: "The account isn't on the plugged-in YubiKey.", comment: "Mac Shortcuts error")
            case .locked:
                String(localized: "Unlock Oriel OTP and try again.", comment: "Mac Shortcuts error when the app is locked")
            }
        }
    }

    static func accounts() async throws -> [AccountEntity] {
        try await withSession { session in
            try await session.calculateAll().map { credential, _ in
                AccountEntity(id: credential.id, issuer: credential.issuer, accountName: credential.accountName)
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

    /// Shortcuts don't get past the app lock. Touch ID or the Mac's password is asked for when it unlocks the app,
    /// a code or password has to be entered in the app.
    private static func unlockApp() async throws {
        let lock = AppLock.shared
        if lock.isLocked && lock.method == .device {
            await lock.unlockWithDeviceOwner()
        }
        guard !lock.isLocked else { throw AccessError.locked }
    }

    private static func withSession<T>(_ body: (OATHSession) async throws -> T) async throws -> T {
        try await unlockApp()
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
