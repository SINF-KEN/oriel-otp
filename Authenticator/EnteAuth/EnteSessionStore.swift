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

/// What's needed to read the accounts again without signing in: the auth token and the authenticator key.
/// The master key and the password are never stored.
nonisolated struct EnteSavedSession: Codable, Sendable, Equatable {
    let server: URL
    let email: String
    let token: String
    let authenticatorKey: Data
}

/// Keeps a signed in Ente session in the keychain, protected by Face ID, Touch ID or the device passcode.
///
/// Saving is opt in. The authenticator key decrypts every secret in Ente Auth, so it is only stored when the
/// device can protect it and the item never leaves the device.
struct EnteSessionStore {

    private static let account = "session"
    private static let emailKey = "EnteAuth.SavedSessionEmail"

    private let secureStore: SecureStore
    private let defaults: UserDefaults

    init(service: String = "EnteAuth", defaults: UserDefaults = .standard) {
        self.secureStore = SecureStore(secureStoreQueryable: PasswordQueryable(service: service))
        self.defaults = defaults
    }

    /// Saving requires a passcode, Face ID or Touch ID on the device.
    static var canSave: Bool {
        PasswordPreferences.evaluatedAuthenticationType() != .none
    }

    /// The email of the saved session, readable without authenticating.
    var savedEmail: String? {
        guard secureStore.hasValue(for: Self.account) else { return nil }
        return defaults.string(forKey: Self.emailKey)
    }

    func save(_ session: EnteSavedSession) throws {
        let data = try JSONEncoder().encode(session)
        try secureStore.setValue(data, useAuthentication: true, for: Self.account)
        defaults.set(session.email, forKey: Self.emailKey)
    }

    /// Asks for Face ID, Touch ID or the passcode.
    func load() async throws -> EnteSavedSession {
        let data: Data = try await secureStore.getValue(for: Self.account)
        return try JSONDecoder().decode(EnteSavedSession.self, from: data)
    }

    func remove() {
        try? secureStore.removeValue(for: Self.account)
        defaults.removeObject(forKey: Self.emailKey)
    }
}
