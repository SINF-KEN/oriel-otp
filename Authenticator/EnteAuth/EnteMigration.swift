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

enum EnteMigrationError: Error, LocalizedError, Equatable {
    case sameServer
    case noAccounts
    case sessionEnded
    case changedWhileMoving
    case notVerified

    var errorDescription: String? {
        switch self {
        case .sameServer:
            return String(localized: "The old and new server are the same.", comment: "Ente migration error")
        case .noAccounts:
            return String(localized: "There are no accounts on the old server.", comment: "Ente migration error")
        case .sessionEnded:
            return String(
                localized: "The old server ended this session. Open Sync from Ente Auth and enter your password, then try again.",
                comment: "Ente migration error")
        case .changedWhileMoving:
            return String(
                localized: "Your accounts changed during the move. Nothing was switched. Try again to copy the changes too.",
                comment: "Ente migration error")
        case .notVerified:
            return String(
                localized:
                    "Some accounts didn't reach the new server. Nothing was switched, and your accounts are still on the old server. Try again.",
                comment: "Ente migration error")
        }
    }
}

/// What moving to another server would do, worked out from the decrypted entities of both servers.
struct EnteMigrationPlan: Equatable {

    /// The plain text of each account on the old server that could be decrypted, including those in Ente's trash.
    let accounts: [String]
    /// The accounts the new server doesn't have yet.
    let toCopy: [String]
    /// Accounts that couldn't be decrypted, which can't be copied.
    let unreadable: Int

    /// `nil` is an entity that couldn't be decrypted.
    init(source: [String?], target: [String?]) {
        accounts = source.compactMap { $0 }
        let onTarget = Set(target.compactMap { $0 })
        toCopy = accounts.filter { !onTarget.contains($0) }
        unreadable = source.count - accounts.count
    }

    var alreadyOnTarget: Int { accounts.count - toCopy.count }

    var trashed: Int { accounts.count(where: { EnteEntry(rawData: $0).isTrashed }) }

    /// Whether every account that could be read is in `target`.
    func isComplete(on target: [String?]) -> Bool {
        Set(accounts).isSubset(of: target.compactMap { $0 })
    }
}

enum EnteMigration {

    /// Encrypts each account with the new server's key and uploads it. The plain text is copied as it is, so Ente's
    /// tags, notes, pins and trash stay. If this stops halfway, a new plan skips what reached the server.
    static func copy(
        _ accounts: [String], api: EnteAPIClient, token: String, authenticatorKey: Data,
        onProgress: (Int) -> Void
    ) async throws {
        for (index, rawData) in accounts.enumerated() {
            try Task.checkCancellation()
            let encrypted = try EnteAuthenticatorSync.encrypt(rawData, authenticatorKey: authenticatorKey)
            _ = try await EnteAuthenticatorSync.signedIn {
                try await api.createAuthenticatorEntity(token: token, encryptedData: encrypted.encryptedData, header: encrypted.header)
            }
            onProgress(index + 1)
        }
    }
}
