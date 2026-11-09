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

/// Moves the Ente Auth accounts from one server to another, e.g. from Ente's to a self-hosted one.
///
/// The new server is only used once every account has been read back from it. Until then nothing changes on this
/// device, and nothing is ever deleted from the old server.
@Observable final class EnteMigrationViewModel {

    enum Side: Equatable {
        case source
        case target
    }

    enum Phase: Equatable {
        case servers
        case signIn(Side)
        case emailCode(Side)
        case secondFactor(Side, totp: Bool, passkey: Bool)
        case review
        case moving
        case finished
    }

    /// A signed in account. `isSaved` is the session the app stays signed in with, which isn't ended when the view goes away.
    private struct SignedInAccount {
        let api: EnteAPIClient
        let email: String
        let token: String
        var authenticatorKey: Data?
        let isSaved: Bool
    }

    var phase: Phase = .servers
    var from: String
    var to = ""
    var email = ""
    var password = ""
    var code = ""
    var isBusy = false
    /// Whether the password is being turned into keys, the part of signing in that can take a few seconds.
    var isDerivingKeys = false
    var error: Error?
    private(set) var plan: EnteMigrationPlan?
    /// How many accounts of the plan have been uploaded.
    private(set) var copied = 0
    /// Whether this device now uses the new server.
    private(set) var didSwitch = false

