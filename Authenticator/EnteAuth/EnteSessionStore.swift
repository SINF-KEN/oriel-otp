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
import LocalAuthentication
import YubiKit

/// What's needed to read and change accounts without signing in again: the auth token and the authenticator key.
/// The master key and the password are never stored.
nonisolated struct EnteSavedSession: Codable, Sendable, Equatable {
    let server: URL
    let email: String
    let token: String
    let authenticatorKey: Data
}

/// The saved Ente account, readable without authenticating.
nonisolated struct EnteSavedAccount: Sendable, Equatable {
    let email: String
    let server: URL
    /// Whether the token and key are in the keychain. False once the server rejected the token or Face ID or
    /// Touch ID changed, until the password is entered again.
    let hasSession: Bool
}

/// Where the session is kept: the keychain in the app, memory in the tests.
nonisolated protocol EnteSessionKeychain: Sendable {
    func hasValue(for userAccount: String) -> Bool
    func setValue(_ value: Data, useAuthentication: Bool, for userAccount: String) throws
    func getValue(for userAccount: String) async throws -> Data
    func removeValue(for userAccount: String) throws
}

nonisolated extension SecureStore: EnteSessionKeychain {}

/// Keeps the Ente account signed in, like Ente's own apps do. The token and the authenticator key are kept in the
/// keychain, only on this device and protected by Face ID or Touch ID, or Touch ID or the password on the Mac.
///
/// The email and server are kept in the app's preferences so the account can be shown without authenticating. When
/// the server rejects the token, only the token and key are forgotten, so the account is still shown and signing
/// in again only needs the password.
struct EnteSessionStore {

    private static let account = "session"
    private static let emailKey = "EnteAuth.SavedSessionEmail"
    private static let serverKey = "EnteAuth.SavedSessionServer"
    /// Set when the session was saved with the current access control. Earlier versions protected it on the Mac
    /// with Touch ID only, and updating an item keeps its access control.
    private static let versionKey = "EnteAuth.SavedSessionVersion"
    private static let version = 2

    private let keychain: EnteSessionKeychain
    private let defaults: UserDefaults
    /// Whether the device can protect a saved session.
    let canSave: Bool

    init(service: String = "EnteAuth", defaults: UserDefaults = .standard) {
        #if os(macOS)
        // Not every Mac has Touch ID, so the Mac's password unlocks the session too.
        let accessControl: SecAccessControlCreateFlags = .userPresence
        #else
        let accessControl: SecAccessControlCreateFlags = .biometryCurrentSet
        #endif
        self.init(keychain: SecureStore(secureStoreQueryable: PasswordQueryable(service: service, accessControl: accessControl)),
                  defaults: defaults, canSave: Self.deviceCanSave)
    }

    init(keychain: EnteSessionKeychain, defaults: UserDefaults, canSave: Bool) {
        self.keychain = keychain
        self.defaults = defaults
        self.canSave = canSave
    }

    /// Saving requires Face ID or Touch ID, or on the Mac Touch ID or a password.
    private static var deviceCanSave: Bool {
        #if os(macOS)
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        #else
        PasswordPreferences.evaluatedAuthenticationType() != .none
        #endif
    }

    var savedAccount: EnteSavedAccount? {
        guard let email = defaults.string(forKey: Self.emailKey) else { return nil }
        // Sessions saved before the server was stored were saved with the server of the sign in screen.
        let server = (defaults.string(forKey: Self.serverKey) ?? defaults.string(forKey: "EnteAuth.ServerURL"))
            .flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? EnteAPIClient.defaultServer
        return EnteSavedAccount(email: email, server: server, hasSession: keychain.hasValue(for: Self.account))
    }

    /// The email of the saved session, nil if there's no session to add accounts with.
    var savedEmail: String? {
        guard let savedAccount, savedAccount.hasSession else { return nil }
        return savedAccount.email
    }

    /// Replaces any saved session. The keychain item is deleted and added again, as updating it would keep the
    /// access control it was first saved with.
    func save(_ session: EnteSavedSession) throws {
        let data = try JSONEncoder().encode(session)
        try keychain.removeValue(for: Self.account)
        try keychain.setValue(data, useAuthentication: true, for: Self.account)
        defaults.set(session.email, forKey: Self.emailKey)
        defaults.set(session.server.absoluteString, forKey: Self.serverKey)
        defaults.set(Self.version, forKey: Self.versionKey)
    }

    /// Returns the token and the authenticator key after asking for Face ID, Touch ID or the Mac's password.
    /// Throws `EnteAuthenticatorSyncError.signedOut` when there's no session to unlock, e.g. because Face ID or
    /// Touch ID changed since it was saved. A session saved by an earlier version is saved again with the current
    /// access control.
    func unlock() async throws -> EnteSavedSession {
        let session = try await read()
        if defaults.integer(forKey: Self.versionKey) < Self.version {
            // If this fails the old item is kept, or the password is asked for on the next launch.
            try? save(session)
        }
        return session
    }

    private func read() async throws -> EnteSavedSession {
        let data: Data
        do {
            data = try await keychain.getValue(for: Self.account)
        } catch SecureStoreError.itemNotFound {
            throw EnteAuthenticatorSyncError.signedOut
        }
        return try JSONDecoder().decode(EnteSavedSession.self, from: data)
    }

    /// Forgets the token and the key but keeps the account, for when the server no longer accepts the token.
    func forgetSession() {
        try? keychain.removeValue(for: Self.account)
        defaults.removeObject(forKey: Self.versionKey)
    }

    /// Forgets the account, the token and the key.
    func remove() {
        forgetSession()
        defaults.removeObject(forKey: Self.emailKey)
        defaults.removeObject(forKey: Self.serverKey)
    }

    /// Signs out: forgets the account on this device, then asks Ente's server to end the session. The token is
    /// unlocked first so the session can be ended; if that's cancelled the account is still forgotten here. Returns
    /// once nothing is left on the device, without waiting for the server, which only ever sees the old token.
    /// The copy of the accounts in the vault is deleted too, with changes that weren't uploaded yet.
    @MainActor func signOut(watch: WatchAccountSync = .shared, cloud: EnteCloud = .shared) async {
        let saved = savedAccount?.hasSession == true ? try? await read() : nil
        remove()
        cloud.remove()
        watch.disable()
        guard let saved, let api = try? EnteAPIClient(server: saved.server) else { return }
        Task { try? await api.logout(token: saved.token) }
    }
}