    @ObservationIgnored private(set) var flow: EnteLoginFlow?
    @ObservationIgnored private var sourceAPI: EnteAPIClient?
    @ObservationIgnored private var targetAPI: EnteAPIClient?
    @ObservationIgnored private var source: SignedInAccount?
    @ObservationIgnored private var target: SignedInAccount?
    @ObservationIgnored private let store: EnteSessionStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let cloud: EnteCloud
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: EnteSessionStore = EnteSessionStore(), defaults: UserDefaults = .standard, session: URLSession = .ente, cloud: EnteCloud = .shared) {
        self.store = store
        self.defaults = defaults
        self.session = session
        self.cloud = cloud
        from = (store.savedAccount?.server ?? EnteAPIClient.defaultServer).absoluteString
    }

    var canStart: Bool {
        !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The server accounts can be created on: the new one, unless it's Ente's own.
    var signUpServer: URL? {
        EnteSignUpViewModel.server(from: to)
    }

    var canSignIn: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    var passkeyURL: URL? { flow?.passkeyURL }

    var fromHost: String { Self.host(of: from) }

    var toHost: String { Self.host(of: to) }

    var sourceEmail: String? { source?.email }

    var targetEmail: String? { target?.email }

    /// Whether this device will use the new server afterwards. A saved account on a third server is left alone.
    var willSwitch: Bool {
        store.canSave && (source?.isSaved == true || store.savedAccount == nil)
    }

    private static func host(of server: String) -> String {
        (try? EnteAPIClient.serverURL(from: server))?.host ?? server
    }

    // MARK: - Servers

    /// Checks the servers and reads the old one, with the saved session if that's the server the app uses.
    func start() {
        guard canStart else { return }
        run {
            let from = try EnteAPIClient.serverURL(from: self.from)
            let to = try EnteAPIClient.serverURL(from: self.to)
            guard !EnteAPIClient.isSameServer(from, to) else { throw EnteMigrationError.sameServer }
            let sourceAPI = try EnteAPIClient(server: from, session: self.session)
            self.sourceAPI = sourceAPI
            self.targetAPI = try EnteAPIClient(server: to, session: self.session)
            guard let account = self.store.savedAccount, EnteAPIClient.isSameServer(account.server, from) else {
                self.phase = .signIn(.source)
                return
            }
            guard account.hasSession else { throw EnteMigrationError.sessionEnded }
            let saved = try await self.store.unlock()
            // The server in the preferences said which session to use; the token is only ever sent to the server
            // the session was saved for.
            guard EnteAPIClient.isSameServer(saved.server, from) else {
                self.phase = .signIn(.source)
                return
            }
            self.cloud.use(saved)
            self.source = SignedInAccount(api: sourceAPI, email: saved.email, token: saved.token,
                                          authenticatorKey: saved.authenticatorKey, isSaved: true)
            try await self.continueToTarget()
        }
    }

    /// Goes back to the servers and ends the sessions of this move.
    func startOver() {
        reset()
        phase = .servers
    }

    // MARK: - Sign in

    private var side: Side? {
        switch phase {
        case .signIn(let side), .emailCode(let side), .secondFactor(let side, _, _): side
        default: nil
        }
    }

    func signIn() {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSignIn, let side, let api = side == .source ? sourceAPI : targetAPI else { return }
        let password = password
        run {
            // Only the flow keeps the password, while the email code or second factor it's needed for can be retried.
            defer { self.password = "" }
            if let flow = self.flow, flow.needsPassword, flow.email == email {
                try await self.handle(side) { try await flow.submitPassword(password) }
                return
            }
            self.flow = nil
            try await self.handle(side) {
                let (flow, step) = try await EnteLoginFlow.start(api: api, email: email, password: password) {
                    self.isDerivingKeys = $0
                }
                self.flow = flow
                return step
            }
        }
    }

    func submitCode() {
        guard let flow, let side, !code.isEmpty else { return }
        // Ente only takes ASCII digits; a pasted or hardware keyboard code can be in Arabic-Indic digits.
        let code = code.asciiDigits
        run {
            defer { self.code = "" }
            try await self.handle(side) { try await flow.submitCode(code) }
        }
    }

    func resendCode() {
        guard let flow else { return }
        run { try await flow.resendEmailCode() }
    }

    /// Call when the user returns from verifying the passkey in the browser.
    func checkPasskey() {
        guard let flow, let side else { return }
        run {
            try await self.handle(side) {
                guard let step = try await flow.checkPasskey() else { throw EnteSyncError.passkeyNotVerified }
                return step
            }
        }
    }

    /// Runs a step of the sign in. A wrong password goes back to the sign in screen, also after the email code.
    private func handle(_ side: Side, _ operation: () async throws -> EnteLoginStep) async throws {
        let step: EnteLoginStep
        do {
            step = try await operation()
        } catch EnteLoginError.incorrectPassword {
            password = ""
            phase = .signIn(side)
            throw EnteLoginError.incorrectPassword
        }
        if case .complete = step, let flow, let keys = flow.keys {
            // Known before anything else is awaited, so close() can end the session.
            let account = SignedInAccount(api: flow.api, email: flow.email, token: keys.token, authenticatorKey: nil, isSaved: false)
            switch side {
            case .source:
                end(source)
                source = account
            case .target:
                end(target)
                target = account
            }
        }
        // The view went away while signing in, after close() looked for sessions to end.
        guard !Task.isCancelled else {
            reset()
            throw CancellationError()
        }
        switch step {
        case .emailCode:
            phase = .emailCode(side)
        case .secondFactor(let totp, let passkey):
            phase = .secondFactor(side, totp: totp, passkey: passkey)
        case .complete:
            guard let flow, let keys = flow.keys else { throw EnteLoginError.invalidAccountData }
            self.flow = nil
            switch side {
            case .source:
                source?.authenticatorKey = try await EnteAuthenticatorSync.authenticatorKey(api: flow.api, keys: keys)
                try await continueToTarget()
            case .target:
                // A new account on a self-hosted server has no key yet, and this is the only moment the master key is here.
                target?.authenticatorKey = try await EnteAuthenticatorSync.authenticatorKeyCreatingIfNeeded(api: flow.api, keys: keys)
                try await loadPlan()
                phase = .review
            }
        }
    }

    /// Reads the old server first, so a server without accounts doesn't ask for the sign in to the new one.
    private func continueToTarget() async throws {
        guard let source else { throw CancellationError() }
        guard try await !rawData(of: source).isEmpty else {
            reset()
            phase = .servers
            throw EnteMigrationError.noAccounts
        }
        email = source.email
        password = ""
        phase = .signIn(.target)
    }

    // MARK: - Move

    /// Copies the accounts, checks they all reached the new server and starts using it. If anything goes wrong this
    /// device stays on the old server, and moving again only copies what's missing.
    func move() {
        guard phase == .review else { return }
        run {
            self.phase = .moving
            do {
                try await self.copyAndSwitch()
                self.phase = .finished
            } catch {
                self.phase = .review
                try? await self.loadPlan()
                throw error
            }
        }
    }

    private func copyAndSwitch() async throws {
        try await loadPlan()
        guard let plan, let source, let target, let key = target.authenticatorKey else { throw EnteLoginError.sessionExpired }
        copied = 0
        try await EnteMigration.copy(plan.toCopy, api: target.api, token: target.token, authenticatorKey: key) { self.copied = $0 }

        let onTarget = try await rawData(of: target)
        guard plan.isComplete(on: onTarget) else { throw EnteMigrationError.notVerified }
        // On the Mac the account list stays usable behind the settings, and switching replaces the vault.
        if source.isSaved, !Set(cloud.vault?.items.compactMap(\.rawData) ?? []).isSubset(of: onTarget.compactMap { $0 }) {
            throw EnteMigrationError.changedWhileMoving
        }

        if willSwitch {
            let saved = EnteSavedSession(server: target.api.server, email: target.email, token: target.token, authenticatorKey: key)
            try store.save(saved)
            defaults.set(target.api.server.absoluteString, forKey: EnteSyncViewModel.serverKey)
            didSwitch = true
            // The new session stays, and the keychain no longer has the old one, saved or not.
            self.target = nil
            self.source = nil
            revoke(source)
            cloud.use(saved)
            await cloud.sync(unlock: false)
        }
        reset()
    }

    /// Works out what to copy from the latest state of both servers. The saved session syncs first, so changes made
    /// on this device that are still waiting are moved too.
    private func loadPlan() async throws {
        guard let source, let target else { throw EnteLoginError.sessionExpired }
        let sourceData = try await rawData(of: source)
        plan = EnteMigrationPlan(source: sourceData, target: try await rawData(of: target))
    }

    private func rawData(of account: SignedInAccount) async throws -> [String?] {
        if account.isSaved {
            try await cloud.syncNow()
            guard !cloud.hasPendingChanges else { throw EnteMigrationError.changedWhileMoving }
        }
        guard let key = account.authenticatorKey else { return [] }
        return try await EnteAuthenticatorSync.decryptedEntities(api: account.api, token: account.token, authenticatorKey: key).map { $0.rawData }
    }

    // MARK: - Sessions

    /// Call when the view goes away. The sign in is abandoned so the password doesn't stay in memory, and the sessions
    /// of this move are ended so no token is left behind.
    func close() {
        task?.cancel()
        reset()
    }

    private func reset() {
        flow = nil
        password = ""
        code = ""
        plan = nil
        end(source)
        end(target)
        source = nil
        target = nil
    }

    private func end(_ account: SignedInAccount?) {
        guard let account, !account.isSaved else { return }
        revoke(account)
    }

    private func revoke(_ account: SignedInAccount) {
        let api = account.api
        let token = account.token
        Task { try? await api.logout(token: token) }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        task = Task {
            defer { isBusy = false }
            do {
                try await operation()
            } catch {
                // Cancelled by close(), the view is gone.
                guard !Task.isCancelled else { return }
                self.error = EnteSyncError(error)
            }
        }
    }
}
